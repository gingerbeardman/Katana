import Foundation

/// Rebuilds the GDmenu / openMenu image in slot 01 so the on-console list matches card order.
enum MenuRebuildService: Sendable {
    enum RebuildError: LocalizedError {
        case noVolume
        case noGames
        case noMenuFolder
        case missingAssets
        case bakeFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVolume: return "No SD card open."
            case .noGames: return "No games to put in the menu list."
            case .noMenuFolder: return "Menu folder (slot 01) not found on the card."
            case .missingAssets: return "GDmenu / openMenu assets are missing from the app bundle."
            case .bakeFailed(let msg): return "Menu GDI build failed: \(msg)"
            case .installFailed(let msg): return "Could not install menu image: \(msg)"
            }
        }
    }

    struct Result: Sendable {
        var menuKind: MenuKind
        var itemCount: Int
        var menuFolderPath: String
        var listByteCount: Int
        /// IP headers read from disk during this rebuild (cache misses) for write-back.
        var filledHeaders: [MenuListGenerator.HeaderFill]
    }

    /// Full rebuild: generate list → bake GDI → replace slot-01 image files.
    /// - Parameter progress: `(message, fraction 0…1)` for UI edge progress.
    nonisolated static func rebuild(
        games: [GameEntry],
        rootURL: URL,
        menuKind: MenuKind? = nil,
        progress: (@Sendable (String, Double) -> Void)? = nil
    ) throws -> Result {
        guard !games.isEmpty else { throw RebuildError.noGames }

        let ordered = games.sorted { $0.number < $1.number }
        let kind = menuKind ?? detectMenuKind(games: ordered) ?? .gdMenu

        // Fixed spans: the per-item header pass owns the bulk of the bar (a warm cache
        // simply sweeps it fast), bake and install stay short tails.
        // Headers 0.02…0.80 · bake 0.80…0.96 · install 0.96…1.0
        let headerSpan = 0.78
        let headerEnd = 0.02 + headerSpan
        let bakeEnd = 0.96

        progress?("Reading game headers…", 0.02)
        let built = MenuListGenerator.itemsWithHeaderFills(for: ordered, menuKind: kind) { done, total, fromCard in
            let t = max(total, 1)
            // Report often enough for a smooth bar without flooding the UI.
            if done == 0 || done == total || done % 10 == 0 || t < 40 {
                let frac = 0.02 + headerSpan * (Double(done) / Double(t))
                let source = fromCard == 0
                    ? "all cached"
                    : "\(done - fromCard) cached · \(fromCard) from card"
                progress?("Reading game headers… \(done)/\(total) (\(source))", frac)
            }
        }
        let items = built.items

        // Keys must match on-disk folders: menu `01`, games `002`… when max ≥ 100 (GCM).
        let maxNumber = ordered.map(\.number).max() ?? ordered.count
        let listText = MenuListGenerator.makeList(kind: kind, items: items, maxNumber: maxNumber)
        progress?("Building \(kind.displayName) image…", headerEnd)

        let assets = try assetsURL(for: kind)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-menu-\(UUID().uuidString)", isDirectory: true)
        let outDir = tempRoot.appendingPathComponent("menu_gdi", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        do {
            try MenuGDIBake.build(
                MenuGDIBake.Options(
                    kind: kind,
                    listText: listText,
                    assetsRoot: assets,
                    outDir: outDir,
                    truncate: true,
                    progress: { message, bakeFraction in
                        let overall = headerEnd + (bakeEnd - headerEnd) * min(1, max(0, bakeFraction))
                        progress?(message, overall)
                    }
                )
            )
        } catch {
            throw RebuildError.bakeFailed(error.localizedDescription)
        }

        progress?("Installing menu into slot 01…", bakeEnd)
        let menuFolder = try installMenu(
            builtGDI: outDir,
            games: ordered,
            rootURL: rootURL,
            kind: kind,
            progress: { installFraction in
                let overall = bakeEnd + (0.98 - bakeEnd) * min(1, max(0, installFraction))
                progress?("Installing menu into slot 01…", overall)
            }
        )
        progress?("Installed \(kind.displayName)", 1.0)

        // Refresh name/serial on the menu folder.
        let nameURL = menuFolder.appendingPathComponent("name.txt")
        let serialURL = menuFolder.appendingPathComponent("serial.txt")
        try kind.menuFolderName.write(to: nameURL, atomically: true, encoding: .utf8)
        // Keep serial if present; otherwise write product from defaults.
        if !FileManager.default.fileExists(atPath: serialURL.path) {
            let serial = items.first?.serial ?? "MK-0000"
            try serial.write(to: serialURL, atomically: true, encoding: .utf8)
        }

        return Result(
            menuKind: kind,
            itemCount: items.count,
            menuFolderPath: menuFolder.path,
            listByteCount: listText.utf8.count,
            filledHeaders: built.filledHeaders
        )
    }

    // MARK: - Detect

    /// Infer which menu system the card uses from slot 01 name and/or IP.BIN.
    nonisolated static func detectMenuKind(games: [GameEntry]) -> MenuKind? {
        let menu = games.first(where: { $0.number == 1 || $0.isMenu }) ?? games.first
        guard let menu else { return nil }

        if let k = MenuKind.detect(fromName: menu.name) {
            LaunchTrace.mark("detectMenuKind: from name \"\(menu.name)\" → \(k.rawValue)")
            return k
        }
        let serialStart = CFAbsoluteTimeGetCurrent()
        if let serial = try? String(
            contentsOf: menu.folderURL.appendingPathComponent("serial.txt"),
            encoding: .utf8
        ), let k = MenuKind.detect(fromName: serial) {
            LaunchTrace.mark(
                "detectMenuKind: from serial.txt (\(Int((CFAbsoluteTimeGetCurrent() - serialStart) * 1000))ms) → \(k.rawValue)"
            )
            return k
        }
        let ipStart = CFAbsoluteTimeGetCurrent()
        if let ip = IpBinReader.read(from: menu), let k = MenuKind.detect(fromIP: ip) {
            LaunchTrace.mark(
                "detectMenuKind: from IP.BIN (\(Int((CFAbsoluteTimeGetCurrent() - ipStart) * 1000))ms) → \(k.rawValue)"
            )
            return k
        }
        LaunchTrace.mark(
            "detectMenuKind: no match (IP.BIN attempt \(Int((CFAbsoluteTimeGetCurrent() - ipStart) * 1000))ms)"
        )
        return nil
    }

    // MARK: - Bundle resources

    /// Returns a directory shaped like `tools/gdMenu` (IP.BIN + menu_data + menu_gdi + menu_low_data).
    ///
    /// Preferred packaging is a zip (`gdMenu.zip` / `openMenu.zip`) so Xcode’s resource copy
    /// doesn’t flatten nested track names. Nested folders and flat files are fallbacks.
    nonisolated static func assetsURL(for kind: MenuKind) throws -> URL {
        let fm = FileManager.default
        let folderName = kind == .gdMenu ? "gdMenu" : "openMenu"
        let zipName = kind == .gdMenu ? "gdMenu" : "openMenu"

        // 1) Nested source-tree layout (if somehow preserved).
        let nestedCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("MenuAssets/\(folderName)"),
            Bundle.main.url(forResource: folderName, withExtension: nil, subdirectory: "MenuAssets"),
        ]
        for case let url? in nestedCandidates {
            if fm.fileExists(atPath: url.appendingPathComponent("IP.BIN").path),
               fm.fileExists(atPath: url.appendingPathComponent("menu_data").path)
            {
                return url
            }
        }

        // 2) Zip in bundle (MenuAssets/gdMenu.zip or flattened gdMenu.zip).
        let zipCandidates: [URL?] = [
            Bundle.main.url(forResource: zipName, withExtension: "zip", subdirectory: "MenuAssets"),
            Bundle.main.url(forResource: zipName, withExtension: "zip"),
            Bundle.main.resourceURL?.appendingPathComponent("MenuAssets/\(zipName).zip"),
            Bundle.main.resourceURL?.appendingPathComponent("\(zipName).zip"),
        ]
        for case let zipURL? in zipCandidates where fm.fileExists(atPath: zipURL.path) {
            return try extractAssetsZip(zipURL, kind: kind)
        }

        // 3) Last resort: flat individual files (gdMenu only).
        return try assembleFlatAssets(for: kind)
    }

    nonisolated private static func extractAssetsZip(_ zipURL: URL, kind: MenuKind) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-menu-assets-\(kind.rawValue)", isDirectory: true)
        if fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // In-process extract — App Sandbox blocks `/usr/bin/unzip` via Process, which
        // silently broke menu rebuild in notarized builds.
        do {
            try ZipExtractor.extract(zipURL: zipURL, to: root)
        } catch {
            throw RebuildError.bakeFailed(error.localizedDescription)
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("IP.BIN").path) else {
            throw RebuildError.missingAssets
        }
        return root
    }

    /// Build a temp assets tree from flat bundle files (legacy / incomplete packaging).
    nonisolated private static func assembleFlatAssets(for kind: MenuKind) throws -> URL {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { throw RebuildError.missingAssets }

        func find(_ name: String) -> URL? {
            let direct = resourceURL.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { return direct }
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return Bundle.main.url(
                forResource: base,
                withExtension: ext.isEmpty ? nil : ext
            )
        }

        guard let ip = find("IP.BIN") else { throw RebuildError.missingAssets }
        guard let boot = find("1ST_READ.BIN") else { throw RebuildError.missingAssets }
        guard let discGdi = find("disc.gdi") else { throw RebuildError.missingAssets }

        let trackNames = ["track01.iso", "track02.raw", "track03.iso", "track04.raw"]
        var tracks: [URL] = []
        for name in trackNames {
            guard let u = find(name) else { throw RebuildError.missingAssets }
            tracks.append(u)
        }

        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-menu-assets-\(kind.rawValue)", isDirectory: true)
        if fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        let menuData = root.appendingPathComponent("menu_data", isDirectory: true)
        let menuGdi = root.appendingPathComponent("menu_gdi", isDirectory: true)
        let menuLow = root.appendingPathComponent("menu_low_data", isDirectory: true)
        try fm.createDirectory(at: menuData, withIntermediateDirectories: true)
        try fm.createDirectory(at: menuGdi, withIntermediateDirectories: true)
        try fm.createDirectory(at: menuLow, withIntermediateDirectories: true)

        try fm.copyItem(at: ip, to: root.appendingPathComponent("IP.BIN"))
        try fm.copyItem(at: boot, to: menuData.appendingPathComponent("1ST_READ.BIN"))
        if let readme = find("readme.txt") {
            try fm.copyItem(at: readme, to: menuData.appendingPathComponent("readme.txt"))
        }
        try fm.copyItem(at: discGdi, to: menuGdi.appendingPathComponent("disc.gdi"))
        for track in tracks {
            try fm.copyItem(at: track, to: menuGdi.appendingPathComponent(track.lastPathComponent))
        }
        if let info = find("GDEMUNFO.TXT") {
            try fm.copyItem(at: info, to: menuLow.appendingPathComponent("GDEMUNFO.TXT"))
        } else {
            try "GDEMU\n".write(
                to: menuLow.appendingPathComponent("GDEMUNFO.TXT"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    // MARK: - Install into slot 01

    nonisolated private static func installMenu(
        builtGDI: URL,
        games: [GameEntry],
        rootURL: URL,
        kind: MenuKind,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default

        // Prefer existing menu folder (number == 1). New menu is always `01` (GCM), never `001`.
        let menuGame = games.first(where: { $0.number == 1 })
        let folderName = menuGame.map { URL(fileURLWithPath: $0.folderPath).lastPathComponent }
            ?? FolderNumbering.format(1)

        let menuFolder = rootURL.appendingPathComponent(folderName, isDirectory: true)

        if !fm.fileExists(atPath: menuFolder.path) {
            try fm.createDirectory(at: menuFolder, withIntermediateDirectories: true)
        }

        let built = try fm.contentsOfDirectory(
            at: builtGDI,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !url.lastPathComponent.hasPrefix(".")
        }
        guard built.contains(where: { $0.lastPathComponent.lowercased() == "disc.gdi" }) else {
            throw RebuildError.installFailed("Builder did not produce disc.gdi")
        }
        // Basic sanity: every track listed in disc.gdi must exist and be non-empty.
        try validateBuiltMenu(builtGDI: builtGDI, files: built)

        // Stage onto the same volume first — never wipe slot 01 until the new set is complete.
        let stageRoot = rootURL
            .appendingPathComponent(CardOperations.tmpFolderName, isDirectory: true)
            .appendingPathComponent("menu-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageRoot.deletingLastPathComponent()) }

        // Uncached card writes (CardOperations.copyFile): buffered copyItem here made the
        // install "finish" into the page cache, then the post-install directorySize walk
        // stalled behind the drain. Byte-weighted progress keeps the bar honest meanwhile.
        let sizes = built.map {
            Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let totalBytes = max(sizes.reduce(0, +), 1)
        var doneBytes: Int64 = 0
        for (src, size) in zip(built, sizes) {
            try CardOperations.copyFile(
                from: src,
                to: stageRoot.appendingPathComponent(src.lastPathComponent)
            ) { written in
                progress?(Double(doneBytes + written) / Double(totalBytes))
            }
            doneBytes += size
        }

        let keepNames: Set<String> = [
            "name.txt", "serial.txt", "katana.sha",
            "info.txt", "0gdtex.pvr", "0GDTEX.PVR",
        ]
        let imageExts: Set<String> = ["gdi", "iso", "raw", "bin", "cdi", "img", "ccd", "sub", "mds", "mdf"]

        let existing = try fm.contentsOfDirectory(
            at: menuFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in existing {
            let name = url.lastPathComponent
            if keepNames.contains(name) { continue }
            let ext = url.pathExtension.lowercased()
            if imageExts.contains(ext)
                || name.lowercased().hasPrefix("track")
                || name.lowercased() == "disc.gdi"
                || name.hasSuffix(".sha")
                || name.hasSuffix(".sha256")
                || name.hasSuffix(".md5")
            {
                try? fm.removeItem(at: url)
            }
        }

        let staged = try fm.contentsOfDirectory(
            at: stageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for src in staged {
            let dest = menuFolder.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: src, to: dest)
        }

        return menuFolder
    }

    /// Ensure disc.gdi references present, non-empty track files before touching slot 01.
    nonisolated private static func validateBuiltMenu(builtGDI: URL, files: [URL]) throws {
        let fm = FileManager.default
        let gdiURL = builtGDI.appendingPathComponent("disc.gdi")
        let text = try String(contentsOf: gdiURL, encoding: .utf8)
        let names = Set(files.map { $0.lastPathComponent })
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // track lines: N LBA type sectorSize filename offset
            guard parts.count >= 5, Int(parts[0]) != nil else { continue }
            let fileName = parts[4]
            guard names.contains(fileName) else {
                throw RebuildError.installFailed("Built menu missing \(fileName) listed in disc.gdi")
            }
            let url = builtGDI.appendingPathComponent(fileName)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else {
                throw RebuildError.installFailed("Built menu file \(fileName) is empty")
            }
        }
        // High-density data track must exist for a usable menu.
        let hasDataTrack = files.contains {
            let n = $0.lastPathComponent.lowercased()
            return n.hasPrefix("track") && n.hasSuffix(".iso") && n != "track01.iso"
        }
        guard hasDataTrack else {
            throw RebuildError.installFailed("Built menu has no high-density data track")
        }
        _ = fm
    }
}
