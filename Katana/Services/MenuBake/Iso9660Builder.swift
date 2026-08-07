import Foundation

// MARK: - Extent model

/// A region of the virtual ISO image (DiscUtils.BuilderExtent subset).
nonisolated struct IsoExtent: Sendable {
    enum Kind: Sendable {
        case bytes([UInt8])
        case file(URL)
        case zeros
    }

    var start: Int64
    let length: Int64
    let kind: Kind
    /// True when this extent is file payload (not path table / directory / volume descriptor).
    let isFileExtent: Bool

    init(start: Int64, length: Int64, kind: Kind, isFileExtent: Bool = false) {
        self.start = start
        self.length = length
        self.kind = kind
        self.isFileExtent = isFileExtent
    }
}

/// Fixed ISO image layout: extent list + total length (may include trailing zero padding to EndSector).
nonisolated struct IsoImageLayout: Sendable {
    var extents: [IsoExtent]
    var totalLength: Int64

    /// Read up to `count` bytes at absolute image offset.
    func read(at position: Int64, into buffer: inout [UInt8], offset: Int, count: Int) throws -> Int {
        if position >= totalLength || count <= 0 { return 0 }
        let maxCount = min(count, Int(totalLength - position))
        var totalRead = 0
        var pos = position

        while totalRead < maxCount {
            guard let extent = extentCovering(pos) else {
                // Gap → zeros until next extent or end.
                let next = nextExtentStart(after: pos) ?? totalLength
                let zeroCount = min(maxCount - totalRead, Int(next - pos))
                for i in 0..<zeroCount {
                    buffer[offset + totalRead + i] = 0
                }
                totalRead += zeroCount
                pos += Int64(zeroCount)
                if zeroCount == 0 { break }
                continue
            }

            let rel = Int(pos - extent.start)
            let avail = min(maxCount - totalRead, Int(extent.length) - rel)
            switch extent.kind {
            case .bytes(let data):
                for i in 0..<avail {
                    buffer[offset + totalRead + i] = data[rel + i]
                }
            case .file(let url):
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(rel))
                let chunk = try handle.read(upToCount: avail) ?? Data()
                for i in 0..<chunk.count {
                    buffer[offset + totalRead + i] = chunk[i]
                }
                // Pad short reads with zeros (truncated file / EOF).
                for i in chunk.count..<avail {
                    buffer[offset + totalRead + i] = 0
                }
            case .zeros:
                for i in 0..<avail {
                    buffer[offset + totalRead + i] = 0
                }
            }
            totalRead += avail
            pos += Int64(avail)
        }
        return totalRead
    }

    func write(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pos: Int64 = 0
        while pos < totalLength {
            let n = try read(at: pos, into: &buffer, offset: 0, count: buffer.count)
            if n == 0 { break }
            try handle.write(contentsOf: Data(buffer[0..<n]))
            pos += Int64(n)
        }
    }

    /// Write a half-open byte range `[from, to)` of the image to a file.
    func writeRange(from: Int64, to: Int64, toFile url: URL) throws {
        precondition(from >= 0 && to >= from)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pos = from
        let end = min(to, totalLength)
        while pos < end {
            let want = min(buffer.count, Int(end - pos))
            let n = try read(at: pos, into: &buffer, offset: 0, count: want)
            if n == 0 { break }
            try handle.write(contentsOf: Data(buffer[0..<n]))
            pos += Int64(n)
        }
    }

    private func extentCovering(_ pos: Int64) -> IsoExtent? {
        // Linear scan is fine for menu images (few extents).
        for e in extents where pos >= e.start && pos < e.start + e.length {
            return e
        }
        return nil
    }

    private func nextExtentStart(after pos: Int64) -> Int64? {
        var best: Int64?
        for e in extents where e.start > pos {
            if best == nil || e.start < best! { best = e.start }
        }
        return best
    }
}

// MARK: - Directory / file members

