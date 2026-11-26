// Runs VoiceiQ's SoundAlikeSpelling over Parakeet transcripts of the eval clips and scores it.
// swiftc -O VoiceIQCore/Sources/FormattingPipeline/SoundAlikeSpelling.swift \
//   eval/names-latency/soundalike/main.swift -o /tmp/sas && /tmp/sas <manifest> <transcripts> <label>
import Foundation

let args = CommandLine.arguments
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let transcripts = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: [String: String]]
let label = args.count > 3 ? args[3] : "current"
let dictionary = manifest["dictionary"] as! [String]
let clips = manifest["clips"] as! [[String: Any]]

func has(_ word: String, in text: String) -> Bool {
    text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
}

var hitBefore = 0, hitAfter = 0, total = 0, flipsBefore = 0, flipsAfter = 0, changedWords = 0
for clip in clips {
    let id = clip["id"] as! String
    guard let heard = transcripts[label]?[id] else { continue }
    let fixed = SoundAlikeSpelling.apply(dictionary, to: heard, language: "en")
    let targets = (clip["targets"] as? [String] ?? []).filter { !["Thursday", "Friday", "April"].contains($0) }
    for target in targets {
        total += 1
        if has(target, in: heard) { hitBefore += 1 }
        if has(target, in: fixed) { hitAfter += 1 }
    }
    for bad in clip["must_not"] as? [String] ?? [] {
        if has(bad, in: heard) { flipsBefore += 1 }
        if has(bad, in: fixed) { flipsAfter += 1 }
    }
    // Every word changed in a clip without names is a false change.
    let before = heard.split(separator: " "), after = fixed.split(separator: " ")
    if targets.isEmpty { changedWords += zip(before, after).filter { $0 != $1 }.count }
    if fixed != heard { print("\(id)\n  heard: \(heard)\n  fixed: \(fixed)") }
}
print("names \(hitBefore)/\(total) -> \(hitAfter)/\(total); English-name flips \(flipsBefore) -> \(flipsAfter); words changed in name-free clips: \(changedWords)")
