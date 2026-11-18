import Foundation
import Testing
@testable import LokiCore

private func machine(_ ip: String, _ services: [String: (Int?, Int?)]) -> Machine {
    Machine(ip: ip, services: services.mapValues { Ports(local: $0.0, remote: $0.1) })
}

@Suite struct MachinesTests {
    @Test func validListHasNoIssues() {
        let list: MachineList = [
            "dev-1": machine("10.0.0.5", ["web": (8080, 80), "db": (5433, 5432)]),
            "prod.eu_2": machine("host-1.example.com", ["ssh": (2222, 22)]),
            "v6": machine("::1", ["a": (1, 65535)]),
            "v6b": machine("[fe80::1]", ["b_c-d": (9000, 9000)]),
            "empty": machine("1.2.3.4", [:]),
        ]
        #expect(validate(list).isEmpty)
        #expect(validate([:]).isEmpty)
    }

    @Test(arguments: ["bad name", "a/b", "ü", "", "a;b"])
    func invalidMachineName(_ name: String) {
        #expect(validate([name: machine("1.2.3.4", [:])]) == [.invalidMachineName(name)])
    }

    @Test(arguments: ["", "   ", "\t"])
    func emptyIP(_ ip: String) {
        #expect(validate(["m": machine(ip, [:])]) == [.emptyIP(machine: "m")])
    }

    @Test(arguments: ["1.2.3.4;", "a b", "-oProxyCommand=x", "host{", "1.2.3.4\n}", "ho$t", " 1.2.3.4", "1.2.3.4 "])
    func invalidIP(_ ip: String) {
        // Surrounding whitespace counts too: the ip is rendered verbatim into `server <ip>:<port>;`.
        #expect(validate(["m": machine(ip, [:])]) == [.invalidIP(machine: "m", ip: ip)])
    }

    @Test(arguments: ["my.svc", "a b", "x;", "", "ü"])
    func invalidServiceName(_ service: String) {
        #expect(validate(["m": machine("1.2.3.4", [service: (8080, 80)])]) == [.invalidServiceName(machine: "m", service: service)])
    }