nonisolated private final class IsoMember: @unchecked Sendable {
    enum Role: Sendable {
        case directory
        case file
    }

    let name: String
    let shortName: String
    let role: Role
    weak var parent: IsoMember?
    var creationTime: Date
    var children: [String: IsoMember] = [:]
    var sortedChildren: [IsoMember]?
    var hierarchyDepth: Int

    // File content
    var contentURL: URL?
    var contentBytes: [UInt8]?
    var contentSize: Int64 = 0

    init(name: String, shortName: String, role: Role, parent: IsoMember?, hierarchyDepth: Int) {
        self.name = name
        self.shortName = shortName
        self.role = role
        self.parent = parent
        self.hierarchyDepth = hierarchyDepth
        self.creationTime = Date()
    }

    var isDirectory: Bool { role == .directory }

    func pickName(override: String? = nil) -> String {
        if let override { return override }
        return shortName
    }

    func dataSize() -> Int64 {
        if role == .file { return contentSize }
        // Directory size: written directory records, sector-aligned.
        return Int64(directoryByteLength())
    }

    func directoryRecordSize() -> UInt32 {
        IsoDirectoryRecord.calcLength(pickName())
    }

    func pathTableEntrySize() -> UInt32 {
        let nameBytes = pickName() == "\0" ? 1 : pickName().utf8.count
        return UInt32(8 + nameBytes + (((nameBytes & 0x1) == 1) ? 1 : 0))
    }

    func getSortedChildren() -> [IsoMember] {
        if let sortedChildren { return sortedChildren }
        let sorted = children.values.sorted { a, b in
            compareMembers(a, b)
        }
        sortedChildren = sorted
        return sorted
    }

    func directoryByteLength() -> Int {
        var total = 34 * 2 // . and ..
        for m in getSortedChildren() {
            let recordSize = Int(m.directoryRecordSize())
            if (total % IsoBinary.sectorSize) + recordSize > IsoBinary.sectorSize {
                total += IsoBinary.sectorSize - (total % IsoBinary.sectorSize)
            }
            total += recordSize
        }
        return IsoBinary.roundUp(total, IsoBinary.sectorSize)
    }

    func writeDirectory(
        into buffer: inout [UInt8],
        at offset: Int,
        locations: [ObjectIdentifier: UInt32]
    ) -> Int {
        var pos = 0
        let selfLoc = locations[ObjectIdentifier(self)] ?? 0
        let parentLoc = locations[ObjectIdentifier(parent ?? self)] ?? selfLoc

        pos += IsoDirectoryRecord.write(
            fileIdentifier: "\0",
            location: selfLoc,
            dataLength: UInt32(dataSize()),
            date: creationTime,
            isDirectory: true,
            into: &buffer,
            at: offset + pos
        )
        pos += IsoDirectoryRecord.write(
            fileIdentifier: "\u{01}",
            location: parentLoc,
            dataLength: UInt32((parent ?? self).dataSize()),
            date: (parent ?? self).creationTime,
            isDirectory: true,
            into: &buffer,
            at: offset + pos
        )

        for m in getSortedChildren() {
            let recordSize = Int(m.directoryRecordSize())
            if (pos % IsoBinary.sectorSize) + recordSize > IsoBinary.sectorSize {
                let pad = IsoBinary.sectorSize - (pos % IsoBinary.sectorSize)
                for i in 0..<pad { buffer[offset + pos + i] = 0 }
                pos += pad
            }
            let loc = locations[ObjectIdentifier(m)] ?? 0
            pos += IsoDirectoryRecord.write(
                fileIdentifier: m.pickName(),
                location: loc,
                dataLength: UInt32(m.dataSize()),
                date: m.creationTime,
                isDirectory: m.isDirectory,
                into: &buffer,
                at: offset + pos
            )
        }

        let finalPad = IsoBinary.roundUp(pos, IsoBinary.sectorSize) - pos
        for i in 0..<finalPad { buffer[offset + pos + i] = 0 }
        return pos + finalPad
    }
}

nonisolated private func compareMembers(_ x: IsoMember, _ y: IsoMember) -> Bool {
    let xParts = x.name.split(separator: ".", omittingEmptySubsequences: false)
        .flatMap { $0.split(separator: ";", omittingEmptySubsequences: false) }
        .map(String.init)
    let yParts = y.name.split(separator: ".", omittingEmptySubsequences: false)
        .flatMap { $0.split(separator: ";", omittingEmptySubsequences: false) }
        .map(String.init)

    for i in 0..<2 {
        let xp = i < xParts.count ? xParts[i] : ""
        let yp = i < yParts.count ? yParts[i] : ""
        if let c = comparePart(xp, yp, pad: " ") { return c < 0 }
    }
    let xv = xParts.count > 2 ? xParts[2] : ""
    let yv = yParts.count > 2 ? yParts[2] : ""
    // Version numbers descending.
    if let c = comparePartBackwards(xv, yv, pad: "0") { return c < 0 }
    return false
}

