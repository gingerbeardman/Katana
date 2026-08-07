import Foundation

// MARK: - Model

/// Strength of evidence that two (or more) games are the same content.
nonisolated enum DuplicateGrade: String, Hashable, Sendable, Comparable {
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

nonisolated struct DuplicateSignal: Hashable, Sendable {
    nonisolated enum Kind: String, Hashable, Sendable {
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

    /// Build per-game duplicate info. Menu entries are never flagged.
    /// - Parameter ignoredIdentityKeys: Per-card “not a duplicate” marks (see `DuplicateIdentity`).
    /// Safe to call off the main actor (O(n²) pair checks).
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

        let serialFreq = serialFrequency(candidates)
        var parent = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.id) })
        var rank = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0) })

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
        var bestEdge: [Set<GameEntry.ID>: (DuplicateGrade, [DuplicateSignal])] = [:]

        let list = candidates
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                let a = list[i], b = list[j]
                guard let match = match(a, b, serialFreq: serialFreq) else { continue }
                union(a.id, b.id)
                bestEdge[Set([a.id, b.id])] = match
            }
        }

        // Components
        var components: [GameEntry.ID: [GameEntry]] = [:]
        for game in candidates {
            let root = find(game.id)
            components[root, default: []].append(game)
        }

        var result: [GameEntry.ID: DuplicateInfo] = [:]
        for (_, members) in components {
            guard members.count > 1 else { continue }
            let sorted = members.sorted { $0.number < $1.number }
            let groupKey = sorted.map(\.id.uuidString).sorted().joined(separator: "|")

            for (offset, game) in sorted.enumerated() {
                // Best grade among edges from this game to any other member.
                var grade: DuplicateGrade = .weak
                var signals: [DuplicateSignal] = []
                for other in sorted where other.id != game.id {
                    if let edge = bestEdge[Set([game.id, other.id])] {
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

    // MARK: - Pair match

    /// Returns grade + signals if the pair should be linked, else nil.
    nonisolated static func match(
        _ a: GameEntry,
        _ b: GameEntry,
        serialFreq: [String: Int]
    ) -> (DuplicateGrade, [DuplicateSignal])? {
        var signals: [DuplicateSignal] = []

        let hashA = a.contentSHA256
        let hashB = b.contentSHA256
        let sameHash = hashA != nil && hashA == hashB

        let sizeA = a.payloadByteSize > 0 ? a.payloadByteSize : a.byteSize
        let sizeB = b.payloadByteSize > 0 ? b.payloadByteSize : b.byteSize
        let sameSize = sizeA >= minSizeForMatch && sizeA == sizeB
        let sizesDifferMaterially = sizesLookLikeDifferentDiscs(sizeA, sizeB)

        let serialA = normalizeSerial(a.serial)
        let serialB = normalizeSerial(b.serial)
        let serialShared = !serialA.isEmpty && serialA == serialB
        let serialIsWeak = serialShared && (serialFreq[serialA] ?? 0) >= weakSerialFrequency

        let nameScore = nameSimilarity(a.name, b.name)
        let namesSimilar = nameScore >= nameSimilarityThreshold
        let namesExact = nameScore >= 0.999

        // Multi-disc: same product serial, different disc # in the title (or very different sizes).
        let multiDiscSet = looksLikeMultiDiscPair(a.name, b.name)
            || (serialShared && sizesDifferMaterially && !sameHash)

        if sameHash {
            signals.append(DuplicateSignal(kind: .hash, detail: String(hashA!.prefix(12))))
        }
        if sameSize {
            signals.append(DuplicateSignal(kind: .size, detail: byteLabel(sizeA)))
        }
        if serialShared {
            signals.append(
                DuplicateSignal(
                    kind: .serial,
                    detail: serialIsWeak ? "\(serialA) (common)" : serialA
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
            // Still flag if payload size matches (unusual for real multi-disc, common for bad dups).
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
        if namesExact || namesSimilar {
            return (.weak, signals)
        }
        return nil
    }

    // MARK: - Multi-disc heuristics

    /// "Game (Disc 1)" vs "Game (Disc 2)", "CD1"/"CD2", "Disk 1 of 3", etc.
    nonisolated static func looksLikeMultiDiscPair(_ nameA: String, _ nameB: String) -> Bool {
        let da = discNumber(in: nameA)
        let db = discNumber(in: nameB)
        if let da, let db, da != db {
            // Same franchise title stem → multi-disc set.
            let stemA = stripDiscMarkers(nameA)
            let stemB = stripDiscMarkers(nameB)
            return nameSimilarity(stemA, stemB) >= 0.75
        }
        return false
    }

    /// Extract a disc index from common naming patterns, if any.
    nonisolated static func discNumber(in name: String) -> Int? {
        let s = name.lowercased()
        let patterns = [
            #"disc\s*(\d+)"#,
            #"disk\s*(\d+)"#,
            #"cd\s*(\d+)"#,
            #"\((\d+)\s*of\s*\d+\)"#,
            #"\b(\d+)\s*of\s*\d+\b"#,
            #"\[(\d+)\]"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: s),
               let n = Int(s[range]), n > 0, n < 20 {
                return n
            }
        }
        return nil
    }

    nonisolated static func stripDiscMarkers(_ name: String) -> String {
        var s = name
        let patterns = [
            #"\(?\s*disc\s*\d+\s*(of\s*\d+)?\)?"#,
            #"\(?\s*disk\s*\d+\s*(of\s*\d+)?\)?"#,
            #"\(?\s*cd\s*\d+\s*\)?"#,
            #"\[\s*\d+\s*\]"#,
            #"\d+\s*of\s*\d+"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
            }
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
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }

        let ba = bigrams(na)
        let bb = bigrams(nb)
        guard !ba.isEmpty, !bb.isEmpty else {
            // Single-character / very short: fall back to containment.
            if na.contains(nb) || nb.contains(na) { return 0.9 }
            return 0
        }
        let inter = ba.intersection(bb).count
        return Double(2 * inter) / Double(ba.count + bb.count)
    }

    private nonisolated static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var set = Set<String>()
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

    private nonisolated static func serialFrequency(_ games: [GameEntry]) -> [String: Int] {
        var freq: [String: Int] = [:]
        for g in games {
            let s = normalizeSerial(g.serial)
            guard !s.isEmpty else { continue }
            freq[s, default: 0] += 1
        }
        return freq
    }

    private nonisolated static func byteLabel(_ n: Int64) -> String {
        ByteCount.string(for: n)
    }
}
