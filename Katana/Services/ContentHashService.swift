import Foundation

/// Live hashing stats for ETA / throughput UI.
struct HashingProgress: Equatable, Sendable {
    var completedCount: Int
    var pendingCount: Int
    /// Payload bytes still to hash (estimates for queued games; shrinks as each finishes).
    var remainingBytes: Int64
    /// Payload bytes successfully hashed this run.
    var hashedBytes: Int64
    /// Average throughput over completed hashes this run (`nil` until first success).
    var bytesPerSecond: Double?
    /// Estimated seconds left from remaining bytes ÷ rate (`nil` until rate is known).
    var etaSeconds: Double?

    var totalCount: Int { completedCount + pendingCount }

    /// Best-effort total payload for this run (hashed + still queued).
    var totalBytes: Int64 { max(0, hashedBytes + remainingBytes) }

    /// 0…1 progress by payload size; falls back to game count.
    var fractionComplete: Double {
        let total = totalBytes
        if total > 0 {
            return min(1, max(0, Double(hashedBytes) / Double(total)))
        }
        let n = totalCount
        guard n > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(n)))
    }
}

/// Gradually fills in `katana.sha` sidecars so exact duplicates light up over time.
@MainActor
final class ContentHashService {
    static let shared = ContentHashService()

    /// Below this, a per-folder size estimate is treated as unreliable (e.g. disc.gdi-only provisional).
    private static let minCrediblePayloadBytes: Int64 = 1_048_576 // 1 MiB

    private var task: Task<Void, Never>?
    /// Invalidates in-flight work when a new run starts or cancel is requested.
    private var runGeneration: UInt64 = 0

    /// Games still missing a hash (folder paths).
    private(set) var pendingCount: Int = 0
    private(set) var isRunning: Bool = false
    /// True after `cancel()` until the current file finishes and the worker exits.
    private(set) var isCancelling: Bool = false
    /// Absolute folder path of the game currently being hashed, if any.
    private(set) var currentFolderPath: String?
    /// Throughput / remaining-bytes snapshot for the active run.
    private(set) var progress: HashingProgress?
    /// Measured throughput from the current (or last completed) run — never the seed alone.
    private(set) var lastMeasuredBytesPerSecond: Double?
    /// Seed from a prior run on this card (used for ETA until live samples exist).
    private(set) var seedBytesPerSecond: Double?

    /// Called on main actor after each successful hash with the folder path + digest.
    var onHashed: ((String, String, Int64) -> Void)?
    /// Called on main actor when the active folder changes (`nil` when idle / finished).
    var onCurrentFolderChanged: ((String?) -> Void)?
    /// Called whenever counts / rate / ETA change during a run.
    var onProgress: ((HashingProgress) -> Void)?
    /// Live measured throughput updated after each successful timed hash (persist this).
    var onMeasuredRate: ((Double) -> Void)?
    /// Called on main actor when a run fully stops (success, cancel drain, or empty).
    var onFinished: (() -> Void)?

