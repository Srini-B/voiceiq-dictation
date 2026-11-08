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

    /// VoiceIQ Writer: MLX on the GPU in the Mac's speech helper, llama.cpp on
    /// the CPU in the iPhone and iPad app.
    public static let makeWriter: LocalWriterSessionFactory = { model in
        #if os(macOS)
        MLXWriterSession(model: model)
        #else
        LlamaWriterSession(model: model)
        #endif
    }

    /// Runs in this process. The Mac app goes through its helper instead.
    public static let transcribeMeeting: LocalMeetingRunner = { request in
        try await LocalMeetingJob.run(request)
    }
}
