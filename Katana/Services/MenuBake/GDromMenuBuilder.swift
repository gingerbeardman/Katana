import Foundation

/// GD-ROM multi-track menu disc builder (port of DiscUtils.Gdrom.GDromBuilder, data mode only).
nonisolated struct GDromMenuBuilder: Sendable {
    static let dataSectorSize = 2048
    static let rawSectorSize = 2352
    static let gdStartLBA: UInt32 = 45000
    static let gdEndLBA: UInt32 = 549150

    var volumeIdentifier: String = "DREAMCAST"
    var systemIdentifier: String = ""
    var volumeSetIdentifier: String = ""
    var publisherIdentifier: String = ""
    var dataPreparerIdentifier: String = ""
    var applicationIdentifier: String = ""
    var truncateData: Bool = true

    struct DiscTrack: Sendable {
        var fileName: String
        var fileSize: Int64
        var lba: UInt32
        /// 4 = data, 0 = audio
        var type: UInt8
    }

    /// Create low-density track01.iso from a flat list of files.
    func createFirstTrack(destinationIso: URL, files: [URL]) throws {
        let builder = Iso9660Builder()
        builder.volumeIdentifier = volumeIdentifier
        builder.systemIdentifier = systemIdentifier
        builder.volumeSetIdentifier = volumeSetIdentifier
        builder.publisherIdentifier = publisherIdentifier
        builder.dataPreparerIdentifier = dataPreparerIdentifier
        builder.applicationIdentifier = applicationIdentifier
        for file in files {
            try builder.addFile(file.lastPathComponent, sourceURL: file)
        }
        try builder.build(to: destinationIso)
    }

    /// Build high-density tracks (track03 + optional CDDA + last data track) into `outDir`.
    /// - Parameters:
    ///   - dataDirectory: High-density file tree (menu_data + LIST.INI).
    ///   - ipBinURL: 32 KiB IP.BIN
    ///   - cddaTracks: Existing audio tracks already copied into outDir (e.g. track04.raw)
    ///   - outDir: Destination GDI folder
    @discardableResult
    func buildGDROM(
        dataDirectory: URL,
        ipBinURL: URL,
        cddaTracks: [URL],
        outDir: URL
    ) throws -> [DiscTrack] {
        let track03Path = outDir.appendingPathComponent("track03.iso")
        let lastTrackName = Self.lastTrackName(cddaCount: cddaTracks.count)
        let lastTrackPath = outDir.appendingPathComponent(lastTrackName)

        var ipbinData = try Data(contentsOf: ipBinURL)
        guard ipbinData.count == 0x8000 else { throw BakeError.ipBinWrongSize }

        let bootBin = try Self.bootBinName(from: ipbinData)

        let builder = Iso9660Builder()
        builder.volumeIdentifier = volumeIdentifier
        builder.systemIdentifier = systemIdentifier
        builder.volumeSetIdentifier = volumeSetIdentifier
        builder.publisherIdentifier = publisherIdentifier
        builder.dataPreparerIdentifier = dataPreparerIdentifier
        builder.applicationIdentifier = applicationIdentifier
        builder.lbaOffset = Self.gdStartLBA
        builder.endSector = Self.gdEndLBA

        try populateFromFolder(
            builder: builder,
            directory: dataDirectory,
            basePath: dataDirectory,
            bootBin: bootBin
        )

        let layout = try builder.buildLayout()

        var tracks = try readCDDA(cddaTracks)

        // Multi-track when CDDA present or truncate path requested with last track.
        if !tracks.isEmpty || truncateData {
            try exportMultiTrack(
                layout: layout,
                ipbinData: &ipbinData,
                tracks: &tracks,
                track03Path: track03Path,
                lastTrackPath: lastTrackPath,
                lastTrackName: lastTrackName
            )
        } else {
            try exportSingleTrack(
                layout: layout,
                ipbinData: &ipbinData,
                tracks: &tracks,
                track03Path: track03Path
            )
        }

        // Persist updated IP.BIN TOC into track03 (already written during export).
        return tracks
    }

    func updateGdiFile(tracks: [DiscTrack], gdiPath: URL) throws {
        var lines: [String] = []
        if FileManager.default.fileExists(atPath: gdiPath.path),
           let existing = try? String(contentsOf: gdiPath, encoding: .utf8)
        {
            let fileLines = existing.split(whereSeparator: \.isNewline).map(String.init)
            var i = 0
            lines.append(String(tracks.count + 2))
            if let first = fileLines.first, first.count <= 3, Int(first) != nil {
                i = 1
            }
            while i < fileLines.count {
                let line = fileLines[i]
                if line.hasPrefix("3") || line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == "3" {
                    break
                }
                // Keep low-density tracks 1–2
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let n = parts.first, let num = Int(n), num < 3 {
                    lines.append(line)
                }
                i += 1
            }
        } else {
            lines.append(String(tracks.count + 2))
        }

        var tn = 3
        for track in tracks {
            let sectorSize = track.type == 0 ? 2352 : 2048
            lines.append("\(tn) \(track.lba) \(track.type) \(sectorSize) \(track.fileName) 0")
            tn += 1
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: gdiPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Export

    private func exportSingleTrack(
        layout: IsoImageLayout,
        ipbinData: inout Data,
        tracks: inout [DiscTrack],
        track03Path: URL
    ) throws {
        let track3 = DiscTrack(
            fileName: track03Path.lastPathComponent,
            fileSize: Int64(Self.gdEndLBA - Self.gdStartLBA) * Int64(Self.dataSectorSize),
            lba: Self.gdStartLBA,
            type: 4
        )
        tracks.append(track3)
        updateIPBIN(&ipbinData, tracks: tracks)

        if FileManager.default.fileExists(atPath: track03Path.path) {
            try FileManager.default.removeItem(at: track03Path)
        }
        FileManager.default.createFile(atPath: track03Path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: track03Path)
        defer { try? handle.close() }
        try handle.write(contentsOf: ipbinData)

        // Rest of ISO from after IP.BIN system area.
        try appendISO(
            layout: layout,
            from: Int64(ipbinData.count),
            to: layout.totalLength,
            handle: handle
        )
        _ = track3
    }

    private func exportMultiTrack(
        layout: IsoImageLayout,
        ipbinData: inout Data,
        tracks: inout [DiscTrack],
        track03Path: URL,
        lastTrackPath: URL,
        lastTrackName: String
    ) throws {
        let sector = Int64(Self.dataSectorSize)
        var lastHeaderEnd: Int64 = 0
        var firstFileStart: Int64 = 0

        for extent in layout.extents.sorted(by: { $0.start < $1.start }) {
            if extent.isFileExtent {
                firstFileStart = extent.start
                break
            } else {
                lastHeaderEnd = extent.start + IsoBinary.roundUp(extent.length, sector)
            }
        }

        lastHeaderEnd = lastHeaderEnd / sector
        firstFileStart = firstFileStart / sector

        var trackEnd = Int(firstFileStart - 150)
        for i in stride(from: tracks.count - 1, through: 0, by: -1) {
            let sectors = IsoBinary.roundUp(tracks[i].fileSize, Int64(Self.rawSectorSize)) / Int64(Self.rawSectorSize)
            trackEnd -= Int(sectors)
            tracks[i].lba = UInt32(trackEnd) + Self.gdStartLBA
        }
        trackEnd -= 150
        if trackEnd < Int(lastHeaderEnd) {
            throw BakeError.notEnoughRoomForCDDA
        }
        if truncateData {
            trackEnd = Int(lastHeaderEnd)
        }

        let track3 = DiscTrack(
            fileName: track03Path.lastPathComponent,
            fileSize: Int64(trackEnd) * sector,
            lba: Self.gdStartLBA,
            type: 4
        )
        tracks.insert(track3, at: 0)

        let lastTrack = DiscTrack(
            fileName: lastTrackName,
            fileSize: (Int64(Self.gdEndLBA - Self.gdStartLBA) - firstFileStart) * sector,
            lba: Self.gdStartLBA + UInt32(firstFileStart),
            type: 4
        )
        tracks.append(lastTrack)

        updateIPBIN(&ipbinData, tracks: tracks)

        // track03: IP.BIN + ISO[0x8000 .. track3.fileSize)
        if FileManager.default.fileExists(atPath: track03Path.path) {
            try FileManager.default.removeItem(at: track03Path)
        }
        FileManager.default.createFile(atPath: track03Path.path, contents: nil)
        let t3 = try FileHandle(forWritingTo: track03Path)
        defer { try? t3.close() }
        try t3.write(contentsOf: ipbinData)

        var bytesWritten = Int64(ipbinData.count)
        var buffer = [UInt8](repeating: 0, count: Self.dataSectorSize)
        var isoPos = Int64(ipbinData.count)
        while bytesWritten < track3.fileSize {
            let want = min(buffer.count, Int(track3.fileSize - bytesWritten))
            let n = try layout.read(at: isoPos, into: &buffer, offset: 0, count: want)
            if n == 0 {
                // Pad remaining with zeros if ISO header region is short.
                let pad = Int(track3.fileSize - bytesWritten)
                if pad > 0 {
                    try t3.write(contentsOf: Data(repeating: 0, count: pad))
                }
                break
            }
            try t3.write(contentsOf: Data(buffer[0..<n]))
            bytesWritten += Int64(n)
            isoPos += Int64(n)
        }

        // last track: ISO from first file start through end of image
        if FileManager.default.fileExists(atPath: lastTrackPath.path) {
            try FileManager.default.removeItem(at: lastTrackPath)
        }
        FileManager.default.createFile(atPath: lastTrackPath.path, contents: nil)
        let tLast = try FileHandle(forWritingTo: lastTrackPath)
        defer { try? tLast.close() }
        let from = firstFileStart * sector
        try appendISO(layout: layout, from: from, to: layout.totalLength, handle: tLast)
    }

    private func appendISO(
        layout: IsoImageLayout,
        from: Int64,
        to: Int64,
        handle: FileHandle
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pos = from
        let end = min(to, layout.totalLength)
        while pos < end {
            let want = min(buffer.count, Int(end - pos))
            let n = try layout.read(at: pos, into: &buffer, offset: 0, count: want)
            if n == 0 { break }
            try handle.write(contentsOf: Data(buffer[0..<n]))
            pos += Int64(n)
        }
    }

    private func updateIPBIN(_ ipbinData: inout Data, tracks: [DiscTrack]) {
        // Tracks 03–99 in TOC area at 0x104
        for t in 0..<97 {
            var dcLBA: UInt32 = 0x00FF_FFFF
            var dcType: UInt8 = 0xFF
            if t < tracks.count {
                let track = tracks[t]
                dcLBA = track.lba + 150
                dcType = (track.type << 4) | 0x1
            }
            let offset = 0x104 + (t * 4)
            ipbinData[offset] = UInt8(dcLBA & 0xFF)
            ipbinData[offset + 1] = UInt8((dcLBA >> 8) & 0xFF)
            ipbinData[offset + 2] = UInt8((dcLBA >> 16) & 0xFF)
            ipbinData[offset + 3] = dcType
        }
    }

    private func readCDDA(_ paths: [URL]) throws -> [DiscTrack] {
        var result: [DiscTrack] = []
        for path in paths {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            result.append(DiscTrack(
                fileName: path.lastPathComponent,
                fileSize: size,
                lba: 0,
                type: 0
            ))
        }
        return result
    }

    private static func lastTrackName(cddaCount: Int) -> String {
        String(format: "track%02d.iso", cddaCount + 4)
    }

    private static func bootBinName(from ipbin: Data) throws -> String {
        guard ipbin.count >= 0x70 else { throw BakeError.ipBinWrongSize }
        let slice = ipbin[0x60..<(0x60 + 16)]
        let name = String(bytes: slice, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw BakeError.bootFileMissing("(empty)") }
        return name
    }

    private func populateFromFolder(
        builder: Iso9660Builder,
        directory: URL,
        basePath: URL,
        bootBin: String?
    ) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let localDirPath = String(directory.path.dropFirst(basePath.path.count))
        if localDirPath.count > 1 {
            let isoPath = localDirPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: "\\")
            if !isoPath.isEmpty {
                builder.addDirectory(isoPath)
            }
        }

        var bootFile: URL?
        var files: [URL] = []
        var dirs: [URL] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                dirs.append(url)
            } else {
                files.append(url)
            }
        }

        for file in files {
            if let bootBin,
               file.lastPathComponent.caseInsensitiveCompare(bootBin) == .orderedSame
            {
                bootFile = file
                continue
            }
            let rel = String(file.path.dropFirst(basePath.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try builder.addFile(rel, sourceURL: file)
        }

        for dir in dirs {
            try populateFromFolder(builder: builder, directory: dir, basePath: basePath, bootBin: nil)
        }

        if let bootFile, let bootBin {
            // Boot file is placed at root with its ISO name (bootBin from IP.BIN).
            try builder.addFile(bootBin, sourceURL: bootFile)
            let size = (try? bootFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let sectorSize = IsoBinary.roundUp(size, Int64(Self.dataSectorSize))
            builder.lastFileStartSector = Self.gdEndLBA - 150 - UInt32(sectorSize / Int64(Self.dataSectorSize))
        } else if bootBin != nil {
            throw BakeError.bootFileMissing(bootBin!)
        }
    }
}
