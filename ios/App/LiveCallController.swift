// The phone's side of a Live call, wired together: the state machine that
// decides, the media that does, the Mac that owns the call.
//
// One instance for the whole app (CompanionApp), because a call outlives the
// chat it was started from — the bar sits in that chat, a thin banner
// everywhere else. Nothing here is optimistic about the call itself: the
// machine goes live on the Mac's 201 and ends on the Mac's word; only what is
// local (mute, speaker, captions, the clock) is decided on the phone.
import AVFoundation
import Combine
import CompanionCore
import OSLog
import SwiftUI

@MainActor
final class LiveCallController: ObservableObject {
    typealias MediaFactory = @MainActor () -> LiveCallMedia
    typealias MicPermission = @Sendable () async -> Bool

    /// How long to wait for the Mac's word after asking it to end the call.
    /// Longer than the Mac's own close window (the harness gives OpenAI 5 s
    /// to confirm the close before it ends the call itself) plus a round
    /// trip, so a slow close still ends on the Mac's answer, not on a guess.
    static let endTimeout: Duration = .seconds(8)
    /// How long `session.close` gets to leave before the transport goes.
    static let closeGrace: Duration = .milliseconds(250)

    @Published private(set) var machine = LiveCallMachine()
    @Published private(set) var isMuted = false
    /// The clock and the caption line: they change every second, and many
    /// times a second while the voice talks. Every chat, the roster and the
    /// settings sheet follow this controller; only the bar's title and
    /// caption and the banner follow the feed.
    let feed = LiveCallFeed()
    @Published var speakerOn: Bool {
        didSet {
            UserDefaults.standard.set(speakerOn, forKey: PrefKey.liveSpeaker)
            media?.setSpeaker(speakerOn)
        }
    }

    private let makeMedia: MediaFactory
    private let requestMic: MicPermission
    private let log = Logger(subsystem: "com.openmausbot.app", category: "live-call")
    private weak var session: Session?
    private var media: LiveCallMedia?
    /// The last call's media while its `session.close` is still leaving.
    /// The audio session is process-wide, so a new call closes it at once
    /// rather than let its late teardown deactivate the new call's audio.
    private var closing: (media: LiveCallMedia, grace: Task<Void, Never>)?
    private var mediaTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var endTimeoutTask: Task<Void, Never>?
    /// `LiveCallMachine.connectTimeout` for the call whose audio is still
    /// on its way. Cancelled when the audio connects or the media closes;
    /// the machine also ignores one that fires for any other call.
    private var connectTimeoutTask: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var connectedAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var interruptionObserver: (any NSObjectProtocol)?

    init(
        makeMedia: @escaping MediaFactory = { WebRTCLiveCallMedia() },
        requestMic: @escaping MicPermission = { await MicrophonePermission.request() }
    ) {
        self.makeMedia = makeMedia
        self.requestMic = requestMic
        self.speakerOn = UserDefaults.standard.object(forKey: PrefKey.liveSpeaker) as? Bool ?? true
    }