nonisolated private func comparePart(_ x: String, _ y: String, pad: Character) -> Int? {
    let maxLen = max(x.count, y.count)
    let xArr = Array(x)
    let yArr = Array(y)
    for i in 0..<maxLen {
        let xc = i < xArr.count ? xArr[i] : pad
        let yc = i < yArr.count ? yArr[i] : pad
        if xc != yc {
            return Int(xc.asciiValue ?? 0) - Int(yc.asciiValue ?? 0)
        }
    }
    return nil
}

nonisolated private func comparePartBackwards(_ x: String, _ y: String, pad: Character) -> Int? {
    let maxLen = max(x.count, y.count)
    let xArr = Array(x)
    let yArr = Array(y)
    let xPad = maxLen - xArr.count
    let yPad = maxLen - yArr.count
    for i in 0..<maxLen {
        let xc = i >= xPad ? xArr[i - xPad] : pad
        let yc = i >= yPad ? yArr[i - yPad] : pad
        if xc != yc {
            // Descending for version.
            return Int(yc.asciiValue ?? 0) - Int(xc.asciiValue ?? 0)
        }
    }
    return nil
}

nonisolated private func comparePathTable(_ x: IsoMember, _ y: IsoMember) -> Bool {
    if x.hierarchyDepth != y.hierarchyDepth {
        return x.hierarchyDepth < y.hierarchyDepth
    }
    if x.parent !== y.parent {
        if let xp = x.parent, let yp = y.parent {
            return comparePathTable(xp, yp)
        }
    }
    return compareNamesSpacePad(x.name, y.name)
}

nonisolated private func compareNamesSpacePad(_ x: String, _ y: String) -> Bool {
    let maxLen = max(x.count, y.count)
    let xArr = Array(x)
    let yArr = Array(y)
    for i in 0..<maxLen {
        let xc = i < xArr.count ? xArr[i] : " "
        let yc = i < yArr.count ? yArr[i] : " "
        if xc != yc {
            return (xc.asciiValue ?? 0) < (yc.asciiValue ?? 0)
        }
    }
    return false
}

// MARK: - Directory record writer

nonisolated private enum IsoDirectoryRecord {
    static func calcLength(_ name: String) -> UInt32 {
        let nameBytes: Int
        if name.count == 1, let s = name.unicodeScalars.first, s.value <= 1 {
            nameBytes = 1
        } else {
            nameBytes = name.utf8.count
        }
        return UInt32(33 + nameBytes + (((nameBytes & 0x1) == 0) ? 1 : 0))
    }

    @discardableResult
    static func write(
        fileIdentifier: String,
        location: UInt32,
        dataLength: UInt32,
        date: Date,
        isDirectory: Bool,
        into buffer: inout [UInt8],
        at offset: Int
    ) -> Int {
        let length = Int(calcLength(fileIdentifier))
        buffer[offset] = UInt8(length)
        buffer[offset + 1] = 0 // XA length
        IsoBinary.writeBothUInt32(location, into: &buffer, at: offset + 2)
        IsoBinary.writeBothUInt32(dataLength, into: &buffer, at: offset + 10)
        IsoBinary.writeDirectoryTimeUTC(date, into: &buffer, at: offset + 18)
        buffer[offset + 25] = isDirectory ? 0x02 : 0x00
        buffer[offset + 26] = 0
        buffer[offset + 27] = 0
        IsoBinary.writeBothUInt16(0, into: &buffer, at: offset + 28) // volume sequence

        let lengthOfFileIdentifier: UInt8
        if fileIdentifier.count == 1, let s = fileIdentifier.unicodeScalars.first, s.value <= 1 {
            buffer[offset + 33] = UInt8(s.value)
            lengthOfFileIdentifier = 1
        } else {
            let n = IsoBinary.writeASCII(
                fileIdentifier,
                into: &buffer,
                at: offset + 33,
                count: length - 33,
                pad: false
            )
            lengthOfFileIdentifier = UInt8(n)
        }
        buffer[offset + 32] = lengthOfFileIdentifier
        return length
    }
}

// MARK: - ISO 9660 builder (Level 1, no Joliet)

