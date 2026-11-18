import Foundation

/// Asks GitHub which release is the latest. Never installs anything: the app shows a button that opens
/// the releases page, where the user downloads the DMG.
public enum UpdateCheck {
    /// What the update button opens. Fixed, so nothing in GitHub's answer decides where it goes.
    public static let releasesPage = URL(string: "https://github.com/rajadubey/loki/releases/latest")!  // literal, always valid
    static let api = URL(string: "https://api.github.com/repos/rajadubey/loki/releases/latest")!  // literal, always valid
    private static let session = URLSession(configuration: .ephemeral)

    public enum Outcome: Equatable, Sendable {
        case newer(version: String)
        case upToDate
        /// No answer (offline, rate limited): worth asking again sooner than a day later.
        case unreachable
    }

    public static func run(current: String) async -> Outcome {
        var request = URLRequest(url: api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
        return outcome(current: current, response: data)
    }

    /// GitHub's answer is untrusted input: anything but a newer X.Y.Z tag means no update.
    static func outcome(current: String, response: Data) -> Outcome {
        struct Latest: Decodable {
            let tag: String
            enum CodingKeys: String, CodingKey { case tag = "tag_name" }
        }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: response),
              let version = semver(latest.tag), let installed = semver(current),
              installed.lexicographicallyPrecedes(version)
        else { return .upToDate }
        return .newer(version: version.map(String.init).joined(separator: "."))
    }

    /// "2.1.0" or "v2.1.0" -> [2, 1, 0]; nil for anything else ("dev", "2.1", "2.1.0-beta", "+2.1.0").
    static func semver(_ tag: String) -> [Int]? {
        let parts = (tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            !part.isEmpty && part.allSatisfy({ ("0"..."9").contains($0) }) ? Int(part) : nil
        }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }
}
