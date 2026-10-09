#if os(macOS)
import Darwin
import Foundation

enum ParakeetCommand: Codable {
    case load(model: LocalSpeechModel, directory: URL, audio: URL, streaming: Bool)
    case append(Data)
    case transcribe(frames: Int64)
}

enum ParakeetReply: Codable {
    case ready
    case accepted(String?)
    case transcript(String?)
}

enum ParakeetWire {
    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        var size = UInt32(data.count).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + data)
    }

    static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        func exact(_ count: Int) throws -> Data {
            var bytes = Data()
            while bytes.count < count {
                guard let next = try handle.read(upToCount: count - bytes.count), !next.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                bytes.append(next)
            }
            return bytes
        }
        let header = try exact(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: exact(Int(size)))
    }
}

/// Runs only in the embedded background application, never in the UI process.
public enum ParakeetHelperServer {
    public static func run() async {
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        // Third-party diagnostic prints must not corrupt the reply pipe.
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let lifetime = HelperLifetime()
        while true {
            do {
                let command = try await Task.detached {
                    try ParakeetWire.read(ParakeetCommand.self, from: .standardInput)
                }.value
                let reply = await lifetime.handle(command)
                try ParakeetWire.write(reply, to: output)
            } catch {
                exit(0) // EOF also covers host termination.
            }
        }
    }
}

private actor HelperLifetime {
    private var session: (any LocalSpeechSession)?
    private var idleExit: Task<Void, Never>?

    func handle(_ command: ParakeetCommand) async -> ParakeetReply {
        idleExit?.cancel()
        idleExit = nil
        switch command {
        case .load(let model, let directory, let audio, let streaming):
            await session?.stop()
            let next = makeLocalSpeechSession(model: model, audioURL: audio, streaming: streaming)
            session = next
            await next.load(from: directory)
            return .ready
        case .append(let pcm):
            return .accepted(await session?.append(pcm))
        case .transcribe(let frames):
            let text = await session?.transcribe(framesWritten: frames)
            await session?.stop()
            session = nil
            idleExit = Task {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                exit(0)
            }
            return .transcript(text)
        }
    }
}

actor LocalRemoteSession: LocalSpeechSession {
    private let id = UUID()
    private let audioURL: URL
    private let model: LocalSpeechModel
    private let streaming: Bool
    private var stopped = false
    private var loading: Task<Void, Never>?

    init(audioURL: URL, model: LocalSpeechModel, streaming: Bool) {
        self.audioURL = audioURL
        self.model = model
        self.streaming = streaming
    }

    func load(from directory: URL) async {
        guard !stopped else { return }
        let task = Task {
            await ParakeetHelperClient.shared.load(id: id, model: model, directory: directory, audio: audioURL, streaming: streaming)
        }
        loading = task
        await task.value
        loading = nil
    }

    func append(_ pcm: Data) async -> String? {
        guard !stopped else { return nil }
        return await ParakeetHelperClient.shared.append(pcm, id: id)
    }

    func transcribe(framesWritten: Int64) async -> String? {
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

private actor ParakeetHelperClient {
    static let shared = ParakeetHelperClient()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var owner: UUID?

    func load(id: UUID, model: LocalSpeechModel, directory: URL, audio: URL, streaming: Bool) async {
        guard owner == nil, !Task.isCancelled else { return }
        owner = id
        do {
            if process?.isRunning != true {
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
            guard case .ready = await exchange(.load(model: model, directory: directory, audio: audio, streaming: streaming), id: id, timeout: 120) else {
                cancel(id: id)
                return
            }
        } catch {
            Log.transcription.notice("Local helper could not start; using cloud: \(error.localizedDescription, privacy: .public)")
            cancel(id: id)
        }
    }

    func append(_ pcm: Data, id: UUID) async -> String? {
        guard case .accepted(let preview?) = await exchange(.append(pcm), id: id, timeout: 30) else {
            cancel(id: id)
            return nil
        }
        return preview
    }

    func transcribe(id: UUID, frames: Int64) async -> String? {
        guard owner == id else { return nil }
        let reply = await exchange(.transcribe(frames: frames), id: id,
                                   timeout: max(120, Double(frames) / 8_000))
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
