import ActivityKit
import AppIntents
import SwiftUI
import VoiceIQBridge
import WidgetKit

@main
struct VoiceIQWidgets: WidgetBundle {
    var body: some Widget {
        VoiceSessionLiveActivity()
        if #available(iOS 18.0, *) {
            DictationControl()
        }
    }
}

/// "VoiceiQ Dictate" in Control Center, assignable to the Action button.
/// Press once to start dictating in whatever app is open, again to stop.
@available(iOS 18.0, *)
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.blue.voiceiq.ios.control.dictate") {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("VoiceiQ Dictate")
        .description("Start or stop a dictation without opening VoiceiQ.")
    }
}

private let brandBlue = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.341, green: 0.525, blue: 0.941, alpha: 1)
        : UIColor(red: 0.133, green: 0.322, blue: 0.737, alpha: 1)
})
private let recordingRed = Color(red: 0.92, green: 0.26, blue: 0.21)
private let activityInk = Color(red: 0.09, green: 0.094, blue: 0.102).opacity(0.92)

struct VoiceSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceSessionAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(context.state.phase == .ready ? 12 : 16)
                .activityBackgroundTint(activityInk)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(for: context.state))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingStatus(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionButton(state: context.state, expanded: true)
                        .padding(.top, 6)
                }
            } compactLeading: {
                CompactLeading(state: context.state)
            } compactTrailing: {
                CompactTrailing(state: context.state)
            } minimal: {
                MinimalView(state: context.state)
            }
            .keylineTint(isRecording(context.state.phase) ? recordingRed : brandBlue)
        }
    }
}

private func isRecording(_ phase: VoiceSessionAttributes.ContentState.Phase) -> Bool {
    phase == .recording || phase == .meeting
}

private func title(for state: VoiceSessionAttributes.ContentState) -> String {
    switch state.phase {
    case .ready: return "VoiceiQ ready"
    case .recording: return "Listening"
    case .processing: return state.mode == .ask ? "Thinking" : "Writing"
    case .meeting: return "Recording notes"
    }
}

private struct CompactLeading: View {
    let state: VoiceSessionAttributes.ContentState

    @ViewBuilder var body: some View {
        switch state.phase {
        case .ready:
            EmptyView()
        case .recording:
            TinyWaveform()
        case .processing:
            Image("BrandMark").resizable().scaledToFit().frame(width: 20, height: 20)
        case .meeting:
            Image(systemName: "record.circle.fill").foregroundStyle(recordingRed)
        }
    }
}

private struct CompactTrailing: View {
    let state: VoiceSessionAttributes.ContentState

    @ViewBuilder var body: some View {
        switch state.phase {
        case .ready:
            EmptyView()
        case .recording, .meeting:
            TimerText(state: state)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(recordingRed)
                .frame(maxWidth: 46)
        case .processing:
            ProgressView().controlSize(.mini).tint(brandBlue)
        }
    }
}

private struct MinimalView: View {
    let state: VoiceSessionAttributes.ContentState

    @ViewBuilder var body: some View {
        switch state.phase {
        case .ready:
            EmptyView()
        case .recording:
            TinyWaveform()
        case .processing:
            ProgressView().controlSize(.mini).tint(brandBlue)
        case .meeting:
            Image(systemName: "record.circle.fill").foregroundStyle(recordingRed)
        }
    }
}

private struct TinyWaveform: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach([8.0, 15.0, 11.0], id: \.self) { height in
                Capsule().fill(recordingRed).frame(width: 3, height: height)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct TimerText: View {
    let state: VoiceSessionAttributes.ContentState

    @ViewBuilder var body: some View {
        if let since = state.since, isRecording(state.phase) {
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TrailingStatus: View {
    let state: VoiceSessionAttributes.ContentState

    @ViewBuilder var body: some View {
        if isRecording(state.phase) {
            TimerText(state: state)
                .font(.title3.monospacedDigit())
                .foregroundStyle(recordingRed)
        } else if state.phase == .processing {
            ProgressView().tint(brandBlue)
        } else {
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActionButton: View {
    let state: VoiceSessionAttributes.ContentState
    var expanded = false

    var body: some View {
        Group {
            switch state.phase {
            case .recording:
                Button(intent: StopDictationIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(recordingRed)
            case .meeting:
                Button(intent: StopMeetingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(recordingRed)
            case .ready, .processing:
                Button(intent: EndVoiceSessionIntent()) {
                    Label(expanded ? "End session" : "End", systemImage: "xmark")
                }
                .tint(.white.opacity(0.18))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .foregroundStyle(.white)
    }
}

private struct LockScreenView: View {
    let state: VoiceSessionAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
            if state.phase == .ready {
                Text("VoiceiQ ready")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: state))
                        .font(.headline)
                        .foregroundStyle(.white)
                    if isRecording(state.phase) {
                        TimerText(state: state)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    } else {
                        Text("In progress")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            Spacer(minLength: 8)
            ActionButton(state: state)
        }
    }
}
