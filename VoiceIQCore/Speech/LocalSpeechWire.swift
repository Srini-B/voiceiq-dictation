#if os(macOS)
import Foundation

public enum ParakeetCommand: Codable {
    case load(model: LocalSpeechModel, directory: URL, audio: URL, streaming: Bool, options: LocalSpeechOptions)
    case append(Data)
    case transcribe(frames: Int64)
}

public enum ParakeetReply: Codable {
    case ready
    case accepted(String?)
    case transcript(LocalSpeechOutput?)
}

public enum ParakeetWire {
    public static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        var size = UInt32(data.count).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + data)
    }

    public static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        func exact(_ count: Int) throws -> Data {
            var bytes = Data()
            while bytes.count < count {
                guard let next = try handle.read(upToCount: count - bytes.count), !next.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                bytes.append(next)
            }
            return bytes
        }
        let header = try exact(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: exact(Int(size)))
    }
}
#endif
