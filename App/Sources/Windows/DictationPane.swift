import VoiceIQCore
import VoiceIQSpeech
import SwiftUI

// MARK: - Dictation

struct DictationPane: View {
    private let settings = SettingsStore()
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var liveTranscription = SettingsStore().liveTranscriptionEnabled
    @State private var dictationSource = SettingsStore().dictationSource
    @State private var localModel = SettingsStore().localSpeechModel
    @State private var meetingSource = SettingsStore().meetingSource
    @State private var smartTranscription = SettingsStore().smartTranscriptionEnabled
    @State private var cleanupPass = SettingsStore().smartCleanupPassEnabled
    @State private var skipShortCleanup = SettingsStore().skipShortDictationCleanup
    @State private var customRules = SettingsStore().customWritingRules
    @State private var autoLearn = SettingsStore().autoLearnEnabled
    @State private var meetingDetection = SettingsStore().meetingDetectionEnabled
    @State private var meetingScreenNames = SettingsStore().meetingScreenNamesEnabled
    @State private var showIdleDot = SettingsStore().showIdleIndicator
    @State private var noiseHandling = SettingsStore().experimentalNoiseHandling
    @State private var agentMode = SettingsStore().agentModeEnabled
    @State private var translationTargets = SettingsStore().translationTargetLanguages
    @State private var spelling = SettingsStore().spellingVariant
    @State private var muteOtherAudio = SettingsStore().muteOtherAudioWhileDictating
    @State private var screenContext = SettingsStore().screenContextEnabled
    @State private var fitToExistingText = SettingsStore().fitToExistingText
    @State private var copyRecovered = SettingsStore().copyRecoveredToClipboard
    @State private var preferredMicrophone = SettingsStore().preferredInputDeviceUID
    @State private var microphones = AudioInputDevices.list()