    /// Request stop. Does not interrupt the file currently being hashed; worker exits after it.
    ///
    /// Important: do **not** bump `runGeneration` here. That token is only for superseding a run
    /// when `startFilling` begins again. Bumping it on cancel left the worker unable to call
    /// `finishIdle()`, so the UI stuck on “Stopping… finishing current file”.
    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        task?.cancel()
        // Keep `isRunning` true until the worker finishes the current folder and calls finishIdle.
    }

    /// Hash any games that lack `contentSHA256`, one folder at a time (low priority).
    /// - Parameter seedBytesPerSecond: Prior run’s throughput for this card (instant ETA).
    func startFilling(games: [GameEntry], seedBytesPerSecond: Double? = nil) {
        // Drop any previous run (including one still draining after cancel).
        runGeneration &+= 1
        task?.cancel()
        task = nil
        isCancelling = false
        lastMeasuredBytesPerSecond = nil

        let missing = games.filter { !$0.isMenu && !$0.hasContentHash }
        guard !missing.isEmpty else {
            finishIdle()
            return
        }

        let generation = runGeneration
        pendingCount = missing.count
        isRunning = true

        let seed: Double? = {
            guard let s = seedBytesPerSecond, s.isFinite, s > 0 else { return nil }
            return s
        }()
        self.seedBytesPerSecond = seed

        // Path → payload size for remaining-byte math (refined as we stat each folder).
        var remainingByPath: [String: Int64] = [:]
        remainingByPath.reserveCapacity(missing.count)
        for game in missing {
            remainingByPath[game.folderPath] = Self.estimatedPayloadBytes(for: game)
        }

        var completedCount = 0
        var hashedBytes: Int64 = 0
        /// Only successful timed hashes contribute to rate (failed ones still leave the queue).
        var timedBytes: Int64 = 0
        var timedSeconds: Double = 0
        var measuredSampleCount = 0
        var lastPublishedMeasured: Double?

        func averageMeasuredPayload() -> Int64? {
            guard measuredSampleCount > 0 else { return nil }
            return timedBytes / Int64(measuredSampleCount)
        }

        /// Replace tiny provisional estimates with the running average once we have samples.
        func recalibrateTinyEstimates() {
            guard let avg = averageMeasuredPayload(), avg >= Self.minCrediblePayloadBytes else { return }
            for (path, size) in remainingByPath where size < Self.minCrediblePayloadBytes {
                remainingByPath[path] = avg
            }
        }

        func publishProgress() {
            let remainingBytes = remainingByPath.values.reduce(Int64(0), +)
            let measured: Double? = timedSeconds > 0.05 ? Double(timedBytes) / timedSeconds : nil
            if let measured {
                lastMeasuredBytesPerSecond = measured
                if lastPublishedMeasured == nil
                    || abs(measured - (lastPublishedMeasured ?? 0)) / max(measured, 1) > 0.05
                {
                    lastPublishedMeasured = measured
                    onMeasuredRate?(measured)
                }
            }
            // Live sample wins; otherwise keep the seed for the whole run until first sample.
            let bps: Double? = measured ?? seed
            let eta: Double? = {
                guard let rate = bps, rate > 0, remainingBytes > 0 else { return nil }
                return Double(remainingBytes) / rate
            }()
            let snapshot = HashingProgress(
                completedCount: completedCount,
                pendingCount: remainingByPath.count,
                remainingBytes: remainingBytes,
                hashedBytes: hashedBytes,
                bytesPerSecond: bps,
                etaSeconds: eta
            )
            pendingCount = snapshot.pendingCount
            progress = snapshot
            onProgress?(snapshot)
        }

        // Immediate first tick so the UI gets seed ETA before any folder work.
        publishProgress()

        let queue = missing
        task = Task.detached(priority: .utility) { [weak self] in
            // Cheap readdir/stat pass so remaining GB / ETA aren't based on disc.gdi-only sizes.
            for game in queue {
                if Task.isCancelled { break }
                let stillCurrent = await MainActor.run { self?.runGeneration == generation }
                guard stillCurrent else { break }

                let path = game.folderPath
                let folder = game.folderURL
                let sized = Self.statPayloadBytes(in: folder)
                    ?? ContentHashService.estimatedPayloadBytes(for: game)

                await MainActor.run {
                    guard let self, self.runGeneration == generation else { return }
                    if remainingByPath[path] != nil {
                        remainingByPath[path] = sized
                    }
                    publishProgress()
                }
            }

            for game in queue {
                if Task.isCancelled { break }
                let stillCurrent = await MainActor.run { self?.runGeneration == generation }
                guard stillCurrent else { break }

                let folder = game.folderURL
                let path = folder.path

                // Skip if a sidecar appeared (or details enrichment) since we queued.
                if let existing = ContentHashSidecar.validHash(in: folder) {
                    await MainActor.run {
                        guard let self, self.runGeneration == generation else { return }
                        remainingByPath.removeValue(forKey: path)
                        completedCount += 1
                        hashedBytes += existing.payloadSize
                        self.onHashed?(path, existing.sha256, existing.payloadSize)
                        publishProgress()
                    }
                    continue
                }

                // Refresh size for this folder right before hashing (authoritative for ETA).
                let preSize = Self.statPayloadBytes(in: folder)
                    ?? ContentHashService.estimatedPayloadBytes(for: game)

                await MainActor.run {
                    guard let self, self.runGeneration == generation else { return }
                    remainingByPath[path] = preSize
                    recalibrateTinyEstimates()
                    self.setCurrentFolder(path)
                    publishProgress()
                }

                let started = Date()
                let result: Result<ContentHashSidecar.Record, Error>
                do {
                    result = .success(try ContentHashSidecar.computeAndWrite(for: folder))
                } catch {
                    result = .failure(error)
                }
                let elapsed = Date().timeIntervalSince(started)

                // Always record the in-flight folder when we still own this generation
                // (including after cancel — cancel does not bump generation).
                await MainActor.run {
                    guard let self, self.runGeneration == generation else { return }
                    remainingByPath.removeValue(forKey: path)
                    completedCount += 1

                    if case .success(let record) = result {
                        hashedBytes += record.payloadSize
                        if elapsed > 0, record.payloadSize > 0 {
                            timedBytes += record.payloadSize
                            timedSeconds += elapsed
                            measuredSampleCount += 1
                        }
                        self.onHashed?(path, record.sha256, record.payloadSize)
                        recalibrateTinyEstimates()
                    }
                    publishProgress()
                }

                // Stop after the current file when user cancelled (or startFilling superseded us).
                if Task.isCancelled { break }
                let cancelled = await MainActor.run { () -> Bool in
                    guard let self else { return true }
                    return self.runGeneration != generation || self.isCancelling
                }
                if cancelled { break }
                try? await Task.sleep(for: .milliseconds(50))
            }

            await MainActor.run {
                guard let self else { return }
                // Own this run (normal complete or user cancel). A newer startFilling bumps
                // generation and takes over finishIdle for itself.
                if self.runGeneration == generation {
                    self.finishIdle()
                }
            }
        }
    }

    /// Prefer payload size; fall back to folder size when details are still provisional.
    nonisolated static func estimatedPayloadBytes(for game: GameEntry) -> Int64 {
        if game.payloadByteSize > 0 { return game.payloadByteSize }
        if game.byteSize > 0 { return game.byteSize }
        return 0
    }

    /// Directory listing only — real track/image total without reading file contents.
    nonisolated static func statPayloadBytes(in folderURL: URL) -> Int64? {
        guard let manifest = try? ContentHashSidecar.payloadManifest(in: folderURL),
              !manifest.isEmpty
        else { return nil }
        let total = ContentHashSidecar.payloadSize(from: manifest)
        return total > 0 ? total : nil
    }

    private func finishIdle() {
        isRunning = false
        isCancelling = false
        pendingCount = 0
        progress = nil
        task = nil
        setCurrentFolder(nil)
        onFinished?()
    }

    private func setCurrentFolder(_ path: String?) {
        currentFolderPath = path
        onCurrentFolderChanged?(path)
    }
}
