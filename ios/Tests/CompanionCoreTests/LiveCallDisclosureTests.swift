// Before a phone's first Live call it says, once, what a call sends to
// OpenAI, with Start call and Cancel. Start call remembers it on this device;
// Cancel starts nothing and leaves it for the next try.
import XCTest
@testable import CompanionCore

final class LiveCallDisclosureTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    /// A phone of its own: a fresh defaults suite.
    private func device() -> UserDefaults {
        let name = "LiveCallDisclosureTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    func testAPhoneThatNeverCalledShowsTheDisclosureFirst() {
        XCTAssertTrue(LiveCallDisclosure(defaults: device()).isDue)
    }

    func testCancelLeavesItForTheNextTry() {
        let phone = device()
        let disclosure = LiveCallDisclosure(defaults: phone)
        XCTAssertTrue(disclosure.isDue)
        // Cancel records nothing: the first call has not happened yet.
        XCTAssertTrue(disclosure.isDue)
        XCTAssertTrue(LiveCallDisclosure(defaults: phone).isDue, "the next launch shows it too")
    }

    func testStartCallRemembersItOnThisPhoneOnly() {
        let phone = device()
        LiveCallDisclosure(defaults: phone).accept()
        XCTAssertFalse(LiveCallDisclosure(defaults: phone).isDue, "never again on this phone, after a relaunch too")
        XCTAssertTrue(phone.bool(forKey: LiveCallDisclosure.defaultsKey))
        XCTAssertTrue(LiveCallDisclosure(defaults: device()).isDue, "another phone has its own first call")
    }

    func testTheRecordIsTheAppsOwnPreference() {
        // The UI tests seed it with a launch argument by this name.
        XCTAssertEqual(LiveCallDisclosure.defaultsKey, "companion.prefs.liveDisclosureShown")
    }
}
