import AppKit
import Foundation

enum VolumeEject {
    /// Unmount and eject the volume that contains `rootURL`.
    static func eject(rootURL: URL) async throws {
        let volumeRoot = try volumeRootURL(for: rootURL)
        try await Task.detached {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeRoot)
        }.value
    }

    private static func volumeRootURL(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.volumeURLKey])
        if let volumeURL = values.volume {
            return volumeURL
        }
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                return URL(fileURLWithPath: "/\(parts[0])/\(parts[1])", isDirectory: true)
            }
        }
        return url
    }
}
