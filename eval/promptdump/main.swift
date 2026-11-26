import Foundation
import VoiceIQBridge

// Prints the dictation prompt the app builds, from the real PromptV1.swift,
// for one eval case read as JSON on stdin:
// {"vocabulary": [...], "spellings": [["wrong","right"]], "customRules": "...",
//  "imagesAttached": true, "app": "...", "window": "...", "page": "...",
//  "before": "...", "after": "...", "transcript": "..."}

struct Spec: Decodable {
    var vocabulary: [String]?
    var spellings: [[String]]?
    var customRules: String?
    var imagesAttached: Bool?
    var app: String?
    var window: String?
    var page: String?
    var before: String?
    var after: String?
    var transcript: String?
}

let spec = try JSONDecoder().decode(Spec.self, from: FileHandle.standardInput.readDataToEndOfFile())
let surrounding = (spec.before != nil || spec.after != nil)
    ? SurroundingText(before: spec.before ?? "", after: spec.after ?? "") : nil
let place = DictationPlace(appName: spec.app, windowTitle: spec.window, pageURL: spec.page)
let prompt = PromptV1.dictationPrompt(
    vocabulary: spec.vocabulary ?? [],
    spellings: (spec.spellings ?? []).compactMap { $0.count == 2 ? (wrong: $0[0], right: $0[1]) : nil },
    customRules: spec.customRules,
    imagesAttached: spec.imagesAttached ?? false,
    surroundingText: surrounding,
    place: place,
    transcript: spec.transcript
)
print(prompt, terminator: "")
