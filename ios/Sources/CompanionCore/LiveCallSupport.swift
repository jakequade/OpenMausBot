// Around a Live call, the decisions that need no microphone and no network:
// what a failure is called, what the data channel said, what fits on one
// caption line, what the clock reads, where the sound goes, and which scene
// phase hangs up.
// LiveCallController (app target) does the doing; these decide.
import Foundation

/// What the media layer can get wrong before or after the Mac is involved.
public enum LiveCallMediaError: Error, Equatable, Sendable {
    /// No peer connection, no microphone track, or no offer.
    case offerFailed(String)
    /// The Mac's 201 arrived but OpenAI's answer could not be applied.
    case answerRejected(String)
}

/// Why a call is not running, classified. The words live in the app, so the
/// string catalog can translate them; the classification lives here, so it
/// can be tested.
public enum LiveCallNotice: Equatable, Sendable {
    case micDenied
    /// No OpenAI key on the computer — "Set up Live calls on your computer first."
    case needsKey
    /// Somebody else is on the line. `client` is "desktop"/"ios"/"android".
    case busy(client: String, botName: String?)
    /// The Mac could not be reached at all (transport detail).
    case unreachable(String)
    /// The Mac (or OpenAI through it) said no, in its own words.
    case refused(String)
    /// The media could not be set up (offer failed, answer rejected).
    case couldNotStart(String)
    /// The connection or the Mac's sideband went away mid-call.
    case dropped
    /// The answer went in but the audio never got through (the peer
    /// connection did not reach `connected` within
    /// `LiveCallMachine.connectTimeout`), so the phone dropped the call.
    case audioNeverConnected
    case ended
    case endedIdle
    case endedExpired
    case endedContent
    case endedDeleted
    case endedShutdown
    /// The sign-in or the paired phone that started the call was signed
    /// out, revoked or unpaired: the computer's `signed-out` end, or this
    /// phone's own session refused. `message` is the computer's own words
    /// when it sent them.
    case signedOut(message: String?)
    /// The computer's own words for why the call ended. `dropped` is what
    /// its reason says (the spec's End reasons table): only a drop offers
    /// Try again, whatever the words.
    case endedWithError(String, dropped: Bool)

    /// The end reasons that are a drop, as the desktop's `endNotice`
    /// (src/lib/live-call-media.ts) classifies them. "remote-hangup" is
    /// OpenAI ending the session from its side, not anyone here: the
    /// desktop and the spec both call that a drop.
    static let droppedReasons: Set<String> = ["remote-hangup", "connection-lost", "sideband-lost", "error"]

    /// Whether "Try again" makes sense: after a dropped call and a failed
    /// start, as on the desktop (`canRetry: notice.dropped`). An end that
    /// is not a drop offers none (dismissing it brings back the phone icon,
    /// which starts the next call); a
    /// missing key and a denied microphone need a person to change
    /// something first; a busy line needs the other device to hang up; a
    /// phone that was signed out has to pair again.
    public var canRetry: Bool {
        switch self {
        case .unreachable, .refused, .couldNotStart, .dropped, .audioNeverConnected:
            return true
        case let .endedWithError(_, dropped):
            return dropped
        case .micDenied, .needsKey, .busy, .ended, .endedIdle, .endedExpired, .endedContent, .endedDeleted,
             .endedShutdown, .signedOut:
            return false
        }
    }

    /// Why the start (the media before it, or `POST /api/live/session`) failed.
    public static func forStartFailure(_ error: any Error, botName: (String) -> String?) -> LiveCallNotice {
        switch error {
        case LiveCallStartError.needsKey:
            return .needsKey
        case let LiveCallStartError.busy(active, _):
            return .busy(client: active.client, botName: botName(active.botId))
        case let LiveCallMediaError.offerFailed(detail), let LiveCallMediaError.answerRejected(detail):
            return .couldNotStart(detail)
        case let APIError.status(code, message):
            return .refused(message ?? "The computer answered with an error (\(code)).")
        case let APIError.transport(detail):
            return .unreachable(detail)
        case APIError.badURL:
            return .unreachable("That address doesn't look right.")
        default:
            return .couldNotStart(error.localizedDescription)
        }
    }

