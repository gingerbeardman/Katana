import Foundation
import os

/// Process-relative launch timing.
/// Always on in DEBUG; also when env `KATANA_TRACE_LAUNCH=1`.
/// Logs to Console (`subsystem com.gingerbeardman.Katana`) and stderr.
enum LaunchTrace {
    private static let log = Logger(subsystem: "com.gingerbeardman.Katana", category: "Launch")
    private static let t0 = CFAbsoluteTimeGetCurrent()
    private static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["KATANA_TRACE_LAUNCH"] == "1" { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Milliseconds since first touch of this type (≈ process start for our purposes).
    nonisolated static var ms: Int {
        Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    nonisolated static func mark(_ label: String) {
        guard enabled else { return }
        let line = "[\(ms)ms] \(label)"
        log.info("\(line, privacy: .public)")
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

    nonisolated static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = CFAbsoluteTimeGetCurrent()
        mark("→ \(label)")
        defer {
            let d = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            mark("← \(label) (\(d)ms)")
        }
        return try body()
    }

    nonisolated static func measureAsync<T: Sendable>(
        _ label: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard enabled else { return try await body() }
        let start = CFAbsoluteTimeGetCurrent()
        mark("→ \(label)")
        do {
            let value = try await body()
            let d = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            mark("← \(label) (\(d)ms)")
            return value
        } catch {
            let d = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            mark("← \(label) FAILED (\(d)ms): \(error.localizedDescription)")
            throw error
        }
    }
}
