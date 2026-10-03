#if DEBUG
// Offline stand-ins so the call bar can be driven with no microphone and no
// WebRTC: in UI tests (`-live-call-preview`, with the store preview) and in
// the simulator against a real fixture harness (`-live-call-fake-media`,
// where the fake GPT-Live's SDP answer cannot be applied by WebRTC anyway).
import CompanionCore
import Foundation
import os

/// Answers the four Live routes and the config the way the harness would.
/// Installed by Session when the app is launched with `-live-call-preview`.
///
/// `-live-call-preview-slow-start` holds the start's 201 back for a few
/// seconds, so a test can hang up while the bar still says "Calling…";
/// `-live-call-preview-slow-config` does the same to the settings sheet's
/// first read, so a test can change a setting before it lands;
/// `-live-call-preview-settings-unreachable` fails the settings' write and
/// read as a network that cannot reach the Mac would;
/// `-live-call-preview-chatty` keeps the voice talking and
/// `-live-call-preview-no-audio` never lets the audio connect (see
/// `PreviewLiveCallMedia`); `-live-call-preview-revoke` unpairs this phone
/// at the next settings change.
final class LiveCallPreviewProtocol: URLProtocol {
    static let call = #"{"callId":"preview-call","botId":"preview-pepper","threadId":"preview-gmail","client":"ios","voice":"marin","startedAt":1789088400000,"status":"live"}"#
    static let endedCall = #"{"callId":"preview-call","botId":"preview-pepper","threadId":"preview-gmail","client":"ios","voice":"marin","startedAt":1789088400000,"status":"ended","endReason":"hung-up"}"#
    static let slowAnswer: TimeInterval = 3
    static let remoteCallId = "preview-remote-call"
    /// A held answer, dropped if URLSession stops the request first.
    private var heldAnswer: DispatchWorkItem?
    /// Set once `-live-call-preview-revoke` has refused a request: from then
    /// on the computer refuses everything this phone asks, as it does a
    /// phone it unpaired.
    private static let revoked = OSAllocatedUnfairLock(initialState: false)
    /// A room for `-live-call-room-preview`.
    static let room = #"{"id":"preview-room","threadId":"preview-room-thread","name":"Launch room","memberIds":["preview-pepper"],"defaultResponder":{"kind":"mentions"},"bulletin":"","unread":false,"createdAt":1787000002000,"messages":[]}"#

    /// The Mac's Live settings, as `GET /api/config` reports them.
    static let settings = #"{"configured":true,"voice":"marin","readTypedReplies":true,"idleMinutes":5}"#

