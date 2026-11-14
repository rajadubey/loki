import Testing
@testable import LokiCore

/// Fixes made after the first test pass: unsafe machine data, include matching, $HOME expansion, log format.
@Suite struct HardeningTests {
    @Test(arguments: ["1.2.3.4; include /etc/passwd", "1.2.3.4 ", "-oProxyCommand=x", "a b"])
    func connectRefusesIPsThatWouldInjectIntoNginxConfig(ip: String) {
        let machine = Machine(ip: ip, services: ["web": Ports(local: 8080, remote: 80)])
        #expect(throws: StoreError.self) { try LokiEngine.checkRenderable("m", machine) }
    }

    @Test func connectRefusesServiceNamesNginxWouldMisread() {
        let machine = Machine(ip: "10.0.0.1", services: ["web}; server {": Ports(local: 8080, remote: 80)])
        #expect(throws: StoreError.self) { try LokiEngine.checkRenderable("m", machine) }
    }

    @Test func nullPortsStillConnect() throws {
        let machine = Machine(ip: "10.0.0.1", services: ["web": Ports(local: 8080, remote: 80), "half": Ports(local: nil, remote: 1)])
        try LokiEngine.checkRenderable("m", machine)
    }

    @Test(arguments: [
        ("stream {\n    include remote.conf;\n}\n", true),
        ("stream {\n    include /opt/homebrew/etc/nginx/remote.conf;\n}\n", true),
        ("stream {\n    include \"/x/remote.conf\";\n}\n", true),
        ("stream {\n    include my-remote.conf;\n}\n", false),
        ("stream {\n    include /x/remote.conf.bak;\n}\n", false),
    ])
    func includeMatchesOnlyTheRealRemoteConf(conf: String, configured: Bool) {
        #expect(StreamInclude.isConfigured(in: conf) == configured)
    }

    @Test func homeExpandsLikeTheShell() {
        #expect(SyncSettings.unquote("$HOME/m.json", home: "/Users/a") == "/Users/a/m.json")
        #expect(SyncSettings.unquote("\"${HOME}/m.json\"", home: "/Users/a") == "/Users/a/m.json")
        #expect(SyncSettings.unquote("'$HOME/m.json'", home: "/Users/a") == "$HOME/m.json")
        #expect(SyncSettings.unquote("$HOMEDIR/m.json", home: "/Users/a") == "$HOMEDIR/m.json")
        #expect(SyncSettings.unquote("\\$HOME", home: "/Users/a") == "$HOME")
    }

    @Test func multiLineLogMessagesGetATimestampOnEveryLine() throws {
        let dir = try TempDir()
        let log = LokiLog(url: dir.url.appending(path: "loki.log"))
        log.append("nginx said:\nline two\nline three")
        let lines = log.tail()
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.wholeMatch(of: /\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] .*/) != nil })
    }
}
