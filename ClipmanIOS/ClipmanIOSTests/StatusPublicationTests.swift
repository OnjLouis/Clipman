import Combine
import XCTest
@testable import Clipman

final class StatusPublicationTests: XCTestCase {
    @MainActor
    func testRepeatedIdenticalStatusDoesNotRepublish() {
        let model = ClipmanAppModel(settings: ClipmanSettings.empty)
        var publications: [String] = []
        let observation = model.$status
            .dropFirst()
            .sink { publications.append($0) }

        model.setTransientStatus("Refreshing history.")
        model.setTransientStatus("Refreshing history.")

        XCTAssertEqual(publications, ["Refreshing history."])
        withExtendedLifetime(observation) {}
    }
}
