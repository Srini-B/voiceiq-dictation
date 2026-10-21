#if os(macOS)
import AVFoundation
import Darwin
import Foundation
import os
import VoiceIQSpeech

/// Runs one meeting through its own copy of the local speech helper, apart
/// from the dictation helper, so a meeting being written up never holds up a
/// dictation and a stuck meeting is ended by killing a process that owns
/// nothing else.
public enum LocalMeetingHelper {
    enum Failure: LocalizedError {
        case helper(String)
        case timedOut
        case disconnected

        var errorDescription: String? {
            switch self {
            case .helper(let reason): return reason
            case .timedOut: return "On-device transcription took too long."
            case .disconnected: return "The on-device transcription helper stopped."
            }
        }
    }

    public static let run: LocalMeetingRunner = { request in try await transcribe(request) }

    static func transcribe(_ request: LocalMeetingRequest) async throws -> LocalMeetingResult {
        let duration = (try? AVAudioFile(forReading: request.audio)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/VoiceiQLocalSpeech.app/Contents/MacOS/VoiceiQLocalSpeech")
        let commands = Pipe(), replies = Pipe()
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = commands
        process.standardOutput = replies
        process.standardError = FileHandle.standardError
        try process.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        let input = commands.fileHandleForWriting, output = replies.fileHandleForReading
        let end: @Sendable () -> Void = {
            // Core ML work is not cooperatively cancellable; the kill is the stop.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.close()
            try? output.close()
        }
        defer { end() }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(TimeoutPolicy.localMeeting(audioSeconds: duration))) } catch { return }
            timedOut.withLock { $0 = true }
            end()
        }
        defer { deadline.cancel() }
        let reply: ParakeetReply
        do {
            reply = try await withTaskCancellationHandler {
                try await Task.detached {
                    try ParakeetWire.write(ParakeetCommand.meeting(request), to: input)
                    return try ParakeetWire.read(ParakeetReply.self, from: output)
                }.value
            } onCancel: { end() }
        } catch {
            throw timedOut.withLock { $0 } ? Failure.timedOut : Failure.disconnected
        }
        switch reply {
        case .meeting(let result): return result
        case .meetingFailed(let reason): throw Failure.helper(reason)
        case .ready, .accepted, .transcript: throw Failure.disconnected
        }
    }
}
#endif