    /// What the bar says when the computer reports the call over: its own
    /// error text when it sent one, otherwise the reason, read as the
    /// desktop's `endNotice` (src/lib/live-call-media.ts) reads it.
    public static func forEnd(_ call: LiveCallState) -> LiveCallNotice {
        let error = call.error.flatMap { $0.isEmpty ? nil : $0 }
        if call.endReason == "signed-out" { return .signedOut(message: error) }
        if let error { return .endedWithError(error, dropped: droppedReasons.contains(call.endReason ?? "")) }
        switch call.endReason {
        case "idle": return .endedIdle
        case "expired": return .endedExpired
        case "content": return .endedContent
        case "deleted": return .endedDeleted
        case "shutdown": return .endedShutdown
        case let reason? where droppedReasons.contains(reason): return .dropped
        default: return .ended
        }
    }
}

/// Before this phone's first Live call it says, once, what a call sends to
/// OpenAI (the spec's disclosure sentence), with Start call and Cancel. A
/// phone has no Live switch: its first call is where Live is turned on.
/// Start call remembers it on this device, and it never comes back here;
/// Cancel starts nothing and records nothing, so the next try shows it again
/// (the first call has not happened yet). The words live in the app.
public struct LiveCallDisclosure {
    /// This device's own record (UserDefaults), not the computer's.
    public static let defaultsKey = "companion.prefs.liveDisclosureShown"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a call this phone starts must show the disclosure first.
    public var isDue: Bool { !defaults.bool(forKey: Self.defaultsKey) }

    /// The person chose Start call: not shown on this device again.
    public func accept() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}

/// What arrives on the phone's `oai-events` data channel, reduced to what
/// captions and the bar need. The harness restricted the channel at session
/// creation to exactly these server events plus `info`.
public enum LiveCallDataEvent: Equatable, Sendable {
    case started
    case inputTranscript(String)
    case outputTranscript(String)
    case closed(reason: String?)
    case error(message: String)
    case other(type: String)

    /// The one event the phone ever sends on the channel. Every append goes
    /// over the Mac's sideband; the channel's allowlist refuses anything else.
    public static let closeCommand = Data(#"{"type":"session.close"}"#.utf8)

    public static func parse(_ data: Data) -> LiveCallDataEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "session.started":
            return .started
        case "session.input_transcript.delta":
            return .inputTranscript(object["delta"] as? String ?? "")
        case "session.output_transcript.delta":
            return .outputTranscript(object["delta"] as? String ?? "")
        case "session.closed":
            return .closed(reason: object["reason"] as? String)
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(message: error?["message"] as? String ?? "unknown error")
        default:
            return .other(type: type)
        }
    }
}

/// The one caption line in the bar: the voice's words, or the person's own
/// words in grey while they speak. A change of speaker starts a fresh line;
/// a long line keeps its tail so the newest words are the ones on screen.
public struct LiveCaptions: Equatable, Sendable {
    public enum Speaker: Equatable, Sendable { case voice, user }

    public private(set) var speaker: Speaker = .voice
    public private(set) var line: String = ""

    public static let maxCharacters = 160

    public init() {}

    public mutating func append(_ delta: String, from speaker: Speaker) {
        if speaker != self.speaker {
            self.speaker = speaker
            line = ""
        }
        line = Self.tail(line + delta)
    }

