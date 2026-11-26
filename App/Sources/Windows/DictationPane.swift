import AppKit
import UniformTypeIdentifiers
import VoiceIQCore
import SwiftUI

// MARK: - Dictation

struct DictationPane: View {
    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func chooseReturnApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !pressReturnApps.contains(bundleID) else { return }
        pressReturnApps.append(bundleID)
    }

    private let settings = SettingsStore()
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var soundVolume = SettingsStore().soundVolume
    @State private var customRules = SettingsStore().customWritingRules
    @State private var meetingDetection = SettingsStore().meetingDetectionEnabled
    @State private var meetingOwnerName = SettingsStore().meetingOwnerName
    @State private var showIdleDot = SettingsStore().showIdleIndicator
    @State private var hidePillFromScreenSharing = SettingsStore().hidePillFromScreenSharing
    @State private var muteOtherAudio = SettingsStore().muteOtherAudioWhileDictating
    @State private var pauseMedia = SettingsStore().pauseMediaWhileDictating
    @State private var screenContext = SettingsStore().screenContextEnabled
    @State private var copyRecovered = SettingsStore().copyRecoveredToClipboard
    @State private var calendar = SettingsStore().calendarForMeetings && CalendarMeetings.isAuthorized
    @State private var voiceIsolation = SettingsStore().voiceIsolation
    @State private var pressReturn = SettingsStore().pressReturnAfterPaste
    @State private var pressReturnApps = SettingsStore().pressReturnApps
    @State private var preferredMicrophone = SettingsStore().preferredInputDeviceUID
    @State private var microphones = AudioInputDevices.list()
    @State private var dictationSource = SettingsStore().dictationSource

    var body: some View {
        Form {
            DictationKeySection()
            PermissionsSection()

            Section("Shortcuts") {
                ShortcutRecorderRow(action: .pasteLastTranscript)
                ShortcutRecorderRow(action: .meetingToggle)
            }

            Section {
                SearchablePicker("Microphone", selection: $preferredMicrophone,
                                 options: [SearchOption(value: String?.none, name: "System default")]
                                     + microphones.map { SearchOption(value: Optional($0.uid), name: $0.name) })
                .onChange(of: preferredMicrophone) { _, uid in
                    settings.setPreferredInputDeviceUID(uid)
                }
                Toggle(isOn: $voiceIsolation) {
                    Text("Voice isolation")
                    Text("Turns down background noise while you dictate, using Apple's voice processing. It can lower other audio a little and move a Bluetooth headset to call quality. If the mic doesn't start with it, VoiceiQ records without it.")
                }
                .onChange(of: voiceIsolation) { _, enabled in settings.setVoiceIsolation(enabled) }
                Toggle("Mute other audio while dictating", isOn: $muteOtherAudio)
                    .onChange(of: muteOtherAudio) { _, enabled in
                        settings.setMuteOtherAudioWhileDictating(enabled)
                    }
                Toggle("Pause Music and Spotify while dictating", isOn: $pauseMedia)
                    .onChange(of: pauseMedia) { _, enabled in
                        settings.setPauseMediaWhileDictating(enabled)
                    }
                Toggle("Copy recovered dictations to the clipboard", isOn: $copyRecovered)
                    .onChange(of: copyRecovered) { _, enabled in
                        settings.setCopyRecoveredToClipboard(enabled)
                    }
            }

            Section {
                Toggle("Press Return after pasting", isOn: $pressReturn)
                    .onChange(of: pressReturn) { _, enabled in settings.setPressReturnAfterPaste(enabled) }
                if pressReturn {
                    ForEach(pressReturnApps, id: \.self) { bundleID in
                        LabeledContent(Self.appName(bundleID)) {
                            Button {
                                pressReturnApps.removeAll { $0 == bundleID }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                    }
                    Button(pressReturnApps.isEmpty ? "Only in Some Apps…" : "Add App…", action: chooseReturnApp)
                }
            } footer: {
                Text(pressReturnApps.isEmpty
                     ? "Sends what you dictated, in every app. Press Esc after you stop speaking to keep the text without sending it."
                     : "Sends what you dictated, only in these apps. Press Esc after you stop speaking to keep the text without sending it.")
            }
            .onChange(of: pressReturnApps) { _, apps in settings.setPressReturnApps(apps) }

            SpeechSourceSection(device: "Mac") { Text($0) }

            // On device, the selected model's own language picker applies.
            if dictationSource == .gemini {
                SpokenLanguagesSection()
            }

            Section {
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
                if sounds {
                    LabeledContent("Volume") {
                        Slider(value: $soundVolume, in: 0.05...1, step: 0.05) { editing in
                            // Let go of the slider to hear the new level.
                            if !editing { NotificationCenter.default.post(name: .voiceIQPreviewSound, object: nil) }
                        }
                        .frame(maxWidth: 220)
                        .accessibilityValue("\(Int((soundVolume * 100).rounded())) percent")
                    }
                    .onChange(of: soundVolume) { _, volume in settings.setSoundVolume(volume) }
                }
                Toggle("Show resting indicator", isOn: $showIdleDot)
                    .onChange(of: showIdleDot) { _, show in settings.setShowIdleIndicator(show) }
                Toggle("Hide pill from screen sharing", isOn: $hidePillFromScreenSharing)
                    .onChange(of: hidePillFromScreenSharing) { _, hide in settings.setHidePillFromScreenSharing(hide) }
            } footer: {
                Text("The resting dot grows into a Dictate button on hover; click it for hands-free. Off = the pill appears only while dictating.")
            }

            Section {
                TextEditor(text: $customRules)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 320)
                    .onChange(of: customRules) { _, text in
                        settings.setCustomWritingRules(text)
                    }
            } header: {
                Text("Custom rules")
            } footer: {
                Text("Gemini hears each dictation and writes it in one step, by the built-in writing rules and yours: corrections you speak later fix what you said earlier, grammar is fixed, sentences are split by grammar rather than pauses, and the layout follows what you said. Spelling follows your Mac's region. Words you change after a dictation lands are added to the Dictionary.")
            }

            Section {
                Toggle("Screen context", isOn: $screenContext)
                    .onChange(of: screenContext) { _, enabled in
                        guard enabled != settings.screenContextEnabled else { return }
                        settings.setScreenContextEnabled(enabled)
                    }
                Toggle("Offer to record calls", isOn: $meetingDetection)
                    .onChange(of: meetingDetection) { _, enabled in settings.setMeetingDetection(enabled) }
                TextField("Your name in meeting notes", text: $meetingOwnerName)
                    .onChange(of: meetingOwnerName) { _, name in settings.setMeetingOwnerName(name) }
                Toggle("Use calendar for meeting notes", isOn: $calendar)
                    .onChange(of: calendar) { _, enabled in
                        Task { calendar = await CalendarMeetings.connect(enabled) }
                    }
            } footer: {
                Text("Screen context reads the text on your screen on this Mac when dictation starts and when you switch apps, and sends that text, not an image, so names and paths on screen are spelled right. It is read while you speak, so it adds almost nothing to a dictation. When a call app or a meeting tab is using the microphone, the pill asks before recording; the Meeting recording shortcut starts and stops a recording at any time. Notes appear under Meetings. While a meeting records, VoiceiQ reads the name tags in the call window on this Mac to name its speakers; no image is kept. With the calendar on, notes take the title of the event you're in and the spelling of its invitees' names, and your next meeting shows in Meetings and the menu-bar menu\(calendar || !CalendarMeetings.isDenied ? "" : "; calendar access is off in System Settings → Privacy & Security → Calendars").")
            }
        }
        .onAppear { microphones = AudioInputDevices.list() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQInputDevicesChanged).receive(on: RunLoop.main)) { _ in
            microphones = AudioInputDevices.list()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case SettingsStore.customWritingRulesKey: customRules = settings.customWritingRules
            case "meetingDetection": meetingDetection = settings.meetingDetectionEnabled
            case "muteOtherAudioWhileDictating": muteOtherAudio = settings.muteOtherAudioWhileDictating
            case "pauseMediaWhileDictating": pauseMedia = settings.pauseMediaWhileDictating
            case "screenContextEnabled": screenContext = settings.screenContextEnabled
            case "copyRecoveredToClipboard": copyRecovered = settings.copyRecoveredToClipboard
            case "preferredInputDeviceUID": preferredMicrophone = settings.preferredInputDeviceUID
            case "transcriptionSource": dictationSource = settings.dictationSource
            default: break
            }
        }
    }
}

