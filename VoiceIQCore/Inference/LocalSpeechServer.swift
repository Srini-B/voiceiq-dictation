#if os(macOS)
import Darwin
import Foundation
import VoiceIQSpeech

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
        case .load(let model, let directory, let audio, let streaming, let options):
            await session?.stop()
            let next = LocalSpeechInference.makeSession(model, audio, streaming, options)
            session = next
            await next.load(from: directory)
            return .ready
        case .append(let pcm):
            return .accepted(await session?.append(pcm))
        case .transcribe(let frames):
            let output = await session?.transcribe(framesWritten: frames)
            await session?.stop()
            session = nil
            idleExit = Task {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                exit(0)
            }
            return .transcript(output)
        }
    }
}
#endif
