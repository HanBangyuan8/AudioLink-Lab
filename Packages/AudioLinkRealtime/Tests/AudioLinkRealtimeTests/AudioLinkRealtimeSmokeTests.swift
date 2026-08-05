import XCTest
@testable import AudioLinkRealtime

final class AudioLinkRealtimeSmokeTests: XCTestCase {
    func testPermissionStatusIsCodable() throws {
        let data = try JSONEncoder().encode(MicrophonePermissionStatus.authorized)
        XCTAssertEqual(
            try JSONDecoder().decode(MicrophonePermissionStatus.self, from: data),
            .authorized
        )
    }
}
