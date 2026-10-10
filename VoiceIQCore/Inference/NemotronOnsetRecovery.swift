import AVFoundation
import FluidAudio
import Foundation

enum NemotronOnsetRecovery {
    static func recover(
        text: String, timings: [TokenTiming], file: AVAudioFile,
        manager: StreamingNemotronMultilingualAsrManager
    ) async throws -> String {
        let chunk = await manager.config.chunkSamples
        let chunkSeconds = Double(chunk) / 16_000
        let original = buildWordTimings(from: timings)
        guard original.count >= 5, let first = original.first,
              first.startTime >= chunkSeconds - 0.001 else { return text }
        let language = await manager.detectedLanguage()

        file.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk * 3)) else {
            return text
        }
        do {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(file.length, Int64(chunk * 3))))
        } catch {
            try Task.checkCancellation()
            return text
        }
        guard let data = buffer.floatChannelData?[0] else { return text }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        // Match the SDK's energy gate to skip quiet openings. This is only
        // a candidate filter; the word alignment below decides what to retain.
        let speechWindows = stride(from: 0, to: min(chunk, samples.count), by: 1_280).filter { start in
            let window = samples[start..<min(start + 1_280, min(chunk, samples.count))]
            return window.reduce(Float(0)) { $0 + $1 * $1 } / Float(window.count) >= 0.0025 * 0.0025
        }.count
        guard speechWindows >= 2 else { return text }

        let started = Date()
        do {
            try Task.checkCancellation()
            await manager.reset()
            if let language {
                await manager.setLanguage(language)
                await manager.setForcedPrefix(true)
            } else {
                // Short clips may emit no language tag. Keep automatic language
                // selection and move the opening out of the first decoder chunk.
                _ = try await manager.process(samples: [Float](repeating: 0, count: chunk))
            }
            for start in stride(from: 0, to: samples.count, by: chunk) {
                try Task.checkCancellation()
                _ = try await manager.process(samples: Array(samples[start..<min(start + chunk, samples.count)]))
            }
            _ = try await manager.process(samples: [Float](repeating: 0, count: chunk))
            let alternative = try await manager.finishWithTokenTimings()
            await manager.setForcedPrefix(false)
            let result = prependMissingWords(
                to: text, original: original,
                alternative: buildWordTimings(from: alternative.timings),
                before: chunkSeconds * (language == nil ? 2 : 1)
            )
            Log.transcription.notice("Nemotron onset check: recovered=\(result != text), \(Date().timeIntervalSince(started), format: .fixed(precision: 3))s")
            return result
        } catch {
            await manager.setForcedPrefix(false)
            try Task.checkCancellation()
            Log.transcription.notice("Nemotron onset check failed; retaining primary transcript")
            return text
        }
    }

    private static func prependMissingWords(
        to text: String, original: [WordTiming], alternative: [WordTiming], before boundary: Double
    ) -> String {
        func normalized(_ word: String) -> String {
            String(word.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let anchor = original.prefix(5).map { normalized($0.word) }
        guard anchor.count == 5, anchor.allSatisfy({ !$0.isEmpty }),
              alternative.prefix(5).map({ normalized($0.word) }) != anchor else { return text }
        for count in 1...3 {
            guard alternative.count >= count + 5 else { break }
            let prefix = alternative.prefix(count)
            guard prefix.allSatisfy({ $0.startTime < boundary && $0.word.contains(where: \.isLetter) }),
                  alternative[count..<(count + 5)].map({ normalized($0.word) }) == anchor else { continue }
            return prefix.map(\.word).joined(separator: " ") + " " + text
        }
        return text
    }
}
