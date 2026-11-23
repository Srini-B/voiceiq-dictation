import Compression
import Foundation

/// Reads the files of an ordinary ZIP archive: stored or deflated entries,
/// no encryption, no ZIP64. Enough for the exports other apps email, and
/// it works the same on the Mac and the iPhone, where Foundation cannot unzip.
struct ZipArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum Failure: Error, Equatable {
        case notAZip
        case unsupported(String)
        case damaged(String)
    }

    let entries: [Entry]
    private let bytes: [UInt8]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16 { Self.u16(bytes, offset) }
        func u32(_ offset: Int) -> UInt32 { Self.u32(bytes, offset) }
        guard bytes.count >= 22, u32(0) == 0x0403_4b50 || u32(0) == 0x0605_4b50 else { throw Failure.notAZip }
        // The end record sits in the last 22 bytes plus up to 64 KB of comment.
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
            where u32(offset) == 0x0605_4b50 {
            end = offset
            break
        }
        guard let end else { throw Failure.damaged("its table of contents is missing") }
        let count = Int(u16(end + 10)), directorySize = Int(u32(end + 12)), directoryOffset = Int(u32(end + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64 archives") }
        guard u16(end + 4) == 0, directoryOffset + directorySize <= end else { throw Failure.damaged("its table of contents is out of range") }
        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard offset + 46 <= end, u32(offset) == 0x0201_4b50 else { throw Failure.damaged("an entry is unreadable") }
            let flags = u16(offset + 8)
            let nameLength = Int(u16(offset + 28)), extraLength = Int(u16(offset + 30)), commentLength = Int(u16(offset + 32))
            guard offset + 46 + nameLength <= end else { throw Failure.damaged("an entry name is out of range") }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            // Names are UTF-8 or the writer's code page; Latin-1 reads any byte without failing.
            let path = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            entries.append(Entry(path: path, method: u16(offset + 10), flags: flags, crc: u32(offset + 16),
                                 compressedSize: Int(u32(offset + 20)), size: Int(u32(offset + 24)),
                                 localHeaderOffset: Int(u32(offset + 42))))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
        self.bytes = bytes
    }

    /// The entry's uncompressed bytes, checked against its CRC.
    func contents(of entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw Failure.unsupported("password-protected files") }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, u32(header) == 0x0403_4b50 else { throw Failure.damaged("\(entry.path) is unreadable") }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressedSize <= bytes.count else { throw Failure.damaged("\(entry.path) is cut short") }
        let compressed = bytes[start..<(start + entry.compressedSize)]
        let output: [UInt8]
        switch entry.method {
        case 0:
            output = Array(compressed)
        case 8:
            guard entry.size > 0 else { output = []; break }
            guard !compressed.isEmpty else { throw Failure.damaged("\(entry.path) is empty") }
            var buffer = [UInt8](repeating: 0, count: entry.size)
            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
            let written = compressed.withUnsafeBufferPointer { source in
                buffer.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(destination.baseAddress!, entry.size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged("\(entry.path) does not decompress") }
            output = buffer
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
        guard Self.crc32(output) == entry.crc else { throw Failure.damaged("\(entry.path) fails its checksum") }
        return Data(output)
    }

    private func u16(_ offset: Int) -> UInt16 { Self.u16(bytes, offset) }
    private func u32(_ offset: Int) -> UInt32 { Self.u32(bytes, offset) }
    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
