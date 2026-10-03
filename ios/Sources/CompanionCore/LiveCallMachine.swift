// A Live call as the phone sees it, with no microphone and no network: the
// phases the bar can be in, the events that move it, and the effects the app
// must carry out. LiveCallController (app target) owns the WebRTC media and
// the HTTP calls and feeds this machine; the machine decides.
//
// The Mac owns the call. The phone's phase is only ever "what I am doing
// about it": starting one, being on it, ending it, or showing why it stopped.
// Frames about calls this phone did not start never move the machine — the
// remote bar reads those straight from `CompanionState.liveCall`.
import Foundation

public struct LiveCallMachine: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var botId: String
        public var botName: String
        public var threadId: String

        public init(botId: String, botName: String, threadId: String) {
            self.botId = botId
            self.botName = botName
            self.threadId = threadId
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Mic permission, offer, POST — all in flight.
        case starting(Target)
        /// The Mac accepted; `call` is its latest word on the call.
        case live(Target, call: LiveCallState)
        /// We asked the Mac to end it; waiting for its word or a timeout.
        case ending(Target, call: LiveCallState)
        /// Over, and the bar says why until the person dismisses it.
        case stopped(Target, notice: LiveCallNotice)
    }

    public enum Event: Equatable, Sendable {
        case start(Target)
        case micDenied
        /// `POST /api/live/session` answered 201 and the answer was applied.
        case started(LiveCallState)
        case startFailed(LiveCallNotice)
        /// The Mac's current call: a `live.call` frame or `GET /api/live/call`.
        case serverCall(LiveCallState?)
        /// The peer connection failed.
        case mediaFailed
        /// The peer connection reached `connected`: the audio got through.
        case mediaConnected
        /// The "oai-events" channel opened. It rides the same transport, so
        /// the audio got through too.
        case channelOpened
        /// `connectTimeout` ran out for this call (armed by `awaitMedia`).
        case connectTimedOut(callId: String)
        /// The data channel closed (OpenAI sent `session.closed`, or the channel went away).
        case channelClosed
        case hangUp
        case leaveForeground
        /// AVAudioSession interruption began (a phone call, Siri).
        case interrupted
        /// This phone's session was refused (unpaired, its token revoked,
        /// or the computer changed): its call must not go on.
        case signedOut
        /// `POST /api/live/call/end` answered (or failed; either way we are done waiting).
        case ended
        case endTimedOut
        case retry
        case dismiss
        /// A start given up on (hung up, backgrounded, or an answer the
        /// media could not apply) got the Mac's 201 all the same. The
        /// controller ends that call; the machine only notes that it was
        /// this phone's, so its frames never read as another device's call.
        case startAbandoned(callId: String)
    }

    public enum Effect: Equatable, Sendable {
        /// Request the microphone, create the media, POST the offer.
        case begin(Target)
        /// Cancel a start in flight (and end on the Mac if a 201 races in).
        case abortStart
        /// Tear the media down; `sendClose` first says `session.close` on the channel.
        case closeMedia(sendClose: Bool)
        case endOnServer(callId: String)
        /// Arm a timeout so an unanswered end still returns the bar to idle.
        case awaitEnd
        /// Arm `connectTimeout` for this call. Unless the audio connects
        /// first, it comes back as `connectTimedOut(callId:)`.
        case awaitMedia(callId: String)
        /// The call is live on this phone: the computer reports it attached
        /// and the data channel is open. The clock counts from here, on the
        /// phone's own clock. Once per call.
        case startClock
    }

    /// How long a call's audio has to get through once the answer is in:
    /// the peer connection reaching `connected`. On a network that lets
    /// WebRTC through that takes a second or two. One that never gets there
    /// would leave the bar on "Connecting…" until the Mac's silence limit
    /// (5 minutes by default) while the OpenAI session bills, so the phone
    /// drops the call itself.
    public static let connectTimeout: Duration = .seconds(20)

    public private(set) var phase: Phase = .idle {
        didSet {
            if case .stopped = phase { return }
            stoppedCallId = nil
        }
    }

    /// The call a `.stopped` phase came from, while it is showing. OpenAI's
    /// `session.closed` reaches the phone's data channel directly, but the
    /// Mac's `ended` frame with the reason (idle, expired, its error text)
    /// goes OpenAI → Mac → SSE, so it usually lands after the phone has
    /// already stopped with a plain "Call ended". Keeping the id lets that
    /// frame still say why. Not part of `Phase`, so the bar's switch keeps
    /// its five cases.
    private var stoppedCallId: String?

    /// Whether this start's audio has got through. It can do so before the
    /// 201 is handled, so it is kept from the start on and cleared by the
    /// next one. Not part of `Phase` either: the bar's "Connecting…" follows
    /// the data channel, not this.
    private var mediaConnected = false

    /// This start's data channel is open, and whether its clock has started.
    /// Kept from the start on and cleared by the next one, as above.
    private var channelOpen = false
    private var clockStarted = false

    /// The last call the Mac made for this phone, kept after the machine
    /// goes idle. A hang-up returns to idle on the Mac's answer or on the
    /// end timeout, and the Mac's `ended` frame can come later still; until
    /// it does, `CompanionState.liveCall` still reads as a running call on
    /// this chat. Knowing it was this phone's keeps the remote bar ("Live
    /// with Ada from an iPhone") from showing the phone its own call.
    public private(set) var lastCallId: String?

    public init() {}

    public var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    /// Starting, live or ending: the phone holds (or is about to hold) the microphone.
    public var isActive: Bool {
        switch phase {
        case .starting, .live, .ending: return true
        case .idle, .stopped: return false
        }
    }

    public var target: Target? {
        switch phase {
        case .idle: return nil
        case let .starting(target), let .live(target, _), let .ending(target, _), let .stopped(target, _): return target
        }
    }

    /// Whether the bar still says "Connecting…": until the computer reports
    /// the call attached and this phone's data channel is open. A status
    /// this build does not know counts as attached; it is running.
    public var isConnecting: Bool {
        guard case let .live(_, call) = phase else { return false }
        return call.status == .connecting || !channelOpen
    }

    public var call: LiveCallState? {
        switch phase {
        case let .live(_, call), let .ending(_, call): return call
        case .idle, .starting, .stopped: return nil
        }
    }

    /// Whether the bar belongs on this chat: any phase but idle, on this thread.
    public func concerns(threadId: String) -> Bool {
        !isIdle && target?.threadId == threadId
    }

    /// Whether a chat may offer a new call, as far as this phone goes: not
    /// while it starts, holds or ends one, and not on the chat whose bar says
    /// why its call stopped (Try again or dismiss is the way on from there).
    /// A call that stopped by itself — idle, expired, dropped, refused —
    /// shows only on its own chat, so it must not take the button away from
    /// every other one; a start there replaces the old notice.
    public func allowsStart(onThread threadId: String) -> Bool {
        !isActive && !concerns(threadId: threadId)
    }

    /// The call the remote bar shows on this chat: one the Mac runs here
    /// that another device holds. Not this phone's own call, whose `ended`
    /// frame may still be on its way (see `lastCallId`), and not a call
    /// that is already `ending` — the desktop's rule too: a hang-up is
    /// briefly still ending on the Mac after its bar has gone.
    public func remoteCall(_ line: LiveCallState?, onThread threadId: String) -> LiveCallState? {
        guard let line, line.isRunning, line.status != .ending,
              line.threadId == threadId, line.callId != lastCallId else { return nil }
        return line
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        // MARK: starting
        case let (.idle, .start(target)), let (.stopped, .start(target)):
            return beginCall(target)
        case let (.stopped(target, notice), .retry) where notice.canRetry:
            return beginCall(target)
        case let (.starting(target), .micDenied):
            phase = .stopped(target, notice: .micDenied)
            return [.closeMedia(sendClose: false)]
        case let (.starting(target), .started(call)):
            lastCallId = call.callId
            if call.status == .ended {
                stop(target, LiveCallNotice.forEnd(call), callId: call.callId)
                return [.closeMedia(sendClose: false)]
            }
            phase = .live(target, call: call)
            // The answer is in; from here the audio has `connectTimeout`.
            return (mediaConnected ? [] : [.awaitMedia(callId: call.callId)]) + goLive()
        case (.starting, .mediaConnected), (.live, .mediaConnected):
            mediaConnected = true
            return []
        case (.starting, .channelOpened), (.live, .channelOpened):
            mediaConnected = true
            channelOpen = true
            return goLive()
        case (.starting, .channelClosed):
            channelOpen = false
            return []
        case let (.starting(target), .startFailed(notice)):
            phase = .stopped(target, notice: notice)
            return [.closeMedia(sendClose: false)]
        case (.starting, .leaveForeground), (.starting, .interrupted), (.starting, .hangUp):
            phase = .idle
            return [.abortStart, .closeMedia(sendClose: true)]
        case let (.starting(target), .signedOut):
            // As a hang-up while calling, but the bar says why: the
            // controller ends whatever a late 201 created.
            phase = .stopped(target, notice: .signedOut(message: nil))
            return [.abortStart, .closeMedia(sendClose: true)]

        // MARK: live
        case let (.live(target, current), .serverCall(latest)):
            guard let latest else {
                stop(target, .ended, callId: current.callId)
                return [.closeMedia(sendClose: true)]
            }
            guard latest.callId == current.callId else { return [] }
            if latest.status == .ended {
                stop(target, LiveCallNotice.forEnd(latest), callId: current.callId)
                return [.closeMedia(sendClose: true)]
            }
            phase = .live(target, call: latest)
            return goLive()
        case let (.live(target, call), .hangUp), let (.live(target, call), .leaveForeground), let (.live(target, call), .interrupted):
            phase = .ending(target, call: call)
            return [.closeMedia(sendClose: true), .endOnServer(callId: call.callId), .awaitEnd]
        case let (.live(target, call), .mediaFailed):
            stop(target, .dropped, callId: call.callId)
            return [.closeMedia(sendClose: false), .endOnServer(callId: call.callId)]
        case let (.live(target, call), .signedOut):
            // At once, and on the phone's own side: `session.close` on the
            // channel ends the OpenAI session even when the computer no
            // longer takes this phone's requests. The end request is best
            // effort; the computer ends the call of a phone it unpaired.
            stop(target, .signedOut(message: nil), callId: call.callId)
            return [.closeMedia(sendClose: true), .endOnServer(callId: call.callId)]
        case let (.live(target, call), .connectTimedOut(callId)) where callId == call.callId && !mediaConnected:
            // The answer went in but the audio never got through, and
            // `mediaFailed` may never come: ICE with no candidate to try
            // waits for one instead of failing. It ends as a drop ends,
            // with its own words; the close goes out on the channel should
            // it have opened after all. A timeout from an earlier call, or
            // one that fires after a hang-up, matches none of this and
            // falls through to the default.
            stop(target, .audioNeverConnected, callId: call.callId)
            return [.closeMedia(sendClose: true), .endOnServer(callId: call.callId)]
        case let (.live(target, call), .channelClosed):
            // OpenAI closed the session (idle, expired, hung up elsewhere).
            // The Mac's sideband saw it too; the end request is idempotent
            // and makes sure no ghost call survives a lost sideband. The
            // Mac's reason usually follows; see `stoppedCallId`.
            stop(target, .ended, callId: call.callId)
            return [.closeMedia(sendClose: false), .endOnServer(callId: call.callId)]

        // MARK: ending
        case (.ending, .ended), (.ending, .endTimedOut):
            phase = .idle
            return []
        case let (.ending(_, current), .serverCall(latest)):
            if latest == nil || (latest?.callId == current.callId && latest?.status == .ended) {
                phase = .idle
            }
            return []

        // MARK: stopped
        case let (.stopped(target, .ended), .serverCall(latest?))
            where latest.callId == stoppedCallId && latest.status == .ended:
            // The Mac's word on why this call ended, after the data channel
            // already stopped it. Only a plain "Call ended" is replaced: a
            // drop the phone saw itself stays a drop, whatever the phone's
            // own end request made the Mac record. The media is already down.
            phase = .stopped(target, notice: LiveCallNotice.forEnd(latest))
            return []
        case let (.stopped(target, .ended), .signedOut) where stoppedCallId != nil:
            // Unpairing ends the call on the computer too, and OpenAI's close
            // can reach the channel before this phone's stream is refused.
            // Only a plain "Call ended" of a call this phone had is replaced.
            phase = .stopped(target, notice: .signedOut(message: nil))
            return []
        case (.stopped, .dismiss):
            phase = .idle
            return []

        // MARK: any phase
        case let (_, .startAbandoned(callId)):
            // A redial waits for the abandoned start to finish, so this
            // lands before the next call's 201. Were a call running anyway,
            // its id is the one worth keeping.
            if call == nil { lastCallId = callId }
            return []

        default:
            return []
        }
    }

    /// A new start: nothing is known yet about its audio.
    private mutating func beginCall(_ target: Target) -> [Effect] {
        phase = .starting(target)
        mediaConnected = false
        channelOpen = false
        clockStarted = false
        return [.begin(target)]
    }

    /// The clock, the first time the bar would stop saying "Connecting…".
    private mutating func goLive() -> [Effect] {
        guard case .live = phase, !isConnecting, !clockStarted else { return [] }
        clockStarted = true
        return [.startClock]
    }

    private mutating func stop(_ target: Target, _ notice: LiveCallNotice, callId: String) {
        phase = .stopped(target, notice: notice)
        stoppedCallId = callId
    }
}
