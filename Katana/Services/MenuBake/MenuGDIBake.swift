import Foundation

/// Native menu GDI bake — replaces the .NET MenuGDIBuilder helper.
///
/// Stages menu assets, writes LIST.INI / OPENMENU.INI into low + high density trees,
/// builds track01 (low density ISO), high-density multi-track GDI with CDDA, and updates disc.gdi.
///
/// Runs off the main actor (project defaults to MainActor isolation).
nonisolated enum MenuGDIBake: Sendable {
    nonisolated struct Options: Sendable {
        var kind: MenuKind
        var listText: String
        var assetsRoot: URL
        var outDir: URL
        var truncate: Bool = true
    }

    /// Bake a complete menu_gdi directory at `options.outDir`.
    nonisolated static func build(_ options: Options) throws {
        let fm = FileManager.default
        let volId = options.kind.volumeIdentifier
        let listName = options.kind.listFileName

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("menugdi-native-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let lowdataPath = tempRoot.appendingPathComponent("lowdensity_data", isDirectory: true)
        let dataPath = tempRoot.appendingPathComponent("data", isDirectory: true)
        let cdiPath = options.outDir

        try fm.createDirectory(at: lowdataPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataPath, withIntermediateDirectories: true)

        if fm.fileExists(atPath: cdiPath.path) {
            let existing = try fm.contentsOfDirectory(at: cdiPath, includingPropertiesForKeys: nil)
            for url in existing {
                try? fm.removeItem(at: url)
            }
        } else {
            try fm.createDirectory(at: cdiPath, withIntermediateDirectories: true)
        }

        let menuData = options.assetsRoot.appendingPathComponent("menu_data", isDirectory: true)
        let menuGdi = options.assetsRoot.appendingPathComponent("menu_gdi", isDirectory: true)
        let menuLow = options.assetsRoot.appendingPathComponent("menu_low_data", isDirectory: true)
        let ipbin = options.assetsRoot.appendingPathComponent("IP.BIN")

        guard fm.fileExists(atPath: menuData.path) else {
            throw BakeError.missingAssets(menuData.path)
        }
        guard fm.fileExists(atPath: menuGdi.path) else {
            throw BakeError.missingAssets(menuGdi.path)
        }
        guard fm.fileExists(atPath: ipbin.path) else {
            throw BakeError.missingAssets(ipbin.path)
        }

        try copyDirectory(from: menuData, to: dataPath)
        try copyDirectory(from: menuGdi, to: cdiPath)
        if fm.fileExists(atPath: menuLow.path) {
            try copyDirectory(from: menuLow, to: lowdataPath)
        }

        let listData = Data(options.listText.utf8)
        try listData.write(to: lowdataPath.appendingPathComponent(listName), options: .atomic)
        try listData.write(to: dataPath.appendingPathComponent(listName), options: .atomic)

        var builder = GDromMenuBuilder()
        builder.volumeIdentifier = volId
        builder.truncateData = options.truncate

        let lowFiles = try fm.contentsOfDirectory(
            at: lowdataPath,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        try builder.createFirstTrack(
            destinationIso: cdiPath.appendingPathComponent("track01.iso"),
            files: lowFiles
        )

        var cdda: [URL] = []
        let track04 = cdiPath.appendingPathComponent("track04.raw")
        if fm.fileExists(atPath: track04.path) {
            cdda.append(track04)
        }

        let tracks = try builder.buildGDROM(
            dataDirectory: dataPath,
            ipBinURL: ipbin,
            cddaTracks: cdda,
            outDir: cdiPath
        )
        try builder.updateGdiFile(
            tracks: tracks,
            gdiPath: cdiPath.appendingPathComponent("disc.gdi")
        )
    }

    // MARK: - Helpers

    nonisolated private static func copyDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try copyDirectory(from: item, to: target)
            } else {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}
