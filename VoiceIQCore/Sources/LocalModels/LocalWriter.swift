import CryptoKit
import Foundation
import os
import VoiceIQSpeech

/// Writes with LFM3-Omni-2B on this device: an on-device dictation by the
/// writing rules, and a meeting's notes. Each call claims the model from its
/// store for the request alone, so a delete waits for it, and the runner
/// frees the model before returning. A speech model warming up finishes
/// first, so the two are never loaded together.
@MainActor
public enum LocalWriter {
    public enum Failure: Error {
        /// Not offered here, not downloaded, or being deleted.
        case unavailable
        /// The answer was not the JSON object asked for.
        case malformed
    }

    /// The writer may run: it is offered on this device and downloaded.
    public static var isReady: Bool {
        LocalWriterSupport.isAvailable && LocalModelStore.writer.state == .ready
    }

    /// The written text of an on-device transcript, "" when it holds no
    /// speech. RAW is the transcript as the speech model wrote it.
    static func dictation(raw: String, context: DictationContext, runner: @escaping LocalWriteRunner) async throws -> String {
        let settings = SettingsStore()
        let english = settings.localSpeechLanguage.isEnglish
        if PromptOnDevice.isOnlyHesitation(raw, english: english) { return "" }
        let dictionary = DictionaryStore()
        let user = PromptOnDevice.user(raw: raw, customRules: settings.customWritingRules,
                                       vocabulary: dictionary.sanitizedVocabulary(), spellings: dictionary.spellings(),
                                       spelling: SpellingVariant.system.promptLine, appName: context.targetAppName, english: english)
        let result = try await generate(system: PromptOnDevice.system, user: user, grammar: textGrammar,
                                         maxTokens: max(256, raw.count / 2), maxContext: 8_192, cachesSystem: true,
                                         runner: runner)
        Log.transcription.info("on-device writer: \(result.promptTokens, privacy: .public) prompt tokens (\(result.cachedTokens, privacy: .public) cached), \(result.generatedTokens, privacy: .public) written; load \(result.loadSeconds, format: .fixed(precision: 2))s, read \(result.promptSeconds, format: .fixed(precision: 2))s, write \(result.generateSeconds, format: .fixed(precision: 2))s")
        guard let text = PromptOnDevice.text(fromAnswer: result.text) else { throw Failure.malformed }
        return text
    }

    /// A meeting's notes from its transcript.
    static func notes(system: String, user: String, runner: @escaping LocalWriteRunner) async throws -> MeetingNotes {
        let result = try await generate(system: system, user: user, grammar: MeetingNotesPrompt.onDeviceGrammar,
                                        maxTokens: MeetingNotesPrompt.onDeviceAnswerTokens,
                                        maxContext: MeetingNotesPrompt.onDeviceContext, cachesSystem: false,
                                        runner: runner)
        Log.meeting.info("on-device notes: \(result.promptTokens, privacy: .public) prompt tokens, \(result.generatedTokens, privacy: .public) written in \(result.loadSeconds + result.promptSeconds + result.generateSeconds, format: .fixed(precision: 1))s")
        return try MeetingNotesPrompt.parse(result.text)
    }

    private static func generate(system: String, user: String, grammar: String?, maxTokens: Int, maxContext: Int,
                                 cachesSystem: Bool, runner: @escaping LocalWriteRunner) async throws -> LocalWriteResult {
        guard LocalWriterSupport.isAvailable else { throw Failure.unavailable }
        await LocalModelWarmup.finished()
        let store = LocalModelStore.writer
        let id = UUID()
        let running = OSAllocatedUnfairLock<Task<LocalWriteResult, Error>?>(initialState: nil)
        let cancel: @Sendable () async -> Void = {
            guard let task = running.withLock({ $0 }) else { return }
            task.cancel()
            _ = await task.result
        }
        guard let directory = store.acquireSession(id: id, cancel: cancel) else { throw Failure.unavailable }
        defer { store.releaseSession(id: id) }
        let key = SHA256.hash(data: Data(system.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        // iOS writes on the CPU, which an app in the background may still use.
        #if os(macOS)
        let useGPU = true
        #else
        let useGPU = false
        #endif
        let request = LocalWriteRequest(
            model: directory.appendingPathComponent(LocalWriterSupport.modelFile), system: system, user: user,
            grammar: grammar, maxTokens: maxTokens, maxContext: maxContext,
            prefixCache: cachesSystem ? directory.appendingPathComponent("prefix-\(key).state") : nil, useGPU: useGPU)
        let task = Task { try await runner(request) }
        running.withLock { $0 = task }
        let timer = Task {
            try await Task.sleep(for: .seconds(TimeoutPolicy.localWrite(maxTokens: maxTokens, context: maxContext)))
            task.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// `{"text": "..."}` and nothing else.
    static let textGrammar = #"""
    root ::= "{" ws "\"text\"" ws ":" ws string ws "}"
    string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F]{4} ) )* "\""
    ws ::= [ \t\n]{0,4}
    """#
}
