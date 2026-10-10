import Foundation
import os
import VoiceIQSpeech

enum Log {
    static let transcription = Logger(subsystem: "io.blue.voiceiq", category: "transcription")
}

public enum LocalSpeechInference {
    public static let makeSession: LocalSpeechSessionFactory = { model, audioURL, streaming in
        switch model {
        case .parakeet: return ParakeetSession(audioURL: audioURL)
        case .nemotron: return NemotronSession(audioURL: audioURL, streaming: streaming)
        }
    }
}
