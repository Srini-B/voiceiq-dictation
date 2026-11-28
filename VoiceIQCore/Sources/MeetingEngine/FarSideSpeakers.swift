import AVFoundation
import Foundation
import VoiceIQSpeech

/// The on-device speaker model's stretches (pyannote community-1) laid over
/// the far side's words from Gemini: who said each word, and the far-side
/// track written to one file for the model to read (`MeetingTranscriber.splitFarSide`).
enum FarSideSpeakers {
    /// The track is written a minute at a time.
    static let piece = 60.0

    /// Words closer together than this are one phrase, said by one person.
    static let phraseGap = 0.3

    /// Where the diarizer heard two or more people at a word, the word goes
    /// to whichever of them said the nearest word in its phrase that only one
    /// person was heard on. Every other word keeps its label: a one-word
    /// reply between someone else's words is a turn change, not noise.
    /// MEASURED 2026-10-27: on a Meet call's far side the diarizer put both
    /// remote speakers on the same half second, and the phrase there was
    /// split between them word by word. Taking the phrase's speaker for
    /// every unsure word, also outside overlaps, moved 77 words in three
    /// earlier meetings, many of them real replies ("Awesome.", "Cool.").
    static func settled(_ words: [TimedWord], segments: [LocalMeetingResult.Segment]) -> [TimedWord] {
        let heard = words.map { word -> Set<String> in
            let middle = (word.start + word.end) / 2
            return Set(segments.filter { $0.start <= middle && middle <= $0.end }.map { "s\($0.speaker + 1)" })
        }
        var out = words
        var first = 0
        while first < words.count {
            var last = first
            while last + 1 < words.count, words[last + 1].start - words[last].end < phraseGap { last += 1 }
            let sure = (first...last).filter { heard[$0].count == 1 }
            for index in first...last where heard[index].count > 1 {
                if let nearest = sure.filter({ heard[index].contains(words[$0].speaker) })
                    .min(by: { abs($0 - index) < abs($1 - index) }) {
                    out[index].speaker = words[nearest].speaker
                }
            }
            first = last + 1
        }
        return out
    }

    /// The whole timeline, silence included, so the models' seconds are the
    /// meeting's seconds.
    static func writeMix(duration: Double, samples read: (ClosedRange<Double>) throws -> [Int16], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: true)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var start = 0.0
        while start < duration {
            try Task.checkCancellation()
            let samples = try read(start...min(duration, start + piece))
            guard !samples.isEmpty else { start += piece; continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            start += piece
        }
    }

    /// Each word takes the speaker talking at its middle; failing that, the
    /// one overlapping it most, then the nearest within two seconds, then the
    /// previous word's. Speaker slots become ids `s1`, `s2`, … by slot.
    static func label(_ words: [LocalMeetingResult.Word], segments: [LocalMeetingResult.Segment]) -> [TimedWord] {
        var out: [TimedWord] = []
        var previous = "s1"
        for word in words {
            let speaker = slot(for: word, in: segments).map { "s\($0 + 1)" } ?? previous
            previous = speaker
            out.append(TimedWord(text: word.text, speaker: speaker, start: word.start, end: word.end))
        }
        return out
    }

    private static func slot(for word: LocalMeetingResult.Word, in segments: [LocalMeetingResult.Segment]) -> Int? {
        let middle = (word.start + word.end) / 2
        if let hit = segments.first(where: { $0.start <= middle && middle <= $0.end }) { return hit.speaker }
        var bestOverlap = 0.0, overlapping: Int?
        var bestGap = 2.0, nearest: Int?
        for segment in segments {
            let overlap = min(segment.end, word.end) - max(segment.start, word.start)
            if overlap > bestOverlap { bestOverlap = overlap; overlapping = segment.speaker }
            let gap = segment.start > word.end ? segment.start - word.end : word.start - segment.end
            if gap <= bestGap { bestGap = gap; nearest = segment.speaker }
        }
        return overlapping ?? nearest
    }

    /// Ids other than the owner's renumbered in order of first appearance, so
    /// the list reads Speaker 1, Speaker 2 with no gaps.
    static func renumber(_ words: [TimedWord]) -> [TimedWord] {
        var mapping: [String: String] = [MeetingSpeaker.you: MeetingSpeaker.you]
        return words.map { word in
            if mapping[word.speaker] == nil { mapping[word.speaker] = "s\(mapping.count)" }
            var renamed = word; renamed.speaker = mapping[word.speaker]!; return renamed
        }
    }
}
