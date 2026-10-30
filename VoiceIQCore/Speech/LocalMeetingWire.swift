import Foundation

/// One saved meeting mix to transcribe on device: Fluid Speech Mini for the
/// words, Nemotron 3 Diarization for who spoke when. Without a diarizer the
/// words come back unlabelled (one speaker); iPhone and iPad run this way.
/// Without a speech model only the speaker stretches come back, for words
/// heard in the cloud.
public struct LocalMeetingRequest: Codable, Sendable {
    public var speechDirectory: URL?
    public var diarizerDirectory: URL?
    /// 16 kHz mono, the whole meeting on one timeline.
    public var audio: URL
    public init(speechDirectory: URL?, diarizerDirectory: URL?, audio: URL) {
        self.speechDirectory = speechDirectory
        self.diarizerDirectory = diarizerDirectory
        self.audio = audio
    }
}

/// Words and speaker stretches on the mix's timeline, in seconds. The two
/// lists come from different models and are joined by time afterwards.
public struct LocalMeetingResult: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }
    public struct Segment: Codable, Sendable, Equatable {
        /// Diarizer slot, 0...7, in order of first appearance.
        public var speaker: Int
        public var start: Double
        public var end: Double
        public init(speaker: Int, start: Double, end: Double) {
            self.speaker = speaker; self.start = start; self.end = end
        }
    }
    public var words: [Word]
    public var segments: [Segment]
    public init(words: [Word], segments: [Segment]) {
        self.words = words
        self.segments = segments
    }
}

public typealias LocalMeetingRunner = @Sendable (LocalMeetingRequest) async throws -> LocalMeetingResult