    var body: some View {
        Form {
            DictationKeySection()
            PermissionsSection()

            Section("Shortcuts") {
                ShortcutRecorderRow(action: .pasteLastTranscript)
                ShortcutRecorderRow(action: .askAnything)
                ShortcutRecorderRow(action: .translate)
                ShortcutRecorderRow(action: .meetingToggle)
                TranslationTargetsRow(targets: $translationTargets)
            }

            Section {
                Picker("Microphone", selection: $preferredMicrophone) {
                    Text("System default").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .onChange(of: preferredMicrophone) { _, uid in
                    settings.setPreferredInputDeviceUID(uid)
                }
                Toggle("Mute other audio while dictating", isOn: $muteOtherAudio)
                    .onChange(of: muteOtherAudio) { _, enabled in
                        settings.setMuteOtherAudioWhileDictating(enabled)
                    }
                Toggle("Copy recovered dictations to the clipboard", isOn: $copyRecovered)
                    .onChange(of: copyRecovered) { _, enabled in
                        settings.setCopyRecoveredToClipboard(enabled)
                    }
            }

            Section {
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
                Toggle("Show resting indicator", isOn: $showIdleDot)
                    .onChange(of: showIdleDot) { _, show in settings.setShowIdleIndicator(show) }
            } footer: {
                Text("The resting dot grows into a Dictate button on hover; click it for hands-free. Off = the pill appears only while dictating.")
            }

            Section {
                TranscriptionSourcePicker("Transcription", selection: $dictationSource)
                    .onChange(of: dictationSource) { _, source in
                        settings.setDictationSource(source)
                    }
                    // Here, not on the controls: they expand to several rows.
                    .onChange(of: localModel) { _, model in
                        settings.setLocalSpeechModel(model)
                    }
                LocalModelControls(localEnabled: dictationSource == .onDevice, meetingsLocal: meetingSource == .onDevice,
                                   selection: $localModel)
                Toggle("Real-time transcription", isOn: $liveTranscription)
                    .onChange(of: liveTranscription) { _, enabled in
                        settings.setLiveTranscriptionEnabled(enabled)
                    }
                TranscriptionSourcePicker("Meeting transcription", selection: $meetingSource)
                    .onChange(of: meetingSource) { _, source in
                        settings.setMeetingSource(source)
                    }
                LocalMeetingControls(meetingsLocal: meetingSource == .onDevice)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    LocalModelFooter(localEnabled: dictationSource == .onDevice, selection: localModel)
                    LocalMeetingFooter(enabled: meetingSource == .onDevice)
                }
            }

            Section {
                Toggle("Smart transcription", isOn: $smartTranscription)
                    .onChange(of: smartTranscription) { _, enabled in
                        settings.setSmartTranscription(enabled)
                    }
            } footer: {
                Text("Removes filler words and applies self-corrections (\"at 2 — actually 3\") as it transcribes. Off = word for word — unless writing rules below are on, which rewrite either way.")
            }

            Section {
                Toggle("Apply writing rules", isOn: $cleanupPass)
                    .onChange(of: cleanupPass) { _, enabled in
                        guard enabled != settings.smartCleanupPassEnabled else { return }
                        settings.setSmartCleanupPass(enabled)
                    }
                Toggle("Skip cleanup for dictations of 5 seconds or less", isOn: $skipShortCleanup)
                    .disabled(!cleanupPass)
                    .onChange(of: skipShortCleanup) { _, enabled in
                        guard enabled != settings.skipShortDictationCleanup else { return }
                        settings.setSkipShortDictationCleanup(enabled)
                    }
                Picker("Spelling", selection: $spelling) {
                    ForEach(SpellingVariant.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .disabled(!cleanupPass)
                .onChange(of: spelling) { _, variant in
                    guard variant != settings.spellingVariant else { return }
                    settings.setSpellingVariant(variant)
                }
            } header: {
                Text("Writing rules")
            } footer: {
                Text("A second model rewrites the transcript by these rules: corrections you speak later fix what you said earlier, sentences are split by grammar rather than pauses, and the layout follows what you said: a message stays a message, several requests become a numbered list.")
            }

            Section("Custom rules") {
                TextEditor(text: $customRules)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 320)
                    .disabled(!cleanupPass)
                    .onChange(of: customRules) { _, text in
                        settings.setCustomWritingRules(text)
                    }
            }

            Section {
                Toggle("Learn from your edits", isOn: $autoLearn)
                    .onChange(of: autoLearn) { _, enabled in settings.setAutoLearn(enabled) }
                Toggle("Screen context", isOn: $screenContext)
                    .onChange(of: screenContext) { _, enabled in
                        guard enabled != settings.screenContextEnabled else { return }
                        settings.setScreenContextEnabled(enabled)
                    }
                Toggle("Fit to existing text", isOn: $fitToExistingText)
                    .onChange(of: fitToExistingText) { _, enabled in
                        guard enabled != settings.fitToExistingText else { return }
                        settings.setFitToExistingText(enabled)
                    }
                Toggle("Offer to record calls", isOn: $meetingDetection)
                    .onChange(of: meetingDetection) { _, enabled in settings.setMeetingDetection(enabled) }
                Toggle("Read names from the screen", isOn: $meetingScreenNames)
                    .onChange(of: meetingScreenNames) { _, enabled in settings.setMeetingScreenNames(enabled) }
            } footer: {
                Text("Words you change after a dictation lands are added to the Dictionary. Screen context sends a snapshot of what you're looking at, taken when dictation starts and when you switch apps, so names and paths on screen are spelled right. Fit to existing text sends the text around the cursor with the transcript, so a dictation continues or follows what is already in the field. When a call app or a meeting tab is using the microphone, the pill asks before recording; the Meeting recording shortcut starts and stops a recording at any time. Notes appear under Meetings. Read names from the screen reads the name tags in the call window on this Mac while a meeting records, to name its speakers; no image is kept.")
            }

            Section {
                Toggle("Better hearing in loud rooms", isOn: $noiseHandling)
                    .onChange(of: noiseHandling) { _, enabled in
                        settings.setExperimentalNoiseHandling(enabled)
                    }
                Toggle("Agent mode", isOn: $agentMode)
                    .onChange(of: agentMode) { _, enabled in settings.setAgentModeEnabled(enabled) }
                if agentMode {
                    ShortcutRecorderRow(action: .agent)
                }
            } footer: {
                Text("Loud rooms judges your voice against the actual room noise instead of a fixed level. Agent mode operates your Mac from a spoken command: it sees the screen and clicks, types and opens apps on your behalf. It needs Screen Recording and Accessibility access, and asks before anything that looks like sending, paying or deleting.")
            }
        }
        .onAppear { microphones = AudioInputDevices.list() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQInputDevicesChanged).receive(on: RunLoop.main)) { _ in
            microphones = AudioInputDevices.list()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "dictationSource": dictationSource = settings.dictationSource
            case "meetingSource": meetingSource = settings.meetingSource
            case "localSpeechModel": localModel = settings.localSpeechModel
            case "liveDictationEnabled": liveTranscription = settings.liveTranscriptionEnabled
            case "smartTranscription": smartTranscription = settings.smartTranscriptionEnabled
            case "agentModeEnabled": agentMode = settings.agentModeEnabled
            case "smartCleanupPass": cleanupPass = settings.smartCleanupPassEnabled
            case "skipShortDictationCleanup": skipShortCleanup = settings.skipShortDictationCleanup
            case SettingsStore.customWritingRulesKey: customRules = settings.customWritingRules
            case "autoLearn": autoLearn = settings.autoLearnEnabled
            case "meetingDetection": meetingDetection = settings.meetingDetectionEnabled
            // voiceiq://set drives this headlessly in DEBUG — the pane must not show
            // a stale toggle after the flag moved underneath it.
            case "experimentalNoiseHandling": noiseHandling = settings.experimentalNoiseHandling
            case "translationTargetLanguages": translationTargets = settings.translationTargetLanguages
            case "spellingVariant": spelling = settings.spellingVariant
            case "muteOtherAudioWhileDictating": muteOtherAudio = settings.muteOtherAudioWhileDictating
            case "screenContextEnabled": screenContext = settings.screenContextEnabled
            case "fitToExistingText": fitToExistingText = settings.fitToExistingText
            case "copyRecoveredToClipboard": copyRecovered = settings.copyRecoveredToClipboard
            case "preferredInputDeviceUID": preferredMicrophone = settings.preferredInputDeviceUID
            default: break
            }
        }
    }
}
