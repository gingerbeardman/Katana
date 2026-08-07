import Foundation

/// Minimal ISO 9660 Level-1 reader for extracting a single file (e.g. 0GDTEX.PVR).
/// Supports single-file ISOs and multi-track GDI (directory on early data track, files on later).
enum Iso9660FileExtractor: Sendable {
    private static let sectorSize = 2048

    /// A 2048-byte data track and its starting LBA (from disc.gdi).
    struct DataTrack: Sendable {
        var lba: UInt32
        var url: URL
    }

    /// Extract a root-level file by name from a single ISO image file.
    nonisolated static func extract(named fileName: String, fromIsoURL url: URL) -> Data? {
        let tracks = [DataTrack(lba: 0, url: url)]
        return extract(named: fileName, tracks: tracks, directoryLBAOffset: 0)
    }

    /// Extract using multi-track GDI layout: absolute LBAs, files may live on later tracks.
    nonisolated static func extract(named fileName: String, tracks: [DataTrack]) -> Data? {
        guard !tracks.isEmpty else { return nil }
        // Prefer a track that has a Primary Volume Descriptor at sector 16 of the file.
        // High-density track03 usually starts at GD LBA 45000 with IP.BIN + PVD.
        let sorted = tracks.sorted { $0.lba < $1.lba }
        for dirTrack in sorted.reversed() {
            if let data = extract(
                named: fileName,
                tracks: sorted,
                directoryLBAOffset: dirTrack.lba,
                preferredDirectoryTrack: dirTrack
            ) {
                return data
            }
        }
        return nil
    }

    // MARK: - Core

    private nonisolated static func extract(
        named fileName: String,
        tracks: [DataTrack],
        directoryLBAOffset: UInt32,
        preferredDirectoryTrack: DataTrack? = nil
    ) -> Data? {
        let dirTrack = preferredDirectoryTrack
            ?? tracks.first(where: { $0.lba == directoryLBAOffset })
            ?? tracks.first
        guard let dirTrack else { return nil }

        guard let pvd = readAbsoluteSector(tracks: tracks, absoluteLBA: directoryLBAOffset + 16)
                ?? readFileSector(dirTrack.url, fileSector: 16)
        else { return nil }
        guard pvd.count >= 190, pvd[0] == 1 else { return nil }

        // Root directory: location is absolute LBA (includes GD offset on high-density images).
        let rootLBA = le32(pvd, 156 + 2)
        let rootLen = Int(le32(pvd, 156 + 10))
        guard rootLBA > 0, rootLen > 0 else { return nil }

        let rootData = readAbsoluteExtent(tracks: tracks, absoluteLBA: rootLBA, length: rootLen)
        guard !rootData.isEmpty else { return nil }

        let target = normalizeName(fileName)
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
                if normalizeName(rawName) == target {
                    let fileLBA = le32(rootData, offset + 2)
                    let fileLen = Int(le32(rootData, offset + 10))
                    if fileLBA > 0, fileLen > 0 {
                        let bytes = readAbsoluteExtent(
                            tracks: tracks,
                            absoluteLBA: fileLBA,
                            length: fileLen
                        )
                        if !bytes.isEmpty { return Data(bytes) }
                    }
                }
            }
            offset += recLen
        }
        return nil
    }

    // MARK: - Track I/O

    /// Read one sector by absolute GD/ISO LBA across multi-track files.
    private nonisolated static func readAbsoluteSector(
        tracks: [DataTrack],
        absoluteLBA: UInt32
    ) -> [UInt8]? {
        guard let (track, rel) = mapLBA(absoluteLBA, tracks: tracks) else { return nil }
        return readFileSector(track.url, fileSector: rel)
    }

    private nonisolated static func readAbsoluteExtent(
        tracks: [DataTrack],
        absoluteLBA: UInt32,
        length: Int
    ) -> [UInt8] {
        guard length > 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(length)
        var lba = absoluteLBA
        var remaining = length
        while remaining > 0 {
            guard let (track, rel) = mapLBA(lba, tracks: tracks) else { break }
            let chunk = min(remaining, sectorSize)
            guard let sector = readFileSector(track.url, fileSector: rel) else { break }
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

    private nonisolated static func readFileSector(_ url: URL, fileSector: UInt32) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = UInt64(fileSector) * UInt64(sectorSize)
        do {
            let size = try handle.seekToEnd()
            guard offset + UInt64(sectorSize) <= size else { return nil }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: sectorSize), data.count == sectorSize else {
                return nil
            }
            return [UInt8](data)
        } catch {
            return nil
        }
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
