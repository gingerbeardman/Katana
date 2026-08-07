import Foundation

enum ByteCount: Sendable {
    // ByteCountFormatter is not Sendable; create per-call for background safety.
    nonisolated static func string(for bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }

    /// Throughput for status lines, e.g. `42.5 MB/s`.
    nonisolated static func throughput(bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return "\(string(for: Int64(bytesPerSecond.rounded())))/s"
    }

    /// Compact remaining-time estimate, e.g. `~45s`, `~12m`, `~1h 20m`.
    nonisolated static func etaString(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded(.up))
        if total < 60 {
            return "~\(max(total, 1))s"
        }
        if total < 3600 {
            let minutes = (total + 30) / 60
            return "~\(max(minutes, 1))m"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if minutes == 0 {
            return "~\(hours)h"
        }
        return "~\(hours)h \(minutes)m"
    }
}