/// The languages the user speaks (`SettingsStore.spokenLanguages`), sent to
/// Gemini as a hint while it transcribes dictation.
struct SpokenLanguagesSection: View {
    private let settings = SettingsStore()
    @State private var languages = SettingsStore().spokenLanguages

    private static func options(_ languages: [SpokenLanguage]) -> [SearchOption<String>] {
        languages.map { SearchOption(value: $0.code, name: $0.name, keywords: $0.code) }
    }

    var body: some View {
        Section {
            SearchablePicker("Spoken language", selection: Binding(get: { languages.first ?? "" }, set: {
                save(SpokenLanguage.choosing(main: $0, in: languages))
            }), options: [SearchOption(value: "", name: "Automatic")] + Self.options(SpokenLanguage.all))
            .help("The language you speak most when dictating. Automatic works it out each time, which can go wrong on a short phrase; pick a main language to add others.")
            if let main = languages.first {
                SearchablePicker("Also spoken", summary: SpokenLanguage.names(languages.dropFirst(), none: "None"),
                                 options: Self.options(SpokenLanguage.all.filter { $0.code != main }),
                                 isSelected: { languages.dropFirst().contains($0) },
                                 toggle: { save(SpokenLanguage.toggling($0, in: languages)) })
                .help("Other languages you speak, in whole sentences or mixed into the main language. Each is written in its own script, never translated.")
            }
        } header: {
            Text("Languages")
        } footer: {
            Text("Dictation is told to expect these languages. Meetings work out each language and every switch between them by themselves.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in
            languages = settings.spokenLanguages
        }
    }

    private func save(_ codes: [String]) {
        languages = codes
        settings.setSpokenLanguages(codes)
    }
}
