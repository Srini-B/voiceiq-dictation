#if os(macOS)
import Darwin
import Foundation
import VoiceIQSpeech

actor LocalRemoteSession: LocalSpeechSession {
    private let id = UUID()
    private let audioURL: URL
    private let model: LocalSpeechModel
    private let streaming: Bool
    private let options: LocalSpeechOptions
    private var stopped = false
    private var loading: Task<Bool, Never>?

    init(audioURL: URL, model: LocalSpeechModel, streaming: Bool, options: LocalSpeechOptions) {
        self.audioURL = audioURL
        self.model = model
        self.streaming = streaming
        self.options = options
    }

    func load(from directory: URL) async -> Bool {
        guard !stopped else { return false }
        let task = Task {
            await ParakeetHelperClient.shared.load(id: id, model: model, directory: directory, audio: audioURL, streaming: streaming, options: options)
        }
        loading = task
        let loaded = await task.value
        loading = nil
        return loaded
    }

    func append(_ pcm: Data) async -> String? {
        guard !stopped else { return nil }
        return await ParakeetHelperClient.shared.append(pcm, id: id)
    }

    func transcribe(framesWritten: Int64) async -> LocalSpeechOutput? {
        guard !stopped else { return nil }
        return await ParakeetHelperClient.shared.transcribe(id: id, frames: framesWritten)
    }

    func stop() async {
        stopped = true
        loading?.cancel()
        await ParakeetHelperClient.shared.cancel(id: id)
        await loading?.value
    }
}

/// VoiceIQ Writer in its own instance of the speech helper, so a writing
/// pass never waits on, or interleaves with, a dictation's speech exchanges.
actor LocalRemoteWriter: LocalWriterSession {
    private let id = UUID()
    private let model: LocalWriterModel

    init(model: LocalWriterModel) {
        self.model = model
    }

    func write(_ request: LocalWriterRequest, directory: URL) async -> LocalWriterOutput? {
        await ParakeetHelperClient.writer.write(id: id, model: model, directory: directory, request: request)
    }

    /// The helper keeps the writer loaded for the next dictation and exits
    /// after a minute idle. Deleting the model stops it at once
    /// (`LocalModelStore.deleteModel` calls `kill`).
    func stop() async {}

    static func kill() async {
        await ParakeetHelperClient.writer.terminateNow()
    }
}

private actor ParakeetHelperClient {
    static let shared = ParakeetHelperClient()
    static let writer = ParakeetHelperClient()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var owner: UUID?

    func load(id: UUID, model: LocalSpeechModel, directory: URL, audio: URL, streaming: Bool, options: LocalSpeechOptions) async -> Bool {
        guard owner == nil, !Task.isCancelled else { return false }
        owner = id
        do {
            try startIfNeeded()
            guard case .ready = await exchange(.load(model: model, directory: directory, audio: audio, streaming: streaming, options: options), id: id, timeout: TimeoutPolicy.localLoad) else {
                cancel(id: id)
                return false
            }
            return true
        } catch {
            Log.transcription.notice("Local helper could not start; using cloud: \(error.localizedDescription, privacy: .public)")
            cancel(id: id)
            return false
        }
    }

    func write(id: UUID, model: LocalWriterModel, directory: URL, request: LocalWriterRequest) async -> LocalWriterOutput? {
        guard owner == nil, !Task.isCancelled else { return nil }
        owner = id
        do {
            try startIfNeeded()
        } catch {
            Log.transcription.notice("Local helper could not start for writing: \(error.localizedDescription, privacy: .public)")
            cancel(id: id)
            return nil
        }
        // A cancelled dictation stops the helper mid-write, so the writer is
        // free for the next one. A finished write leaves it loaded.
        let reply = await withTaskCancellationHandler {
            await exchange(.write(model: model, directory: directory, request: request), id: id,
                           timeout: TimeoutPolicy.localWrite(maxTokens: request.maxTokens))
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        guard case .written(let output) = reply else {
            cancel(id: id)
            return nil
        }
        owner = nil
        return output
    }

    func terminateNow() {
        owner = nil
        terminate()
    }

    private func startIfNeeded() throws {
        guard process?.isRunning != true else { return }
        terminate()
        let child = Process()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/VoiceiQLocalSpeech.app/Contents/MacOS/VoiceiQLocalSpeech")
        let commands = Pipe()
        let replies = Pipe()
        // An idle helper can exit between isRunning and the write.
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardInput = commands
        child.standardOutput = replies
        child.standardError = FileHandle.standardError
        try child.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        process = child
        input = commands.fileHandleForWriting
        output = replies.fileHandleForReading
    }

    func append(_ pcm: Data, id: UUID) async -> String? {
        guard case .accepted(let preview?) = await exchange(.append(pcm), id: id, timeout: 30) else {
            cancel(id: id)
            return nil
        }
        return preview
    }

    func transcribe(id: UUID, frames: Int64) async -> LocalSpeechOutput? {
        guard owner == id else { return nil }
        let reply = await exchange(.transcribe(frames: frames), id: id,
                                   timeout: TimeoutPolicy.localTranscribe(frames: frames))
        guard owner == id else { return nil }
        owner = nil
        guard case .transcript(let text) = reply else { terminate(); return nil }
        return text
    }

    func cancel(id: UUID) {
        guard owner == id else { return }
        owner = nil
        terminate()
    }

    private func exchange(_ command: ParakeetCommand, id: UUID, timeout: Double) async -> ParakeetReply? {
        guard owner == id, let input, let output else { return nil }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self.cancel(id: id)
        }
        defer { deadline.cancel() }
        do {
            let reply = try await Task.detached {
                try ParakeetWire.write(command, to: input)
                return try ParakeetWire.read(ParakeetReply.self, from: output)
            }.value
            return owner == id ? reply : nil
        } catch {
            Log.transcription.notice("Local helper disconnected; using saved audio with cloud transcription")
            return nil
        }
    }

    private func terminate() {
        if let process, process.isRunning {
            // Core ML load/inference is not cooperatively cancellable. Exit is
            // also the barrier before model deletion is allowed to proceed.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
    }
}
#endif
