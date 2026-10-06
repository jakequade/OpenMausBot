import XCTest
@testable import CompanionCore

final class SignedOutEngineTests: XCTestCase {
    func testDirectAndRoomFailuresUseTheirSpeakerAndOnlySignInEngines() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bots-paged", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "bots-paged", withExtension: "json"))
        let fleet = try JSONDecoder().decode(Fleet.self, from: Data(contentsOf: url))
        var bot = try XCTUnwrap(fleet.bots.first)
        bot.modelSelection = ModelSelection(instanceId: "claude", model: "m")
        var room = try XCTUnwrap(fleet.groups.first)
        let engine = try JSONDecoder().decode(Instance.self, from: Data(#"{"instanceId":"claude","driverKind":"claudeAgent","displayName":"Claude","snapshot":{"state":"available","authenticated":false},"install":{},"models":{"default":"m","options":[]}}"#.utf8))
        var state = CompanionState()
        state.bots = [bot]
        state.rooms = [room]
        var failed = Message(id: "e", role: .bot, kind: .activity, at: 2)
        failed.tool = ToolActivity(name: "error: Not logged in · Please run /login", ok: false, setup: true)

        XCTAssertEqual(signedOutEngine(for: .bot(bot), message: failed, in: state, instances: [engine]), engine)
        failed.from = Sender(botId: bot.id, name: bot.name, color: bot.color)
        XCTAssertEqual(signedOutEngine(for: .room(room), message: failed, in: state, instances: [engine]), engine)
        failed.from = nil
        XCTAssertNil(signedOutEngine(for: .room(room), message: failed, in: state, instances: [engine]))
        failed.tool?.setup = false
        XCTAssertNil(signedOutEngine(for: .bot(bot), message: failed, in: state, instances: [engine]))
        failed.tool?.setup = true
        failed.tool?.claudeUpdate = true
        XCTAssertNil(signedOutEngine(for: .bot(bot), message: failed, in: state, instances: [engine]))
        failed.tool?.claudeUpdate = false
        var signedIn = engine
        signedIn.snapshot.authenticated = true
        XCTAssertNil(signedOutEngine(for: .bot(bot), message: failed, in: state, instances: [signedIn]))
        var apiKey = engine
        apiKey.access = "api"
        apiKey.driverKind = "openai-compat"
        XCTAssertNil(signedOutEngine(for: .bot(bot), message: failed, in: state, instances: [apiKey]))
    }
}