    /// Another device's call, for `-live-call-remote-preview`.
    static func remoteCall(startedAt: Date, status: LiveCallState.Status = .live, endReason: String? = nil) -> LiveCallState {
        LiveCallState(
            callId: remoteCallId, botId: "preview-pepper", threadId: "preview-gmail", client: "desktop",
            voice: "marin", startedAt: startedAt.timeIntervalSince1970 * 1_000, status: status, endReason: endReason
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let arguments = ProcessInfo.processInfo.arguments
        let status: Int
        let body: String
        var delay: TimeInterval = 0
        let settingsUnreachable = arguments.contains("-live-call-preview-settings-unreachable")
        if method == "GET", path == "/api/attachments/preview-voice-note.mp3" {
            // The thread's voice note, so a test can see it held back during a call.
            guard let url = Bundle.main.url(forResource: "VoiceNotePreview", withExtension: "mp3"),
                  let data = try? Data(contentsOf: url) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let clip = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
            client?.urlProtocol(self, didReceive: clip, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if arguments.contains("-live-call-preview-revoke") {
            // The event stream waits, as a quiet one does, so its reconnects
            // do not cover the refusal with "connecting" while a test reads it.
            if path == "/api/events" { return }
            if method == "PATCH", path == "/api/live/settings" { Self.revoked.withLock { $0 = true } }
            if Self.revoked.withLock({ $0 }) {
                let refused = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: refused, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"error":"This device is not paired with this computer."}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }
        switch (method, path) {
        case ("POST", "/api/live/session"):
            (status, body) = (201, #"{"call":\#(Self.call),"transport":{"type":"webrtc","sdp":"v=0\r\ns=preview\r\n"}}"#)
            if arguments.contains("-live-call-preview-slow-start") { delay = Self.slowAnswer }
        case ("POST", "/api/live/call/end"):
            // The remote bar hangs up the other device's call; everything
            // else here ends this phone's.
            if Self.requestedCallId(request) == Self.remoteCallId,
               let ended = try? JSONEncoder().encode(["call": Self.remoteCall(startedAt: Date(), status: .ended, endReason: "hung-up")]) {
                (status, body) = (200, String(decoding: ended, as: UTF8.self))
            } else {
                (status, body) = (200, #"{"call":\#(Self.endedCall)}"#)
            }
        case ("GET", "/api/live/call"):
            (status, body) = (200, #"{"call":null}"#)
        // Each pattern takes its own `where`: on a shared one it would bind
        // to the last pattern only.
        case ("PATCH", "/api/live/settings") where settingsUnreachable, ("GET", "/api/config") where settingsUnreachable:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case ("PATCH", "/api/live/settings"):
            // The change applied over the Mac's settings, as the harness answers.
            var live = (try? JSONSerialization.jsonObject(with: Data(Self.settings.utf8))) as? [String: Any] ?? [:]
            for (key, value) in Self.requestObject(request) ?? [:] where live[key] != nil { live[key] = value }
            let answer = (try? JSONSerialization.data(withJSONObject: ["live": live])) ?? Data()
            (status, body) = (200, String(decoding: answer, as: UTF8.self))
        case ("GET", "/api/config"):
            (status, body) = (200, #"{"live":\#(Self.settings)}"#)
            if arguments.contains("-live-call-preview-slow-config") { delay = Self.slowAnswer }
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let answer = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            let held = DispatchWorkItem(block: answer)
            heldAnswer = held
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: held)
        } else {
            answer()
        }
    }

    override func stopLoading() {
        heldAnswer?.cancel()
        heldAnswer = nil
    }

    /// The `callId` in a JSON body.
    private static func requestedCallId(_ request: URLRequest) -> String? {
        requestObject(request)?["callId"] as? String
    }

    /// A JSON body. URLSession hands a protocol the body as a stream, not
    /// as `httpBody`.
    private static func requestObject(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Media with no WebRTC: a canned offer, any answer accepted, the audio
/// "connects" and the channel "opens" at once, and a scripted exchange gives
/// the caption line words. With `-live-call-preview-chatty` the voice then
/// keeps talking, a word every 50 ms as a streamed reply's transcript
/// arrives, until the call closes: the caption line changes many times a
/// second, as in a real call. With `-live-call-preview-no-audio` the answer
/// goes in and nothing follows, as on a network that lets no WebRTC through:
/// the bar says "Connecting…" until the connect timeout drops the call.
@MainActor
final class PreviewLiveCallMedia: LiveCallMedia {
    let events: AsyncStream<LiveCallMediaEvent>
    private let emit: AsyncStream<LiveCallMediaEvent>.Continuation
    private(set) var muted = false
    private(set) var closeSent = false

    init() {
        let (stream, continuation) = AsyncStream<LiveCallMediaEvent>.makeStream()
        events = stream
        emit = continuation
    }

    func createOffer() async throws -> String {
        "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=preview\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:1\r\n"
    }

    func accept(answer: String) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-live-call-preview-no-audio") { return }
        emit.yield(.connected)
        emit.yield(.channelOpen)
        let chatty = arguments.contains("-live-call-preview-chatty")
        Task { [emit] in
            try? await Task.sleep(for: .milliseconds(400))
            emit.yield(.data(.inputTranscript("What is on my calendar today?")))
            try? await Task.sleep(for: .milliseconds(400))
            emit.yield(.data(.outputTranscript("Hello from the preview voice.")))
            guard chatty else { return }
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if case .terminated = emit.yield(.data(.outputTranscript(" and on"))) { return }
            }
        }
    }

    func setMuted(_ muted: Bool) { self.muted = muted }
    func setSpeaker(_ speaker: Bool) {}
    func sendClose() {
        assert(muted, "Hang-up must mute the microphone before waiting for session.close.")
        closeSent = true
    }
    func close() { emit.finish() }
}

enum LiveCallPreview {
    static var wantsFakeMedia: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-live-call-preview") || arguments.contains("-live-call-fake-media")
    }
}
#endif
