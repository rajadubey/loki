import Foundation

/// Local and remote port of one proxied service. Optional because existing
/// machine.json files may carry nulls; such services are skipped, as in the CLI.
public struct Ports: Codable, Equatable, Hashable, Sendable {
    public var local: Int?
    public var remote: Int?

    public init(local: Int?, remote: Int?) {
        self.local = local
        self.remote = remote
    }
}

/// One entry of machine.json: `{ "ip": "...", "services": { "name": { "local": 8080, "remote": 80 } } }`.
public struct Machine: Codable, Equatable, Hashable, Sendable {
    public var ip: String
    public var services: [String: Ports]

    public init(ip: String, services: [String: Ports]) {
        self.ip = ip
        self.services = services
    }

    /// Services with both ports set, the ones that get an nginx block.
    public var ports: [String: ResolvedPorts] {
        services.compactMapValues { p in
            guard let l = p.local, let r = p.remote else { return nil }
            return ResolvedPorts(local: l, remote: r)
        }
    }
}

public struct ResolvedPorts: Equatable, Hashable, Sendable {
    public let local: Int
    public let remote: Int

    public init(local: Int, remote: Int) {
        self.local = local
        self.remote = remote
    }
}

/// machine.json as a whole: machine name -> machine.
public typealias MachineList = [String: Machine]

// MARK: - Validation

public enum ValidationIssue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidMachineName(String)
    case emptyIP(machine: String)
    case invalidIP(machine: String, ip: String)
    case invalidServiceName(machine: String, service: String)
    case missingPort(machine: String, service: String)
    case portOutOfRange(machine: String, service: String, port: Int)
    case duplicateLocalPort(machine: String, port: Int, services: [String])

    public var description: String {
        switch self {
        case .invalidMachineName(let n):
            "Machine name “\(n)” can only use letters, digits, “.”, “_” and “-”."
        case .emptyIP(let m):
            "\(m): enter an IP address or hostname."
        case .invalidIP(let m, let ip):
            "\(m): “\(ip)” isn't a valid IP address or hostname."
        case .invalidServiceName(let m, let s):
            "\(m): service name “\(s)” can only use letters, digits, “_” and “-” (nginx uses it as an upstream name)."
        case .missingPort(let m, let s):
            "\(m) → \(s): set both the local and the remote port."
        case .portOutOfRange(let m, let s, let p):
            "\(m) → \(s): port \(p) must be between 1 and 65535."
        case .duplicateLocalPort(let m, let p, let ss):
            "\(m): local port \(p) is used by \(ss.joined(separator: ", "))."
        }
    }
}

enum NamePattern {
    // Machine names end up in ~/.loki/active and CLI arguments.
    static let machine = /^[A-Za-z0-9._-]+$/
    // Service names become nginx upstream names.
    static let service = /^[A-Za-z0-9_-]+$/
    // IPv4/IPv6 literal or hostname; no spaces, semicolons or braces that would break nginx config.
    static let host = /^[A-Za-z0-9.:\-\[\]]+$/
}

/// Everything wrong with a machine list, in a stable order. Empty means it is safe to save and render.
public func validate(_ machines: MachineList) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    for name in machines.keys.sorted() {
        let machine = machines[name]!
        if name.wholeMatch(of: NamePattern.machine) == nil { issues.append(.invalidMachineName(name)) }
        let ip = machine.ip
        if ip.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.emptyIP(machine: name))
        } else if ip.wholeMatch(of: NamePattern.host) == nil || ip.hasPrefix("-") {
            // checked untrimmed: render writes the ip verbatim, and "1.2.3.4 :80" breaks nginx
            issues.append(.invalidIP(machine: name, ip: machine.ip))
        }
        var byLocal: [Int: [String]] = [:]
        for service in machine.services.keys.sorted() {
            let p = machine.services[service]!
            if service.wholeMatch(of: NamePattern.service) == nil {
                issues.append(.invalidServiceName(machine: name, service: service))
            }
            guard let local = p.local, let remote = p.remote else {
                issues.append(.missingPort(machine: name, service: service))
                continue
            }
            for port in [local, remote] where !(1...65535).contains(port) {
                issues.append(.portOutOfRange(machine: name, service: service, port: port))
            }
            byLocal[local, default: []].append(service)
        }
        for (port, services) in byLocal.sorted(by: { $0.key < $1.key }) where services.count > 1 {
            issues.append(.duplicateLocalPort(machine: name, port: port, services: services))
        }
    }
    return issues
}

// MARK: - Search

/// Case-insensitive filter; recent machines first, then the rest alphabetically.
public func filterMachines(_ names: [String], query: String, recents: [String]) -> [String] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    let hits = names.filter { q.isEmpty || $0.lowercased().contains(q) }.sorted()
    let recent = recents.filter(hits.contains)
    return recent + hits.filter { !recent.contains($0) }
}
