import CryptoKit
import Foundation

// MARK: - Model

/// Strength of evidence that two (or more) games are the same content.
nonisolated enum DuplicateGrade: String, Hashable, Sendable, Comparable, Codable {
    /// SHA-256 of disc payload matches (or size+hash when both present).
    case exact
    /// Same payload size plus serial and/or strong name match.
    case strong
    /// Same payload size only, or serial + similar name without size.
    case likely
    /// Same serial alone, or name similarity alone (fake serials often land here).
    case weak

    var label: String {
        switch self {
        case .exact: return "Exact"
        case .strong: return "Strong"
        case .likely: return "Likely"
        case .weak: return "Weak"
        }
    }

    /// Short badge text.
    var shortLabel: String {
        switch self {
        case .exact: return "EXACT"
        case .strong: return "DUP"
        case .likely: return "SIZE"
        case .weak: return "SIM"
        }
    }

    private var rank: Int {
        switch self {
        case .exact: return 4
        case .strong: return 3
        case .likely: return 2
        case .weak: return 1
        }
    }

    nonisolated static func < (lhs: DuplicateGrade, rhs: DuplicateGrade) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct DuplicateSignal: Hashable, Sendable, Codable {
    nonisolated enum Kind: String, Hashable, Sendable, Codable {
        case hash
        case size
        case serial
        case name
    }

    var kind: Kind
    var detail: String
}

/// How a game participates in a duplicate group.
nonisolated struct DuplicateInfo: Hashable, Sendable {
    var groupKey: String
    /// Best evidence linking this game to the group.
    var grade: DuplicateGrade
    var signals: [DuplicateSignal]
    /// 1-based index within the group when sorted by slot (1 = keep candidate).
    var indexInGroup: Int
    var groupSize: Int

    var isPrimary: Bool { indexInGroup == 1 }
    var isRedundant: Bool { indexInGroup > 1 }

    /// Backward-compatible label for older UI help strings.
    var reasonLabel: String {
        signals.map(\.kind.rawValue).joined(separator: "+")
    }
}

/// Stable “this is not a duplicate” identity for a game on a card.
/// Prefer content hash; fall back to folder + serial + name + size so marks survive rescan.
enum DuplicateIdentity: Sendable {
    /// Key stored per volume UUID in `VolumeStore`.
    nonisolated static func key(for game: GameEntry) -> String {
        if let hash = game.contentSHA256?.lowercased(), hash.count >= 16 {
            return "h:\(hash)"
        }
        let folder = URL(fileURLWithPath: game.folderPath).lastPathComponent
        let serial = game.serial.uppercased().filter { $0.isLetter || $0.isNumber }
        let name = game.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let size = game.payloadByteSize > 0 ? game.payloadByteSize : game.byteSize
        return "f:\(folder)|s:\(serial)|n:\(name)|z:\(size)"
    }
}

// MARK: - Disk cache (per volume)

/// Persisted duplicate analysis for a card. Invalidated when game names/sizes/hashes change.
nonisolated struct DuplicateCacheRecord: Codable, Sendable {
    var version: Int
    var volumeUUID: String
    /// SHA-256 hex of the analysis input (folders, names, sizes, hashes, ignored keys).
    var signature: String
    var rows: [DuplicateCacheRow]

    /// Bump when match rules change so stale per-card caches are ignored.
    static let currentVersion = 2
}

nonisolated struct DuplicateCacheRow: Codable, Sendable {
    var folderName: String
    var number: Int
    var grade: DuplicateGrade
    var signals: [DuplicateSignal]
    var indexInGroup: Int
    var groupSize: Int
    /// Stable group id (sorted folder names), not UUID-based.
    var groupKey: String
}

// MARK: - Detector

enum DuplicateDetector {
    /// Minimum payload size (bytes) to treat as a size-based duplicate signal.
    /// Tiny folders are ignored for size-only matches.
    nonisolated static let minSizeForMatch: Int64 = 1_000_000

    /// Name similarity (0…1) at or above this counts as a name signal.
    nonisolated static let nameSimilarityThreshold: Double = 0.82

    /// Serials that appear this often are treated as “fake / shared” and
    /// cannot form a group on serial alone.
    nonisolated static let weakSerialFrequency: Int = 4

    // MARK: Input signature (cache key)

    /// Fingerprint of everything that affects analysis for `games`.
    nonisolated static func analysisSignature(
        games: [GameEntry],
        ignoredIdentityKeys: Set<String> = []
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(games.count + 1)
        for g in games.sorted(by: { $0.number < $1.number }) {
            if g.isMenu { continue }
            let folder = URL(fileURLWithPath: g.folderPath).lastPathComponent
            let size = g.payloadByteSize > 0 ? g.payloadByteSize : g.byteSize
            lines.append(
                "\(folder)|\(g.number)|\(g.name)|\(g.serial)|\(size)|\(g.contentSHA256 ?? "")"
            )
        }
        lines.append("ignored:" + ignoredIdentityKeys.sorted().joined(separator: ","))
        let data = Data(lines.joined(separator: "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rebuild a live `DuplicateInfo` map from a disk cache (caller must check signature).
    nonisolated static func mapFromCache(
        _ record: DuplicateCacheRecord,
        onto games: [GameEntry]
    ) -> [GameEntry.ID: DuplicateInfo]? {
        guard record.version == DuplicateCacheRecord.currentVersion else { return nil }

        let liveByFolder: [String: GameEntry] = Dictionary(
            games.filter { !$0.isMenu }.map {
                (URL(fileURLWithPath: $0.folderPath).lastPathComponent, $0)
            },
            uniquingKeysWith: { _, last in last }
        )

        var result: [GameEntry.ID: DuplicateInfo] = [:]
        result.reserveCapacity(record.rows.count)
        for row in record.rows {
            guard let game = liveByFolder[row.folderName], game.number == row.number else {
                // Folder gone or renumbered — force recompute.
                return nil
            }
            result[game.id] = DuplicateInfo(
                groupKey: row.groupKey,
                grade: row.grade,
                signals: row.signals,
                indexInGroup: row.indexInGroup,
                groupSize: row.groupSize
            )
        }
        return result
    }

    /// Snapshot analysis results for disk (folder-keyed, UUID-stable).
    nonisolated static func cacheRecord(
        volumeUUID: String,
        signature: String,
        games: [GameEntry],
        info: [GameEntry.ID: DuplicateInfo]
    ) -> DuplicateCacheRecord {
        let rows: [DuplicateCacheRow] = games.compactMap { game in
            guard !game.isMenu, let dup = info[game.id] else { return nil }
            let folder = URL(fileURLWithPath: game.folderPath).lastPathComponent
            return DuplicateCacheRow(
                folderName: folder,
                number: game.number,
                grade: dup.grade,
                signals: dup.signals,
                indexInGroup: dup.indexInGroup,
                groupSize: dup.groupSize,
                groupKey: dup.groupKey
            )
        }
        .sorted { $0.number < $1.number }

        return DuplicateCacheRecord(
            version: DuplicateCacheRecord.currentVersion,
            volumeUUID: volumeUUID,
            signature: signature,
            rows: rows
        )
    }

    // MARK: Analyze

    /// Build per-game duplicate info. Menu entries are never flagged.
    /// - Parameter ignoredIdentityKeys: Per-card “not a duplicate” marks (see `DuplicateIdentity`).
    /// Safe to call off the main actor (O(n²) pair checks with precomputed features).
    nonisolated static func analyze(
        _ games: [GameEntry],
        ignoredIdentityKeys: Set<String> = []
    ) -> [GameEntry.ID: DuplicateInfo] {
        let candidates = games.filter { game in
            guard !game.isMenu else { return false }
            if ignoredIdentityKeys.isEmpty { return true }
            return !ignoredIdentityKeys.contains(DuplicateIdentity.key(for: game))
        }
        guard candidates.count >= 2 else { return [:] }

        // Precompute once — pair loop used to re-normalize names / rebuild bigrams / recompile regexes.
        let features = candidates.map(Features.init(game:))
        let serialFreq = serialFrequency(features)

        var parent = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0.id) })
        var rank = Dictionary(uniqueKeysWithValues: features.map { ($0.id, 0) })

        func find(_ id: GameEntry.ID) -> GameEntry.ID {
            var x = id
            while parent[x] != x {
                parent[x] = parent[parent[x]!]
                x = parent[x]!
            }
            return x
        }

        func union(_ a: GameEntry.ID, _ b: GameEntry.ID) {
            var ra = find(a), rb = find(b)
            if ra == rb { return }
            if rank[ra]! < rank[rb]! { swap(&ra, &rb) }
            parent[rb] = ra
            if rank[ra] == rank[rb] { rank[ra]! += 1 }
        }

        // Best edge grade between each pair that matches (for per-member grade).
        // Ordered UUID pair keys avoid allocating a Set per edge.
        var bestEdge: [EdgeKey: (DuplicateGrade, [DuplicateSignal])] = [:]
        bestEdge.reserveCapacity(min(features.count * 2, 4096))

        let list = features
        let n = list.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = list[i], b = list[j]
                guard let match = match(a, b, serialFreq: serialFreq) else { continue }
                union(a.id, b.id)
                bestEdge[EdgeKey(a.id, b.id)] = match
            }
        }

        // Components
        var components: [GameEntry.ID: [Features]] = [:]
        for f in features {
            let root = find(f.id)
            components[root, default: []].append(f)
        }

        var result: [GameEntry.ID: DuplicateInfo] = [:]
        for (_, members) in components {
            guard members.count > 1 else { continue }
            let sorted = members.sorted { $0.number < $1.number }
            // Stable group key (folder names) so disk cache remaps cleanly across UUID churn.
            let groupKey = sorted.map(\.folderName).sorted().joined(separator: "|")

            for (offset, game) in sorted.enumerated() {
                var grade: DuplicateGrade = .weak
                var signals: [DuplicateSignal] = []
                for other in sorted where other.id != game.id {
                    if let edge = bestEdge[EdgeKey(game.id, other.id)] {
                        if edge.0 > grade {
                            grade = edge.0
                            signals = edge.1
                        } else if edge.0 == grade {
                            for s in edge.1 where !signals.contains(s) {
                                signals.append(s)
                            }
                        }
                    }
                }
                if signals.isEmpty {
                    signals = [DuplicateSignal(kind: .name, detail: "grouped")]
                }

                result[game.id] = DuplicateInfo(
                    groupKey: groupKey,
                    grade: grade,
                    signals: signals,
                    indexInGroup: offset + 1,
                    groupSize: sorted.count
                )
            }
        }

        return result
    }

    nonisolated static func redundantIDs(
        in games: [GameEntry],
        ignoredIdentityKeys: Set<String> = []
    ) -> Set<GameEntry.ID> {
        Set(
            analyze(games, ignoredIdentityKeys: ignoredIdentityKeys)
                .compactMap { id, info in info.isRedundant ? id : nil }
        )
    }

    /// Prefer deleting exact/strong extras first.
    nonisolated static func redundantIDs(
        in games: [GameEntry],
        minimumGrade: DuplicateGrade,
        ignoredIdentityKeys: Set<String> = []
    ) -> Set<GameEntry.ID> {
        Set(
            analyze(games, ignoredIdentityKeys: ignoredIdentityKeys).compactMap { id, info in
                (info.isRedundant && info.grade >= minimumGrade) ? id : nil
            }
        )
    }

    nonisolated static func allDuplicateIDs(
        in games: [GameEntry],
        ignoredIdentityKeys: Set<String> = []
    ) -> Set<GameEntry.ID> {
        Set(analyze(games, ignoredIdentityKeys: ignoredIdentityKeys).keys)
    }

    nonisolated static func groupCount(
        in games: [GameEntry],
        ignoredIdentityKeys: Set<String> = []
    ) -> Int {
        Set(analyze(games, ignoredIdentityKeys: ignoredIdentityKeys).values.map(\.groupKey)).count
    }

    // MARK: - Precomputed features

    /// Per-game fields used in the pair loop (computed once).
    nonisolated struct Features: Sendable {
        var id: GameEntry.ID
        var number: Int
        var folderName: String
        var name: String
        var serialNorm: String
        var size: Int64
        var hash: String?
        var normalizedName: String
        var bigrams: Set<String>
        var discNumber: Int?
        var stemNormalized: String
        var stemBigrams: Set<String>

        nonisolated init(game: GameEntry) {
            id = game.id
            number = game.number
            folderName = URL(fileURLWithPath: game.folderPath).lastPathComponent
            name = game.name
            serialNorm = normalizeSerial(game.serial)
            size = game.payloadByteSize > 0 ? game.payloadByteSize : game.byteSize
            hash = game.contentSHA256
            normalizedName = normalizeName(game.name)
            bigrams = bigramsOf(normalizedName)
            discNumber = DuplicateDetector.discNumber(in: game.name)
            let stem = stripDiscMarkers(game.name)
            stemNormalized = stem
            stemBigrams = bigramsOf(stem)
        }
    }

    private nonisolated struct EdgeKey: Hashable, Sendable {
        var lo: GameEntry.ID
        var hi: GameEntry.ID

        init(_ a: GameEntry.ID, _ b: GameEntry.ID) {
            if a.uuidString < b.uuidString {
                lo = a; hi = b
            } else {
                lo = b; hi = a
            }
        }
    }

    // MARK: - Pair match

    /// Returns grade + signals if the pair should be linked, else nil.
    nonisolated static func match(
        _ a: GameEntry,
        _ b: GameEntry,
        serialFreq: [String: Int]
    ) -> (DuplicateGrade, [DuplicateSignal])? {
        match(Features(game: a), Features(game: b), serialFreq: serialFreq)
    }

    nonisolated static func match(
        _ a: Features,
        _ b: Features,
        serialFreq: [String: Int]
    ) -> (DuplicateGrade, [DuplicateSignal])? {
        var signals: [DuplicateSignal] = []

        let sameHash = a.hash != nil && a.hash == b.hash

        let sameSize = a.size >= minSizeForMatch && a.size == b.size
        let sizesDifferMaterially = sizesLookLikeDifferentDiscs(a.size, b.size)

        let serialShared = !a.serialNorm.isEmpty && a.serialNorm == b.serialNorm
        let serialIsWeak = serialShared && (serialFreq[a.serialNorm] ?? 0) >= weakSerialFrequency

        let nameScore = nameSimilarity(
            normalizedA: a.normalizedName,
            bigramsA: a.bigrams,
            normalizedB: b.normalizedName,
            bigramsB: b.bigrams
        )
        let namesSimilar = nameScore >= nameSimilarityThreshold
        let namesExact = nameScore >= 0.999

        // Multi-disc: same product serial, different disc # in the title (or very different sizes).
        let multiDiscSet = looksLikeMultiDiscPair(a, b)
            || (serialShared && sizesDifferMaterially && !sameHash)

        if sameHash {
            signals.append(DuplicateSignal(kind: .hash, detail: String(a.hash!.prefix(12))))
        }
        if sameSize {
            signals.append(DuplicateSignal(kind: .size, detail: byteLabel(a.size)))
        }
        if serialShared {
            signals.append(
                DuplicateSignal(
                    kind: .serial,
                    detail: serialIsWeak ? "\(a.serialNorm) (common)" : a.serialNorm
                )
            )
        }
        if namesSimilar {
            signals.append(
                DuplicateSignal(
                    kind: .name,
                    detail: String(format: "%.0f%%", nameScore * 100)
                )
            )
        }

        // Grade ladder — exact content always wins (true duplicate dumps).
        if sameHash {
            return (.exact, signals)
        }

        // Multi-disc of the same game: do **not** flag on serial (or soft name) alone.
        if multiDiscSet {
            if sameSize && namesSimilar {
                return (.strong, signals)
            }
            if sameSize {
                return (.likely, signals)
            }
            return nil
        }

        if sameSize && (serialShared || namesSimilar) {
            return (.strong, signals)
        }
        if sameSize {
            return (.likely, signals)
        }
        if serialShared && namesSimilar && !serialIsWeak {
            return (.likely, signals)
        }
        if serialShared && !serialIsWeak {
            return (.weak, signals)
        }
        if serialShared && serialIsWeak && namesSimilar {
            return (.weak, signals)
        }

        // Name-only weak links are the noisiest path (sequels, series entries).
        // Require that nothing hard contradicts "same game".
        if namesExact || namesSimilar {
            // Distinct product codes → different retail SKUs (e.g. Virtua Tennis vs Virtua Tennis 2).
            let serialsConflict = !a.serialNorm.isEmpty && !b.serialNorm.isEmpty && !serialShared
            // Very different image sizes without hash/serial agreement → different dumps.
            if sizesDifferMaterially {
                return nil
            }
            // Soft name match + different serials: sequels / related titles, not duplicates.
            if serialsConflict && !namesExact {
                return nil
            }
            // "Game" vs "Game 2" / "Game II" even with empty or matching-ish names.
            if looksLikeSequelPair(a, b) {
                return nil
            }
            // Same title text, different serial, similar size — still weak (region renames / re-dumps).
            return (.weak, signals)
        }
        return nil
    }

    // MARK: - Multi-disc heuristics

    /// "Game (Disc 1)" vs "Game (Disc 2)", "CD1"/"CD2", "Disk 1 of 3", etc.
    nonisolated static func looksLikeMultiDiscPair(_ nameA: String, _ nameB: String) -> Bool {
        looksLikeMultiDiscPair(Features(game: stubEntry(name: nameA)), Features(game: stubEntry(name: nameB)))
    }

    /// "Virtua Tennis" vs "Virtua Tennis 2", "Resident Evil 2" vs "Resident Evil 3", "Game" vs "Game II".
    nonisolated static func looksLikeSequelPair(_ nameA: String, _ nameB: String) -> Bool {
        looksLikeSequelPair(Features(game: stubEntry(name: nameA)), Features(game: stubEntry(name: nameB)))
    }

    nonisolated private static func looksLikeSequelPair(_ a: Features, _ b: Features) -> Bool {
        // Exact same normalized title is a true rename/dup candidate, not a sequel.
        if a.normalizedName == b.normalizedName { return false }

        let stripA = stripSequelMarker(a.normalizedName)
        let stripB = stripSequelMarker(b.normalizedName)
        // At least one title carried a sequel token we removed, or both did.
        let changed = stripA != a.normalizedName || stripB != b.normalizedName
        guard changed else { return false }

        let stemScore = nameSimilarity(
            normalizedA: stripA,
            bigramsA: bigramsOf(stripA),
            normalizedB: stripB,
            bigramsB: bigramsOf(stripB)
        )
        // Stems must match strongly after dropping "2" / "II" / etc.
        return stemScore >= 0.90
    }

    /// Strip a trailing sequel ordinal: "2", "3", "ii", "iii", "2nd", "part 2", …
    nonisolated static func stripSequelMarker(_ normalizedName: String) -> String {
        var s = normalizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let range = NSRange(s.startIndex..., in: s)
        for regex in sequelStripRegexes {
            let replaced = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            let trimmed = replaced
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split { $0.isWhitespace }
                .joined(separator: " ")
            if trimmed != s, !trimmed.isEmpty {
                return trimmed
            }
        }
        return s
    }

    private nonisolated static let sequelStripRegexes: [NSRegularExpression] = {
        let patterns = [
            // "… part 2", "… episode 3"
            #"\s+(part|episode|ep|vol|volume)\s*[0-9ivxlcdm]+$"#,
            // "… 2nd", "… 3rd", "… 4th"
            #"\s+\d+(st|nd|rd|th)$"#,
            // "… ii", "… iii", "… iv" (roman, whole token)
            #"\s+[ivxlcdm]{1,6}$"#,
            // "… 2", "… 2000" — only 1–2 digit trailing numbers (avoid "nba 2k")
            #"\s+\d{1,2}$"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    nonisolated private static func looksLikeMultiDiscPair(_ a: Features, _ b: Features) -> Bool {
        if let da = a.discNumber, let db = b.discNumber, da != db {
            let stemScore = nameSimilarity(
                normalizedA: a.stemNormalized,
                bigramsA: a.stemBigrams,
                normalizedB: b.stemNormalized,
                bigramsB: b.stemBigrams
            )
            return stemScore >= 0.75
        }
        return false
    }

    /// Extract a disc index from common naming patterns, if any.
    nonisolated static func discNumber(in name: String) -> Int? {
        let s = name.lowercased()
        let range = NSRange(s.startIndex..., in: s)
        for regex in discNumberRegexes {
            guard let match = regex.firstMatch(in: s, range: range),
                  match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: s),
                  let n = Int(s[r]), n > 0, n < 20
            else { continue }
            return n
        }
        return nil
    }

    /// Compiled once — was the largest avoidable cost inside the O(n²) loop.
    private nonisolated static let discNumberRegexes: [NSRegularExpression] = {
        let patterns = [
            #"disc\s*(\d+)"#,
            #"disk\s*(\d+)"#,
            #"cd\s*(\d+)"#,
            #"\((\d+)\s*of\s*\d+\)"#,
            #"\b(\d+)\s*of\s*\d+\b"#,
            #"\[(\d+)\]"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    private nonisolated static let discStripRegexes: [NSRegularExpression] = {
        let patterns = [
            #"\(?\s*disc\s*\d+\s*(of\s*\d+)?\)?"#,
            #"\(?\s*disk\s*\d+\s*(of\s*\d+)?\)?"#,
            #"\(?\s*cd\s*\d+\s*\)?"#,
            #"\[\s*\d+\s*\]"#,
            #"\d+\s*of\s*\d+"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    nonisolated static func stripDiscMarkers(_ name: String) -> String {
        var s = name
        for regex in discStripRegexes {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        return normalizeName(s)
    }

    /// Different discs of a multi-disc set almost always differ in size a lot.
    nonisolated static func sizesLookLikeDifferentDiscs(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return false }
        let larger = Double(max(a, b))
        let smaller = Double(min(a, b))
        // >8% difference → treat as different disc images, not duplicate dumps.
        return (larger - smaller) / larger > 0.08
    }

    // MARK: - Name similarity (Dice bigrams)

    nonisolated static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalizeName(a)
        let nb = normalizeName(b)
        return nameSimilarity(
            normalizedA: na,
            bigramsA: bigramsOf(na),
            normalizedB: nb,
            bigramsB: bigramsOf(nb)
        )
    }

    nonisolated private static func nameSimilarity(
        normalizedA na: String,
        bigramsA ba: Set<String>,
        normalizedB nb: String,
        bigramsB bb: Set<String>
    ) -> Double {
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        guard !ba.isEmpty, !bb.isEmpty else {
            if na.contains(nb) || nb.contains(na) { return 0.9 }
            return 0
        }
        let inter = ba.intersection(bb).count
        return Double(2 * inter) / Double(ba.count + bb.count)
    }

    nonisolated private static func bigramsOf(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var set = Set<String>()
        set.reserveCapacity(chars.count)
        for i in 0..<(chars.count - 1) {
            set.insert(String(chars[i...i + 1]))
        }
        return set
    }

    // MARK: - Helpers

    nonisolated static func normalizeSerial(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics
        let collapsed = trimmed.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(collapsed))
    }

    nonisolated static func normalizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        // Drop common TOSEC/region noise in parentheses/brackets.
        var cleaned = ""
        var depth = 0
        for ch in lower {
            if ch == "(" || ch == "[" { depth += 1; continue }
            if ch == ")" || ch == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { cleaned.append(ch) }
        }
        let scalars = cleaned.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        let joined = String(scalars)
        return joined.split { $0.isWhitespace }.joined(separator: " ")
    }

    private nonisolated static func serialFrequency(_ features: [Features]) -> [String: Int] {
        var freq: [String: Int] = [:]
        for f in features {
            guard !f.serialNorm.isEmpty else { continue }
            freq[f.serialNorm, default: 0] += 1
        }
        return freq
    }

    private nonisolated static func byteLabel(_ n: Int64) -> String {
        ByteCount.string(for: n)
    }

    /// Minimal entry for public multi-disc helper that still takes raw names.
    private nonisolated static func stubEntry(name: String) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 2,
            name: name,
            serial: "",
            format: .unknown,
            imageFileName: "disc.cdi",
            folderPath: "/tmp/x",
            byteSize: 0,
            payloadByteSize: 0,
            contentSHA256: nil,
            isMenu: false
        )
    }
}
