import CryptoKit
import Foundation

/// Disc content hashing with gradual on-card sidecars.
///
/// Supported sidecar layouts (read any that are present):
/// - `disc.cdi.sha` / `track04.iso.sha256` / `foo.md5` — common “filename.<algo>” files
/// - `katana.sha` — Katana multi-file aggregate (JSON: digest + fingerprints)
///
/// Extension → algorithm (when writing we prefer `.sha256`):
/// - `.md5` → MD5 (read-only recognition; we still store hex for comparison)
/// - `.sha1` / `.sha` (40 hex chars) → SHA-1
/// - `.sha256` / `.sha` (64 hex chars) → SHA-256
enum ContentHashSidecar: Sendable {
    /// Aggregate written by Katana (JSON `Record`, not a bare hex dump).
    nonisolated static let aggregateFileName = "katana.sha"
    nonisolated static let version = 1

    /// Files that count as disc payload (not manager metadata / hash sidecars).
    nonisolated static let payloadExtensions: Set<String> = [
        "cdi", "gdi", "bin", "iso", "raw", "img", "sub", "mdf", "mds", "ccd", "nrg"
    ]

    /// Hash-sidecar extensions (and short forms).
    nonisolated static let hashExtensions: Set<String> = [
        "md5", "sha", "sha1", "sha256", "sha512", "crc32", "sfv"
    ]

    nonisolated static let metadataNames: Set<String> = [
        "name.txt", "serial.txt", "info.txt",
        aggregateFileName.lowercased(),
    ]

    nonisolated struct Record: Codable, Hashable, Sendable {
        var version: Int
        /// Total bytes of all payload files at hash time.
        var payloadSize: Int64
        /// Canonical digest for the whole folder (SHA-256 hex of name-sorted payload stream).
        var sha256: String
        /// Per-file size+mtime fingerprint to detect staleness without re-hashing.
        var fileFingerprints: [String]
        var computedAt: Date
    }

    // MARK: - Public API

    /// Best available hash for a game folder without reading disc data.
    /// Prefer valid aggregate; else combine per-file `*.sha*` sidecars if complete.
    nonisolated static func validHash(in folderURL: URL) -> Record? {
        if let aggregate = readAggregate(in: folderURL),
           let manifest = try? payloadManifest(in: folderURL),
           fingerprintLines(from: manifest) == aggregate.fileFingerprints {
            return aggregate
        }

        // Per-file sidecars only — build a stable composite when every payload file has one.
        guard let manifest = try? payloadManifest(in: folderURL), !manifest.isEmpty else { return nil }
        var perFile: [(name: String, hex: String)] = []
        for item in manifest {
            guard let hex = readAdjacentHash(forFileNamed: item.name, in: folderURL) else {
                return nil
            }
            perFile.append((item.name, hex.lowercased()))
        }

        // Composite key from name:hex pairs (not a true hash of content, but stable & exact when files match).
        let composite = perFile.map { "\($0.name):\($0.hex)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(composite.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return Record(
            version: version,
            payloadSize: payloadSize(from: manifest),
            sha256: hex,
            fileFingerprints: fingerprintLines(from: manifest),
            computedAt: .distantPast // unknown; still usable for equality
        )
    }

    /// Canonical payload file name (as stored on the card) + URL to read content from.
    /// Content may live on a faster volume during import (hash source before SD write).
    nonisolated struct PayloadSource: Sendable {
        var name: String
        var contentURL: URL
    }

    nonisolated struct ComputeResult: Sendable {
        var sha256: String
        var payloadSize: Int64
        var perFileSHA256: [(name: String, hex: String)]
    }

    /// Hash payload bytes from arbitrary paths using **canonical names** in the digest.
    /// Does not write sidecars — use `write(_:to:)` after files exist at the destination.
    nonisolated static func compute(sources: [PayloadSource]) throws -> ComputeResult {
        let ordered = sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !ordered.isEmpty else { throw HashError.noPayload }

        var hasher = SHA256()
        var perFileSHA256: [(name: String, hex: String)] = []
        var totalSize: Int64 = 0

        for item in ordered {
            hasher.update(data: Data(item.name.utf8))
            hasher.update(data: Data([0]))

            var fileHasher = SHA256()
            guard let handle = try? FileHandle(forReadingFrom: item.contentURL) else {
                throw HashError.unreadable(item.name)
            }
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                fileHasher.update(data: chunk)
            }
            let fileHex = fileHasher.finalize().map { String(format: "%02x", $0) }.joined()
            perFileSHA256.append((item.name, fileHex))
            let size = (try? item.contentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            totalSize += size
        }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ComputeResult(sha256: hex, payloadSize: totalSize, perFileSHA256: perFileSHA256)
    }

