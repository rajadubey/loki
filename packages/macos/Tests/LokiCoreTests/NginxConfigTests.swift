import Foundation
import Testing
@testable import LokiCore

private let fixedDate = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 14, minute: 7, second: 9))!

@Suite struct NginxConfigTests {
    @Test func rendersTwoServicesByteExact() {
        let machine = Machine(ip: "10.0.0.5", services: [
            "web": Ports(local: 8080, remote: 80),
            "db": Ports(local: 5433, remote: 5432),
        ])
        let expected = """
        # Auto-generated remote.conf for dev (10.0.0.5) [2024-03-05 14:07:09]

        upstream db {
            server 10.0.0.5:5432;
        }
        server {
            listen 5433;
            proxy_pass db;
        }

        upstream web {
            server 10.0.0.5:80;
        }
        server {
            listen 8080;
            proxy_pass web;
        }

        """
        #expect(NginxConfig.render(machineName: "dev", machine: machine, date: fixedDate) == expected)
    }

    @Test func headerOnlyMode() {
        let machine = Machine(ip: "10.0.0.5", services: ["web": Ports(local: 8080, remote: 80)])
        #expect(NginxConfig.render(machineName: "dev", machine: machine, includeServices: false, date: fixedDate)
                == "# Auto-generated remote.conf for dev (10.0.0.5) [2024-03-05 14:07:09]\n")
    }

    @Test func machineWithoutServicesIsJustTheHeader() {
        #expect(NginxConfig.render(machineName: "m", machine: Machine(ip: "h", services: [:]), date: fixedDate)
                == "# Auto-generated remote.conf for m (h) [2024-03-05 14:07:09]\n")
    }

    @Test func servicesWithANullPortAreSkipped() {
        let machine = Machine(ip: "1.2.3.4", services: [
            "a": Ports(local: nil, remote: 80),
            "b": Ports(local: 8081, remote: nil),
            "c": Ports(local: 8082, remote: 82),
        ])
        let out = NginxConfig.render(machineName: "m", machine: machine, date: fixedDate)
        #expect(!out.contains("upstream a "))
        #expect(!out.contains("upstream b "))
        #expect(out.hasSuffix("\nupstream c {\n    server 1.2.3.4:82;\n}\nserver {\n    listen 8082;\n    proxy_pass c;\n}\n"))
        #expect(out.components(separatedBy: "upstream ").count == 2)
    }

    @Test func servicesAreSortedByCodePointLikeJq() {
        let names = ["zeta", "Alpha", "alpha", "a_b", "a-b", "B", "1x"]
        let machine = Machine(ip: "h", services: Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ($0.element, Ports(local: 9000 + $0.offset, remote: 80))
        }))
        let out = NginxConfig.render(machineName: "m", machine: machine, date: fixedDate)
        let rendered = out.split(separator: "\n").filter { $0.hasPrefix("upstream ") }.map { $0.split(separator: " ")[1] }
        #expect(rendered == ["1x", "Alpha", "B", "a-b", "a_b", "alpha", "zeta"])
    }

    @Test func usesCurrentDateByDefault() {
        let out = NginxConfig.render(machineName: "m", machine: Machine(ip: "h", services: [:]))
        let stamp = LokiLog.timestamp(Date())
        #expect(out.hasPrefix("# Auto-generated remote.conf for m (h) [\(stamp.prefix(10))"))
    }
}
