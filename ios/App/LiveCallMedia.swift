// The phone's half of a Live call that touches hardware: the WebRTC peer
// connection to OpenAI, the microphone track, the speaker route, and the
// "oai-events" data channel that carries captions. Everything *decided*
// about a call lives in CompanionCore (LiveCallMachine, and
// LiveCallAudioRoute for the speaker); this file only does what it is told
// and reports what happened.
//
// This is the one file in the app that imports WebRTC. Keep it that way:
// the controller talks to `LiveCallMedia`, so previews and UI tests can run
// the whole bar with `PreviewLiveCallMedia` and no framework at all.
import AVFoundation
import CompanionCore
import Foundation
import OSLog
import WebRTC

enum LiveCallMediaEvent: Equatable {
    /// The peer connection reached `connected`: the audio got through. A
    /// call that neither gets here nor opens its channel within
    /// `LiveCallMachine.connectTimeout` of its answer is dropped.
    case connected
    case channelOpen
    case channelClosed
    case data(LiveCallDataEvent)
    /// The connection is gone for good (peer connection `failed`).
    case failed(String)
}

/// What a call needs from the media layer.
@MainActor
protocol LiveCallMedia: AnyObject {
    var events: AsyncStream<LiveCallMediaEvent> { get }
    /// Configure audio, add the microphone track, create the "oai-events"
    /// channel *before* the offer (so the offer carries the m=application
    /// line OpenAI needs), create the offer, set it locally, wait for ICE
    /// gathering (at most 10 s). Returns the local SDP, to be posted unchanged.
    func createOffer() async throws -> String
    /// Apply OpenAI's answer, exactly as the Mac relayed it.
    func accept(answer: String) async throws
    func setMuted(_ muted: Bool)
    /// The loudspeaker (true) or the earpiece while no headset is connected;
    /// a headset always takes the call (`LiveCallAudioRoute`).
    func setSpeaker(_ speaker: Bool)
    /// The one client event the phone may send: {"type":"session.close"}.
    func sendClose()
    /// Tear the peer connection down and give the audio session back.
    func close()
}

@MainActor
final class WebRTCLiveCallMedia: NSObject, LiveCallMedia {
    static let iceTimeout: Duration = .seconds(10)

    private static let log = Logger(subsystem: "com.openmausbot.app", category: "live-call-media")

    /// One factory per process: it owns the audio device module.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    let events: AsyncStream<LiveCallMediaEvent>
    private let emit: AsyncStream<LiveCallMediaEvent>.Continuation
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var track: RTCAudioTrack?
    private var iceWait: CheckedContinuation<Void, Never>?
    private var closed = false
    /// The person's Speaker or Earpiece choice. Nil until the controller
    /// applies it: until then the route is the system's own.
    private var speaker: Bool?
    private var routeObserver: (any NSObjectProtocol)?

    override init() {
        let (stream, continuation) = AsyncStream<LiveCallMediaEvent>.makeStream()
        events = stream
        emit = continuation
        super.init()
    }

    // MARK: - LiveCallMedia

    func createOffer() async throws -> String {
        try configureAudioSession()
        observeRouteChanges()

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        // Gather once, then send the whole offer: OpenAI answers with a
        // complete SDP and there is no trickle path. Same as the desktop.
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw LiveCallMediaError.offerFailed("WebRTC could not start.")
        }
        self.peer = peer

        let track = Self.factory.audioTrack(with: Self.factory.audioSource(with: constraints), trackId: "omb-mic")
        self.track = track
        guard peer.add(track, streamIds: ["omb"]) != nil else {
            throw LiveCallMediaError.offerFailed("The microphone track could not be added.")
        }

