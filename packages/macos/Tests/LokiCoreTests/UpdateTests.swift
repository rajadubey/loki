import Foundation
import Testing
@testable import LokiCore

/// The update button: GitHub's latest release against the running version. Untrusted-response
/// cases (a hostile link, garbled JSON) are in SecurityTests.
@Suite struct UpdateCheckTests {
    private func response(_ tag: String) -> Data { Data(#"{"tag_name": "\#(tag)"}"#.utf8) }

    @Test(arguments: [("2.0.1", "2.0.2", "2.0.2"), ("2.0.1", "2.1.0", "2.1.0"), ("2.0.1", "10.0.0", "10.0.0"),
                      ("2.9.9", "2.10.0", "2.10.0"), ("2.0.1", "v3.0.0", "3.0.0")])
    func aNewerReleaseIsOffered(_ current: String, _ tag: String, _ version: String) {
        #expect(UpdateCheck.outcome(current: current, response: response(tag)) == .newer(version: version))
    }

    @Test(arguments: [
        ("2.0.1", "2.0.1"), ("2.1.0", "2.0.9"), ("dev", "9.0.0"),  // same, older, unknown running version
        ("2.0.1", "2.1"), ("2.0.1", "2.1.0-beta"), ("2.0.1", "+2.1.0"), ("2.0.1", "2.1.x"), ("2.0.1", "99999999999999999999.0.0"),
    ])
    func noUpdateOtherwise(_ current: String, _ tag: String) {
        #expect(UpdateCheck.outcome(current: current, response: response(tag)) == .upToDate)
    }
}
