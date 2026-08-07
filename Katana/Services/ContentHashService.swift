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
}

/// Gradually fills in `hash.dcgdsd` sidecars so exact duplicates light up over time.
@MainActor
final class ContentHashService {
    static let shared = ContentHashService()

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

    /// Called on main actor after each successful hash with the folder path + digest.
    var onHashed: ((String, String, Int64) -> Void)?
    /// Called on main actor when the active folder changes (`nil` when idle / finished).
    var onCurrentFolderChanged: ((String?) -> Void)?
    /// Called whenever counts / rate / ETA change during a run.
    var onProgress: ((HashingProgress) -> Void)?
    /// Called on main actor when a run fully stops (success, cancel drain, or empty).
    var onFinished: (() -> Void)?

    /// Request stop. Does not interrupt the file currently being hashed; worker exits after it.
    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        runGeneration &+= 1
        task?.cancel()
        // Keep `isRunning` true until the worker finishes draining the current file.
    }

    /// Hash any games that lack `contentSHA256`, one folder at a time (low priority).
    func startFilling(games: [GameEntry]) {
        // Drop any previous run (including one still draining after cancel).
        runGeneration &+= 1
        task?.cancel()
        task = nil
        isCancelling = false

        let missing = games.filter { !$0.isMenu && !$0.hasContentHash }
        guard !missing.isEmpty else {
            finishIdle()
            return
        }

        let generation = runGeneration
        pendingCount = missing.count
        isRunning = true

        // Path → estimated payload size for remaining-byte math.
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

        func publishProgress() {
            let remainingBytes = remainingByPath.values.reduce(Int64(0), +)
            let bps: Double? = timedSeconds > 0.05 ? Double(timedBytes) / timedSeconds : nil
            let eta: Double? = {
                guard let bps, bps > 0, remainingBytes > 0 else { return nil }
                return Double(remainingBytes) / bps
            }()
            let snapshot = HashingProgress(
                completedCount: completedCount,
                pendingCount: pendingCount,
                remainingBytes: remainingBytes,
                hashedBytes: hashedBytes,
                bytesPerSecond: bps,
                etaSeconds: eta
            )
            progress = snapshot
            onProgress?(snapshot)
        }

        publishProgress()

        task = Task.detached(priority: .utility) { [weak self] in
            for game in missing {
                if Task.isCancelled { break }
                let stillCurrent = await MainActor.run { self?.runGeneration == generation }
                guard stillCurrent else { break }

                let folder = game.folderURL
                let path = folder.path
                await MainActor.run {
                    guard let self, self.runGeneration == generation else { return }
                    self.setCurrentFolder(path)
                }

                // May take a while; cancel only takes effect after this returns.
                let started = Date()
                let result: Result<ContentHashSidecar.Record, Error>
                do {
                    result = .success(try ContentHashSidecar.computeAndWrite(for: folder))
                } catch {
                    result = .failure(error)
                }
                let elapsed = Date().timeIntervalSince(started)

                await MainActor.run {
                    guard let self, self.runGeneration == generation else { return }
                    remainingByPath.removeValue(forKey: path)
                    self.pendingCount = max(0, self.pendingCount - 1)
                    completedCount += 1

                    if case .success(let record) = result {
                        hashedBytes += record.payloadSize
                        if elapsed > 0, record.payloadSize > 0 {
                            timedBytes += record.payloadSize
                            timedSeconds += elapsed
                        }
                        self.onHashed?(path, record.sha256, record.payloadSize)
                    }
                    publishProgress()
                }

                if Task.isCancelled { break }
                // Yield so UI stays responsive on slow USB media.
                try? await Task.sleep(for: .milliseconds(50))
            }

            await MainActor.run {
                guard let self else { return }
                // Only the active generation owns shutdown (a newer startFilling may have taken over).
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
