import FluidAudio
import Foundation

// Transcribes every clip with an on-device Parakeet model folder the way
// ParakeetSession does (loadLocal as .v3, no language hint), without the
// English tools' vocabulary rescoring.
// Usage: OnDeviceEval <model dir> <clips dir> <ids file> <out.json>
let args = CommandLine.arguments
let modelDir = URL(fileURLWithPath: args[1]), clips = URL(fileURLWithPath: args[2])
let ids = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").map(String.init)
let started = Date()
let models = try AsrModels.loadLocal(from: modelDir, version: .v3)
let manager = AsrManager(config: .default, models: models)
try await manager.loadModels(models)
print("loaded in \(Date().timeIntervalSince(started)) s")
var out: [String: [String: Double]] = [:]
var texts: [String: String] = [:]
for id in ids {
    let t = Date()
    var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(clips.appendingPathComponent("\(id).flac"), decoderState: &decoder)
    texts[id] = result.text
    out[id] = ["seconds": Date().timeIntervalSince(t)]
}
let json: [String: Any] = ["texts": texts, "timing": out]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: args[4]))
print("wrote \(ids.count)")
