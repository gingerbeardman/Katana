# Katana

Native **macOS** app for managing **GDEMU** SD cards (Dreamcast) with **GDmenu** and **openMenu**.

Open a card root, browse numbered game folders, rename / reorder / delete with **immediate on-card writes**, inspect disc metadata and covers, detect duplicates, hash content, and rebuild the slot-01 menu image so the console list matches the SD card.

## Features

| Area | What you get |
| --- | --- |
| **Cards** | Open a GDEMU root (folders `01`, `02`, …); recent cards via security-scoped bookmarks; optional eject on quit |
| **Scan** | Fast folder scan (`name.txt`, `serial.txt`, disc image); snapshot cache for quick re-open; progress in the window subtitle |
| **List** | Multi-select table; search; **display-only** column sort (per card) vs **Apply A–Z to Disc** (renumbers folders) |
| **Rename** | Finder-style **inline rename** (right-click / double-click / Return); bulk sentence case and auto-rename from IP.BIN / GameDB / file / folder name |
| **Inspector** | Title, IP.BIN fields, **0GDTEX** cover (PVR decode), on-card path, actions; collapsible sections (persisted) |
| **Duplicates** | Serial / name / size / hash signals; grade badges; “not a duplicate” marks **per card** (persisted with the volume) |
| **Hashing** | Background SHA-256 of disc payload; sidecars; rate/ETA; mutual exclusion with menu rebuild |
| **Menu rebuild** | Native Swift bake of **GDmenu** (`LIST.INI`) or **openMenu** (`OPENMENU.INI`) into slot 01; prompt on quit if out of date |
| **Safety** | Read-only card detection (e.g. SD lock); writes are immediate — no separate Save; ⌘Z undo where supported |

## Requirements

- **macOS 14+**
- **Xcode 16+** (to build from source)
- A GDEMU-formatted SD card mounted under `/Volumes` (or a local fixture folder with the same layout)

## Build & run

```bash
open Katana.xcodeproj
# or
xcodebuild -scheme Katana -configuration Debug -destination 'platform=macOS' build
```

Tests:

```bash
xcodebuild -scheme Katana -destination 'platform=macOS' test
```

## Release (universal notarized DMG)

Release builds are **universal** (`arm64` + `x86_64`). Menu GDI bake is **entirely native Swift** — no nested helper binary, no .NET runtime, no brotli dylibs in the app.

```bash
# Once: notary credentials (Developer ID Application cert in keychain)
xcrun notarytool store-credentials "notarytool-password" \
  --apple-id "you@example.com" --team-id "YOUR_TEAM_ID" --password "app-specific-password"

Scripts/make-notarized-dmg.sh
# → build/export/Katana.app · build/Katana.dmg · dist/Katana.dmg
```

Pipeline: archive → Developer ID export → notarize/staple app → HFS-compressed stage into UDZO DMG → notarize/staple DMG → `spctl` verify.

### App bundle resources

| Resource | Purpose |
| --- | --- |
| `MenuAssets/gdMenu.zip` | Stock GDmenu assets for slot-01 rebuild |
| `MenuAssets/openMenu.zip` | Stock openMenu assets for slot-01 rebuild |
| `GameDB/dreamcast-titles.json` | Serial → pretty title map (scan / auto-rename) |

## Architecture notes

- **Menu bake** lives under `Katana/Services/MenuBake/` (`MenuGDIBake`, ISO 9660 Level 1 + multi-track GDI, LBA 45000, truncate/CDDA). Invoked only from `MenuRebuildService`.
- **No runtime helper:** rebuild is native Swift — no .NET process, no nested helper binary.
- **`Tools/MenuAssets/`** — unpacked stock gdMenu / openMenu trees for unit tests (the app ships zipped copies under `Katana/Resources/MenuAssets/`).
- **`Tools/scripts/build-gamedb.py`** — regenerate the bundled serial→title map.
- **`Tools/licenses/`** — third-party license texts (e.g. DiscUtils MIT).

### Title resolution (scan / auto-rename)

`name.txt` → **GameDB** (serial / product) → IP.BIN product name → folder / image base name.

Update the bundled GameDB from upstream data:

```bash
python3 Tools/scripts/build-gamedb.py
```

## Credits

Katana stands on the shoulders of the Dreamcast homebrew community.

### [GDMENU Card Manager](https://github.com/sonik-br/GDMENUCardManager) (sonik-br)

**Primary inspiration and reference implementation.**

Katana is a separate native macOS app, but it follows the same on-disk conventions and menu-rebuild approach, including:

- Numbered game folders and `name.txt` / `serial.txt`
- GDmenu `LIST.INI` and openMenu `OPENMENU.INI`
- Folder number width by magnitude
- Proper **GDI** menu image for slot 01 (MIL-CD–safe)
- IP.BIN field layout compatibility for menu entries

GDMENUCardManager is **[GNU GPL v3](https://github.com/sonik-br/GDMENUCardManager/blob/master/LICENSE)**. Many thanks to **sonik-br** and contributors.

For Windows/Linux, archive import, GDI shrinking, or the original Avalonia UI, use GDMENUCardManager — it remains the multi-platform reference tool.

### DiscUtils & GDI tooling lineage

Menu GDI construction is a **Swift port** of the multi-track path used by GDMENUCardManager (itself built on community GDI tools), notably:

- **[DiscUtils](https://github.com/DiscUtils/DiscUtils)** (Kenneth Bell) — MIT (see `Tools/licenses/DiscUtils-LICENSE.txt`)
- [GdiBuilder](https://github.com/Sappharad/GDIbuilder/) (Sappharad) and related GDI / ISO tooling

### Console menus & scene

As also credited by GDMENUCardManager:

- **GDmenu** by neuroacid  
- **[openMenu](https://github.com/mrneo240/openmenu/)** by mrneo240  
- openMenu DAT resources: [imagedb](https://github.com/mrneo240/openMenu_imagedb), [metadb](https://github.com/mrneo240/openMenu_metadb)  
- Special thanks to **megavolt85** and the wider Dreamcast scene  

### Other references

- **[Aaru](https://github.com/aaru-dps/Aaru)** — IP.BIN / disc structure documentation  
- Apple **SwiftUI** / **AppKit**

### Game title database

- Source: **[GameDB-Dreamcast](https://github.com/niemasd/GameDB-Dreamcast)** (niemasd), derived from **[Redump](https://redump.org)** (+ GameFAQs)  
- License: **GPL-3.0** (see upstream)  
- Bundled: `Katana/Resources/GameDB/dreamcast-titles.json`

## License notes

- Menu GDI bake is a **Swift port** of the DiscUtils / GDromBuilder multi-track path (no Joliet, LBA 45000, truncated high-density tracks with CDDA).
- **DiscUtils** lineage is **MIT** (Kenneth Bell); license text in `Tools/licenses/DiscUtils-LICENSE.txt`.
- **GDMENUCardManager** is **GPL-3.0**; Katana’s menu rebuild design and list formats are adapted from that project’s public behaviour and documented layouts.
- Bundled **GameDB-Dreamcast** title data is **GPL-3.0**.
- Bundled **GDmenu** / **openMenu** binary assets are third-party menu images for rebuild; they are not original Katana content. Respect their original authors’ terms when redistributing.

If you are the author of code or assets included here and want clearer attribution or a license adjustment, please open an issue.

## Contributing

Issues and PRs welcome. Prefer small, focused changes; keep writes **immediate and on-card** (no deferred save model).
