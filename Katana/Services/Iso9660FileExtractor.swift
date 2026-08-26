import Foundation

/// Minimal ISO 9660 Level-1 reader for extracting a single file (e.g. 0GDTEX.PVR).
/// Supports single-file ISOs and multi-track GDI (directory on early data track, files on later).
/// Opt out of default MainActor isolation — used from hash/scan workers.
nonisolated enum Iso9660FileExtractor: Sendable {
    private static let sectorSize = 2048

    /// A 2048-byte data track and its starting LBA (from disc.gdi).
    struct DataTrack: Sendable {
        var lba: UInt32
        var url: URL
    }

    /// Extract a root-level file by name from a single ISO image file.
    nonisolated static func extract(named fileName: String, fromIsoURL url: URL) -> Data? {
        let tracks = [DataTrack(lba: 0, url: url)]
        return extract(named: [fileName], tracks: tracks)[fileName]
    }

    /// Extract using multi-track GDI layout: absolute LBAs, files may live on later tracks.
    nonisolated static func extract(named fileName: String, tracks: [DataTrack]) -> Data? {
        extract(named: [fileName], tracks: tracks)[fileName]
    }

    /// One directory walk for several root-level names (openMenu DAT preserve).
    nonisolated static func extract(named fileNames: [String], tracks: [DataTrack]) -> [String: Data] {
        guard !tracks.isEmpty, !fileNames.isEmpty else { return [:] }
        let io = HandleCache()
        defer { io.close() }
        let wanted = Dictionary(uniqueKeysWithValues: fileNames.map { (normalizeName($0), $0) })
        var found: [String: Data] = [:]
        let sorted = tracks.sorted { $0.lba < $1.lba }
        for dirTrack in sorted.reversed() {
            extractFromDirectory(
                wanted: wanted,
                found: &found,
                tracks: sorted,
                directoryLBAOffset: dirTrack.lba,
                preferredDirectoryTrack: dirTrack,
                io: io
            )
            if found.count == wanted.count { break }
        }
        return found
    }

    // MARK: - Core

    private nonisolated static func extractFromDirectory(
        wanted: [String: String],
        found: inout [String: Data],
        tracks: [DataTrack],
        directoryLBAOffset: UInt32,
        preferredDirectoryTrack: DataTrack?,
        io: HandleCache
    ) {
        let dirTrack = preferredDirectoryTrack
            ?? tracks.first(where: { $0.lba == directoryLBAOffset })
            ?? tracks.first
        guard let dirTrack else { return }

        guard let pvd = readAbsoluteSector(
            tracks: tracks, absoluteLBA: directoryLBAOffset + 16, io: io
        ) ?? io.readSector(dirTrack.url, fileSector: 16)
        else { return }
        guard pvd.count >= 190, pvd[0] == 1 else { return }

        let rootLBA = le32(pvd, 156 + 2)
        let rootLen = Int(le32(pvd, 156 + 10))
        guard rootLBA > 0, rootLen > 0 else { return }

        let rootData = readAbsoluteExtent(
            tracks: tracks, absoluteLBA: rootLBA, length: rootLen, io: io
        )
        guard !rootData.isEmpty else { return }

        var offset = 0
        while offset + 33 <= rootData.count {
            let recLen = Int(rootData[offset])
            if recLen == 0 {
                let sectorOff = offset % sectorSize
                if sectorOff == 0 { break }
                offset += sectorSize - sectorOff
                continue
            }
            if offset + recLen > rootData.count { break }
            let nameLen = Int(rootData[offset + 32])
            guard nameLen > 0, offset + 33 + nameLen <= rootData.count else {
                offset += recLen
                continue
            }
            let flags = rootData[offset + 25]
            let isDir = (flags & 0x02) != 0
            if !isDir {
                let rawName = String(
                    bytes: rootData[(offset + 33)..<(offset + 33 + nameLen)],
                    encoding: .ascii
                ) ?? ""
                if let canonical = wanted[normalizeName(rawName)], found[canonical] == nil {
                    let fileLBA = le32(rootData, offset + 2)
                    let fileLen = Int(le32(rootData, offset + 10))
                    if fileLBA > 0, fileLen > 0 {
                        let bytes = readAbsoluteExtent(
                            tracks: tracks,
                            absoluteLBA: fileLBA,
                            length: fileLen,
                            io: io
                        )
                        if !bytes.isEmpty {
                            found[canonical] = Data(bytes)
                            if found.count == wanted.count { return }
                        }
                    }
                }
            }
            offset += recLen
        }
    }

    // MARK: - Track I/O

    /// Keeps track files open for the whole extract — opening per 2 KB sector on FAT SD
    /// made artwork-DAT preserve (BOX.DAT especially) stall a rebuild for minutes.
    private final class HandleCache: @unchecked Sendable {
        private var handles: [String: FileHandle] = [:]

        func readSector(_ url: URL, fileSector: UInt32) -> [UInt8]? {
            let data = read(
                url,
                offset: UInt64(fileSector) * UInt64(Iso9660FileExtractor.sectorSize),
                count: Iso9660FileExtractor.sectorSize
            )
            guard let data, data.count == Iso9660FileExtractor.sectorSize else { return nil }
            return [UInt8](data)
        }

        func read(_ url: URL, offset: UInt64, count: Int) -> Data? {
            guard count > 0 else { return Data() }
            let key = url.path
            let handle: FileHandle
            if let existing = handles[key] {
                handle = existing
            } else if let opened = try? FileHandle(forReadingFrom: url) {
                handles[key] = opened
                handle = opened
            } else {
                return nil
            }
            do {
                let size = try handle.seekToEnd()
                guard offset < size else { return nil }
                let want = min(UInt64(count), size - offset)
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: Int(want))
            } catch {
                return nil
            }
        }

        func close() {
            for handle in handles.values {
                try? handle.close()
            }
            handles.removeAll()
        }

        deinit { close() }
    }

    private nonisolated static func readAbsoluteSector(
        tracks: [DataTrack],
        absoluteLBA: UInt32,
        io: HandleCache
    ) -> [UInt8]? {
        guard let (track, rel) = mapLBA(absoluteLBA, tracks: tracks) else { return nil }
        return io.readSector(track.url, fileSector: rel)
    }

    private nonisolated static func readAbsoluteExtent(
        tracks: [DataTrack],
        absoluteLBA: UInt32,
        length: Int,
        io: HandleCache
    ) -> [UInt8] {
        guard length > 0 else { return [] }
        if let (track, rel) = mapLBA(absoluteLBA, tracks: tracks) {
            let offset = UInt64(rel) * UInt64(sectorSize)
            if let data = io.read(track.url, offset: offset, count: length), data.count == length {
                return [UInt8](data)
            }
        }
        var result = [UInt8]()
        result.reserveCapacity(length)
        var lba = absoluteLBA
        var remaining = length
        while remaining > 0 {
            guard let (track, rel) = mapLBA(lba, tracks: tracks) else { break }
            let chunk = min(remaining, sectorSize)
            guard let sector = io.readSector(track.url, fileSector: rel) else { break }
            result.append(contentsOf: sector.prefix(chunk))
            remaining -= chunk
            lba += 1
        }
        return result
    }

    /// Map absolute LBA → (track, sector index within that track file).
    private nonisolated static func mapLBA(
        _ absoluteLBA: UInt32,
        tracks: [DataTrack]
    ) -> (DataTrack, UInt32)? {
        let sorted = tracks.sorted { $0.lba < $1.lba }
        // Single track with lba 0: treat absolute LBA as file sector.
        if sorted.count == 1, sorted[0].lba == 0 {
            return (sorted[0], absoluteLBA)
        }
        // Find last track whose start LBA ≤ absoluteLBA.
        var chosen: DataTrack?
        for t in sorted where t.lba <= absoluteLBA {
            chosen = t
        }
        guard let track = chosen else {
            // Directory LBA might be relative to high-density start on some builds.
            if let first = sorted.first(where: { $0.lba >= 45000 }) {
                if absoluteLBA >= first.lba {
                    return (first, absoluteLBA - first.lba)
                }
                // Relative to high-density base
                return (first, absoluteLBA)
            }
            return nil
        }
        return (track, absoluteLBA - track.lba)
    }

    private nonisolated static func normalizeName(_ name: String) -> String {
        let noVer = name.split(separator: ";").first.map(String.init) ?? name
        return noVer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private nonisolated static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