        // Before the offer, on purpose.
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw LiveCallMediaError.offerFailed("The event channel could not be created.")
        }
        channel.delegate = self
        self.channel = channel

        let offer = try await makeOffer(peer, constraints: constraints)
        try await setLocal(peer, offer)
        await waitForIceGathering(peer)
        guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty else {
            throw LiveCallMediaError.offerFailed("No local description.")
        }
        return sdp
    }

    func accept(answer: String) async throws {
        guard let peer else { throw LiveCallMediaError.answerRejected("The call was closed before the answer arrived.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error {
                    continuation.resume(throwing: LiveCallMediaError.answerRejected(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        track?.isEnabled = !muted
    }

    func setSpeaker(_ speaker: Bool) {
        self.speaker = speaker
        route(after: .setting)
    }

    func sendClose() {
        guard let channel, channel.readyState == .open else { return }
        _ = channel.sendData(RTCDataBuffer(data: LiveCallDataEvent.closeCommand, isBinary: false))
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        finishIceWait()
        channel?.delegate = nil
        channel?.close()
        channel = nil
        peer?.delegate = nil
        peer?.close()
        peer = nil
        track = nil
        releaseAudioSession()
        emit.finish()
    }

    // MARK: - Audio session

    /// WebRTC's own defaults are playAndRecord + voiceChat; set both anyway,
    /// as the spec asks, so nobody has to know that. Manual audio means the
    /// framework never activates the session on its own — `createOffer`
    /// runs only after the microphone permission is granted.
    private func configureAudioSession() throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        // No .defaultToSpeaker: the earpiece is the default and `setSpeaker`
        // overrides the port when no headset is connected, so the person's
        // choice actually applies.
        configuration.categoryOptions = [.allowBluetoothHFP]
        do {
            try audio.setConfiguration(configuration, active: true)
        } catch {
            throw LiveCallMediaError.offerFailed("The audio session could not be configured: \(error.localizedDescription)")
        }
        audio.isAudioEnabled = true
    }

    private func releaseAudioSession() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        audio.isAudioEnabled = false
        // The override belongs to the process-wide session, not the call.
        try? audio.overrideOutputAudioPort(.none)
        try? audio.setActive(false)
        audio.unlockForConfiguration()
        audio.useManualAudio = false
    }

    // MARK: - Route

    /// Earbuds put in mid-call take it; taken out, the call goes back to the
    /// Speaker setting. Registered once the call has configured the session.
    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey]
            let value = (raw as? NSNumber)?.uintValue ?? (raw as? UInt)
            let trigger = LiveCallAudioRoute.Trigger(value.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)))
            Task { @MainActor in self?.route(after: trigger) }
        }
    }

    /// Apply `LiveCallAudioRoute` to the route the system reports now. Only
    /// while this call holds the session, and only once the controller has
    /// applied the person's choice.
    private func route(after trigger: LiveCallAudioRoute.Trigger) {
        guard !closed, peer != nil, let speaker,
              case let .decide(clearingOverride) = LiveCallAudioRoute.action(for: trigger) else { return }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            if clearingOverride { try audio.overrideOutputAudioPort(.none) }
            let outputs = audio.currentRoute.outputs.map { LiveCallAudioRoute.Output($0.portType) }
            if LiveCallAudioRoute.forcesSpeaker(speaker: speaker, outputs: outputs) {
                try audio.overrideOutputAudioPort(.speaker)
            } else if !clearingOverride {
                try audio.overrideOutputAudioPort(.none)
            }
        } catch {
            Self.log.error("speaker route failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Offer plumbing

    private func makeOffer(_ peer: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.offer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: LiveCallMediaError.offerFailed(error?.localizedDescription ?? "No offer."))
                }
            }
        }
    }

    private func setLocal(_ peer: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: LiveCallMediaError.offerFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Wait for ICE gathering to complete, or 10 s, whichever comes first.
    /// On timeout the offer goes out with the candidates gathered so far: a
    /// host candidate is enough for OpenAI's public endpoint, and refusing
    /// the call would punish slow networks for nothing.
    private func waitForIceGathering(_ peer: RTCPeerConnection) async {
        if peer.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            iceWait = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.iceTimeout)
                self?.finishIceWait()
            }
        }
    }

    private func finishIceWait() {
        iceWait?.resume()
        iceWait = nil
    }
}

// Delegate callbacks arrive on WebRTC's own threads; every one hops to the
// main actor before touching state.
extension WebRTCLiveCallMedia: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in self.finishIceWait() }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        // `connected` clears the connect timeout; `disconnected` can
        // recover on its own; `failed` cannot.
        let event: LiveCallMediaEvent
        switch newState {
        case .connected: event = .connected
        case .failed: event = .failed("The connection to OpenAI was lost.")
        default: return
        }
        Task { @MainActor in
            guard !self.closed else { return }
            self.emit.yield(event)
        }
    }
}

extension WebRTCLiveCallMedia: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor in
            guard !self.closed else { return }
            switch state {
            case .open: self.emit.yield(.channelOpen)
            case .closed: self.emit.yield(.channelClosed)
            case .connecting, .closing: break
            @unknown default: break
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let event = LiveCallDataEvent.parse(buffer.data) else { return }
        Task { @MainActor in
            guard !self.closed else { return }
            self.emit.yield(.data(event))
        }
    }
}

private extension LiveCallAudioRoute.Output {
    init(_ port: AVAudioSession.Port) {
        switch port {
        case .headphones: self = .headphones
        case .bluetoothHFP: self = .bluetoothHFP
        case .bluetoothA2DP: self = .bluetoothA2DP
        // LE audio, and how Made for iPhone hearing aids connect.
        case .bluetoothLE: self = .bluetoothLE
        case .usbAudio: self = .usbAudio
        case .carAudio: self = .carAudio
        case .builtInReceiver: self = .builtInReceiver
        case .builtInSpeaker: self = .builtInSpeaker
        default: self = .other
        }
    }
}

private extension LiveCallAudioRoute.Trigger {
    init(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .newDeviceAvailable: self = .newDevice
        case .oldDeviceUnavailable: self = .oldDeviceGone
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        default: self = .otherChange
        }
    }
}
