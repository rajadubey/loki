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

/// Every machine by name, containers expanded: what connect, the menu and health checks use.
public typealias MachineList = [String: Machine]

/// machine.json as written. Every top-level key is a machine with its own `ip` and `services`, except
/// two: `containers` maps more machines' names to their IPs, and each of those gets the top-level
/// `services`. A file without those two keys (the original format) reads as it always did.
public struct MachineFile: Codable, Equatable, Sendable {
    public var machines: MachineList
    public var containers: [String: String]
    public var services: [String: Ports]

    public init(machines: MachineList = [:], containers: [String: String] = [:], services: [String: Ports] = [:]) {
        self.machines = machines
        self.containers = containers
        self.services = services
    }

    /// The top-level keys that aren't machines, so no machine can be called that.
    public static let reservedNames: Set<String> = ["containers", "services"]

    /// Each container with the shared services, plus the machines of their own. Of a container and a
    /// machine with the same name, which validation refuses, the machine wins, as in the CLI.
    public var all: MachineList {
        machines.merging(containers.mapValues { Machine(ip: $0, services: services) }) { own, _ in own }
    }

    private struct Key: CodingKey {
        let stringValue: String
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.init(stringValue) }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        containers = try c.decodeIfPresent([String: String].self, forKey: Key("containers")) ?? [:]
        services = try c.decodeIfPresent([String: Ports].self, forKey: Key("services")) ?? [:]
        machines = [:]
        for key in c.allKeys where !Self.reservedNames.contains(key.stringValue) {
            machines[key.stringValue] = try c.decode(Machine.self, forKey: key)
        }
    }

    /// `containers` and `services` only when set, so a file in the original format stays in it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        if !containers.isEmpty { try c.encode(containers, forKey: Key("containers")) }
        if !services.isEmpty { try c.encode(services, forKey: Key("services")) }
        for (name, machine) in machines { try c.encode(machine, forKey: Key(name)) }
    }
}

// MARK: - Validation

public enum ValidationIssue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidMachineName(String)
    case reservedMachineName(String)
    case listedTwice(String)
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
        case .reservedMachineName(let n):
            "A machine can't be called “\(n)”: machine.json uses “containers” and “services” for shared services."
        case .listedTwice(let n):
            "“\(n)” is in containers and is also a machine of its own; keep one."
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

/// Everything wrong with machine.json, in a stable order. Empty means it is safe to save and render.
/// The shared services are checked once, as “Shared services”, not once per container.
public func validate(_ file: MachineFile) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    for name in Set(file.machines.keys).union(file.containers.keys).sorted() {
        if MachineFile.reservedNames.contains(name) {
            issues.append(.reservedMachineName(name))
        } else if name.wholeMatch(of: NamePattern.machine) == nil {
            issues.append(.invalidMachineName(name))
        }
        if let machine = file.machines[name] {
            if file.containers[name] != nil { issues.append(.listedTwice(name)) }
            issues += hostIssues(machine.ip, of: name) + serviceIssues(machine.services, of: name)
        } else if let ip = file.containers[name] {
            issues += hostIssues(ip, of: name)
        }
    }
    return issues + serviceIssues(file.services, of: "Shared services")
}

/// The same checks for machines with their services (containers already expanded).
public func validate(_ machines: MachineList) -> [ValidationIssue] {
    validate(MachineFile(machines: machines))
}

private func hostIssues(_ ip: String, of machine: String) -> [ValidationIssue] {
    if ip.trimmingCharacters(in: .whitespaces).isEmpty { return [.emptyIP(machine: machine)] }
    // checked untrimmed: render writes the ip verbatim, and "1.2.3.4 :80" breaks nginx
    if ip.wholeMatch(of: NamePattern.host) == nil || ip.hasPrefix("-") { return [.invalidIP(machine: machine, ip: ip)] }
    return []
}

private func serviceIssues(_ services: [String: Ports], of machine: String) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var byLocal: [Int: [String]] = [:]
    for (service, p) in services.sorted(by: { $0.key < $1.key }) {
        if service.wholeMatch(of: NamePattern.service) == nil {
            issues.append(.invalidServiceName(machine: machine, service: service))
        }
        guard let local = p.local, let remote = p.remote else {
            issues.append(.missingPort(machine: machine, service: service))
            continue
        }
        for port in [local, remote] where !(1...65535).contains(port) {
            issues.append(.portOutOfRange(machine: machine, service: service, port: port))
        }
        byLocal[local, default: []].append(service)
    }
    for (port, names) in byLocal.sorted(by: { $0.key < $1.key }) where names.count > 1 {
        issues.append(.duplicateLocalPort(machine: machine, port: port, services: names))
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
