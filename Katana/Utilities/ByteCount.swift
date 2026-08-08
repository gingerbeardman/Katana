import Foundation

/// Storage sizes using **decimal** units (1000ⁿ), matching Disk Utility / Finder.
///
/// Policy:
/// - **Game sizes** (table Size column, inspector): always **MB** (never GB).
/// - **Volume chrome** (sidebar free/capacity/trash, window subtitle totals): **GB** when large.
enum ByteCount: Sendable {
    private nonisolated static let bytesPerMB: Double = 1_000_000
    private nonisolated static let bytesPerGB: Double = 1_000_000_000

    // MARK: - Game / list sizes (MB only)

    /// Size column, inspector, per-game totals.
    /// - `integerMegabytes` true: whole MB (`1,188 MB`).
    /// - false: adaptive KB/MB with decimals — still no GB.
    nonisolated static func gameSizeString(for bytes: Int64, integerMegabytes: Bool = true) -> String {
        let value = max(0, bytes)
        if integerMegabytes {
            let mb = Int((Double(value) / bytesPerMB).rounded())
            return "\(mb.formatted()) MB"
        }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB] // never GB in the size column / inspector
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: value)
    }

    // MARK: - Volume chrome (GB when large)

    /// Sidebar free/capacity/trash and title-bar card totals.
    /// Uses whole GB (or 1 decimal when `integerMegabytes` is false) once the value or
    /// card capacity is ≥ 1 GB; otherwise falls back to game-size MB formatting.
    nonisolated static func volumeSizeString(
        for bytes: Int64,
        integerMegabytes: Bool = true,
        capacityHint: Int64? = nil
    ) -> String {
        let value = max(0, bytes)
        let hint = capacityHint ?? 0
        let preferGB = value >= Int64(bytesPerGB) || hint >= Int64(bytesPerGB)

        guard preferGB else {
            return gameSizeString(for: value, integerMegabytes: integerMegabytes)
        }

        if integerMegabytes {
            let gb = Int((Double(value) / bytesPerGB).rounded())
            return "\(gb.formatted()) GB"
        }
        let gb = Double(value) / bytesPerGB
        let formatted = gb.formatted(
            .number
                .precision(.fractionLength(1))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
        return "\(formatted) GB"
    }

    // MARK: - Throughput / ETA

    /// Throughput for status lines, e.g. `43 MB/s` (always MB-scale).
    nonisolated static func throughput(bytesPerSecond: Double, integerMegabytes: Bool = true) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return "\(gameSizeString(for: Int64(bytesPerSecond.rounded()), integerMegabytes: integerMegabytes))/s"
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

    // MARK: - Back-compat aliases

    /// Prefer `gameSizeString` — kept for call sites that mean list/game sizes.
    nonisolated static func string(for bytes: Int64, integerMegabytes: Bool = true) -> String {
        gameSizeString(for: bytes, integerMegabytes: integerMegabytes)
    }

    /// Prefer `volumeSizeString` — kept for call sites that pass `capacityHint`.
    nonisolated static func string(
        for bytes: Int64,
        integerMegabytes: Bool = true,
        capacityHint: Int64?
    ) -> String {
        volumeSizeString(for: bytes, integerMegabytes: integerMegabytes, capacityHint: capacityHint)
    }
}
