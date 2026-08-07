import Foundation

extension String {
    /// First character uppercased, remainder lowercased (after trim).
    var sentenceCasedTitle: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