/// Minimal ISO 9660 Level-1 writer matching DiscUtils CDBuilder with UseJoliet = false.
/// Supports LBA offset, last-file placement, and EndSector padding used by GDrom menus.
///
/// Marked `nonisolated` because the app defaults to MainActor isolation; bake runs off-main.
nonisolated final class Iso9660Builder: @unchecked Sendable {
    private static let diskStart: Int64 = 0x8000

    var volumeIdentifier: String = ""
    var systemIdentifier: String = ""
    var volumeSetIdentifier: String = ""
    var publisherIdentifier: String = ""
    var dataPreparerIdentifier: String = ""
    var applicationIdentifier: String = ""
    var lbaOffset: UInt32 = 0
    var lastFileStartSector: UInt32 = 0
    var endSector: UInt32?

    private var files: [IsoMember] = []
    private var dirs: [IsoMember] = []
    private let root: IsoMember

    init() {
        root = IsoMember(name: "\0", shortName: "\0", role: .directory, parent: nil, hierarchyDepth: 0)
        root.parent = root
        dirs.append(root)
    }

    func addDirectory(_ path: String) {
        let parts = splitPath(path)
        _ = getDirectory(parts, pathLength: parts.count, createMissing: true)
    }

    func addFile(_ path: String, sourceURL: URL) throws {
        let parts = splitPath(path)
        guard !parts.isEmpty else { throw BakeError.invalidPath(path) }
        let dir = getDirectory(parts, pathLength: parts.count - 1, createMissing: true)
        let fileName = parts[parts.count - 1]
        if dir.children[fileName] != nil {
            throw BakeError.fileExists(fileName)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        let short = makeShortFileName(fileName)
        let member = IsoMember(
            name: IsoBinary.normalizeFileName(fileName),
            shortName: short,
            role: .file,
            parent: dir,
            hierarchyDepth: dir.hierarchyDepth + 1
        )
        member.contentURL = sourceURL
        member.contentSize = size
        member.creationTime = mtime
        files.append(member)
        dir.children[fileName] = member
        dir.sortedChildren = nil
    }

    func addFile(_ path: String, data: Data) throws {
        let parts = splitPath(path)
        guard !parts.isEmpty else { throw BakeError.invalidPath(path) }
        let dir = getDirectory(parts, pathLength: parts.count - 1, createMissing: true)
        let fileName = parts[parts.count - 1]
        if dir.children[fileName] != nil {
            throw BakeError.fileExists(fileName)
        }
        let short = makeShortFileName(fileName)
        let member = IsoMember(
            name: IsoBinary.normalizeFileName(fileName),
            shortName: short,
            role: .file,
            parent: dir,
            hierarchyDepth: dir.hierarchyDepth + 1
        )
        member.contentBytes = Array(data)
        member.contentSize = Int64(data.count)
        files.append(member)
        dir.children[fileName] = member
        dir.sortedChildren = nil
    }

    func buildLayout() throws -> IsoImageLayout {
        let buildTime = Date()
        let sector = Int64(IsoBinary.sectorSize)
        let firstDataExtent = Self.diskStart + (2 * sector) // Primary + terminator (no Joliet)

        var primaryLocation: [ObjectIdentifier: UInt32] = [:]
        var fixedRegions: [IsoExtent] = []

        // 1. Place files at firstDataExtent
        var focus = firstDataExtent
        var highestFileLocation: Int64 = 0
        for fi in files {
            primaryLocation[ObjectIdentifier(fi)] = UInt32(focus / sector)
            let len = fi.contentSize
            if len != 0 {
                let kind: IsoExtent.Kind
                if let url = fi.contentURL {
                    kind = .file(url)
                } else if let bytes = fi.contentBytes {
                    kind = .bytes(bytes)
                } else {
                    kind = .zeros
                }
                fixedRegions.append(IsoExtent(start: focus, length: len, kind: kind, isFileExtent: true))
            }
            highestFileLocation = focus
            focus += IsoBinary.roundUp(len, sector)
        }

        // 2. Insert directories before files
        var pushFilesBackAmt: Int64 = 0
        var regionIdx = 0
        var unfocused = focus
        focus = firstDataExtent

        var startOfFirstDirData = focus
        for di in dirs {
            primaryLocation[ObjectIdentifier(di)] = UInt32(focus / sector)
            let dirLen = di.dataSize()
            var buf = [UInt8](repeating: 0, count: Int(dirLen))
            // Locations for dirs are temporary; rewritten after path-table push with LBA.
            // We'll rebuild directory bytes after final locations are known.
            fixedRegions.insert(
                IsoExtent(start: focus, length: dirLen, kind: .bytes(buf), isFileExtent: false),
                at: regionIdx
            )
            regionIdx += 1
            let pushAmt = IsoBinary.roundUp(dirLen, sector)
            pushFilesBackAmt += pushAmt
            focus += pushAmt
        }
        _ = startOfFirstDirData

        pushDataBack(
            primaryLocation: &primaryLocation,
            fixedRegions: &fixedRegions,
            pushAmount: pushFilesBackAmt,
            firstRegionIdx: regionIdx,
            applyLBA: false
        )
        unfocused += pushFilesBackAmt
        highestFileLocation += pushFilesBackAmt
        focus = firstDataExtent
        pushFilesBackAmt = 0
        let numDirExtents = regionIdx
        regionIdx = 0

        // 3. Path tables (LE + BE ASCII)
        let startOfFirstPathTable = focus
        let pathTableLength = calcPathTableLength()
        // Placeholder extents; filled after final locations + LBA applied.
        fixedRegions.insert(
            IsoExtent(start: focus, length: Int64(pathTableLength), kind: .bytes([UInt8](repeating: 0, count: Int(pathTableLength))), isFileExtent: false),
            at: regionIdx
        )
        regionIdx += 1
        var pushAmt = IsoBinary.roundUp(Int64(pathTableLength), sector)
        focus += pushAmt
        pushFilesBackAmt += pushAmt
        let primaryPathTableLength = pathTableLength

        let startOfSecondPathTable = focus
        fixedRegions.insert(
            IsoExtent(start: focus, length: Int64(pathTableLength), kind: .bytes([UInt8](repeating: 0, count: Int(pathTableLength))), isFileExtent: false),
            at: regionIdx
        )
        regionIdx += 1
        pushAmt = IsoBinary.roundUp(Int64(pathTableLength), sector)
        focus += pushAmt
        pushFilesBackAmt += pushAmt

        startOfFirstDirData = firstDataExtent + pushFilesBackAmt
        // Actually after path tables, dirs start at focus before push of files...
        // Path tables occupy firstDataExtent .. startOfFirstDirData-1 after this push.
        highestFileLocation += pushFilesBackAmt

        pushDataBack(
            primaryLocation: &primaryLocation,
            fixedRegions: &fixedRegions,
            pushAmount: pushFilesBackAmt,
            firstRegionIdx: regionIdx,
            applyLBA: true
        )
        unfocused += pushFilesBackAmt
        pushFilesBackAmt = 0

        // Correct startOfFirstDirData: after path tables (2 extents), dirs begin.
        // Path table LE at firstDataExtent, BE after, then dirs.
        let pathTableSectors = IsoBinary.roundUp(Int64(primaryPathTableLength), sector) / sector
        startOfFirstDirData = firstDataExtent + pathTableSectors * sector * 2

        // 3a. Last file placement
        if lastFileStartSector > 0 {
            let highFileSector = highestFileLocation / sector
            if lastFileStartSector < UInt32(highFileSector) + lbaOffset {
                throw BakeError.discTooBigForGDROM
            }
            pushFilesBackAmt = Int64(lastFileStartSector - UInt32(highFileSector) - lbaOffset) * sector
            pushDataBack(
                primaryLocation: &primaryLocation,
                fixedRegions: &fixedRegions,
                pushAmount: pushFilesBackAmt,
                firstRegionIdx: regionIdx + numDirExtents,
                applyLBA: false
            )
        }

        var totalLength = unfocused
        if let end = endSector {
            let desired = Int64(end - lbaOffset) * sector
            if totalLength < desired {
                totalLength = desired
            } else {
                throw BakeError.discExceedsEndSector
            }
        }

        // Rebuild path tables + directories with final locations.
        // Extent order after all inserts/pushes:
        // [path LE][path BE][dirs...][files...]
        let sortedDirs = dirs.sorted { comparePathTable($0, $1) }

        // Path LE
        if let leIdx = fixedRegions.firstIndex(where: { !$0.isFileExtent && $0.start == startOfFirstPathTable || ($0.start == firstDataExtent && !$0.isFileExtent) }) {
            // Find by kind/order more reliably
            _ = leIdx
        }

        // Assign extent indices: first two non-file after sort by start that are path tables.
        fixedRegions.sort { $0.start < $1.start }

        // Rebuild path table bytes
        let pathLE = buildPathTable(byteSwap: false, sortedDirs: sortedDirs, locations: primaryLocation)
        let pathBE = buildPathTable(byteSwap: true, sortedDirs: sortedDirs, locations: primaryLocation)

        // Find path table extents by start
        for i in fixedRegions.indices {
            if fixedRegions[i].start == startOfFirstPathTable {
                fixedRegions[i] = IsoExtent(
                    start: startOfFirstPathTable,
                    length: Int64(pathLE.count),
                    kind: .bytes(pathLE),
                    isFileExtent: false
                )
            } else if fixedRegions[i].start == startOfSecondPathTable {
                fixedRegions[i] = IsoExtent(
                    start: startOfSecondPathTable,
                    length: Int64(pathBE.count),
                    kind: .bytes(pathBE),
                    isFileExtent: false
                )
            }
        }

        // Rebuild directory extents
        for di in dirs {
            let loc = primaryLocation[ObjectIdentifier(di)] ?? 0
            // Directory extent start = (loc - lbaOffset) * sector
            let dirStart = Int64(loc - lbaOffset) * sector
            let dirLen = di.dataSize()
            var buf = [UInt8](repeating: 0, count: Int(dirLen))
            _ = di.writeDirectory(into: &buf, at: 0, locations: primaryLocation)
            // Replace matching extent
            if let idx = fixedRegions.firstIndex(where: { !$0.isFileExtent && $0.start == dirStart }) {
                fixedRegions[idx] = IsoExtent(start: dirStart, length: dirLen, kind: .bytes(buf), isFileExtent: false)
            } else {
                // Insert if missing (shouldn't happen)
                fixedRegions.append(IsoExtent(start: dirStart, length: dirLen, kind: .bytes(buf), isFileExtent: false))
            }
            _ = loc
        }

        // Volume descriptors at 0x8000
        let rootLoc = primaryLocation[ObjectIdentifier(root)] ?? 0
        let rootLen = UInt32(root.dataSize())
        let pvd = buildPrimaryVolumeDescriptor(
            volumeSpaceSize: UInt32(totalLength / sector),
            pathTableSize: UInt32(primaryPathTableLength),
            typeLPathTableLocation: UInt32(startOfFirstPathTable / sector) + lbaOffset,
            typeMPathTableLocation: UInt32(startOfSecondPathTable / sector) + lbaOffset,
            rootDirExtentLocation: rootLoc,
            rootDirDataLength: rootLen,
            buildTime: buildTime
        )
        let term = buildSetTerminator()

        fixedRegions.insert(
            IsoExtent(start: Self.diskStart, length: sector, kind: .bytes(pvd), isFileExtent: false),
            at: 0
        )
        fixedRegions.insert(
            IsoExtent(start: Self.diskStart + sector, length: sector, kind: .bytes(term), isFileExtent: false),
            at: 1
        )

        fixedRegions.sort { $0.start < $1.start }
        return IsoImageLayout(extents: fixedRegions, totalLength: totalLength)
    }

    func build(to url: URL) throws {
        let layout = try buildLayout()
        // For CreateFirstTrack we must not pad to EndSector with sparse zeros if totalLength is huge —
        // but track01 does not set EndSector. Write only through last non-zero extent end for small ISOs.
        if endSector == nil {
            let end = layout.extents.map { $0.start + IsoBinary.roundUp($0.length, Int64(IsoBinary.sectorSize)) }.max() ?? 0
            var trimmed = layout
            trimmed.totalLength = max(end, Self.diskStart + Int64(IsoBinary.sectorSize) * 2)
            try trimmed.write(to: url)
        } else {
            try layout.write(to: url)
        }
    }

    // MARK: - Private

    private func splitPath(_ path: String) -> [String] {
        path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func getDirectory(_ path: [String], pathLength: Int, createMissing: Bool) -> IsoMember {
        var focus = root
        if pathLength <= 0 { return root }
        for i in 0..<pathLength {
            let part = path[i]
            if let next = focus.children[part] {
                guard next.isDirectory else {
                    // Conflicting file name
                    return focus
                }
                focus = next
            } else if createMissing {
                let short = makeShortDirName(part)
                let di = IsoMember(
                    name: part,
                    shortName: short,
                    role: .directory,
                    parent: focus,
                    hierarchyDepth: focus.hierarchyDepth + 1
                )
                focus.children[part] = di
                focus.sortedChildren = nil
                dirs.append(di)
                focus = di
            } else {
                return focus
            }
        }
        return focus
    }

    private func makeShortDirName(_ longName: String) -> String {
        if IsoBinary.isValidDirectoryName(longName) { return longName }
        var chars = Array(longName.uppercased())
        for i in chars.indices {
            if !IsoBinary.isValidDChar(chars[i]) && chars[i] != "." && chars[i] != ";" {
                chars[i] = "_"
            }
        }
        return String(chars)
    }

    private func makeShortFileName(_ longName: String) -> String {
        if IsoBinary.isValidFileName(longName) && longName.contains(";") {
            return longName
        }
        var chars = Array(longName.uppercased())
        for i in chars.indices {
            if !IsoBinary.isValidDChar(chars[i]) && chars[i] != "." && chars[i] != ";" {
                chars[i] = "_"
            }
        }
        var parts = IsoBinary.splitFileName(String(chars))
        if parts.0.count + parts.1.count > 30 {
            parts.1 = String(parts.1.prefix(min(parts.1.count, 3)))
        }
        if parts.0.count + parts.1.count > 30 {
            parts.0 = String(parts.0.prefix(30 - parts.1.count))
        }
        return "\(parts.0).\(parts.1);\(parts.2)"
    }

    private func pushDataBack(
        primaryLocation: inout [ObjectIdentifier: UInt32],
        fixedRegions: inout [IsoExtent],
        pushAmount: Int64,
        firstRegionIdx: Int,
        applyLBA: Bool
    ) {
        guard pushAmount != 0 || applyLBA else { return }
        let sector = Int64(IsoBinary.sectorSize)
        let sectorPush = UInt32(pushAmount / sector)
        let lba = applyLBA ? lbaOffset : 0

        var rebuilt: [ObjectIdentifier: UInt32] = [:]
        for (key, value) in primaryLocation {
            // Files always move with push; dirs only get LBA when applyLBA (matching DiscUtils).
            // DiscUtils: if file OR applyLBA → add push + lba; else → value + lba only (dirs during file push keep offset).
            // When applyLBA is false (dir insert push): files get +push, dirs keep value.
            // When applyLBA is true (path table push): everyone gets +push + lba.
            let isFile = files.contains { ObjectIdentifier($0) == key }
            if isFile || applyLBA {
                rebuilt[key] = value + sectorPush + lba
            } else {
                rebuilt[key] = value + lba
            }
        }
        primaryLocation = rebuilt

        if firstRegionIdx < fixedRegions.count {
            for i in firstRegionIdx..<fixedRegions.count {
                fixedRegions[i].start += pushAmount
            }
        }
    }

    private func calcPathTableLength() -> Int {
        var length = 0
        for di in dirs {
            length += Int(di.pathTableEntrySize())
        }
        return length
    }

    private func buildPathTable(byteSwap: Bool, sortedDirs: [IsoMember], locations: [ObjectIdentifier: UInt32]) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: calcPathTableLength())
        var pos = 0
        var dirNumbers: [ObjectIdentifier: UInt16] = [:]
        var i: UInt16 = 1
        for di in sortedDirs {
            dirNumbers[ObjectIdentifier(di)] = i
            i += 1
        }
        for di in sortedDirs {
            let name = di.pickName()
            let nameBytes: [UInt8]
            if name == "\0" {
                nameBytes = [0]
            } else {
                nameBytes = Array(name.utf8)
            }
            let parentNum = dirNumbers[ObjectIdentifier(di.parent ?? di)] ?? 1
            var location = locations[ObjectIdentifier(di)] ?? 0
            var parent = parentNum
            if byteSwap {
                location = IsoBinary.bitSwapUInt32(location)
                parent = IsoBinary.bitSwapUInt16(parent)
            }
            buffer[pos] = UInt8(nameBytes.count)
            buffer[pos + 1] = 0
            IsoBinary.writeUInt32LE(location, into: &buffer, at: pos + 2)
            IsoBinary.writeUInt16LE(parent, into: &buffer, at: pos + 6)
            for (j, b) in nameBytes.enumerated() {
                buffer[pos + 8 + j] = b
            }
            let entryLen = 8 + nameBytes.count + (((nameBytes.count & 1) == 1) ? 1 : 0)
            pos += entryLen
        }
        return buffer
    }

    private func buildPrimaryVolumeDescriptor(
        volumeSpaceSize: UInt32,
        pathTableSize: UInt32,
        typeLPathTableLocation: UInt32,
        typeMPathTableLocation: UInt32,
        rootDirExtentLocation: UInt32,
        rootDirDataLength: UInt32,
        buildTime: Date
    ) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: IsoBinary.sectorSize)
        buffer[0] = 1 // Primary
        IsoBinary.writeASCII("CD001", into: &buffer, at: 1, count: 5, pad: false)
        buffer[6] = 1
        // system id A-chars
        IsoBinary.writeASCII(systemIdentifier, into: &buffer, at: 8, count: 32, pad: true)
        // volume id — DiscUtils uses WriteString with canTruncate
        IsoBinary.writeASCII(volumeIdentifier, into: &buffer, at: 40, count: 32, pad: true, canTruncate: true)
        IsoBinary.writeBothUInt32(volumeSpaceSize, into: &buffer, at: 80)
        IsoBinary.writeBothUInt16(1, into: &buffer, at: 120) // volume set size
        IsoBinary.writeBothUInt16(1, into: &buffer, at: 124) // volume sequence
        IsoBinary.writeBothUInt16(UInt16(IsoBinary.sectorSize), into: &buffer, at: 128)
        IsoBinary.writeBothUInt32(pathTableSize, into: &buffer, at: 132)
        IsoBinary.writeUInt32LE(typeLPathTableLocation, into: &buffer, at: 140)
        IsoBinary.writeUInt32LE(0, into: &buffer, at: 144) // optional L
        IsoBinary.writeUInt32LE(IsoBinary.bitSwapUInt32(typeMPathTableLocation), into: &buffer, at: 148)
        IsoBinary.writeUInt32LE(0, into: &buffer, at: 152) // optional M

        // Root directory record at 156
        _ = IsoDirectoryRecord.write(
            fileIdentifier: "\0",
            location: rootDirExtentLocation,
            dataLength: rootDirDataLength,
            date: buildTime,
            isDirectory: true,
            into: &buffer,
            at: 156
        )
        // Root record should have VolumeSequenceNumber = 1; rewrite that field.
        IsoBinary.writeBothUInt16(1, into: &buffer, at: 156 + 28)

        IsoBinary.writeASCII(volumeSetIdentifier, into: &buffer, at: 190, count: 128, pad: true)
        // DiscUtils writes 129 D-chars for volume set — keep 128 + leave last as written by pad
        IsoBinary.writeASCII(publisherIdentifier, into: &buffer, at: 318, count: 128, pad: true)
        IsoBinary.writeASCII(dataPreparerIdentifier, into: &buffer, at: 446, count: 128, pad: true)
        IsoBinary.writeASCII(applicationIdentifier, into: &buffer, at: 574, count: 128, pad: true)
        // copyright / abstract / bibliographic (37 D-chars each) — leave spaces via zeros→ we'll pad spaces
        for range in [702..<739, 739..<776, 776..<813] {
            for i in range { buffer[i] = 0x20 }
        }
        IsoBinary.writeVolumeDescriptorTimeUTC(buildTime, into: &buffer, at: 813)
        IsoBinary.writeVolumeDescriptorTimeUTC(buildTime, into: &buffer, at: 830)
        IsoBinary.writeVolumeDescriptorTimeUTC(Date.distantPast, into: &buffer, at: 847)
        IsoBinary.writeVolumeDescriptorTimeUTC(buildTime, into: &buffer, at: 864)
        buffer[881] = 1 // file structure version
        return buffer
    }

    private func buildSetTerminator() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: IsoBinary.sectorSize)
        buffer[0] = 255
        IsoBinary.writeASCII("CD001", into: &buffer, at: 1, count: 5, pad: false)
        buffer[6] = 1
        return buffer
    }
}

// MARK: - Errors

nonisolated enum BakeError: LocalizedError, Sendable {
    case invalidPath(String)
    case fileExists(String)
    case discTooBigForGDROM
    case discExceedsEndSector
    case ipBinWrongSize
    case bootFileMissing(String)
    case missingAssets(String)
    case notEnoughRoomForCDDA
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let p): return "Invalid ISO path: \(p)"
        case .fileExists(let n): return "File already exists in ISO: \(n)"
        case .discTooBigForGDROM: return "Disc image is too big for GD-ROM."
        case .discExceedsEndSector: return "Disc is too big; exceeds the desired end sector."
        case .ipBinWrongSize: return "IP.BIN is the wrong size (expected 32768 bytes)."
        case .bootFileMissing(let n): return "IP.BIN requires boot file \(n), which was not found in menu data."
        case .missingAssets(let p): return "Missing menu assets: \(p)"
        case .notEnoughRoomForCDDA: return "Not enough room to fit CDDA after high-density data headers."
        case .io(let m): return m
        }
    }
}