    /// Write aggregate + adjacent sidecars into a folder that already has the payload files.
    /// Fingerprints use **destination** size/mtime so `validHash` stays fresh after a copy.
    nonisolated static func write(_ computed: ComputeResult, to folderURL: URL) throws {
        let manifest = try payloadManifest(in: folderURL)
        guard !manifest.isEmpty else { throw HashError.noPayload }

        for item in computed.perFileSHA256 {
            try writeAdjacentHash(hex: item.hex, algorithm: .sha256, forFileNamed: item.name, in: folderURL)
        }
        if computed.perFileSHA256.count == 1, let only = computed.perFileSHA256.first {
            try writeAdjacentHash(hex: only.hex, algorithm: .sha, forFileNamed: only.name, in: folderURL)
        }

        let record = Record(
            version: version,
            payloadSize: computed.payloadSize > 0 ? computed.payloadSize : payloadSize(from: manifest),
            sha256: computed.sha256,
            fileFingerprints: fingerprintLines(from: manifest),
            computedAt: Date()
        )
        try writeAggregate(record, to: folderURL)
    }

    /// Compute SHA-256 over payload and write sidecars into the same folder.
    nonisolated static func computeAndWrite(for folderURL: URL) throws -> Record {
        let manifest = try payloadManifest(in: folderURL)
        guard !manifest.isEmpty else { throw HashError.noPayload }
        let sources = manifest.map {
            PayloadSource(name: $0.name, contentURL: folderURL.appendingPathComponent($0.name))
        }
        let computed = try compute(sources: sources)
        try write(computed, to: folderURL)
        return Record(
            version: version,
            payloadSize: computed.payloadSize,
            sha256: computed.sha256,
            fileFingerprints: fingerprintLines(from: try payloadManifest(in: folderURL)),
            computedAt: Date()
        )
    }

    // MARK: - Adjacent hash files (filename.sha / .sha256 / .md5)

    enum HashAlgorithm: String {
        case md5
        case sha1
        case sha256
        case sha // ambiguous short form — length decides when reading
        case sha512
    }

    /// Read `base.sha`, `base.sha256`, etc. Returns lowercase hex or nil.
    nonisolated static func readAdjacentHash(forFileNamed fileName: String, in folderURL: URL) -> String? {
        let candidates = [
            fileName + ".sha256",
            fileName + ".sha",
            fileName + ".sha1",
            fileName + ".md5",
            fileName + ".SHA256",
            fileName + ".SHA",
            fileName + ".MD5",
        ]
        for name in candidates {
            let url = folderURL.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let hex = parseHashFileContents(raw) {
                return hex
            }
        }
        return nil
    }

    nonisolated static func writeAdjacentHash(
        hex: String,
        algorithm: HashAlgorithm,
        forFileNamed fileName: String,
        in folderURL: URL
    ) throws {
        let ext: String
        switch algorithm {
        case .md5: ext = "md5"
        case .sha1: ext = "sha1"
        case .sha256: ext = "sha256"
        case .sha: ext = "sha"
        case .sha512: ext = "sha512"
        }
        let url = folderURL.appendingPathComponent("\(fileName).\(ext)")
        // Common plain format: one hex line (optionally "hex  filename").
        let body = "\(hex.lowercased())  \(fileName)\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parse GNU `md5sum`/`sha256sum` style or bare hex.
    nonisolated static func parseHashFileContents(_ raw: String) -> String? {
        let line = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let line else { return nil }

        // "hex", "hex  filename", "hex *filename", "MD5 (file) = hex"
        if let eq = line.range(of: "= ") {
            let hex = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            return sanitizeHex(hex)
        }
        let token = line.split(whereSeparator: { $0.isWhitespace || $0 == "*" }).first.map(String.init) ?? line
        return sanitizeHex(token)
    }

    private nonisolated static func sanitizeHex(_ s: String) -> String? {
        let hex = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hex.isEmpty, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        // 32=md5, 40=sha1, 64=sha256, 128=sha512
        guard [32, 40, 64, 128].contains(hex.count) else { return nil }
        return hex
    }

    // MARK: - Aggregate JSON

    nonisolated static func readAggregate(in folderURL: URL) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = folderURL.appendingPathComponent(aggregateFileName)
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(Record.self, from: data)
        else { return nil }
        return record
    }

    nonisolated static func writeAggregate(_ record: Record, to folderURL: URL) throws {
        let url = folderURL.appendingPathComponent(aggregateFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    // MARK: - Manifest

    nonisolated static func payloadManifest(in folderURL: URL) throws -> [(name: String, size: Int64, mtime: Int64)] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var items: [(String, Int64, Int64)] = []
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            let lower = name.lowercased()
            if metadataNames.contains(lower) { continue }
            let ext = url.pathExtension.lowercased()
            if hashExtensions.contains(ext) { continue }
            // Skip "disc.cdi.sha256" already handled by hashExtensions on last path component
            // — but "file.iso.sha" has extension "sha" ✓
            guard payloadExtensions.contains(ext) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970.rounded(.down))
            items.append((name, size, mtime))
        }
        return items.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    nonisolated static func fingerprintLines(from manifest: [(name: String, size: Int64, mtime: Int64)]) -> [String] {
        manifest.map { "\($0.name):\($0.size):\($0.mtime)" }
    }

    nonisolated static func payloadSize(from manifest: [(name: String, size: Int64, mtime: Int64)]) -> Int64 {
        manifest.reduce(0) { $0 + $1.size }
    }
}

enum HashError: LocalizedError {
    case noPayload
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noPayload: return "No game payload files to hash."
        case .unreadable(let name): return "Could not read \(name)."
        }
    }
}
