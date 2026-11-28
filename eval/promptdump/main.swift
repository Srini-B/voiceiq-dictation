import Foundation
import VoiceIQBridge

// Prints the dictation prompt the app builds, from the real PromptV1.swift,
// for one eval case read as JSON on stdin:
// {"vocabulary": [...], "spellings": [["wrong","right"]], "customRules": "...", "spelling": "...",
//  "screenText": ["..."], "app": "...", "window": "...", "page": "...",
//  "before": "...", "after": "...", "transcript": "..."}
// With {"output": "..."} instead, it prints the writer's answer after the
// app's own post-processing (EmailLayout), as AssemblyAITranscriptionService does.

struct Spec: Decodable {
    var vocabulary: [String]?
    var spellings: [[String]]?
    var customRules: String?
    var spelling: String?
    var screenText: [String]?
    var app: String?
    var window: String?
    var page: String?
    var before: String?
    var after: String?
    var transcript: String?
    var output: String?
}

let spec = try JSONDecoder().decode(Spec.self, from: FileHandle.standardInput.readDataToEndOfFile())
if let output = spec.output {
    print(EmailLayout.apply(ValidationGate.stripArtifacts(output).trimmingCharacters(in: .whitespacesAndNewlines)), terminator: "")
    exit(0)
}
let surrounding = (spec.before != nil || spec.after != nil)
    ? SurroundingText(before: spec.before ?? "", after: spec.after ?? "") : nil
let place = DictationPlace(appName: spec.app, windowTitle: spec.window, pageURL: spec.page)
let prompt = PromptV1.dictationPrompt(
    vocabulary: spec.vocabulary ?? [],
    spellings: (spec.spellings ?? []).compactMap { $0.count == 2 ? (wrong: $0[0], right: $0[1]) : nil },
    customRules: spec.customRules,
    spelling: spec.spelling,
    screenText: spec.screenText ?? [],
    surroundingText: surrounding,
    place: place,
    transcript: spec.transcript ?? ""
)
print(prompt, terminator: "")