    /// Follow the Mac: every `live.call` frame (and the hydrate-time lookup)
    /// lands in `state.liveCall`; a change of computer hangs up, and so does
    /// the computer refusing this phone.
    func attach(to session: Session) {
        self.session = session
        cancellables.removeAll()
        session.$state
            .map(\.liveCall)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] call in self?.dispatch(.serverCall(call)) }
            .store(in: &cancellables)
        // Before the phone leaves this computer: hang up while the session
        // still talks to it, so the end request reaches the computer that
        // holds the call. Session clears its state next, and a call gone
        // from the state reads as the computer saying it ended, which asks
        // the computer nothing.
        session.leavingComputer
            .sink { [weak self] in self?.dispatch(.hangUp) }
            .store(in: &cancellables)
        session.$connection
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // A deliberate hang-up leaves no bar: dismiss clears the
                // notice of a call that had already stopped by itself.
                self?.dispatch(.hangUp)
                self?.dispatch(.dismiss)
            }
            .store(in: &cancellables)
        // Unpaired, its token revoked, or the computer changed under the
        // same connection: the call must not go on talking to the bot for a
        // phone that is no longer trusted. It hangs up at once, and the
        // unpaired screen that replaces the chat says why.
        session.$status
            .map { $0 == .unauthorized }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.dispatch(.signedOut) }
            .store(in: &cancellables)
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey]
                let value = (raw as? NSNumber)?.uintValue ?? (raw as? UInt)
                guard value == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.dispatch(.interrupted) }
            }
        }
    }

    // MARK: - Intent

    func start(bot: Bot) {
        dispatch(.start(LiveCallMachine.Target(botId: bot.id, botName: bot.name, threadId: bot.threadId)))
    }

    func hangUp() { dispatch(.hangUp) }
    func retry() { dispatch(.retry) }
    func dismiss() { dispatch(.dismiss) }
    func leaveForeground() { dispatch(.leaveForeground) }

    func toggleMute() {
        isMuted.toggle()
        media?.setMuted(isMuted)
    }

    func concerns(threadId: String) -> Bool { machine.concerns(threadId: threadId) }

    // MARK: - Machine

    private func dispatch(_ event: LiveCallMachine.Event) {
        let effects = machine.handle(event)
        log.info("live call: \(String(describing: event), privacy: .public) -> \(String(describing: self.machine.phase), privacy: .public)")
        for effect in effects { run(effect) }
    }

    private func run(_ effect: LiveCallMachine.Effect) {
        switch effect {
        case let .begin(target):
            begin(target)
        case .abortStart:
            // Kept, not dropped: its POST runs on to the Mac's answer (see
            // `begin`), and a redial waits for that start to finish.
            startTask?.cancel()
        case let .closeMedia(sendClose):
            closeMedia(sendClose: sendClose)
        case let .endOnServer(callId):
            // Sent to the computer that holds the call: a change of computers
            // replaces the session's client right after this effect runs.
            let end = session?.endLiveCall(callId: callId)
            Task { [weak self] in
                _ = await end?.value
                self?.dispatch(.ended)
            }
        case .awaitEnd:
            endTimeoutTask?.cancel()
            endTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.endTimeout)
                guard !Task.isCancelled else { return }
                self?.dispatch(.endTimedOut)
            }
        case let .awaitMedia(callId):
            connectTimeoutTask?.cancel()
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: LiveCallMachine.connectTimeout)
                guard !Task.isCancelled else { return }
                self?.dispatch(.connectTimedOut(callId: callId))
            }
        case .startClock:
            startClock()
        }
    }

    // MARK: - Starting

    private func begin(_ target: LiveCallMachine.Target) {
        // An abandoned start may still be waiting on its POST, and will end
        // what it created. Asking for the line before then would get the
        // Mac's "busy" about that very call, so the new start waits for it.
        let previous = startTask
        previous?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            // Permission first, session second: a session created while the
            // person reads the prompt bills OpenAI for nothing.
            let granted = await requestMic()
            // A start that was abandoned (hung up, backgrounded, a newer
            // start) must not move the machine: it may be on another call.
            guard !Task.isCancelled else { return }
            guard granted else {
                dispatch(.micDenied)
                return
            }
            guard let session else {
                dispatch(.startFailed(.unreachable(String(localized: "This computer is offline."))))
                return
            }
            finishClosing()
            VoiceNoteCenter.shared.beginInputOwnership(.liveCall)
            let media = makeMedia()
            self.media = media
            observe(media)
            var created: (callId: String, end: @MainActor () -> Task<LiveCallState?, Never>)?
            do {
                let offer = try await media.createOffer()
                await previous?.value
                try Task.checkCancellation()
                // In a task of its own, so a hang-up does not cancel it.
                // URLSession stops a cancelled request and drops the 201,
                // but the Mac has already made the call, and it would hold
                // the line until its idle timer. Run to the answer instead;
                // the catch below ends whatever a 201 created.
                let (start, end) = try await Task {
                    try await session.startLiveCall(botId: target.botId, threadId: target.threadId, sdp: offer)
                }.value
                created = (start.call.callId, end)
                try Task.checkCancellation()
                if start.call.status == .ended {
                    dispatch(.started(start.call))
                    return
                }
                try await media.accept(answer: start.transport.sdp)
                try Task.checkCancellation()
                media.setSpeaker(speakerOn)
                media.setMuted(isMuted)
                dispatch(.started(start.call))
                // The machine ignores frames while starting, so a `live`
                // frame that beat the answer would otherwise leave the bar
                // on the 201's "connecting" until the next frame.
                if let latest = session.state.liveCall { dispatch(.serverCall(latest)) }
            } catch {
                // A 201 we could not follow through leaves a call on the Mac.
                // The end runs in a task of its own (`endLiveCall` makes one):
                // in this one, cancelled by the hang-up, the end request would
                // be cancelled before it left.
                if let created {
                    log.info("live call: ending a call whose start did not finish")
                    dispatch(.startAbandoned(callId: created.callId))
                    _ = await created.end().value
                }
                guard !Task.isCancelled else { return }
                let notice = LiveCallNotice.forStartFailure(error) { [weak session] botId in
                    session?.state.bot(botId)?.name
                }
                dispatch(.startFailed(notice))
            }
        }
    }

    private func observe(_ media: LiveCallMedia) {
        mediaTask?.cancel()
        mediaTask = Task { [weak self] in
            for await event in media.events {
                guard let self, !Task.isCancelled else { return }
                handleMedia(event)
            }
        }
    }

    private func handleMedia(_ event: LiveCallMediaEvent) {
        switch event {
        case .connected:
            mediaConnected(.mediaConnected)
        case .channelOpen:
            // The channel rides the same transport, so it opening means the
            // call connected, should the peer connection's own word be late.
            // Captions can arrive now, and the bar may stop saying
            // "Connecting…" (the machine's `isConnecting`).
            mediaConnected(.channelOpened)
        case .channelClosed:
            dispatch(.channelClosed)
        case let .data(.inputTranscript(delta)):
            feed.captions.append(delta, from: .user)
        case let .data(.outputTranscript(delta)):
            feed.captions.append(delta, from: .voice)
        case let .data(.closed(reason)):
            log.info("live call: session closed (\(reason ?? "-", privacy: .public))")
            dispatch(.channelClosed)
        case let .data(.error(message)):
            // Appends still pending when the session closes produce errors;
            // none of them is a reason to hang up. Logged, not shown.
            log.notice("live call: data channel error (\(message.count, privacy: .public) chars)")
        case .data(.started), .data(.other):
            break
        case let .failed(message):
            log.error("live call: media failed: \(message, privacy: .public)")
            dispatch(.mediaFailed)
        }
    }

    /// The audio got through: the connect timeout has nothing left to wait for.
    private func mediaConnected(_ event: LiveCallMachine.Event) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        dispatch(event)
    }

    // MARK: - Stopping

    private func closeMedia(sendClose: Bool) {
        endTimeoutTask?.cancel()
        endTimeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopClock()
        feed.captions = LiveCaptions()
        isMuted = false
        guard let media else {
            VoiceNoteCenter.shared.endInputOwnership(.liveCall)
            return
        }
        self.media = nil
        media.setMuted(true)
        mediaTask?.cancel()
        mediaTask = nil
        if sendClose {
            // Give the close a moment to leave before the transport goes.
            finishClosing()
            media.sendClose()
            let grace = Task { [weak self] in
                try? await Task.sleep(for: Self.closeGrace)
                guard !Task.isCancelled else { return }
                self?.finishClosing()
            }
            closing = (media, grace)
        } else {
            media.close()
            VoiceNoteCenter.shared.endInputOwnership(.liveCall)
        }
    }

    /// Close the media still in its grace period, now.
    private func finishClosing() {
        guard let closing else { return }
        self.closing = nil
        closing.grace.cancel()
        closing.media.close()
        VoiceNoteCenter.shared.endInputOwnership(.liveCall)
    }

    // MARK: - Clock

    /// From the moment the bar shows the call live (the machine's
    /// `startClock`), on this phone's own clock.
    private func startClock() {
        connectedAt = Date()
        feed.elapsedSeconds = 0
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let connectedAt = self.connectedAt else { return }
                self.feed.elapsedSeconds = Int(Date().timeIntervalSince(connectedAt))
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
        connectedAt = nil
        feed.elapsedSeconds = 0
    }
}

/// What a call changes all the time: the clock and the caption line. Apart
/// from `LiveCallController` so a tick or a word redraws only the lines that
/// show them. As the controller's own, each one redrew every screen that
/// follows the call (the chat, the roster, the settings sheet over them), and
/// a tap that landed during one of those redraws was lost: a settings switch
/// flipped while the voice talked sprang back and never reached the Mac.
@MainActor
final class LiveCallFeed: ObservableObject {
    @Published fileprivate(set) var captions = LiveCaptions()
    @Published fileprivate(set) var elapsedSeconds = 0
}

extension ScenePhase {
    /// SwiftUI's phase, in CompanionCore's words, so the rule can be tested there.
    var liveCallPhase: LiveCallLifecycle.ScenePhase {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }
}

extension LiveCallController {
    /// Production media, unless a preview launch argument asks for the fake.
    static func forThisLaunch() -> LiveCallController {
        #if DEBUG
        if LiveCallPreview.wantsFakeMedia {
            return LiveCallController(makeMedia: { PreviewLiveCallMedia() }, requestMic: { true })
        }
        #endif
        return LiveCallController()
    }
}
