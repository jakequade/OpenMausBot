// Every way a Live call can go, as transitions on a value type. The
// controller only forwards events and runs effects; if a transition is wrong
// it is wrong here, where a test can say so without a microphone.
import XCTest
@testable import CompanionCore

final class LiveCallMachineTests: XCTestCase {
    private let ada = LiveCallMachine.Target(botId: "b1", botName: "Ada", threadId: "t1")

    private func call(_ status: LiveCallState.Status = .connecting, id: String = "c1", endReason: String? = nil) -> LiveCallState {
        LiveCallState(callId: id, botId: "b1", threadId: "t1", client: "ios", voice: "marin", startedAt: 1, status: status, endReason: endReason)
    }

    private func live() -> LiveCallMachine {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        _ = machine.handle(.started(call(.connecting)))
        return machine
    }

    // MARK: - Starting

    func testStartBeginsMediaAndTheRequest() {
        var machine = LiveCallMachine()
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.start(ada)), [.begin(ada)])
        XCTAssertEqual(machine.phase, .starting(ada))
        XCTAssertTrue(machine.isActive)
        XCTAssertTrue(machine.concerns(threadId: "t1"))
        XCTAssertFalse(machine.concerns(threadId: "t2"))
        // a second tap while starting does nothing
        XCTAssertEqual(machine.handle(.start(ada)), [])
    }

    func testTheMacsAcceptanceMakesTheCallLive() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.started(call(.connecting))), [.awaitMedia(callId: "c1")], "the audio's clock starts with the answer")
        XCTAssertEqual(machine.phase, .live(ada, call: call(.connecting)))
        XCTAssertEqual(machine.call?.callId, "c1")
    }

    func testAnAcceptanceThatAlreadyEndedStopsWithTheComputersReason() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        let ended = call(.ended, endReason: "sideband-lost")
        XCTAssertEqual(machine.handle(.started(ended)), [.closeMedia(sendClose: false)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .dropped))
        XCTAssertEqual(machine.lastCallId, "c1")
        XCTAssertFalse(machine.isActive)
    }

    func testADeniedMicrophoneStopsWithoutARetry() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.micDenied), [.closeMedia(sendClose: false)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .micDenied))
        XCTAssertFalse(machine.isActive)
        XCTAssertEqual(machine.handle(.retry), [], "Try again is not offered; Settings is the fix")
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .micDenied))
    }

    func testAFailedStartShowsWhyAndCanBeRetried() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.startFailed(.refused("OpenAI refused the call."))), [.closeMedia(sendClose: false)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .refused("OpenAI refused the call.")))
        XCTAssertEqual(machine.handle(.retry), [.begin(ada)])
        XCTAssertEqual(machine.phase, .starting(ada))
    }

    func testAnAnswerThatCannotBeAppliedStopsWithANotice() {
        // the controller reports setRemoteDescription failures as a start
        // failure after telling the Mac to end the call it just created
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.startFailed(.couldNotStart("bad answer"))), [.closeMedia(sendClose: false)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .couldNotStart("bad answer")))
        XCTAssertTrue(LiveCallNotice.couldNotStart("bad answer").canRetry)
    }

    func testLeavingWhileStartingAbortsQuietly() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.leaveForeground), [.abortStart, .closeMedia(sendClose: true)])
        XCTAssertTrue(machine.isIdle)
    }

    func testHangingUpWhileCallingAbortsTheStart() {
        // the bar's hang-up while it still says "Calling…": no notice, the
        // start is cancelled, and a 201 that lands later is not a call
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.hangUp), [.abortStart, .closeMedia(sendClose: true)])
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.started(call(.connecting))), [], "the abandoned start's 201 moves nothing")
        XCTAssertTrue(machine.isIdle)
        XCTAssertTrue(machine.allowsStart(onThread: "t1"))
    }

    func testAnAbandonedStartsCallIsStillKnownAsThisPhones() {
        // the controller ends what a late 201 created and says so first, so
        // that call's frames never show as another device's call
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        _ = machine.handle(.hangUp)
        XCTAssertEqual(machine.handle(.startAbandoned(callId: "c9")), [])
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.lastCallId, "c9")
        XCTAssertNil(machine.remoteCall(call(.connecting, id: "c9"), onThread: "t1"))

        // a call that is running keeps its own id
        var running = live()
        XCTAssertEqual(running.handle(.startAbandoned(callId: "old")), [])
        XCTAssertEqual(running.lastCallId, "c1")
        XCTAssertEqual(running.phase, .live(ada, call: call(.connecting)))
    }

    // MARK: - Going live

    func testTheBarGoesLiveAndTheClockStartsOnceTheComputerAndTheChannelAreBothThere() {
        // The computer attaches (`live`) and this phone's data channel
        // opens, in either order. "Connecting…" until both; the clock counts
        // from the later of the two, on the phone's own clock.
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.started(call(.connecting))), [.awaitMedia(callId: "c1")], "no clock while connecting")
        XCTAssertTrue(machine.isConnecting)
        XCTAssertEqual(machine.handle(.channelOpened), [], "the computer has not attached yet")
        XCTAssertTrue(machine.isConnecting)
        XCTAssertEqual(machine.handle(.serverCall(call(.live))), [.startClock])
        XCTAssertFalse(machine.isConnecting)
        XCTAssertEqual(machine.handle(.serverCall(call(.live))), [], "once per call")

        var computerFirst = live()
        XCTAssertEqual(computerFirst.handle(.serverCall(call(.live))), [])
        XCTAssertTrue(computerFirst.isConnecting, "the channel is not open yet")
        XCTAssertEqual(computerFirst.handle(.channelOpened), [.startClock])
        XCTAssertFalse(computerFirst.isConnecting)
    }

    func testAChannelThatOpenedBeforeTheAnswerWasHandledCounts() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.channelOpened), [])
        XCTAssertEqual(machine.handle(.started(call(.live))), [.startClock], "the audio got through: no connect timeout either")
        XCTAssertFalse(machine.isConnecting)
    }

    func testEachCallGetsItsOwnClock() {
        var machine = live()
        _ = machine.handle(.channelOpened)
        XCTAssertEqual(machine.handle(.serverCall(call(.live))), [.startClock])
        _ = machine.handle(.hangUp)
        _ = machine.handle(.ended)
        _ = machine.handle(.start(ada))
        _ = machine.handle(.started(call(.connecting, id: "c2")))
        XCTAssertTrue(machine.isConnecting, "a new call connects again")
        XCTAssertEqual(machine.handle(.serverCall(call(.live, id: "c2"))), [])
        XCTAssertEqual(machine.handle(.channelOpened), [.startClock])
    }

    // MARK: - Live

    func testTheMacsWordUpdatesTheCall() {
        var machine = live()
        XCTAssertEqual(machine.handle(.serverCall(call(.live))), [])
        XCTAssertEqual(machine.call?.status, .live)
    }

    func testAnEndedFrameForThisCallStopsWithItsReason() {
        var machine = live()
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, endReason: "idle"))), [.closeMedia(sendClose: true)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .endedIdle))
    }

    func testAnEndedFrameForAnotherCallIdIsIgnored() {
        // the previous call's `ended` can land after this one's 201
        var machine = live()
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, id: "old"))), [])
        XCTAssertEqual(machine.phase, .live(ada, call: call(.connecting)))
    }

    func testNullFromTheMacEndsTheCallWithoutARetryStorm() {
        // harness restart: GET /api/live/call comes back null
        var machine = live()
        XCTAssertEqual(machine.handle(.serverCall(nil)), [.closeMedia(sendClose: true)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .ended))
        XCTAssertEqual(machine.handle(.serverCall(nil)), [], "a repeat changes nothing")
    }

    func testHangUpTellsTheMacAndWaitsForItsWord() {
        var machine = live()
        XCTAssertEqual(machine.handle(.hangUp), [.closeMedia(sendClose: true), .endOnServer(callId: "c1"), .awaitEnd])
        XCTAssertEqual(machine.phase, .ending(ada, call: call(.connecting)))
        XCTAssertTrue(machine.isActive)
        XCTAssertEqual(machine.handle(.ended), [])
        XCTAssertTrue(machine.isIdle, "a deliberate hang-up leaves no notice behind")
    }

    func testLeavingTheComputerTellsItOnceAndLeavesNoBar() {
        // The controller hangs up before Session clears its state (a new
        // pairing, a switch, forgetting the computer). The cleared state,
        // the new connection and the end request's return change nothing.
        var machine = live()
        XCTAssertEqual(machine.handle(.hangUp), [.closeMedia(sendClose: true), .endOnServer(callId: "c1"), .awaitEnd])
        XCTAssertEqual(machine.handle(.serverCall(nil)), [])
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.hangUp), [])
        XCTAssertEqual(machine.handle(.dismiss), [])
        XCTAssertEqual(machine.handle(.ended), [])
        XCTAssertTrue(machine.isIdle)
    }

    func testLeavingTheForegroundHangsUpAndTellsTheMac() {
        var machine = live()
        XCTAssertEqual(machine.handle(.leaveForeground), [.closeMedia(sendClose: true), .endOnServer(callId: "c1"), .awaitEnd])
        XCTAssertEqual(machine.handle(.endTimedOut), [])
        XCTAssertTrue(machine.isIdle)
    }

    func testAPhoneCallInterruptionHangsUp() {
        var machine = live()
        XCTAssertEqual(machine.handle(.interrupted), [.closeMedia(sendClose: true), .endOnServer(callId: "c1"), .awaitEnd])
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, endReason: "hung-up"))), [])
        XCTAssertTrue(machine.isIdle, "the Mac's ended frame settles an ending call too")
    }

    func testMediaFailureIsDroppedAndTheMacIsTold() {
        var machine = live()
        XCTAssertEqual(machine.handle(.mediaFailed), [.closeMedia(sendClose: false), .endOnServer(callId: "c1")])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .dropped))
        XCTAssertEqual(machine.handle(.ended), [], "the end confirmation does not clear a notice")
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .dropped))
    }

    func testTheChannelClosingEndsTheCall() {
        var machine = live()
        XCTAssertEqual(machine.handle(.channelClosed), [.closeMedia(sendClose: false), .endOnServer(callId: "c1")])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .ended))
    }

    func testTheMacsReasonStillArrivesAfterTheChannelCloses() {
        // OpenAI's `session.closed` reaches the phone straight away; the
        // Mac's `ended` frame with the reason takes the long way round
        var machine = live()
        _ = machine.handle(.serverCall(call(.ending)))
        _ = machine.handle(.channelClosed)
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, endReason: "idle"))), [], "the media is already down")
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .endedIdle))

        var expired = live()
        _ = expired.handle(.channelClosed)
        _ = expired.handle(.serverCall(call(.ended, endReason: "expired")))
        XCTAssertEqual(expired.phase, .stopped(ada, notice: .endedExpired))

        var failed = live()
        _ = failed.handle(.channelClosed)
        var withError = call(.ended, endReason: "error")
        withError.error = "The call connection to OpenAI dropped."
        _ = failed.handle(.serverCall(withError))
        XCTAssertEqual(failed.phase, .stopped(ada, notice: .endedWithError("The call connection to OpenAI dropped.", dropped: true)))
    }

    func testALateEndedFrameOnlyExplainsThisCallsPlainEnd() {
        var machine = live()
        _ = machine.handle(.channelClosed)
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, id: "old", endReason: "idle"))), [])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .ended), "another call's reason is not this call's")

        var dropped = live()
        _ = dropped.handle(.mediaFailed)
        XCTAssertEqual(dropped.handle(.serverCall(call(.ended, endReason: "hung-up"))), [])
        XCTAssertEqual(dropped.phase, .stopped(ada, notice: .dropped), "the phone's own end request does not relabel a drop")

        // dismissing forgets why the call stopped: a late reason for it
        // no longer brings a notice back
        _ = machine.handle(.dismiss)
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.serverCall(call(.ended, endReason: "idle"))), [])
        XCTAssertTrue(machine.isIdle)
    }

    // MARK: - Audio that never connects

    func testAudioThatNeverConnectsIsDroppedAfterTwentySeconds() {
        // The simulator run: the answer went in, the peer connection
        // neither connected nor failed, and the bar said "Connecting…" for
        // five minutes while OpenAI billed.
        var line = Timeline()
        line.send(.start(ada))
        line.send(.started(call(.connecting)))
        line.advance(by: .seconds(19))
        XCTAssertEqual(line.machine.phase, .live(ada, call: call(.connecting)), "still connecting at 0:19")
        XCTAssertEqual(line.endRequests, [])

        line.advance(by: .seconds(1))
        XCTAssertEqual(line.machine.phase, .stopped(ada, notice: .audioNeverConnected))
        XCTAssertEqual(line.endRequests, ["c1"], "the Mac is told at 0:20")
        XCTAssertTrue(LiveCallNotice.audioNeverConnected.canRetry)

        // The Mac's answer to that end request, and its ended frame, neither
        // relabel the drop nor send a second request.
        line.send(.ended)
        line.send(.serverCall(call(.ended, endReason: "hung-up")))
        line.advance(by: .seconds(60))
        XCTAssertEqual(line.machine.phase, .stopped(ada, notice: .audioNeverConnected))
        XCTAssertEqual(line.endRequests, ["c1"], "one end request")
    }

    func testTheDropClosesTheSessionReleasesTheMediaAndTellsTheMac() {
        // As a dropped connection ends, plus `session.close` on the channel
        // (sent only if the channel ever opened).
        var machine = live()
        XCTAssertEqual(machine.handle(.connectTimedOut(callId: "c1")), [.closeMedia(sendClose: true), .endOnServer(callId: "c1")])
        XCTAssertFalse(machine.isActive, "the microphone is given back")
        XCTAssertEqual(machine.handle(.retry), [.begin(ada)], "Try again")
    }

    func testAudioThatConnectsInTimeIsNeverDropped() {
        var line = Timeline()
        line.send(.start(ada))
        line.send(.started(call(.connecting)))
        line.advance(by: .seconds(3))
        line.send(.mediaConnected)
        line.advance(by: .seconds(120))
        XCTAssertEqual(line.machine.phase, .live(ada, call: call(.connecting)))
        XCTAssertEqual(line.endRequests, [])

        // The audio can beat the Mac's 201 to the machine; then there is
        // nothing to wait for.
        var early = Timeline()
        early.send(.start(ada))
        early.send(.mediaConnected)
        early.send(.started(call(.connecting)))
        XCTAssertTrue(early.alarms.isEmpty)
        early.advance(by: .seconds(120))
        XCTAssertEqual(early.machine.phase, .live(ada, call: call(.connecting)))
        XCTAssertEqual(early.endRequests, [])
    }

    func testAHangUpBeforeTheTimeoutLeavesNoLateDrop() {
        var line = Timeline()
        line.send(.start(ada))
        line.send(.started(call(.connecting)))
        line.advance(by: .seconds(5))
        line.send(.hangUp)
        line.send(.ended)
        XCTAssertTrue(line.machine.isIdle)
        line.advance(by: .seconds(60))
        XCTAssertTrue(line.machine.isIdle, "no notice turns up after a hang-up")
        XCTAssertEqual(line.endRequests, ["c1"], "the hang-up's request, and no second one")

        // The timeout fires while the hang-up still waits for the Mac.
        var slow = Timeline()
        slow.send(.start(ada))
        slow.send(.started(call(.connecting)))
        slow.advance(by: .seconds(19))
        slow.send(.hangUp)
        slow.advance(by: .seconds(1))
        XCTAssertEqual(slow.machine.phase, .ending(ada, call: call(.connecting)))
        slow.send(.ended)
        XCTAssertTrue(slow.machine.isIdle)
        XCTAssertEqual(slow.endRequests, ["c1"])

        // A call OpenAI already closed keeps its own reason.
        var closed = Timeline()
        closed.send(.start(ada))
        closed.send(.started(call(.connecting)))
        closed.send(.channelClosed)
        closed.advance(by: .seconds(20))
        XCTAssertEqual(closed.machine.phase, .stopped(ada, notice: .ended))
        XCTAssertEqual(closed.endRequests, ["c1"])
    }

    func testALaterCallIsNotDroppedByAnEarlierCallsTimeout() {
        var line = Timeline()
        line.send(.start(ada))
        line.send(.started(call(.connecting)))                  // c1 at 0:00
        line.advance(by: .seconds(2))
        line.send(.hangUp)
        line.send(.ended)
        line.advance(by: .seconds(8))
        line.send(.start(ada))
        line.send(.started(call(.connecting, id: "c2")))        // c2 at 0:10
        line.advance(by: .seconds(10))                          // c1's timeout
        XCTAssertEqual(line.machine.phase, .live(ada, call: call(.connecting, id: "c2")), "c1's timeout is not c2's")
        XCTAssertEqual(line.endRequests, ["c1"])
        line.advance(by: .seconds(10))                          // c2's own
        XCTAssertEqual(line.machine.phase, .stopped(ada, notice: .audioNeverConnected))
        XCTAssertEqual(line.endRequests, ["c1", "c2"])

        // Try again gets a call of its own, and this one connects.
        line.send(.retry)
        line.send(.started(call(.connecting, id: "c3")))
        line.send(.mediaConnected)
        line.advance(by: .seconds(120))
        XCTAssertEqual(line.machine.phase, .live(ada, call: call(.connecting, id: "c3")))
        XCTAssertEqual(line.endRequests, ["c1", "c2"])

        // One call's audio getting through says nothing about the next's.
        line.send(.hangUp)
        line.send(.ended)
        line.send(.start(ada))
        line.send(.started(call(.connecting, id: "c4")))
        line.advance(by: .seconds(20))
        XCTAssertEqual(line.machine.phase, .stopped(ada, notice: .audioNeverConnected))
        XCTAssertEqual(line.endRequests, ["c1", "c2", "c3", "c4"])
    }

    // MARK: - Stopped and idle

    func testDismissClearsANoticeAndANewCallCanStart() {
        var machine = live()
        _ = machine.handle(.mediaFailed)
        XCTAssertEqual(machine.handle(.dismiss), [])
        XCTAssertTrue(machine.isIdle)
        let other = LiveCallMachine.Target(botId: "b2", botName: "Bo", threadId: "t2")
        XCTAssertEqual(machine.handle(.start(other)), [.begin(other)])
        XCTAssertEqual(machine.target, other)
    }

    // MARK: - Signed out

    func testARefusedPhoneHangsUpAtOnceAndSaysWhy() {
        // Unpaired on the computer, its token refused: the call must not go
        // on talking to the bot for a phone that is no longer trusted.
        var machine = live()
        XCTAssertEqual(machine.handle(.signedOut), [.closeMedia(sendClose: true), .endOnServer(callId: "c1")])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .signedOut(message: nil)))
        XCTAssertFalse(machine.isActive, "the microphone is given back")
        XCTAssertEqual(machine.handle(.retry), [], "pairing again is the way on, not Try again")
        XCTAssertEqual(machine.handle(.signedOut), [], "a repeat changes nothing")
    }

    func testARefusedPhoneAbandonsAStartInFlight() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.handle(.signedOut), [.abortStart, .closeMedia(sendClose: true)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .signedOut(message: nil)))
        XCTAssertEqual(machine.handle(.started(call(.connecting))), [], "a 201 that races in is not a call")
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .signedOut(message: nil)))
    }

    func testARefusalExplainsACallThatJustEndedPlainly() {
        // Unpairing ends the call on the computer too, and OpenAI's close
        // can reach the phone's channel before its stream is refused.
        var closed = live()
        _ = closed.handle(.channelClosed)
        XCTAssertEqual(closed.handle(.signedOut), [], "the media is already down")
        XCTAssertEqual(closed.phase, .stopped(ada, notice: .signedOut(message: nil)))

        var dropped = live()
        _ = dropped.handle(.mediaFailed)
        XCTAssertEqual(dropped.handle(.signedOut), [])
        XCTAssertEqual(dropped.phase, .stopped(ada, notice: .dropped), "a drop the phone saw stays a drop")

        var failed = LiveCallMachine()
        _ = failed.handle(.start(ada))
        _ = failed.handle(.startFailed(.needsKey))
        XCTAssertEqual(failed.handle(.signedOut), [])
        XCTAssertEqual(failed.phase, .stopped(ada, notice: .needsKey), "a start that failed was no call")

        var ending = live()
        _ = ending.handle(.hangUp)
        XCTAssertEqual(ending.handle(.signedOut), [], "already hanging up")
        XCTAssertEqual(ending.phase, .ending(ada, call: call(.connecting)))

        var idle = LiveCallMachine()
        XCTAssertEqual(idle.handle(.signedOut), [])
        XCTAssertTrue(idle.isIdle)
    }

    func testTheComputersSignedOutEndHasNoTryAgain() {
        var machine = live()
        var unpaired = call(.ended, endReason: "signed-out")
        unpaired.error = "The call has ended because the phone that started it was unpaired from this computer."
        XCTAssertEqual(machine.handle(.serverCall(unpaired)), [.closeMedia(sendClose: true)])
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .signedOut(message: unpaired.error)))
        XCTAssertEqual(machine.handle(.retry), [])
    }

    // MARK: - Offering a call

    func testNoChatOffersASecondCallWhileThisPhoneHoldsOne() {
        var machine = LiveCallMachine()
        XCTAssertTrue(machine.allowsStart(onThread: "t1"))
        XCTAssertTrue(machine.allowsStart(onThread: "t2"))
        _ = machine.handle(.start(ada))
        XCTAssertFalse(machine.allowsStart(onThread: "t1"), "starting")
        XCTAssertFalse(machine.allowsStart(onThread: "t2"), "starting")
        _ = machine.handle(.started(call(.connecting)))
        XCTAssertFalse(machine.allowsStart(onThread: "t1"), "live")
        XCTAssertFalse(machine.allowsStart(onThread: "t2"), "live")
        _ = machine.handle(.hangUp)
        XCTAssertFalse(machine.allowsStart(onThread: "t1"), "ending")
        XCTAssertFalse(machine.allowsStart(onThread: "t2"), "ending")
        _ = machine.handle(.ended)
        XCTAssertTrue(machine.allowsStart(onThread: "t1"), "a hang-up leaves no bar behind")
        XCTAssertTrue(machine.allowsStart(onThread: "t2"))
    }

    func testACallThatStoppedByItselfOnlyHoldsItsOwnChat() {
        // An idle hang-up, an expiry or a drop shows why on its own chat
        // only. Every other chat must keep its phone button: nothing there
        // says why it would be gone.
        var machine = live()
        _ = machine.handle(.serverCall(call(.ended, endReason: "idle")))
        XCTAssertEqual(machine.phase, .stopped(ada, notice: .endedIdle))
        XCTAssertFalse(machine.allowsStart(onThread: "t1"), "its own chat offers Try again or dismiss instead")
        XCTAssertTrue(machine.allowsStart(onThread: "t2"))

        let bo = LiveCallMachine.Target(botId: "b2", botName: "Bo", threadId: "t2")
        XCTAssertEqual(machine.handle(.start(bo)), [.begin(bo)])
        XCTAssertEqual(machine.phase, .starting(bo))
        XCTAssertFalse(machine.concerns(threadId: "t1"), "the new call replaces the old notice")
    }

    func testAStartThatFailedOnlyHoldsItsOwnChat() {
        var machine = LiveCallMachine()
        _ = machine.handle(.start(ada))
        _ = machine.handle(.startFailed(.needsKey))
        XCTAssertFalse(machine.allowsStart(onThread: "t1"))
        XCTAssertTrue(machine.allowsStart(onThread: "t2"))
        _ = machine.handle(.dismiss)
        XCTAssertTrue(machine.allowsStart(onThread: "t1"))
    }

    // MARK: - The remote bar

    func testTheLastCallIdOutlivesTheHangUp() {
        // the machine goes idle on the Mac's answer or the end timeout; the
        // Mac's `ended` frame can come after that, and until it does the
        // line still reads as this phone's running call
        var machine = live()
        XCTAssertEqual(machine.lastCallId, "c1")
        _ = machine.handle(.hangUp)
        _ = machine.handle(.endTimedOut)
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.lastCallId, "c1")
        XCTAssertNil(machine.remoteCall(call(.live), onThread: "t1"), "never this phone's own call")

        // the same when the Mac's answer to the hang-up is what ends it
        var answered = live()
        _ = answered.handle(.hangUp)
        _ = answered.handle(.ended)
        XCTAssertTrue(answered.isIdle)
        XCTAssertEqual(answered.lastCallId, "c1")
        XCTAssertNil(answered.remoteCall(call(.ending), onThread: "t1"))
        XCTAssertNil(answered.remoteCall(call(.live), onThread: "t1"), "the ended frame is still on its way")

        _ = machine.handle(.start(ada))
        XCTAssertEqual(machine.lastCallId, "c1", "a start alone is no call yet")
        _ = machine.handle(.started(call(.connecting, id: "c2")))
        XCTAssertEqual(machine.lastCallId, "c2")
    }

    func testTheRemoteBarShowsAnotherDevicesRunningCallOnItsChat() {
        let machine = LiveCallMachine()
        var desktop = call(.live, id: "desktop-call")
        desktop.client = "desktop"
        XCTAssertEqual(machine.remoteCall(desktop, onThread: "t1"), desktop)
        XCTAssertNil(machine.remoteCall(desktop, onThread: "t2"), "another chat's call")
        XCTAssertNil(machine.remoteCall(nil, onThread: "t1"))

        desktop.status = .connecting
        XCTAssertEqual(machine.remoteCall(desktop, onThread: "t1")?.status, .connecting)
        desktop.status = .unknown
        XCTAssertEqual(machine.remoteCall(desktop, onThread: "t1")?.status, .unknown, "an unknown status still reads as running")
        desktop.status = .ending
        XCTAssertNil(machine.remoteCall(desktop, onThread: "t1"), "a hang-up is briefly still ending on the Mac")
        desktop.status = .ended
        XCTAssertNil(machine.remoteCall(desktop, onThread: "t1"))
    }

    func testSomebodyElsesCallLeavesAnIdlePhoneAlone() {
        // the Mac reports calls from other devices too; only the remote bar
        // reads those, never this machine
        var machine = LiveCallMachine()
        XCTAssertEqual(machine.handle(.serverCall(call(.live, id: "desktop-call"))), [])
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.serverCall(nil)), [])
        XCTAssertEqual(machine.handle(.hangUp), [])
        XCTAssertEqual(machine.handle(.leaveForeground), [])
        XCTAssertTrue(machine.isIdle)
    }
}

