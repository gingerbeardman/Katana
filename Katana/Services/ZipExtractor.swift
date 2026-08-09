import Foundation
import zlib

/// Minimal ZIP reader for unpacking bundled menu asset packs.
///
/// The app is sandboxed and cannot spawn `/usr/bin/unzip`, so rebuild must inflate
/// archives in-process. Supports store (0) and deflate (8) entries only — enough
/// for `gdMenu.zip` / `openMenu.zip`.
enum ZipExtractor: Sendable {
    enum Error: LocalizedError {
        case truncated
        case unsupportedCompression(UInt16)
        case inflateFailed
        case emptyArchive

        var errorDescription: String? {
            switch self {
            case .truncated: return "ZIP archive is truncated or corrupt."
            case .unsupportedCompression(let m): return "Unsupported ZIP compression method \(m)."
            case .inflateFailed: return "Failed to decompress a ZIP entry."
            case .emptyArchive: return "ZIP archive contained no files."
            }
        }
    }

    /// Extract `zipURL` into `destination` (created if needed). Overwrites existing files.
    nonisolated static func extract(zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL, options: [.mappedIfSafe])
        try extract(data: data, to: destination)
    }

    nonisolated static func extract(data: Data, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var offset = 0
        var filesWritten = 0

        while offset + 30 <= data.count {
            // Local file header signature 0x04034b50
            let sig = readUInt32(data, offset)
            if sig == 0x02014b50 || sig == 0x06054b50 {
                // Central directory / end of central directory — done.
                break
            }
            guard sig == 0x04034b50 else {
                // Skip garbage / unexpected; stop rather than loop forever.
                break
            }

            let compression = readUInt16(data, offset + 8)
            let compSize = Int(readUInt32(data, offset + 18))
            let uncompSize = Int(readUInt32(data, offset + 22))
            let nameLen = Int(readUInt16(data, offset + 26))
            let extraLen = Int(readUInt16(data, offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + compSize
            guard dataEnd <= data.count, nameEnd <= data.count else {
                throw Error.truncated
            }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty else {
                offset = dataEnd
                continue
            }

            // Zip-slip guard.
            let destURL = destination.appendingPathComponent(name)
            let destPath = destURL.standardizedFileURL.path
            let rootPath = destination.standardizedFileURL.path
            guard destPath == rootPath || destPath.hasPrefix(rootPath + "/") else {
                offset = dataEnd
                continue
            }

            if name.hasSuffix("/") {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                offset = dataEnd
                continue
            }

            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let payload = data.subdata(in: dataStart..<dataEnd)
            let plain: Data
            switch compression {
            case 0:
                plain = payload
            case 8:
                plain = try inflateRaw(payload, expectedSize: uncompSize)
            default:
                throw Error.unsupportedCompression(compression)
            }

            try plain.write(to: destURL, options: .atomic)
            filesWritten += 1
            offset = dataEnd
        }

        guard filesWritten > 0 else { throw Error.emptyArchive }
    }

    // MARK: - Binary helpers

    nonisolated private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// Raw DEFLATE (ZIP method 8) — zlib with negative window bits, no wrapper.
    nonisolated private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty {
            return Data()
        }

        var stream = z_stream()
        var status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Error.inflateFailed }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) -> Data in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else {
                throw Error.inflateFailed
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            var chunks: [Data] = []
            var chunk = [UInt8](repeating: 0, count: max(expectedSize, 64 * 1024))

            while true {
                status = chunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    chunks.append(Data(chunk[0..<produced]))
                }
                switch status {
                case Z_STREAM_END:
                    var out = Data()
                    out.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
                    for c in chunks { out.append(c) }
                    return out
                case Z_OK:
                    if stream.avail_out == 0 {
                        // Need a larger scratch buffer next round.
                        if chunk.count < 8 * 1024 * 1024 {
                            chunk = [UInt8](repeating: 0, count: chunk.count * 2)
                        }
                    }
                    continue
                default:
                    throw Error.inflateFailed
                }
            }
        }
    }
}