    @Test func missingPort() {
        let list: MachineList = ["m": machine("1.2.3.4", ["a": (nil, 80), "b": (8080, nil), "c": (nil, nil)])]
        #expect(validate(list) == [
            .missingPort(machine: "m", service: "a"),
            .missingPort(machine: "m", service: "b"),
            .missingPort(machine: "m", service: "c"),
        ])
    }

    @Test func portOutOfRangeReportsLocalThenRemote() {
        let list: MachineList = ["m": machine("1.2.3.4", ["a": (0, 65536), "b": (-1, 80), "c": (1, 65535)])]
        #expect(validate(list) == [
            .portOutOfRange(machine: "m", service: "a", port: 0),
            .portOutOfRange(machine: "m", service: "a", port: 65536),
            .portOutOfRange(machine: "m", service: "b", port: -1),
        ])
    }

    @Test func duplicateLocalPortsOnlyWithinAMachine() {
        let list: MachineList = [
            "one": machine("1.1.1.1", ["web": (8080, 80), "api": (8080, 81), "x": (9000, 1), "y": (9000, 2), "z": (7000, 3)]),
            "two": machine("2.2.2.2", ["web": (8080, 80)]),  // same port as "one", different machine: fine
        ]
        #expect(validate(list) == [
            .duplicateLocalPort(machine: "one", port: 8080, services: ["api", "web"]),
            .duplicateLocalPort(machine: "one", port: 9000, services: ["x", "y"]),
        ])
    }

    @Test func sameRemotePortTwiceIsFine() {
        #expect(validate(["m": machine("1.2.3.4", ["a": (8080, 80), "b": (8081, 80)])]).isEmpty)
    }

    @Test func issuesComeInStableOrder() {
        let list: MachineList = [
            "zeta": machine("", ["b": (1, 1), "a": (1, 1)]),
            "alpha bad": machine("1.2.3.4", ["s.x": (nil, 1), "ok": (70000, 2)]),
        ]
        let expected: [ValidationIssue] = [
            .invalidMachineName("alpha bad"),
            .portOutOfRange(machine: "alpha bad", service: "ok", port: 70000),
            .invalidServiceName(machine: "alpha bad", service: "s.x"),
            .missingPort(machine: "alpha bad", service: "s.x"),
            .emptyIP(machine: "zeta"),
            .duplicateLocalPort(machine: "zeta", port: 1, services: ["a", "b"]),
        ]
        #expect(validate(list) == expected)
        for _ in 0..<20 { #expect(validate(list) == expected) }
    }

    @Test func descriptionsNameTheProblem() {
        #expect(ValidationIssue.invalidMachineName("a b").description.contains("a b"))
        #expect(ValidationIssue.emptyIP(machine: "m").description.hasPrefix("m:"))
        #expect(ValidationIssue.invalidIP(machine: "m", ip: "x;").description.contains("x;"))
        #expect(ValidationIssue.invalidServiceName(machine: "m", service: "s.x").description.contains("s.x"))
        #expect(ValidationIssue.missingPort(machine: "m", service: "s").description == "m → s: set both the local and the remote port.")
        #expect(ValidationIssue.portOutOfRange(machine: "m", service: "s", port: 0).description == "m → s: port 0 must be between 1 and 65535.")
        #expect(ValidationIssue.duplicateLocalPort(machine: "m", port: 80, services: ["a", "b"]).description == "m: local port 80 is used by a, b.")
    }

    @Test func portsSkipsServicesWithANullPort() {
        let m = machine("1.2.3.4", ["a": (8080, 80), "b": (nil, 81), "c": (8082, nil), "d": (nil, nil)])
        #expect(m.ports == ["a": ResolvedPorts(local: 8080, remote: 80)])
    }

    @Test func decodesNullsMissingKeysAndExtraKeys() throws {
        let json = #"""
        {
          "m": {
            "ip": "10.0.0.1",
            "owner": "ops",
            "services": {
              "a": { "local": null, "remote": 80 },
              "b": { "remote": 81 },
              "c": { "local": 8082, "remote": 82, "proto": "tcp" }
            }
          }
        }
        """#
        let list = try JSONDecoder().decode(MachineList.self, from: Data(json.utf8))
        let m = try #require(list["m"])
        #expect(m.ip == "10.0.0.1")
        #expect(m.services["a"] == Ports(local: nil, remote: 80))
        #expect(m.services["b"] == Ports(local: nil, remote: 81))
        #expect(m.services["c"] == Ports(local: 8082, remote: 82))
        #expect(m.ports == ["c": ResolvedPorts(local: 8082, remote: 82)])
    }

    // MARK: containers and shared services

    @Test func containersGetTheSharedServicesAndOtherMachinesOnlyTheirOwn() throws {
        let json = #"""
        {
          "containers": { "c1": "10.0.1.1", "c2": "10.0.1.2" },
          "services": { "web": { "local": 8080, "remote": 80 } },
          "solo": { "ip": "10.0.2.1", "services": { "ssh": { "local": 2222, "remote": 22 } } }
        }
        """#
        let file = try JSONDecoder().decode(MachineFile.self, from: Data(json.utf8))
        #expect(file.all == [
            "c1": machine("10.0.1.1", ["web": (8080, 80)]),
            "c2": machine("10.0.1.2", ["web": (8080, 80)]),
            "solo": machine("10.0.2.1", ["ssh": (2222, 22)]),
        ])
        #expect(validate(file).isEmpty)
    }

    @Test(arguments: [
        #"{"m": {"ip": "10.0.0.1", "services": {}}}"#,
        #"{"containers": null, "services": null, "m": {"ip": "10.0.0.1", "services": {}}}"#,
    ])
    func aFileWithoutContainersIsMachinesOnly(_ json: String) throws {
        let file = try JSONDecoder().decode(MachineFile.self, from: Data(json.utf8))
        #expect(file == MachineFile(machines: ["m": machine("10.0.0.1", [:])]))
    }

    @Test func aMachineOfItsOwnWinsOverAContainerOfTheSameName() {
        // As in the CLI; validation refuses such a file, but a hand-edited one still loads
        let file = MachineFile(machines: ["x": machine("1.1.1.1", [:])], containers: ["x": "2.2.2.2"],
                               services: ["web": Ports(local: 8080, remote: 80)])
        #expect(file.all == ["x": machine("1.1.1.1", [:])])
    }

    @Test func fileIssuesComeInStableOrderAndSharedServicesOnce() {
        let file = MachineFile(
            machines: ["dup": machine("1.1.1.1", [:]), "services": machine("1.1.1.2", [:])],
            containers: ["dup": "1.1.1.3", "c1": "1.2.3.4;", "c2": "", "c3": "10.0.0.3", "containers": "1.1.1.4"],
            services: ["s.x": Ports(local: 1, remote: nil), "a": Ports(local: 8080, remote: 80), "b": Ports(local: 8080, remote: 81)]
        )
        let expected: [ValidationIssue] = [
            .invalidIP(machine: "c1", ip: "1.2.3.4;"),
            .emptyIP(machine: "c2"),
            .reservedMachineName("containers"),
            .listedTwice("dup"),
            .reservedMachineName("services"),
            .invalidServiceName(machine: "Shared services", service: "s.x"),
            .missingPort(machine: "Shared services", service: "s.x"),
            .duplicateLocalPort(machine: "Shared services", port: 8080, services: ["a", "b"]),
        ]
        #expect(validate(file) == expected)
        for _ in 0..<20 { #expect(validate(file) == expected) }
        #expect(ValidationIssue.listedTwice("dup").description.contains("dup"))
        #expect(ValidationIssue.reservedMachineName("services").description.contains("“services”"))
    }

    @Test func filterIsCaseInsensitiveAndTrimmed() {
        let names = ["prod-eu", "Prod-US", "dev", "staging"]
        #expect(filterMachines(names, query: "  PROD ", recents: []) == ["Prod-US", "prod-eu"])
        #expect(filterMachines(names, query: "nothing", recents: ["dev"]) == [])
    }

    @Test func emptyQueryListsRecentsFirstThenAlphabetical() {
        let names = ["c", "a", "d", "b"]
        #expect(filterMachines(names, query: "", recents: ["d", "b"]) == ["d", "b", "a", "c"])
    }

    @Test func recentsThatDontMatchOrDontExistAreDropped() {
        let names = ["api-1", "api-2", "db"]
        #expect(filterMachines(names, query: "api", recents: ["db", "gone", "api-2"]) == ["api-2", "api-1"])
    }
}
