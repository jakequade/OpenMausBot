// Live calls, the wire half: what the harness tells the phone about the one
// call it runs, and the settings a phone may change.
//
// The Mac owns the call (server/live-call-controller.ts). It creates the
// GPT-Live session with a key that never leaves it, runs every rule — what a
// spoken request becomes, what the voice is told, spoken yes/no for
// approvals, the idle hang-up — and reports state over SSE as `live.call`.
// The phone owns only its microphone, speaker and captions. Nothing here
// carries a key or a word anyone said.
import Foundation

public struct LiveCallState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case connecting, live, ending, ended
        /// A status this build has never heard of. Read as "still running":
        /// the harness says `ended` when it is over, and guessing that early
        /// would hide a bar for a call that is still on the line.
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public var callId: String
    public var botId: String
    public var threadId: String
    /// Which app holds the microphone: "desktop", "ios" or "android".
    /// Self-declared by that app, so for display only.
    public var client: String
    public var voice: String
    /// Epoch milliseconds on the Mac's clock.
    public var startedAt: Double
    public var status: Status
    /// hung-up · idle · expired · content · remote-hangup · connection-lost
    /// · sideband-lost · deleted · shutdown · error — free text on the wire.
    public var endReason: String?
    /// Short and user-facing; present when the call ended on a problem.
    public var error: String?

    public init(
        callId: String, botId: String, threadId: String, client: String, voice: String,
        startedAt: Double, status: Status, endReason: String? = nil, error: String? = nil
    ) {
        self.callId = callId
        self.botId = botId
        self.threadId = threadId
        self.client = client
        self.voice = voice
        self.startedAt = startedAt
        self.status = status
        self.endReason = endReason
        self.error = error
    }

    public var isRunning: Bool { status != .ended }
}

/// Non-secret Live settings, as `GET /api/config` (`live`) and
/// `PATCH /api/live/settings` report them. The key is not a field: it never
/// crosses to a phone.
public struct LiveSettings: Codable, Hashable, Sendable {
    public var configured: Bool
    public var voice: String
    public var readTypedReplies: Bool
    public var idleMinutes: Int

    public init(configured: Bool, voice: String, readTypedReplies: Bool, idleMinutes: Int) {
        self.configured = configured
        self.voice = voice
        self.readTypedReplies = readTypedReplies
        self.idleMinutes = idleMinutes
    }

    private enum CodingKeys: String, CodingKey { case configured, voice, readTypedReplies, idleMinutes }

    /// Tolerant on purpose: a Mac running today's harness sends only
    /// `{ configured, voice }`, and a strict decode here would fail the whole
    /// `ConfigStatus` it arrived in.
    ///
    /// A Mac with no voice chosen sends `voice: ""`, which the desktop reads
    /// as marin (`config.live.voice || "marin"`). The phone reads it the same
    /// way, or its picker would grow and select an empty row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        let voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? ""
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LiveVoices.defaultVoice : voice
        readTypedReplies = try container.decodeIfPresent(Bool.self, forKey: .readTypedReplies) ?? true
        idleMinutes = try container.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? LiveVoices.defaultIdleMinutes
    }
}

/// `PATCH /api/live/settings`. `nil` means "leave it alone" and is omitted
/// on the wire (synthesized `Encodable` uses `encodeIfPresent`).
public struct LiveSettingsPatch: Encodable, Sendable {
    public var voice: String?
    public var readTypedReplies: Bool?
    public var idleMinutes: Int?

    public init(voice: String? = nil, readTypedReplies: Bool? = nil, idleMinutes: Int? = nil) {
        self.voice = voice
        self.readTypedReplies = readTypedReplies
        self.idleMinutes = idleMinutes
    }
}

/// The 201 from `POST /api/live/session`: the call as the Mac sees it, and
/// OpenAI's SDP answer to apply to the peer connection unchanged.
public struct LiveCallStart: Decodable, Sendable {
    public struct Transport: Decodable, Sendable {
        public var type: String
        public var sdp: String
    }

    public var call: LiveCallState
    public var transport: Transport
}

/// The two 409s a start can get. Kept apart from `APIError` because they
/// carry structure the generic error body drops.
public enum LiveCallStartError: Error, Equatable, Sendable {
    /// No OpenAI key on the Mac. The phone cannot fix that.
    case needsKey(message: String)
    /// Somebody is already on the line; `active` says who.
    case busy(active: LiveCallState, message: String)
}

public enum LiveVoices {
    public struct Option: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// Same list, same order, same labels as `LIVE_VOICE_OPTIONS` in
    /// shared/live-call.ts.
    /// No route exposes it, so the phone carries a copy.
    public static let options: [Option] = [
        Option(id: "marin", label: "Marin (default)"),
        Option(id: "cedar", label: "Cedar"),
        Option(id: "alloy", label: "Alloy"),
        Option(id: "ash", label: "Ash"),
        Option(id: "ballad", label: "Ballad"),
        Option(id: "coral", label: "Coral"),
        Option(id: "echo", label: "Echo"),
        Option(id: "sage", label: "Sage"),
        Option(id: "shimmer", label: "Shimmer"),
        Option(id: "verse", label: "Verse"),
        Option(id: "gleam", label: "Gleam — North American, feminine"),
        Option(id: "meridian", label: "Meridian — North American, masculine"),
        Option(id: "quartz", label: "Quartz — Australian, feminine"),
        Option(id: "ripple", label: "Ripple — Australian, masculine"),
        Option(id: "vesper", label: "Vesper — British, masculine"),
        Option(id: "willow", label: "Willow — Irish, feminine"),
        Option(id: "stone", label: "Stone — Irish, masculine"),
        Option(id: "delta", label: "Delta — Southern U.S., feminine"),
        Option(id: "cinder", label: "Cinder — Southern U.S., masculine"),
        Option(id: "beacon", label: "Beacon — Filipino, masculine"),
        Option(id: "bossa", label: "Bossa — Brazilian Portuguese, feminine"),
        Option(id: "tempo", label: "Tempo — Brazilian Portuguese, masculine"),
    ]
    public static let defaultVoice = "marin"
    public static let idleMinutesRange = 1...60
    public static let defaultIdleMinutes = 5

    /// The idle hang-up minutes every client offers: the desktop's
    /// `IDLE_CHOICES` (src/components/LiveCallSettings.tsx).
    public static let idleMinuteChoices = [1, 2, 3, 5, 10, 15, 30, 60]

    /// The choices for a picker whose current value is `current`: the
    /// shared list, plus `current` in its place when it is none of them
    /// (set before, when any minute could be chosen), so it is shown and
    /// stays selected. The desktop does the same.
    public static func idleChoices(current: Int) -> [Int] {
        Array(Set(idleMinuteChoices + [current])).sorted()
    }
}

// MARK: - Response envelopes (module-internal)

struct LiveCallEnvelope: Decodable {
    /// `null` on the wire means the line is free; `decodeIfPresent` reads it as nil.
    var call: LiveCallState?
}

struct LiveSettingsEnvelope: Decodable {
    var live: LiveSettings
}

/// The 409 body of `POST /api/live/session`, read before `check()` because
/// `check()` keeps only `error`.
struct LiveCallRefusalBody: Decodable {
    var error: String
    var needsKey: Bool?
    var activeCall: LiveCallState?
}
