// Vision OCR of screen captures, timed, the way ScreenContextCollector reads them.
// swiftc -O eval/names-latency/ocr/main.swift -o /tmp/ocr && /tmp/ocr words.txt a.png b.png
import AppKit
import Vision

let args = CommandLine.arguments
let words = (try? String(contentsOfFile: args[1], encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
for path in args.dropFirst(2) {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.customWords = words
    let started = Date()
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let text = lines.joined(separator: "\n")
    print("== \(path) \(image.width)x\(image.height) \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms, \(text.count) chars")
    print(text)
}