/// The controller's timers on a clock the test moves. `awaitMedia` sets an
/// alarm `connectTimeout` ahead that comes back as `connectTimedOut` for its
/// call. The controller also cancels that timer when the audio connects or
/// the call closes; this one never does, so every late or stale timeout
/// reaches the machine, which alone must make nothing of it. Each
/// `endOnServer` is a request to the Mac, counted.
private struct Timeline {
    private(set) var machine = LiveCallMachine()
    private(set) var now: Duration = .zero
    private(set) var alarms: [(at: Duration, event: LiveCallMachine.Event)] = []
    private(set) var endRequests: [String] = []

    mutating func send(_ event: LiveCallMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case let .awaitMedia(callId):
                alarms.append((now + LiveCallMachine.connectTimeout, .connectTimedOut(callId: callId)))
            case let .endOnServer(callId):
                endRequests.append(callId)
            case .begin, .abortStart, .closeMedia, .awaitEnd, .startClock:
                break
            }
        }
    }

    /// Move the clock on, firing each alarm that falls due, earliest first.
    mutating func advance(by duration: Duration) {
        now += duration
        while let due = alarms.indices.filter({ alarms[$0].at <= now }).min(by: { alarms[$0].at < alarms[$1].at }) {
            send(alarms.remove(at: due).event)
        }
    }
}
