import VoiceIQCore

/// What the keyboard tells the user when a dictation ends badly, and the
/// session log's step-time line. Shared by the app and the keyboard, which
/// both run `DictationCoordinator`.
enum DictationNotice {
    static func isMicrophoneFailure(_ failure: DictationFailure) -> Bool {
        switch failure {
        case .audio, .noMicrophone: return true
        default: return false
        }
    }

    @MainActor
    static func message(for state: DictationState, coordinator: DictationCoordinator) -> String? {
        switch state {
        case .failed(let failure):
            if let message = coordinator.modeFailureMessage { return message }
            switch failure {
            case .auth: return "API key rejected. Check it in VoiceiQ."
            case .modelAccess: return "Model unavailable. Check Settings › Advanced."
            case .network: return "Couldn't reach the model. It's saved in History."
            case .rateLimited: return "Rate limited. Retry from History."
            case .quotaExhausted: return "Daily quota reached"
            case .timeout: return "Timed out. Retry from History."
            case .audio, .noMicrophone, .noAudio: return "Microphone unavailable"
            case .storage: return "Storage is full"
            case .badRequest, .validation, .safetyBlocked: return "Couldn't transcribe. It's in History."
            }
        case .done(.queuedForRetry): return "Offline. It will send when you're back."
        case .done(.silent): return "Didn't catch that"
        default: return nil
        }
    }

    /// Splits "processed in" so a slow result can be blamed on the mic
    /// teardown, the transcript, the cleanup request, or typing it in.
    static func stepsLine(_ stages: DictationSteps) -> String {
        var parts = [String(format: "finalize %.1fs", stages.finishRecording)]
        parts.append(String(format: stages.live ? "cloud live final %.1fs" : "cloud transcribe %.1fs", stages.transcription))
        if let writing = stages.writing { parts.append(String(format: "writing %.1fs", writing)) }
        if let insert = stages.insert { parts.append(String(format: "insert %.1fs", insert)) }
        return parts.joined(separator: ", ")
    }
}
