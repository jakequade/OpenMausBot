// The gear on the call bar. Four settings, three of them on the Mac
// (PATCH /api/live/settings) and one on this phone (speaker or earpiece).
// The OpenAI key is shown as a fact, not a field: it lives on the Mac and
// the companion refuses to carry it either way. The sheet also says what a
// call sends to OpenAI besides the voice, in the words every client uses.
import CompanionCore
import SwiftUI

struct LiveCallSettingsSheet: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var liveCall: LiveCallController
    @Environment(\.dismiss) private var dismiss
    @State private var settings: LiveSettings?
    /// The Mac's last word on its settings (the first read, or a save's
    /// answer). A change that reached neither the Mac nor a re-read goes
    /// back to this, so it does not stay on screen under its error.
    @State private var confirmed: LiveSettings?
    /// The last save, so the next one waits for it: two quick changes send
    /// two PATCHes, and the Mac has to end on the last one, not on
    /// whichever request happens to land last.
    @State private var saving: Task<Void, Never>?
    /// Saves not yet answered. Only the last one's answer is shown, or an
    /// earlier change's answer would pull a later one back.
    @State private var pendingSaves = 0
    /// The Mac's (or the sidecar's) words for a change it refused. Shown in
    /// the sheet, as TaskManagerView does, rather than in the app's alert
    /// behind it.
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Voice", selection: voice) {
                        ForEach(voiceOptions) { option in
                            Text(verbatim: option.label).tag(option.id)
                        }
                    }
                } footer: {
                    Text("Takes effect on the next call.")
                }

                Section {
                    Picker("Sound output", selection: $liveCall.speakerOn) {
                        Text("Speaker").tag(true)
                        Text("Earpiece").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Sound output")
                } footer: {
                    // LiveCallAudioRoute: the Speaker choice never overrides a headset.
                    Text("Applies to calls on this iPhone. A connected headset takes the call instead.")
                }

                Section {
                    Toggle("Read replies to typed messages", isOn: readTypedReplies)
                } footer: {
                    Text("When this is off, messages you type during a call and the bot's answers to them are not sent to OpenAI.")
                }

                Section {
                    // The minutes every client offers, one PATCH per choice.
                    Picker("Hang up after silence", selection: idleMinutes) {
                        ForEach(LiveVoices.idleChoices(current: idleMinutes.wrappedValue), id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("live-call-idle")
                }

                Section {
                    // Not LabeledContent: in a Form that merges the row into
                    // one element, "OpenAI key, Managed on your computer", and
                    // the value can no longer be found by its own words, which
                    // is how the UI test reads it.
                    HStack {
                        Text("OpenAI key")
                        Spacer(minLength: 12)
                        Text("Managed on your computer")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("live-call-key")
                    }
                } footer: {
                    Text("A Live call sends your voice to OpenAI, along with the chat's recent messages, the bot's answers and the details of any approval it asks for. The OpenAI key stays on your computer.")
                }
            }
            // On the Form, not the stack: an outer identifier replaces the
            // inner ones, and the error inset below keeps its own.
            .accessibilityIdentifier("live-call-settings-sheet")
            .navigationTitle("Live call settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.regularMaterial)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("live-call-settings-error")
                }
            }
            .overlay {
                if settings == nil { ProgressView() }
            }
            .task {
                let loaded = await session.configStatus()?.live
                    ?? LiveSettings(configured: false, voice: LiveVoices.defaultVoice, readTypedReplies: true, idleMinutes: LiveVoices.defaultIdleMinutes)
                // A change made before this first read landed has already
                // been answered with the Mac's newer settings; the read is
                // older news and must not put the old value back.
                if settings == nil { settings = loaded }
                if confirmed == nil { confirmed = loaded }
            }
        }
    }

    /// The Mac's current voice is shown even when this build does not know
    /// it, so the picker never silently swaps it for the first entry.
    private var voiceOptions: [LiveVoices.Option] {
        let current = settings?.voice ?? LiveVoices.defaultVoice
        if LiveVoices.options.contains(where: { $0.id == current }) { return LiveVoices.options }
        return LiveVoices.options + [LiveVoices.Option(id: current, label: current)]
    }

    private var voice: Binding<String> {
        Binding(
            get: { settings?.voice ?? LiveVoices.defaultVoice },
            set: { value in
                settings?.voice = value
                save(LiveSettingsPatch(voice: value))
            }
        )
    }

    private var readTypedReplies: Binding<Bool> {
        Binding(
            get: { settings?.readTypedReplies ?? true },
            set: { value in
                settings?.readTypedReplies = value
                save(LiveSettingsPatch(readTypedReplies: value))
            }
        )
    }

    private var idleMinutes: Binding<Int> {
        Binding(
            get: { settings?.idleMinutes ?? LiveVoices.defaultIdleMinutes },
            set: { value in
                settings?.idleMinutes = value
                save(LiveSettingsPatch(idleMinutes: value))
            }
        )
    }

    /// One PATCH at a time, in order. When the last one is answered the
    /// sheet shows the Mac's settings: its answer, or, if it refused, what it
    /// has now, so a refused change does not stay on screen as if saved.
    /// When the Mac cannot be reached at all (offline), the sheet says so
    /// and goes back to what the Mac last said.
    private func save(_ patch: LiveSettingsPatch) {
        saveError = nil
        pendingSaves += 1
        let previous = saving
        saving = Task {
            await previous?.value
            let live = await session.updateLiveSettings(patch)
            if let live { confirmed = live }
            if live == nil, let message = session.actionError {
                saveError = message
                session.actionError = nil
            }
            pendingSaves -= 1
            guard pendingSaves == 0 else { return }
            if let live {
                settings = live
            } else if let current = await session.configStatus()?.live {
                guard pendingSaves == 0 else { return }
                settings = current
                confirmed = current
            } else if pendingSaves == 0, let confirmed {
                settings = confirmed
            }
        }
    }
}
