import Foundation

/// Locations inside the loki home folder (~/.loki), shared with the CLI.
/// It holds machine addresses and sync settings (a sync URL may carry a token), so like ~/.ssh the
/// folder is owner-only (0700) and every file loki writes in it is too (0600). The CLI does the same.
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

    /// Creates the folder owner-only when it's missing. Writes call this; it leaves an existing folder
    /// alone, so a refused chmod (a network home, say) can't stop machines from saving.
    public func ensurePrivateHome() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Makes the folder owner-only (older versions left it readable by everyone), like the CLI's
    /// `chmod 700` on every run; the app runs this at launch. Only the folder, which already keeps
    /// other users away from every file in it: changing a file's mode would quietly "fix" a
    /// world-writable config the CLI must refuse to run.
    public func makePrivate() throws {
        try ensurePrivateHome()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.resolvingSymlinksInPath().path)
    }
}

/// Atomic write, then owner-only permissions (0600). Inside the 0700 home nobody else can
/// reach the file even before the chmod; the 0600 keeps it private if it's copied out.
func writePrivately(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    /// Every machine, containers expanded, or none when machine.json doesn't exist yet.
    public func load() throws -> MachineList {
        try loadFile().all
    }

    /// machine.json as written, or an empty one when it doesn't exist yet.
    public func loadFile() throws -> MachineFile {
        guard FileManager.default.fileExists(atPath: paths.machines.path) else { return MachineFile() }
        return try Self.decode(Data(contentsOf: paths.machines), source: "machine.json")
    }

    /// Validates, backs up the previous file to machine.json.bak, then writes atomically (both 0600).
    public func save(_ file: MachineFile) throws {
        let issues = validate(file)
        guard issues.isEmpty else { throw StoreError.invalid(issues) }
        try paths.ensurePrivateHome()
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.machines.path) {
            let backup = paths.home.appending(path: "machine.json.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: paths.machines, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try writePrivately(Self.encode(file), to: paths.machines)
    }

    /// Reads a machine.json from anywhere; throws if it isn't valid JSON or fails validation.
    public func importMachines(from url: URL) throws -> MachineFile {
        let file = try Self.decode(Data(contentsOf: url), source: url.lastPathComponent)
        try save(file)
        return file
    }

    public func exportMachines(to url: URL) throws {
        try Self.encode(try loadFile()).write(to: url, options: .atomic)
    }

    public func activeName() -> String? {
        guard let text = try? String(contentsOf: paths.active, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Writes (or with nil, removes) ~/.loki/active, in the CLI's format (name + newline).
    public func setActive(_ name: String?) throws {
        if let name {
            try paths.ensurePrivateHome()
            try writePrivately(Data((name + "\n").utf8), to: paths.active)
        } else if FileManager.default.fileExists(atPath: paths.active.path) {
            try FileManager.default.removeItem(at: paths.active)
        }
    }

    public func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func decode(_ data: Data, source: String) throws -> MachineFile {
        do {
            return try JSONDecoder().decode(MachineFile.self, from: data)
        } catch {
            throw StoreError.unreadable("\(source) isn't a valid machine list: \(Self.describe(error))")
        }
    }

    static func encode(_ file: MachineFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
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

    /// Past this size the log moves to loki.log.1 (replacing the previous one), as the CLI does.
    public static let maxBytes = 1_000_000

    public func append(_ message: String, date: Date = Date()) {
        // Every line gets the prefix, including each line of multi-line nginx output (as the CLI does)
        let stamp = "[\(Self.timestamp(date))] "
        let line = message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stamp + $0 }.joined(separator: "\n") + "\n"
        rotateIfFull()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // O_APPEND appends atomically next to the CLI's `>>`; O_CREAT makes a new log owner-only.
        // An existing log is never replaced, even one we can't write to (we just skip the line).
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Keeps the log bounded: once it's over `maxBytes` it becomes loki.log.1 and a new one starts.
    func rotateIfFull() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
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
