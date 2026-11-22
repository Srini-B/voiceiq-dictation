import Foundation
import os
import VoiceIQSpeech

enum Log {
    static let transcription = Logger(subsystem: "io.blue.voiceiq", category: "transcription")
}

public enum LocalSpeechInference {
    public static let makeSession: LocalSpeechSessionFactory = { model, audioURL, streaming, options in
        // Both models are Parakeet TDT 0.6B v3 packages; only their files differ.
        ParakeetSession(audioURL: audioURL, streaming: streaming, options: options)
    }

    /// Runs in this process. The Mac app goes through its helper instead.
    public static let transcribeMeeting: LocalMeetingRunner = { request in
        try await LocalMeetingJob.run(request)
    }
}
