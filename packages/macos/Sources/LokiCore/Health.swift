import Foundation
import Network

public enum Health: Equatable, Sendable {
    case unknown, up, slow, down
}

public struct ServiceStatus: Equatable, Sendable {
    public var health: Health
    public var latencyMs: Int?
    public var http: String?

    public init(health: Health = .unknown, latencyMs: Int? = nil, http: String? = nil) {
        self.health = health
        self.latencyMs = latencyMs
        self.http = http
    }
}

public let slowThresholdMs = 300

/// How often the app checks health, in seconds (Settings → General). A stored value that isn't one
/// of the choices (missing, or hand-edited defaults) falls back to every minute.
public enum HealthInterval {
    public static let choices = [15, 30, 60, 120, 300, 600]
    public static let standard = 60

    public static func sanitized(_ seconds: Int) -> Int { choices.contains(seconds) ? seconds : standard }
}

/// nil latency means the connection failed.
public func classify(_ latencyMs: Int?) -> Health {
    guard let ms = latencyMs else { return .down }
    return ms < slowThresholdMs ? .up : .slow
}

public func downText(since: Date, now: Date = Date()) -> String {
    let minutes = Int(now.timeIntervalSince(since)) / 60
    return minutes < 1 ? "Down <1m" : minutes < 60 ? "Down \(minutes)m" : "Down \(minutes / 60)h"
}

/// One serial queue for every probe's callbacks, which are tiny, instead of a queue per probe.
private let probeQueue = DispatchQueue(label: "loki.probe")

/// TCP connect time in ms, or nil if refused / unreachable within `timeout` seconds.
/// Goes straight to the remote, so it works for HTTP and non-HTTP services alike.
public func tcpProbe(host: String, port: Int, timeout: Double = 3) async -> Int? {
    guard (1...65535).contains(port), let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
    return await withCheckedContinuation { continuation in
        let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let queue = probeQueue
        let start = Date()
        let state = ProbeState()
        @Sendable func finish(_ value: Int?) {
            guard state.finishOnce() else { return }
            connection.cancel()
            continuation.resume(returning: value)
        }
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready: finish(Int(Date().timeIntervalSince(start) * 1000))
            case .failed, .waiting, .cancelled: finish(nil)  // .waiting = refused / no route
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}

/// Guards a continuation against double resume; only touched on the serial probe queue.
private final class ProbeState: @unchecked Sendable {
    private var done = false
    func finishOnce() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

private let probeSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    config.urlCache = nil  // a probe only wants the status: nothing to keep between checks
    config.httpCookieStorage = nil
    return URLSession(configuration: config)
}()

/// "HTTP 200" etc. through the local nginx port, or nil for non-HTTP / no answer. Stops as soon as the
/// response arrives (with its first bytes): the rest of the body, which can be a whole web app, isn't
/// downloaded.
public func httpProbe(port: Int, host: String = "127.0.0.1") async -> String? {
    guard let url = URL(string: "http://\(host):\(port)"),
          let (body, response) = try? await probeSession.bytes(from: url) else { return nil }
    body.task.cancel()
    return (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" }
}
