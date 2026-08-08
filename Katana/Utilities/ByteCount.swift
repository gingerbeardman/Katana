import Foundation

/// Storage sizes using **decimal** units (1000ⁿ), matching Disk Utility and Finder.
/// (Binary GiB labeled “GB” made a 196.8 GB card read as “183 GB”.)
enum ByteCount: Sendable {
    private nonisolated static let bytesPerKB: Double = 1_000
    private nonisolated static let bytesPerMB: Double = 1_000_000
    private nonisolated static let bytesPerGB: Double = 1_000_000_000

    /// - Parameter integerMegabytes: When true, whole MB under 1 GB and whole GB at/above
    ///   (e.g. `1,188 MB`, `140 GB`). When false, adaptive units with decimals (KB / MB / GB).
    nonisolated static func string(for bytes: Int64, integerMegabytes: Bool = true) -> String {
        if integerMegabytes {
            return integerString(for: max(0, bytes))
        }
        let f = ByteCountFormatter()
        f.countStyle = .file // decimal SI — same basis as Disk Utility / Finder
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }

    /// Volume free/capacity line: keep free and total in the same unit as the card.
    /// Respects the integer-sizes preference (whole GB / MB) so the sidebar line doesn’t wrap.
    nonisolated static func string(
        for bytes: Int64,
        integerMegabytes: Bool = true,
        capacityHint: Int64?
    ) -> String {
        let value = max(0, bytes)
        let hint = capacityHint ?? 0
        let preferGB = value >= Int64(bytesPerGB) || hint >= Int64(bytesPerGB)

        if preferGB {
            if integerMegabytes {
                // Whole GB (decimal SI) — e.g. `39 GB`, `197 GB`.
                let gb = Int((Double(value) / bytesPerGB).rounded())
                return "\(gb.formatted()) GB"
            }
            // Adaptive / decimal mode: one place for volume chrome.
            return decimalGBString(value, fractionDigits: 1)
        }

        return string(for: value, integerMegabytes: integerMegabytes)
    }

    private nonisolated static func integerString(for bytes: Int64) -> String {
        if Double(bytes) >= bytesPerGB {
            let gb = Int((Double(bytes) / bytesPerGB).rounded())
            return "\(gb.formatted()) GB"
        }
        let mb = Int((Double(bytes) / bytesPerMB).rounded())
        return "\(mb.formatted()) MB"
    }

    /// e.g. `196.8 GB` when integer sizes are off.
    private nonisolated static func decimalGBString(_ bytes: Int64, fractionDigits: Int) -> String {
        let gb = Double(bytes) / bytesPerGB
        let formatted = gb.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
        return "\(formatted) GB"
    }

    /// Throughput for status lines, e.g. `43 MB/s`.
    nonisolated static func throughput(bytesPerSecond: Double, integerMegabytes: Bool = true) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return "\(string(for: Int64(bytesPerSecond.rounded()), integerMegabytes: integerMegabytes))/s"
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
