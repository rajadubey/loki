import Foundation
import Testing
@testable import LokiCore

private let sample: MachineList = [
    "zulu": Machine(ip: "10.0.0.9", services: ["web": Ports(local: 8080, remote: 80)]),
    "alpha": Machine(ip: "10.0.0.1", services: ["ssh": Ports(local: 2222, remote: 22), "db": Ports(local: 5433, remote: 5432)]),
]

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

@Suite struct StoreTests {
    let tmp: TempDir
    let paths: LokiPaths
    let store: MachineStore

    init() throws {
        tmp = try TempDir()
        paths = LokiPaths(home: tmp.path(".loki"))
        store = MachineStore(paths: paths)
    }

    @Test func pathsLiveInHome() {
        #expect(paths.machines == tmp.path(".loki/machine.json"))
        #expect(paths.active.lastPathComponent == "active")
        #expect(paths.generatedConf.lastPathComponent == "remote.conf")
        #expect(paths.log.lastPathComponent == "loki.log")
        #expect(paths.config.lastPathComponent == "config")
        #expect(LokiPaths().home.path.hasSuffix("/.loki"))
    }

    @Test func loadWithoutFileIsEmpty() throws {
        #expect(try store.load().isEmpty)
    }

    @Test func saveThenLoadRoundTrips() throws {
        try store.save(MachineFile(machines: sample))
        #expect(try store.load() == sample)
    }

    @Test func saveWritesSortedPrettyJSON() throws {
        try store.save(MachineFile(machines: sample))
        let text = try #require(tmp.read(".loki/machine.json"))
        #expect(text.contains("\n  "))  // pretty printed
        let order = ["\"alpha\"", "\"db\"", "\"ssh\"", "\"zulu\""].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        // keys inside a machine and inside ports are sorted too
        #expect(text.range(of: "\"ip\"")!.lowerBound < text.range(of: "\"services\"")!.lowerBound)
        #expect(text.range(of: "\"local\"")!.lowerBound < text.range(of: "\"remote\"")!.lowerBound)
        #expect(!text.contains("\\/"))
    }

    @Test func saveIsDeterministic() throws {
        try store.save(MachineFile(machines: sample))
        let first = try Data(contentsOf: paths.machines)
        try store.save(MachineFile(machines: sample))
        #expect(try Data(contentsOf: paths.machines) == first)
    }

    @Test func saveKeepsPreviousFileAsBak() throws {
        try store.save(MachineFile(machines: sample))
        #expect(!tmp.exists(".loki/machine.json.bak"))
        let first = try #require(tmp.read(".loki/machine.json"))
        try store.save(MachineFile(machines: ["only": Machine(ip: "1.1.1.1", services: [:])]))
        #expect(tmp.read(".loki/machine.json.bak") == first)
        let second = try #require(tmp.read(".loki/machine.json"))
        try store.save(MachineFile(machines: sample))
        #expect(tmp.read(".loki/machine.json.bak") == second)  // replaced, not appended
    }