    /// Whitespace runs collapse to one space; a trailing space survives so
    /// the next delta ("four" after "three ") does not glue onto the last word.
    static func tail(_ text: String, limit: Int = maxCharacters) -> String {
        var flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let last = text.last, last.isWhitespace, !flat.isEmpty { flat += " " }
        guard flat.count > limit else { return flat }
        let cut = flat.suffix(limit)
        guard let space = cut.firstIndex(where: \.isWhitespace) else { return String(cut) }
        return String(cut[cut.index(after: space)...])
    }
}

public enum LiveCallClock {
    /// "m:ss", or "h:mm:ss" once a call passes an hour.
    public static func text(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Seconds since a start the Mac reported (epoch ms on its clock), for
    /// a call this phone did not start. Never negative: a Mac clock a little
    /// ahead of the phone's must not count backwards.
    public static func elapsed(since startedAtMs: Double, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince1970 - startedAtMs / 1_000))
    }
}

/// Where a call's sound goes: the rule Android's `LiveCallAudioRouting`
/// follows, kept free of AVFoundation so it can be tested. A headset the
/// person has on or plugged in (wired, USB, Bluetooth HFP, A2DP or LE, which
/// is also how hearing aids connect, or a car) always takes the call, so the
/// bot's answers are not played out loud to the room while earbuds are in.
/// The Speaker setting only chooses between the loudspeaker and the earpiece
/// when none is connected.
///
/// The loudspeaker is `overrideOutputAudioPort(.speaker)`, which in
/// playAndRecord moves the output *and* the microphone to the phone's own,
/// whatever else is connected. So it is set only when the route the system
/// picked by itself has no headset in it, and decided again on every
/// `AVAudioSession.routeChangeNotification`.
public enum LiveCallAudioRoute {
    /// An output port (`AVAudioSession.Port`), reduced to what the rule needs.
    /// The app maps the real ports in; anything else is `other`.
    public enum Output: Equatable, Sendable {
        case headphones, bluetoothHFP, bluetoothA2DP, bluetoothLE, usbAudio, carAudio
        case builtInReceiver, builtInSpeaker, other

        /// Something the person wears, plugged in or paired for calls. A
        /// car counts: on Android a car kit is a Bluetooth headset too.
        public var isHeadset: Bool {
            switch self {
            case .headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio: return true
            case .builtInReceiver, .builtInSpeaker, .other: return false
            }
        }
    }

    /// What asks for the route to be decided again.
    public enum Trigger: Equatable, Sendable {
        /// The Speaker or Earpiece choice, applied as the call starts or changed during it.
        case setting
        /// `routeChangeNotification`, by its reason.
        case newDevice, oldDeviceGone, categoryChange, override, otherChange
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Read the route and apply `forcesSpeaker`. `clearingOverride` takes
        /// the loudspeaker override off first: it hides the route the system
        /// would pick, including a headset that connected under it.
        case decide(clearingOverride: Bool)
    }

    public static func action(for trigger: Trigger) -> Action {
        switch trigger {
        case .setting, .newDevice: return .decide(clearingOverride: true)
        case .oldDeviceGone, .categoryChange, .otherChange: return .decide(clearingOverride: false)
        // The rule's own override: deciding again would only set off another.
        case .override: return .none
        }
    }

    /// Whether to force the loudspeaker, given the outputs of the route the
    /// system picked with no override of ours in effect.
    public static func forcesSpeaker(speaker: Bool, outputs: [Output]) -> Bool {
        speaker && !outputs.contains(where: \.isHeadset)
    }
}

public enum LiveCallLifecycle {
    public enum ScenePhase: Equatable, Sendable { case active, inactive, background }

    /// Only a true background ends the call. `.inactive` is what iOS reports
    /// for Control Center, the app switcher, an incoming-call banner and the
    /// microphone permission prompt itself; hanging up on any of those would
    /// end the first call ever made the moment iOS asks for the mic. Locking
    /// the screen moves the app to `.background`, so the spec's two cases —
    /// backgrounded or locked — are both covered.
    public static func endsCall(on phase: ScenePhase) -> Bool {
        phase == .background
    }
}
