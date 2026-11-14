import Foundation
import Network
import Testing
@testable import LokiCore

/// A loopback-only TCP listener; `reply` (if any) is sent after the first bytes arrive, then the connection closes.
private final class LocalListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "loki.tests.listener")

    init(reply: String? = nil) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            guard let reply else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Starts listening and returns the port.
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let once = Once()  // state updates arrive on `queue`, one at a time
            listener.stateUpdateHandler = { [listener] state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; c.resume(returning: Int(listener.port!.rawValue))
                case .failed(let e): once.done = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    private final class Once: @unchecked Sendable { var done = false }
}

@Suite struct HealthTests {
    @Test func classifyThresholds() {
        #expect(classify(nil) == .down)
        #expect(classify(0) == .up)
        #expect(classify(slowThresholdMs - 1) == .up)
        #expect(classify(slowThresholdMs) == .slow)
        #expect(classify(5_000) == .slow)
        #expect(slowThresholdMs == 300)
    }

    @Test func downTextBuckets() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(downText(since: now, now: now) == "Down <1m")
        #expect(downText(since: now - 59, now: now) == "Down <1m")
        #expect(downText(since: now - 60, now: now) == "Down 1m")
        #expect(downText(since: now - 59 * 60 - 59, now: now) == "Down 59m")
        #expect(downText(since: now - 60 * 60, now: now) == "Down 1h")
        #expect(downText(since: now - 150 * 60, now: now) == "Down 2h")
        #expect(downText(since: now - 26 * 3600, now: now) == "Down 26h")
    }

    @Test func serviceStatusDefaults() {
        #expect(ServiceStatus() == ServiceStatus(health: .unknown, latencyMs: nil, http: nil))
    }

    @Test func tcpProbeReachesAListeningPort() async throws {
        let server = try LocalListener()
        let port = try await server.start()
        let latency = await tcpProbe(host: "127.0.0.1", port: port, timeout: 2)
        let ms = try #require(latency)
        #expect(ms >= 0 && ms < 2_000)
        #expect(classify(latency) != .down)
        withExtendedLifetime(server) {}
    }

    @Test func tcpProbeOfAClosedPortIsDown() async throws {
        // grab a free port, then close it
        let port: Int
        do {
            let server = try LocalListener()
            port = try await server.start()
            server.listener.cancel()
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        #expect(await tcpProbe(host: "127.0.0.1", port: port, timeout: 1) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test(arguments: [0, -1, 65_536, 100_000])
    func tcpProbeRejectsInvalidPorts(_ port: Int) async {
        #expect(await tcpProbe(host: "127.0.0.1", port: port, timeout: 0.5) == nil)
    }

    @Test func httpProbeReportsStatus() async throws {
        let server = try LocalListener(reply: "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let port = try await server.start()
        #expect(await httpProbe(port: port) == "HTTP 204")
        withExtendedLifetime(server) {}
    }

    @Test func httpProbeOfAClosedPortIsNil() async throws {
        let port: Int
        do {
            let server = try LocalListener()
            port = try await server.start()
            server.listener.cancel()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await httpProbe(port: port) == nil)
    }
}
