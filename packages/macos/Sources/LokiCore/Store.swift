import Foundation

/// Locations inside the loki home folder (~/.loki), shared with the CLI.
public struct LokiPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".loki")) {
        self.home = home
    }

    public var machines: URL { home.appending(path: "machine.json") }
    public var active: URL { home.appending(path: "active") }
    /// Last generated config, kept for inspection like the CLI's TMP_CONF.
    public var generatedConf: URL { home.appending(path: "remote.conf") }
    public var log: URL { home.appending(path: "loki.log") }
    /// Shell-style settings file the CLI sources (`LOKI_SSH_HOST='...'`).
    public var config: URL { home.appending(path: "config") }
}

public enum StoreError: Error, LocalizedError, Equatable {
    case invalid([ValidationIssue])
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let issues): issues.map(\.description).joined(separator: "\n")
        case .unreadable(let why): why
        }
    }
}

/// Reads and writes machine.json and the active-machine marker.
public struct MachineStore: Sendable {
    public let paths: LokiPaths

    public init(paths: LokiPaths = LokiPaths()) {
        self.paths = paths
    }

    /// The machine list, or an empty list when machine.json doesn't exist yet.
    public func load() throws -> MachineList {
        guard FileManager.default.fileExists(atPath: paths.machines.path) else { return [:] }
        return try decode(Data(contentsOf: paths.machines), source: "machine.json")
    }

    /// Validates, backs up the previous file to machine.json.bak, then writes atomically.
    public func save(_ machines: MachineList) throws {
        let issues = validate(machines)
        guard issues.isEmpty else { throw StoreError.invalid(issues) }
        try ensureHome()
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.machines.path) {
            let backup = paths.home.appending(path: "machine.json.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: paths.machines, to: backup)
        }
        try Self.encode(machines).write(to: paths.machines, options: .atomic)
    }

    /// Reads a machine.json from anywhere; throws if it isn't valid JSON or fails validation.
    public func importMachines(from url: URL) throws -> MachineList {
        let machines = try decode(Data(contentsOf: url), source: url.lastPathComponent)
        try save(machines)
        return machines
    }

    public func exportMachines(to url: URL) throws {
        try Self.encode(try load()).write(to: url, options: .atomic)
    }

    public func activeName() -> String? {
        guard let text = try? String(contentsOf: paths.active, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Writes (or with nil, removes) ~/.loki/active, in the CLI's format (name + newline).
    public func setActive(_ name: String?) throws {
        if let name {
            try ensureHome()
            try Data((name + "\n").utf8).write(to: paths.active, options: .atomic)
        } else if FileManager.default.fileExists(atPath: paths.active.path) {
            try FileManager.default.removeItem(at: paths.active)
        }
    }

    public func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func ensureHome() throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    }

    func decode(_ data: Data, source: String) throws -> MachineList {
        do {
            return try JSONDecoder().decode(MachineList.self, from: data)
        } catch {
            throw StoreError.unreadable("\(source) isn't a valid machine list: \(Self.describe(error))")
        }
    }

    static func encode(_ machines: MachineList) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(machines)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            "missing “\(key.stringValue)” at \(path(ctx.codingPath))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            "wrong value at \(path(ctx.codingPath))"
        case DecodingError.dataCorrupted(let ctx):
            ctx.codingPath.isEmpty ? "not valid JSON" : "bad data at \(path(ctx.codingPath))"
        default:
            error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "the top level" : keys.map(\.stringValue).joined(separator: " → ")
    }
}

/// Appends to ~/.loki/loki.log in the CLI's format: `[yyyy-MM-dd HH:mm:ss] message`.
public struct LokiLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ message: String, date: Date = Date()) {
        // Every line gets the prefix, including each line of multi-line nginx output (as the CLI does)
        let stamp = "[\(Self.timestamp(date))] "
        let line = message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stamp + $0 }.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Last `count` lines from the final 64 KB of the log.
    public func tail(_ count: Int = 50) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").suffix(count).map(String.init)
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
