// The decisions around a Live call that need no microphone: what a failure
// is called, what the data channel said, what one caption line holds, what
// the clock reads, and which scene phase hangs up.
import XCTest
@testable import CompanionCore

final class LiveCallSupportTests: XCTestCase {
    private func call(status: LiveCallState.Status = .ended, endReason: String? = nil, error: String? = nil) -> LiveCallState {
        LiveCallState(callId: "c1", botId: "b1", threadId: "t1", client: "desktop", voice: "marin", startedAt: 1, status: status, endReason: endReason, error: error)
    }

    // MARK: - Notices

    func testNoKeyOnTheMacCannotBeRetriedFromThePhone() {
        let notice = LiveCallNotice.forStartFailure(LiveCallStartError.needsKey(message: "Add a key."), botName: { _ in nil })
        XCTAssertEqual(notice, .needsKey)
        XCTAssertFalse(notice.canRetry)
    }

    func testBusyNamesTheDeviceAndTheBot() {
        let active = LiveCallState(callId: "c0", botId: "b2", threadId: "t2", client: "desktop", voice: "marin", startedAt: 1, status: .live)
        let notice = LiveCallNotice.forStartFailure(LiveCallStartError.busy(active: active, message: "busy"), botName: { $0 == "b2" ? "Ada" : nil })
        XCTAssertEqual(notice, .busy(client: "desktop", botName: "Ada"))
        XCTAssertFalse(notice.canRetry, "somebody else has to hang up first")
    }

    func testTheMacsOwnWordsSurviveAndCanBeRetried() {
        XCTAssertEqual(
            LiveCallNotice.forStartFailure(APIError.status(code: 502, message: "OpenAI refused the call (HTTP 429)."), botName: { _ in nil }),
            .refused("OpenAI refused the call (HTTP 429).")
        )
        XCTAssertEqual(
            LiveCallNotice.forStartFailure(APIError.status(code: 503, message: nil), botName: { _ in nil }),
            .refused("The computer answered with an error (503).")
        )
        XCTAssertEqual(LiveCallNotice.forStartFailure(APIError.transport("The request timed out."), botName: { _ in nil }), .unreachable("The request timed out."))
        XCTAssertEqual(LiveCallNotice.forStartFailure(LiveCallMediaError.answerRejected("bad sdp"), botName: { _ in nil }), .couldNotStart("bad sdp"))
        XCTAssertEqual(LiveCallNotice.forStartFailure(LiveCallMediaError.offerFailed("no mic"), botName: { _ in nil }), .couldNotStart("no mic"))
        XCTAssertTrue(LiveCallNotice.refused("x").canRetry)
        XCTAssertTrue(LiveCallNotice.unreachable("x").canRetry)
        XCTAssertTrue(LiveCallNotice.couldNotStart("x").canRetry)
        XCTAssertFalse(LiveCallNotice.micDenied.canRetry)
    }

