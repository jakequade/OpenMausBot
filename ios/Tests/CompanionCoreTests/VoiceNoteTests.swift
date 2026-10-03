import XCTest
@testable import CompanionCore

final class VoiceNoteTests: XCTestCase {
    // The portable suite cannot link the App target's AVAudioSession code.
    // Pin the preview to the same owned player as transcript audio instead.
    func testVoicePreviewUsesTheOwnedPlayerAndCancelsPendingLoads() throws {
        let iosDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile = try String(contentsOf: iosDirectory.appendingPathComponent("App/AgentProfileView.swift"), encoding: .utf8)
        XCTAssertTrue(profile.contains("@StateObject private var player = VoiceNotePlayer()"))
        XCTAssertFalse(profile.contains("beginPlaybackSession()"), "loading must not claim the shared audio session")
        XCTAssertTrue(profile.contains("guard let data = await session.previewVoice(voice, for: current), !Task.isCancelled else { return }"))
        XCTAssertEqual(profile.components(separatedBy: "guard VoiceNoteCenter.shared.playbackAllowed else").count, 3,
                       "input ownership must be checked again after the network suspension")
        XCTAssertTrue(profile.contains("VoiceNoteCenter.shared.claim(player)\n            player.play(mode: .spokenAudio)"))
        XCTAssertTrue(profile.contains("previewTask?.cancel()\n                player.pause()\n                VoiceNoteCenter.shared.release(player)"))
    }

    func testDecodesAudioAttachmentsAlongsideImagesAndUnknownKinds() throws {
        let json = #"{"id":"m1","role":"bot","kind":"text","at":1,"text":"Spoken summary","attachments":[{"kind":"audio","path":"note-1744.mp3","mime":"audio/mpeg","durationMs":2400},{"kind":"image","path":"shot-1.png","mime":"image/png"},{"kind":"video","path":"clip-9.mov"}]}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))

        XCTAssertEqual(message.voiceNotes.count, 1)
        let note = try XCTUnwrap(message.voiceNotes.first)
        XCTAssertEqual(note.path, "note-1744.mp3")
        XCTAssertEqual(note.mime, "audio/mpeg")
        XCTAssertEqual(note.durationMs, 2400)
        XCTAssertEqual(message.generatedImages.map { $0.path }, ["shot-1.png"])
    }

    func testVoiceNotesSkipEmptyPathsAndDeduplicateReplays() throws {
        let json = #"{"id":"m2","role":"bot","kind":"text","at":2,"attachments":[{"kind":"audio","path":"note-1744.mp3"},{"kind":"audio","path":"note-1744.mp3","durationMs":2400},{"kind":"audio","path":"   "}]}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))

        XCTAssertEqual(message.voiceNotes.count, 1)
        XCTAssertNil(message.voiceNotes.first?.durationMs)
    }

    func testAudioAttachmentRoundTripsThroughTheWireShape() throws {
        let attachment = MessageImageAttachment(kind: "audio", path: "note-1744.mp3", mime: "audio/mpeg", durationMs: 2400)
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(MessageImageAttachment.self, from: try encoder.encode(attachment))
        XCTAssertEqual(decoded, attachment)
    }

    func testVoiceNoteFileNameAcceptsOnlyGeneratedMp3Names() {
        XCTAssertEqual(CompanionClient.voiceNoteFileName("note-1744.mp3"), "note-1744.mp3")
        XCTAssertEqual(
            CompanionClient.voiceNoteFileName("/api/attachments/note-1744.mp3"),
            "note-1744.mp3"
        )
        // Directory parts are dropped, mirroring the web bubble's basename
        // step; the route still only ever resolves inside its attachment dir.
        XCTAssertEqual(CompanionClient.voiceNoteFileName("replays/note-1744.mp3"), "note-1744.mp3")

        XCTAssertNil(CompanionClient.voiceNoteFileName("note.mp4"))
        XCTAssertNil(CompanionClient.voiceNoteFileName("note.mp3.exe"))
        XCTAssertNil(CompanionClient.voiceNoteFileName("two.words.mp3"))
        XCTAssertNil(CompanionClient.voiceNoteFileName(".mp3"))
        XCTAssertNil(CompanionClient.voiceNoteFileName(""))
        XCTAssertNil(CompanionClient.voiceNoteFileName("note 1744.mp3"))
        XCTAssertNil(CompanionClient.voiceNoteFileName("/api/attachments/"))
    }
}
