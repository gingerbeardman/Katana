import Foundation

/// Rebuilds the GDmenu / openMenu image in slot 01 so the on-console list matches disc order.
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
    }

    /// Full rebuild: generate list → bake GDI → replace slot-01 image files.
    nonisolated static func rebuild(
        games: [GameEntry],
        rootURL: URL,
        menuKind: MenuKind? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> Result {
        guard !games.isEmpty else { throw RebuildError.noGames }

        let ordered = games.sorted { $0.number < $1.number }
        let kind = menuKind ?? detectMenuKind(games: ordered) ?? .gdMenu

        progress?("Reading disc headers…")
        let items = MenuListGenerator.items(for: ordered, menuKind: kind) { done, total in
            if done == 0 || done == total || done % 25 == 0 {
                progress?("Reading disc headers… \(done)/\(total)")
            }
        }

        let listText = MenuListGenerator.makeList(kind: kind, items: items)
        progress?("Building \(kind.displayName) image…")

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
                    truncate: true
                )
            )
        } catch {
            throw RebuildError.bakeFailed(error.localizedDescription)
        }

        progress?("Installing menu into slot 01…")
        let menuFolder = try installMenu(
            builtGDI: outDir,
            games: ordered,
            rootURL: rootURL,
            kind: kind
        )

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
            listByteCount: listText.utf8.count
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", zipURL.path, "-d", root.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unzip failed"
            throw RebuildError.bakeFailed(msg)
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
        kind: MenuKind
    ) throws -> URL {
        let fm = FileManager.default

        // Prefer existing menu folder (number == 1), else create formatted "01"/"001".
        let menuGame = games.first(where: { $0.number == 1 })
        let maxNumber = games.map(\.number).max() ?? 1
        let folderName = menuGame.map { URL(fileURLWithPath: $0.folderPath).lastPathComponent }
            ?? FolderNumbering.format(1, maxNumber: max(maxNumber, 1))

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

        for src in built {
            try fm.copyItem(at: src, to: stageRoot.appendingPathComponent(src.lastPathComponent))
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
