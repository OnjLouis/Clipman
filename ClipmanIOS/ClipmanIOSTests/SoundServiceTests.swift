import AVFoundation
import XCTest
@testable import Clipman

final class SoundServiceTests: XCTestCase {
    @MainActor
    func testFeedbackSoundsUseAmbientMixingAudioSession() {
        let service = SoundService()

        XCTAssertTrue(service.configureAudioSession())
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }
}
