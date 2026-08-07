import Foundation

nonisolated struct CardVolume: Identifiable, Hashable, Sendable {
    var id: String { volumeUUID }
    var rootURL: URL
    var volumeUUID: String
    var volumeName: String
    var freeBytes: Int64?
    var totalBytes: Int64?
    /// True when the volume (or root path) is not writable — e.g. SD lock switch.
    var isReadOnly: Bool

    var rootPath: String { rootURL.path }
}