    @Test func invalidSaveThrowsAndLeavesFileUntouched() throws {
        let original = "{\"hand\":{\"ip\":\"1.2.3.4\",\"services\":{}}}"
        try tmp.write(".loki/machine.json", original)
        let bad: MachineList = ["m": Machine(ip: "1.2.3.4;", services: ["a": Ports(local: nil, remote: 1)])]
        #expect(throws: StoreError.invalid([.invalidIP(machine: "m", ip: "1.2.3.4;"), .missingPort(machine: "m", service: "a")])) {
            try store.save(MachineFile(machines: bad))
        }
        #expect(tmp.read(".loki/machine.json") == original)
        #expect(!tmp.exists(".loki/machine.json.bak"))
    }

    @Test func invalidErrorDescriptionListsEveryIssue() {
        let e = StoreError.invalid([.emptyIP(machine: "a"), .emptyIP(machine: "b")])
        #expect(e.errorDescription == "a: enter an IP address or hostname.\nb: enter an IP address or hostname.")
    }

    @Test func loadRejectsBadJSONWithAReadableReason() throws {
        try tmp.write(".loki/machine.json", "not json")
        #expect(throws: StoreError.unreadable("machine.json isn't a valid machine list: not valid JSON")) { try store.load() }

        try tmp.write(".loki/machine.json", #"{"m":{"services":{}}}"#)
        #expect(throws: StoreError.unreadable("machine.json isn't a valid machine list: missing “ip” at m")) { try store.load() }

        try tmp.write(".loki/machine.json", #"{"m":{"ip":"1.2.3.4","services":{"a":{"local":"8080","remote":80}}}}"#)
        #expect(throws: StoreError.unreadable("machine.json isn't a valid machine list: wrong value at m → services → a → local")) { try store.load() }
    }

    @Test func loadDoesNotValidate() throws {
        // A hand-edited file with nulls still loads (render skips those services, like the CLI).
        try tmp.write(".loki/machine.json", #"{"m":{"ip":"1.2.3.4","services":{"a":{"local":null,"remote":80}}}}"#)
        #expect(try store.load()["m"]?.services["a"] == Ports(local: nil, remote: 80))
    }

    @Test func importSavesValidFile() throws {
        try store.save(MachineFile(machines: ["old": Machine(ip: "9.9.9.9", services: [:])]))
        let source = try tmp.write("in/team.json", #"{"new":{"ip":"1.2.3.4","services":{"web":{"local":8080,"remote":80}}}}"#)
        let imported = try store.importMachines(from: source)
        #expect(imported == MachineFile(machines: ["new": Machine(ip: "1.2.3.4", services: ["web": Ports(local: 8080, remote: 80)])]))
        #expect(try store.loadFile() == imported)
        #expect(tmp.read(".loki/machine.json.bak")?.contains("old") == true)
    }

    @Test func importRejectsBadJSONAndInvalidLists() throws {
        try store.save(MachineFile(machines: sample))
        let before = try Data(contentsOf: paths.machines)
        let garbage = try tmp.write("in/bad.json", "[1,2,3]")
        #expect(throws: StoreError.self) { try store.importMachines(from: garbage) }
        let invalid = try tmp.write("in/invalid.json", #"{"m":{"ip":"","services":{}}}"#)
        #expect(throws: StoreError.invalid([.emptyIP(machine: "m")])) { try store.importMachines(from: invalid) }
        #expect(try Data(contentsOf: paths.machines) == before)
    }

    @Test func containersAndSharedServicesAreSavedAsWritten() throws {
        let file = MachineFile(machines: ["solo": Machine(ip: "10.0.2.1", services: ["ssh": Ports(local: 2222, remote: 22)])],
                               containers: ["c1": "10.0.1.1", "c2": "10.0.1.2"],
                               services: ["web": Ports(local: 8080, remote: 80)])
        try store.save(file)
        #expect(try store.loadFile() == file)
        #expect(try store.load() == file.all)
        let top = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.machines)) as? [String: Any])
        #expect(Set(top.keys) == ["containers", "services", "solo"])
    }

    @Test func aFileWithoutContainersIsSavedWithoutThem() throws {
        try store.save(MachineFile(machines: sample))
        let top = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.machines)) as? [String: Any])
        #expect(Set(top.keys) == ["alpha", "zulu"])
    }

    @Test func exportWritesTheSameJSONAsSave() throws {
        try store.save(MachineFile(machines: sample))
        let out = tmp.path("out.json")
        try store.exportMachines(to: out)
        #expect(try Data(contentsOf: out) == Data(contentsOf: paths.machines))
    }

    @Test func activeFileUsesTheCLIFormat() throws {
        #expect(store.activeName() == nil)
        try store.setActive("dev-1")
        #expect(tmp.read(".loki/active") == "dev-1\n")
        #expect(store.activeName() == "dev-1")
        try store.setActive(nil)
        #expect(!tmp.exists(".loki/active"))
        #expect(store.activeName() == nil)
        try store.setActive(nil)  // removing twice is fine
    }

    @Test func activeNameTrimsAndTreatsBlankAsNone() throws {
        try tmp.write(".loki/active", "  prod \n\n")
        #expect(store.activeName() == "prod")
        try tmp.write(".loki/active", " \n")
        #expect(store.activeName() == nil)
    }

    @Test func modifiedDate() throws {
        #expect(store.modified(paths.machines) == nil)
        try store.save(MachineFile(machines: sample))
        let date = try #require(store.modified(paths.machines))
        #expect(abs(date.timeIntervalSinceNow) < 60)
    }

    @Test func logLineFormat() throws {
        let log = LokiLog(url: tmp.path("logs/nested/loki.log"))  // creates missing folders
        log.append("✅ Connected to: dev", date: localDate(2024, 3, 5, 14, 7, 9))
        log.append("second", date: localDate(2024, 12, 31, 23, 59, 59))
        #expect(tmp.read("logs/nested/loki.log") == "[2024-03-05 14:07:09] ✅ Connected to: dev\n[2024-12-31 23:59:59] second\n")
    }

    @Test func logAppendsToExistingFile() throws {
        let url = try tmp.write("loki.log", "[2020-01-01 00:00:00] from the CLI\n")
        LokiLog(url: url).append("from the app", date: localDate(2024, 1, 2, 3, 4, 5))
        #expect(tmp.read("loki.log") == "[2020-01-01 00:00:00] from the CLI\n[2024-01-02 03:04:05] from the app\n")
    }

    @Test func timestampUses24HourClock() {
        #expect(LokiLog.timestamp(localDate(2024, 7, 4, 0, 0, 1)) == "2024-07-04 00:00:01")
        #expect(LokiLog.timestamp(localDate(2024, 7, 4, 13, 5, 0)) == "2024-07-04 13:05:00")
    }

    @Test func tailReturnsLastLines() throws {
        let log = LokiLog(url: tmp.path("loki.log"))
        #expect(log.tail() == [])
        for i in 1...60 { log.append("line \(i)") }
        let last = log.tail(3)
        #expect(last.count == 3)
        #expect(last.map { $0.hasSuffix("] line 58") } == [true, false, false])
        #expect(last[2].hasSuffix("] line 60"))
        #expect(log.tail().count == 50)
    }

    @Test func tailReadsOnlyTheEndOfAHugeLog() throws {
        let filler = String(repeating: "x", count: 99) + "\n"
        let url = try tmp.write("big.log", String(repeating: filler, count: 2_000) + "last line\n")
        let lines = LokiLog(url: url).tail(1_000)
        #expect(lines.last == "last line")
        #expect(lines.count <= 65_536 / 100 + 2)  // full lines + the cut-off first one + "last line"
    }
}
