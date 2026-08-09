import Foundation

/// Remembered disk transfer rates, learned from real operations and used to time-weight
/// progress bars (import copy vs. hash finalize).
///
/// - **Card write** rate is per volume UUID — cards differ wildly.
/// - **Import hash** rate is global — import hashing reads the *source* volume, which varies
///   per import anyway. (Card *read* hashing keeps its own per-volume rate in `VolumeStore`,
///   measured by `ContentHashService`, because it seeds hashing ETAs.)
///
/// New samples blend with EWMA so a single outlier doesn't swing the estimate.
@MainActor
enum TransferRateStore {
    private static let writeKeyPrefix = "transferRate.cardWrite."
    private static let importHashKey = "transferRate.importHash"
    /// Blend factor for a new sample.
    private static let alpha = 0.35
    /// Ignore tiny samples — cache effects and sub-second bursts are noise.
    private static let minSampleBytes: Int64 = 8_000_000
    private static let minSampleSeconds = 0.3

    /// Rates to time-weight the next import's progress bar.
    static func estimates(volumeUUID: String?) -> CardOperations.TransferRateEstimates {
        var rates = CardOperations.TransferRateEstimates.defaults
        if let uuid = volumeUUID {
            let stored = UserDefaults.standard.double(forKey: writeKeyPrefix + uuid)
            if stored > 0 { rates.writeBytesPerSecond = stored }
        }
        let hash = UserDefaults.standard.double(forKey: importHashKey)
        if hash > 0 { rates.hashBytesPerSecond = hash }
        return rates
    }

    /// Fold in a measured card-write sample (bytes copied onto the card in `seconds`).
    static func recordCardWrite(bytes: Int64, seconds: Double, volumeUUID: String?) {
        guard let uuid = volumeUUID, let rate = sampleRate(bytes: bytes, seconds: seconds) else {
            return
        }
        blend(rate, into: writeKeyPrefix + uuid)
    }

    /// Fold in a measured import-hash sample (source payload bytes hashed in `seconds`).
    static func recordImportHash(bytes: Int64, seconds: Double) {
        guard let rate = sampleRate(bytes: bytes, seconds: seconds) else { return }
        blend(rate, into: importHashKey)
    }

    private static func sampleRate(bytes: Int64, seconds: Double) -> Double? {
        guard bytes >= minSampleBytes, seconds >= minSampleSeconds else { return nil }
        return Double(bytes) / seconds
    }

    private static func blend(_ rate: Double, into key: String) {
        let defaults = UserDefaults.standard
        let old = defaults.double(forKey: key)
        let blended = old > 0 ? old * (1 - alpha) + rate * alpha : rate
        defaults.set(blended, forKey: key)
    }
}
