import Foundation

extension String {
    /// Entire name uppercased (after trim).
    /// Example: `Sonic Adventure` → `SONIC ADVENTURE`
    var uppercasedName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Entire name lowercased (after trim).
    /// Example: `SONIC ADVENTURE` → `sonic adventure`
    var lowercasedName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// First character uppercased, remainder lowercased (after trim).
    /// Example: `SONIC ADVENTURE` → `Sonic adventure`
    var sentenceCasedTitle: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let rest = trimmed.dropFirst().lowercased()
        return String(first).uppercased() + rest
    }

    /// Title Case: capitalize each word; keep short glue words lowercase except first/last.
    /// Example: `SONIC ADVENTURE 2` → `Sonic Adventure 2`
    /// Example: `THE HOUSE OF THE DEAD` → `The House of the Dead`
    var titleCasedName: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Common English glue words (and short prepositions/conjunctions).
        let smallWords: Set<String> = [
            "a", "an", "and", "as", "at", "but", "by", "for", "from",
            "in", "into", "nor", "of", "on", "or", "the", "to", "vs",
            "via", "with", "vs.",
        ]

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return trimmed }

        return words.enumerated().map { index, raw in
            capitalizeWord(raw, forceCapital: index == 0 || index == words.count - 1, smallWords: smallWords)
        }
        .joined(separator: " ")
    }

    /// Capitalize a single whitespace-delimited token, preserving internal hyphens/apostrophes.
    private func capitalizeWord(
        _ raw: String,
        forceCapital: Bool,
        smallWords: Set<String>
    ) -> String {
        // Split on hyphens so "spider-man" → "Spider-Man".
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let mapped = parts.map { part -> String in
            guard !part.isEmpty else { return part }
            let lower = part.lowercased()
            if !forceCapital, parts.count == 1, smallWords.contains(lower) {
                return lower
            }
            // Leading punctuation (e.g. `'til`, `"quoted`) — capitalize first letter.
            if let idx = lower.firstIndex(where: { $0.isLetter || $0.isNumber }) {
                let before = lower[..<idx]
                let first = lower[idx]
                let after = lower[lower.index(after: idx)...]
                return before + String(first).uppercased() + after
            }
            return lower
        }
        return mapped.joined(separator: "-")
    }
}