    func testAnEndedCallIsExplainedByItsReason() {
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "hung-up")), .ended)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: nil)), .ended)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "idle")), .endedIdle)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "expired")), .endedExpired)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "sideband-lost")), .dropped)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "connection-lost")), .dropped)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "remote-hangup")), .dropped, "OpenAI ending it is a drop, as on the desktop")
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "error", error: "OpenAI closed the session.")), .endedWithError("OpenAI closed the session.", dropped: true))
        XCTAssertFalse(LiveCallNotice.forEnd(call(endReason: "idle")).canRetry, "an end that is not a drop")
    }

    func testEveryReasonTheDesktopNamesHasItsOwnNotice() {
        // The desktop's endNotice (src/lib/live-call-media.ts) names these;
        // the phone said a plain "Call ended." for them.
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "content")), .endedContent)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "deleted")), .endedDeleted)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "shutdown")), .endedShutdown)
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "a-reason-from-a-newer-computer")), .ended)
        // The computer's own words still come first, whatever the reason.
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "shutdown", error: "Restarting for an update.")), .endedWithError("Restarting for an update.", dropped: false))
    }

    func testASignedOutEndShowsTheComputersWordsWithoutARetry() {
        // "signed-out": the sign-in or the paired phone that started the
        // call was signed out, revoked or unpaired. Its own words come first.
        let words = "The call has ended because the sign-in that started it has ended. Sign in again to start a new call."
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "signed-out", error: words)), .signedOut(message: words))
        XCTAssertEqual(LiveCallNotice.forEnd(call(endReason: "signed-out")), .signedOut(message: nil))
        XCTAssertFalse(LiveCallNotice.signedOut(message: words).canRetry, "a retry cannot help")
        XCTAssertFalse(LiveCallNotice.signedOut(message: nil).canRetry)
    }

    /// Try again as on the desktop (`canRetry: notice.dropped`): only a
    /// dropped call and a failed start offer it. An end that is not a drop
    /// offers none, whatever words it carries; the phone icon starts the
    /// next call.
    func testTryAgainOnlyAfterADropOrAFailedStart() {
        let words = "The computer's own words."
        for reason in ["hung-up", "idle", "expired", "content", "deleted", "shutdown", "signed-out", "a-reason-from-a-newer-computer"] {
            XCTAssertFalse(LiveCallNotice.forEnd(call(endReason: reason)).canRetry, reason)
            XCTAssertFalse(LiveCallNotice.forEnd(call(endReason: reason, error: words)).canRetry, "\(reason), in the computer's words")
        }
        XCTAssertFalse(LiveCallNotice.forEnd(call(endReason: nil)).canRetry, "no reason at all")
        XCTAssertFalse(LiveCallNotice.ended.canRetry, "OpenAI closed the call, or the computer no longer reports it")
        for reason in ["remote-hangup", "connection-lost", "sideband-lost", "error"] {
            XCTAssertTrue(LiveCallNotice.forEnd(call(endReason: reason)).canRetry, reason)
            XCTAssertTrue(LiveCallNotice.forEnd(call(endReason: reason, error: words)).canRetry, "\(reason), in the computer's words")
        }
        XCTAssertTrue(LiveCallNotice.dropped.canRetry)
        XCTAssertTrue(LiveCallNotice.audioNeverConnected.canRetry, "the phone's own drop")
    }

    // MARK: - Data channel

    func testParsesTheEventsCaptionsNeedAndNothingMore() {
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"session.started","event_id":"e1","session":{"id":"s"}}"#.utf8)), .started)
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"session.input_transcript.delta","delta":"hello","start_ms":10,"end_ms":20}"#.utf8)), .inputTranscript("hello"))
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"session.output_transcript.delta","delta":" there"}"#.utf8)), .outputTranscript(" there"))
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"session.closed","reason":"close_requested","usage":{"seconds":42}}"#.utf8)), .closed(reason: "close_requested"))
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"error","error":{"code":"x","message":"append pending"}}"#.utf8)), .error(message: "append pending"))
        XCTAssertEqual(LiveCallDataEvent.parse(Data(#"{"type":"info","code":"data_channel_permissions"}"#.utf8)), .other(type: "info"))
        XCTAssertNil(LiveCallDataEvent.parse(Data("not json".utf8)))
        XCTAssertNil(LiveCallDataEvent.parse(Data(#"{"delta":"no type"}"#.utf8)))
    }

    func testTheOnlyThingThePhoneEverSendsIsClose() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LiveCallDataEvent.closeCommand) as? [String: Any])
        XCTAssertEqual(object as? [String: String], ["type": "session.close"])
    }

    // MARK: - Captions

    func testCaptionsKeepOneLinePerSpeaker() {
        var captions = LiveCaptions()
        XCTAssertEqual(captions.line, "")
        captions.append("Hello", from: .voice)
        captions.append(" there.", from: .voice)
        XCTAssertEqual(captions.line, "Hello there.")
        XCTAssertEqual(captions.speaker, .voice)
        // the person starts talking: their words replace the voice's line, in their own colour
        captions.append("What is", from: .user)
        captions.append(" on my calendar", from: .user)
        XCTAssertEqual(captions.line, "What is on my calendar")
        XCTAssertEqual(captions.speaker, .user)
        // the voice answers: a fresh line again
        captions.append("Two things", from: .voice)
        XCTAssertEqual(captions.line, "Two things")
        XCTAssertEqual(captions.speaker, .voice)
    }

    func testCaptionsKeepTheTailOfALongSentenceAtAWordBoundary() {
        var captions = LiveCaptions()
        let words = (1...80).map { "word\($0)" }.joined(separator: " ")
        captions.append(words, from: .voice)
        XCTAssertLessThanOrEqual(captions.line.count, LiveCaptions.maxCharacters)
        XCTAssertTrue(captions.line.hasSuffix("word80"))
        XCTAssertTrue(captions.line.hasPrefix("word"), "cut at a word boundary, not mid-word: \(captions.line.prefix(8))")
        XCTAssertFalse(captions.line.hasPrefix(" "))
    }

    func testCaptionsCollapseNewlinesAndRepeatedSpaces() {
        var captions = LiveCaptions()
        captions.append("one\n\ntwo   three ", from: .voice)
        captions.append("four", from: .voice)
        XCTAssertEqual(captions.line, "one two three four")
    }

    // MARK: - Clock

    func testTheClockReadsLikeThePhoneApp() {
        XCTAssertEqual(LiveCallClock.text(0), "0:00")
        XCTAssertEqual(LiveCallClock.text(7), "0:07")
        XCTAssertEqual(LiveCallClock.text(65), "1:05")
        XCTAssertEqual(LiveCallClock.text(600), "10:00")
        XCTAssertEqual(LiveCallClock.text(3_661), "1:01:01")
        XCTAssertEqual(LiveCallClock.text(-5), "0:00")
        let now = Date(timeIntervalSince1970: 1_700_000_090)
        XCTAssertEqual(LiveCallClock.elapsed(since: 1_700_000_000_000, now: now), 90)
        XCTAssertEqual(LiveCallClock.elapsed(since: 1_700_000_500_000, now: now), 0, "a Mac clock ahead of the phone never counts backwards")
    }

    // MARK: - Sound output

    private let headsets: [LiveCallAudioRoute.Output] = [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio]

    func testAHeadsetTakesTheCallEvenWithSpeakerChosen() {
        // AirPods, a hearing aid, earbuds on a wire: the loudspeaker override
        // would play the bot's answers to the room and swap the headset's
        // microphone for the phone's own.
        for headset in headsets {
            XCTAssertFalse(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: [headset]), "\(headset)")
            XCTAssertFalse(LiveCallAudioRoute.forcesSpeaker(speaker: false, outputs: [headset]), "\(headset)")
        }
        XCTAssertFalse(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: [.builtInSpeaker, .bluetoothLE]), "a headset anywhere in the route")
    }

    func testTheSpeakerSettingChoosesOnlyWhenNoHeadsetIsConnected() {
        XCTAssertTrue(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: [.builtInReceiver]))
        XCTAssertFalse(LiveCallAudioRoute.forcesSpeaker(speaker: false, outputs: [.builtInReceiver]), "the earpiece is the call's own default")
        XCTAssertTrue(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: [.builtInSpeaker]), "the loudspeaker already")
        XCTAssertTrue(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: []), "no route reported yet")
        XCTAssertTrue(LiveCallAudioRoute.forcesSpeaker(speaker: true, outputs: [.other]), "a TV or a dock is not something anyone wears")
        for headset in headsets { XCTAssertTrue(headset.isHeadset, "\(headset)") }
        for builtIn: LiveCallAudioRoute.Output in [.builtInReceiver, .builtInSpeaker, .other] { XCTAssertFalse(builtIn.isHeadset, "\(builtIn)") }
    }

    func testTheRouteIsDecidedAgainWhenADeviceComesOrGoes() {
        // Earbuds put in mid-call take it; taken out, the Speaker setting
        // applies again. A device that arrives under the loudspeaker override
        // is hidden by it, so the override comes off before the route is read.
        XCTAssertEqual(LiveCallAudioRoute.action(for: .newDevice), .decide(clearingOverride: true))
        XCTAssertEqual(LiveCallAudioRoute.action(for: .setting), .decide(clearingOverride: true), "the route is read as the system picked it")
        XCTAssertEqual(LiveCallAudioRoute.action(for: .oldDeviceGone), .decide(clearingOverride: false))
        XCTAssertEqual(LiveCallAudioRoute.action(for: .categoryChange), .decide(clearingOverride: false), "a new category can drop the override")
        XCTAssertEqual(LiveCallAudioRoute.action(for: .otherChange), .decide(clearingOverride: false))
        XCTAssertEqual(LiveCallAudioRoute.action(for: .override), .none, "the rule's own override: deciding again would only set off another")
    }

    func testEarbudsInAndOutDuringACallWithSpeakerChosen() {
        // What the system reports at each step, and what the rule makes of it.
        var route = SpeakerRoute(speaker: true)
        route.change(.setting, systemRoute: [.builtInReceiver])
        XCTAssertEqual(route.heard, [.builtInSpeaker], "no headset: the loudspeaker, as chosen")
        route.change(.newDevice, systemRoute: [.bluetoothHFP])
        XCTAssertEqual(route.heard, [.bluetoothHFP], "AirPods put in take the call")
        route.change(.setting, systemRoute: [.bluetoothHFP])
        XCTAssertEqual(route.heard, [.bluetoothHFP], "choosing Speaker again does not pull the call off them")
        route.change(.oldDeviceGone, systemRoute: [.builtInReceiver])
        XCTAssertEqual(route.heard, [.builtInSpeaker], "taken out: back to the loudspeaker")

        var earpiece = SpeakerRoute(speaker: false)
        earpiece.change(.setting, systemRoute: [.builtInReceiver])
        XCTAssertEqual(earpiece.heard, [.builtInReceiver])
        earpiece.change(.newDevice, systemRoute: [.headphones])
        XCTAssertEqual(earpiece.heard, [.headphones])
    }

    // MARK: - Lifecycle

    func testOnlyABackgroundEndsTheCall() {
        // .inactive is Control Center, the app switcher, an incoming-call
        // banner, and the microphone permission prompt itself
        XCTAssertFalse(LiveCallLifecycle.endsCall(on: .active))
        XCTAssertFalse(LiveCallLifecycle.endsCall(on: .inactive))
        XCTAssertTrue(LiveCallLifecycle.endsCall(on: .background))
    }
}

/// The audio session as the rule sees it: the route the system picks by
/// itself, with the loudspeaker override on top. The override is modelled as
/// sticking through a route change, the worst case, so the rule has to take
/// it off itself when a headset arrives under it.
private struct SpeakerRoute {
    let speaker: Bool
    private var overridden = false
    private var systemRoute: [LiveCallAudioRoute.Output] = []

    init(speaker: Bool) { self.speaker = speaker }

    /// What the call sounds through now.
    var heard: [LiveCallAudioRoute.Output] { overridden ? [.builtInSpeaker] : systemRoute }

    mutating func change(_ trigger: LiveCallAudioRoute.Trigger, systemRoute: [LiveCallAudioRoute.Output]) {
        self.systemRoute = systemRoute
        guard case let .decide(clearingOverride) = LiveCallAudioRoute.action(for: trigger) else { return }
        if clearingOverride { overridden = false }
        overridden = LiveCallAudioRoute.forcesSpeaker(speaker: speaker, outputs: heard)
    }
}
