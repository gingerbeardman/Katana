# Katana — Features

Native macOS manager for **GDEMU** SD cards (Sega Dreamcast), with **GDmenu** and **openMenu** support.

Open a card, browse the numbered game folders, rename / reorder / delete with immediate on-card writes, inspect game metadata and cover art, find duplicates, hash content, and rebuild the slot-01 menu image so the console list matches the card.

---

## Cards

- **Open a GDEMU root** — point Katana at the folder containing the numbered slots (`01`, `02`, …). Works with a mounted SD card under `/Volumes` or any local folder with the same layout
- **Recents** — app-scoped security bookmarks (same model as 2UP / Brutify) reopen cards across launches without re-picking
- **Multipass** (optional) — a Recent list in the sidebar for switching between cards. Off by default: one card at a time, but the last card still reopens on launch
- **Session restore** — the last card reopens automatically at launch, painted from cache before the SD card is touched
- **Volume identity** — cards are tracked by volume UUID, so a Finder rename doesn't lose the cache, sort order, or duplicate marks
- **Capacity meter** — free / total with a colour band (green → amber under 25% → red under 10%), plus trash size
- **Trash size** — when soft-deleted items exist, the sidebar shows trash bulk in GB with a **0.1 GB minimum** (never “0 GB in Trash” for a non-empty trash)
- **Title-bar status** — game count, **percent used**, menu type, and read-only (absolute free/used stay in the sidebar meter)
- **Read-only detection** — an SD lock switch is caught up front with a clear warning instead of failed writes
- **Session write access** — security scope is held for the whole time a card is open (2UP-style); stopped only on eject, switch card, or quit
- **Write access recovery** — if the grant is lost (remount, eject, another app on the volume), Katana re-binds from the bookmark or offers **Grant Access…** so you can re-select the card root without losing the list
- **Eject** — from the toolbar, sidebar, or `⇧``⌘``E`; optional automatic eject on quit

## Scanning

- **Fast lazy scan** — lists file names, finds the disc image, reads `name.txt` / `serial.txt`, and stats the image. No IP.BIN parsing on the fast path
- **Background enrichment** — folder and payload sizes plus stored hash sidecars fill in afterwards
- **Snapshot cache** — if the saved snapshot matches the live slot folders exactly, the card opens with no per-folder I/O
- **Cache survives edits** — adding, deleting, reordering, rebuilding, and hashing update the saved cache in place (fingerprints are carried forward for untouched folders; only changed ones are re-probed), so the next open stays instant
- **On-disk fingerprints** — cache validation compares folder name, image size + mtime, sidecar contents, and file count against what's actually on the card; a rescan keeps everything that still matches
- **Batched progress** — entries arrive in batches of 24 so the table fills smoothly; live progress in the window subtitle and as a 2pt edge bar
- **Tuned concurrency** — 8 concurrent folder workers, deliberately moderate because FAT/exFAT on SD hates high fan-out
- **Off the main actor** — all card I/O is detached, so the UI never beachballs
- **Rescan** and **Clear Cache and Rescan** (`⌘``R`) for when you've changed the card behind Katana's back
- **Last Scan** readout — entries scanned, cache hits, and wall-clock duration

## Game List

- **Multi-select table** — Title, Serial, Format, Size, and slot number columns
- **Toggleable columns** — Control-click a column header to show or hide Serial, Format, or Size (same native SwiftUI table customization as 2UP). # and Title stay visible; widths and visibility persist across launches
- **Display-only sorting** — click a column header to sort the view. Slot numbers on the card are never touched. A status strip spells this out whenever a non-slot sort is active, with one-click **Newest First** / **Slot Order**
- **Sort remembered per card** — each volume keeps its own display sort across sessions
- **Apply A–Z to Card** — the deliberate, separate action that actually renumbers folders on the SD card
- **Search** — filter by name, serial, or slot number
- **Format badges** — GDI, CDI, CCD
- **Reveal in Finder** for any selection

## Renaming

- **Finder-style inline rename** — double-click, right-click → Rename, or press Return on a selected row (same immediate activation pattern as 2UP, so the first rename of a session focuses correctly)
- **Inspector rename** — edit the title field and press Return
- **Manual case conversion** — Sentence Case, Title Case, Uppercase, Lowercase, applied in bulk to any selection
- **Automatic rename** from three sources, applied in bulk:
  - **GameDB lookup** — GameDB title looked up by the serial from IP.BIN, falling back to the product name in the IP.BIN header
  - **Folder name** — the on-card folder name (skipped when it's just a slot number)
  - **File name** — the image file base name (e.g. `.gdi` / `.cdi`), tidied (underscores and dots become spaces)
- **Writes `name.txt` immediately** — compatible with other GDEMU managers; non-atomic FAT-friendly writes under the App Sandbox
- **Undo** — `⌘``Z` for renames, bulk renames, deletes, and reorders, with proper action names in the Edit menu

## Adding & Removing Games

- **Add Games** (`⌘``I`) — pick disc images or game folders into the next free slots, or **drag and drop** from Finder onto the game list
- **Finder drop target** — AppKit pasteboard destination (2UP-style), not SwiftUI `.onDrop`, so multi-select Finder drops work reliably; accent ring while hovering
- **Multi-file sets** — multi-select a `.gdi` with its tracks (or `.ccd` + companions); Katana groups them into one game. GDI imports copy **only** the cue + referenced tracks (not the whole parent folder). Redump-style **quoted track names** (spaces) are supported for copy and IP.BIN
- **ZIP import** — drop or pick a `.zip` of game folders / disc-image sets; extracted in-process (sandbox-safe), then imported like loose packages
- **Transparent copy** — each new slot’s folder and title appear in the list immediately; a top edge bar tracks overall progress and a per-row spinner marks the active file
- **Chunked edge progress** — one bar for scan, rebuild, import, and delete: **time-weighted per-file chunks** on import using remembered transfer rates (one marker per valid file — a 1 GB track gets a wide chunk, every file keeps a ~2% floor so its marker stays visible — plus a hash stretch after each game's files, so finalize **crawls instead of stalling at 99%**), the fill advances by real bytes and **reaches a notch exactly when that file finishes** (never before); notches are gaps punched clean through the fill (visible on any fill colour, light or dark) and solid ticks on the unfilled track; import holds short of full until finalize
- **Honest card writes** — copies to the card bypass the macOS write cache (`F_NOCACHE`), so the bar tracks bytes physically on the card: no instant leap on big files, no long wait at a finished file's marker, and measured transfer rates stay true
- **Formats** — GDI (cue + tracks), CDI, CCD (plus `.img` / `.sub` / `.cue` companions), game folders, or `.zip` archives
- **Automatic renumbering** — existing folders are widened first when the digit count has to grow (99 → 100); menu slot stays **`01`**
- **Import naming** — by default, **Automatically rename added games** (Settings) names each new slot from the GameDB via the IP.BIN serial (fallback: IP.BIN product name). Off uses the source file or folder name. **Build-tag / variant filenames win** even with auto-rename on: names with hyphens or underscores (e.g. `beltrunner-shipplay-f64-dc`, `beltrunner-combat-stats-f32-dc`) keep the source label instead of a short shared product title. **Hold ⌥** while confirming Add Games or while dropping (Option is tracked for the whole drag) to force source names for that import. Names that would collide with the card or the rest of the same multi-add batch also fall back to the source
- **Hashes on import** — content hashes are computed after add so new games join the duplicate suite; hashing is paused before delete / empty trash so FAT cards can free space cleanly
- **Soft delete** — ⌫ / Delete moves games to `.katana-trash` (fast, undoable); remaining slots pack down with single-pass renames
- **Delete Immediately** — ⌥⌫, or hold ⌥ in Game / context menus so **Delete** swaps to **Delete Immediately…** (Finder-style alternate); erases folders from the card now (slow for large GDI sets, with edge progress); confirmation; cannot be undone
- **Empty Card Trash** — permanently reclaim space (scoped wipe, including AppleDouble companions); confirmation shows count and size

## Reordering

- **Move Up / Move Down on Card** — renumber the selection, one slot at a time
- **Apply A–Z Order to Card** — alphabetical renumber of the whole card
- **Compact packing** — after deletes, remaining games only move down into freed slots, one rename each, with a two-phase fallback when a destination is still occupied
- **Correct folder width** — menu slot is always `01`; other slots follow the card’s magnitude (`02`… or `002`…), matching GDEMU / GCM

## Inspector

Collapsible sections, each remembering its expanded state:

- **Title** — editable display name, slot number, format, size
- **Duplicate** — grade, matching signals, position in the group, group member list, and group-selection actions
- **IP.BIN** — product title (only when it differs from the display name), version, disc number, VGA flag, serial, region, CRC, and Code Breaker detection
- **Cover** — the game’s `0GDTEX.PVR` artwork, decoded natively
- **On Card** — image file name and full on-disk path, selectable
- **Actions** — rename menus, Reveal in Finder, delete
- **Multi-select** — count, combined size, a preview list, and bulk actions

## Cover Art

- **Native PVR decoding** — no external tools. RGB565, ARGB1555, and ARGB4444, in square-twiddled, rectangle, and rectangle-twiddled layouts
- **Loose `0GDTEX.PVR`** next to the disc image is used when present
- **Extracted from GDI** — for GDI sets, Katana reads the high-density ISO track directly and pulls the texture out (quote-aware `.gdi` cues, same as import / IP.BIN)

## Duplicate Detection

- **Four grades**, each with its own badge:
  - **Exact** — SHA-256 of the game payload matches
  - **Strong** — same payload size plus serial and/or a strong name match
  - **Likely** — same payload size alone, or serial plus a similar name
  - **Weak** — serial alone, or careful name-only links (where fake serials tend to land)
- **Signals shown** — which of hash / size / serial / name actually matched
- **Multi-disc aware** — sets that share a serial are ignored unless size or hash also match
- **Sequel-aware** — name-only matches are rejected when product codes differ, sizes diverge a lot, or titles look like sequels (`Virtua Tennis` / `Virtua Tennis 2`, `Resident Evil 2` / `3`, trailing `II`, and similar)
- **Keep candidate** — the lowest slot in each group is marked primary; the rest are extras
- **Sidebar metrics** — groups, flagged, exact, extras, ignored, unhashed
- **Selection helpers** — Select All Duplicates, Select Exact Extras, Select All Extras, Select Redundant in Group
- **"Not a duplicate" marks** — per card, saved with the volume, with Select Ignored and Clear Ignored
- **Markers and filtering** — grade chips in the list, and a Show Duplicates Only mode that dims non-duplicates in place without reflowing the table
- **Off by default** — turn on in Settings or View when you want to clean the card; the inspector drops the Duplicate section immediately when the feature is off

## Content Hashing

- **Background SHA-256** of the game payload, filling in gradually
- **Sidecars** — hashes are written to the card so they survive across sessions and machines
- **Live progress** — completed / pending count, bytes hashed, throughput, percentage, and ETA
- **Stop at any time**, resuming later from where it left off
- **Mutually exclusive with menu rebuild** — both need exclusive access to the card, and the UI says so rather than letting them collide

## Menu Rebuild

- **Native Swift bake** — GDmenu (`LIST.INI`) or openMenu (`OPENMENU.INI`) written into slot 01
- **Real GDI output** — ISO 9660 Level 1, multi-track GDI at LBA 45000, with truncate and CDDA handling, MIL-CD-safe
- **No helper binaries** — no .NET runtime, no nested executables, no brotli dylibs in the app bundle; menu asset zips unpack **in-process** (sandbox-safe; no `/usr/bin/unzip`)
- **List keys match folders** — menu stays in **`01`** (same as GDMENU Card Manager); game slots use card-wide width (`002`… on a 100+ game card) so GDmenu can resolve titles
- **Menu type picker** — switch between GDmenu and openMenu from Settings or the Card menu
- **Out-of-date banner** — a warning strip appears above the list when names or order no longer match the baked menu; **fingerprint-based** dirty state clears if you reverse the change (e.g. add a game then delete it, or undo a rename)
- **Prompt on quit** — you're asked before leaving with a stale menu image; quit-time rebuild skips UI thrash so exit stays responsive
- **Progress** — headers (2–80%), bake stages (assets, tracks, disc.gdi), and byte-tracked install on the edge bar; bar reaches full width on completion; the status line shows where headers come from (**“270 cached · 12 from card”**)
- **Cached IP headers** — import, enrichment, rebuilds, and the inspector store IP.BIN fields on each game **and in the on-disk card cache**, so rebuilds skip re-reading every GDI across launches; cleared when the disc content hash changes (homebrew images without a readable IP.BIN are re-read each time)
- **Bundled stock assets** — GDmenu and openMenu packs ship inside the app as zip resources

## Game Database

- **4,208 title mappings** (1,400 primary titles plus aliases) from IP.BIN product and Redump serials
- **Title resolution order** — `name.txt` → GameDB by serial or product → IP.BIN product name → folder or image base name
- **Warmed off the main actor** at launch so the first card scan doesn't hitch
- **Regenerable** from upstream via a bundled script

## Safety

- **No Save button** — the SD card is the source of truth, and every change is written immediately
- **Undo** for renames, soft-deletes, and reorders (immediate delete has no undo)
- **Soft delete** to on-card trash by default; optional immediate erase
- **Read-only cards** detected up front
- **Operations serialised** — hashing, rebuilding, scanning, and importing never overlap
- **Sandboxed file access** — App Sandbox with `user-selected` + **app-scoped bookmarks** (same pattern as 2UP/Brutify), session-held scope while a card is open, and a **`/Volumes/` write exception** so remounted SD cards stay usable without endless re-grant prompts (Developer ID distribution; not App Store)
- **Outbound network only for updates** — optional GitHub Releases check; no other network use

## Mac Native

- **SwiftUI** with a NavigationSplitView: sidebar, table, and trailing inspector
- **Customisable toolbar** — the default set is Open · Add · Delete · Rebuild · A–Z · Eject · Inspector, with Move Up, Move Down, and Duplicates available in the palette
- **Full keyboard support** — `⌘``O` open, `⌘``I` add, `⌘``S` rebuild, `⌘``R` clear cache and rescan, `⇧``⌘``E` eject, `⌫` soft-delete, `⌥``⌫` delete immediately, Return to rename, `⌥``⌘``I` inspector, `⌘``D` duplicate tools, `⌥``⌘``D` duplicate markers, `⌘``Z` undo
- **Context menus** throughout the game list
- **Dark Mode**, full screen, and window state restoration
- **Welcome window** on first launch, reopenable from the Help menu
- **Settings** — General (adding, duplicates, units) and SD Card (menu type, multipass, cache, eject)
- **Unit preference** — whole megabytes or adaptive KB/MB for games; GB for card capacity and trash (trash floor **0.1 GB** when non-empty)
- **Non-blocking status** — flash messages, an inline error banner you can dismiss, and progress in the window subtitle
- **Edge progress** — scan, menu rebuild, and disk mutations (add / delete / renumber / eject) share one chunked top bar (markers + fill) instead of a center blocking card; active import rows spin
- **Check for Updates** — Help → Check for Updates… queries the public GitHub Releases API for this app; a quiet check also runs at launch and shows a banner when a newer version is available (sandboxed outbound network for updates only)

## Distribution

- **Universal binary** — arm64 and x86_64
- **Notarized** Developer ID build, stapled and `spctl`-verified
- **macOS 14 Sonoma** or later
- **No dependencies** — no .NET, no helper processes, no bundled third-party runtimes
- **MIT licence** — see `LICENSE`
- **GitHub Releases** — DMG downloads and in-app **Check for Updates** against `gingerbeardman/Katana`

---

## Compared with GDMENU Card Manager

[GDMENU Card Manager](https://github.com/sonik-br/GDMENUCardManager) by sonik-br is the primary inspiration and reference implementation, and remains the multi-platform tool of choice. Katana is a separate native macOS app that follows the same on-disk conventions.

**No GDMENUCardManager source code is used in Katana.** Katana is written from scratch in Swift. What the two share is the on-disk format — folder layout, file names, and list syntax that GDmenu and openMenu themselves define, and which any manager has to match for the console to boot. The menu GDI writer derives from the MIT-licensed DiscUtils / GDIbuilder community lineage, not from GDMENUCardManager.

| | Katana | GDMENU Card Manager |
|---|---|---|
| Platform | macOS only | Windows, Linux, macOS |
| Built with | Native Swift / SwiftUI | C# / .NET 6 / Avalonia |
| Runtime required | None | .NET 6 Desktop Runtime |
| GDmenu + openMenu | Yes | Yes |
| Menu GDI bake | Native Swift | Bundled tooling |
| GDI / CDI / CCD | Yes | Yes |
| MDS images | – | Yes |
| Zip import | Yes | Yes |
| rar / 7z import | – | Yes |
| GDI shrinking | – | Yes |
| Add / delete / rename | Yes | Yes |
| Soft delete + empty trash | Yes | – |
| Delete immediately (permanent) | Yes | – |
| Drag-and-drop add games | Yes | Yes |
| Multi-file GDI/CCD drop grouping | Yes | Yes |
| Transparent add (live list + byte-weighted progress) | Yes | – |
| Sort alphabetically | Yes | Yes |
| Drag-and-drop manual order | – | Yes |
| Move up / down on card | Yes | – |
| Auto-rename from GameDB / IP.BIN / folder / file | Yes | Yes |
| Variant/build-tag filenames kept on auto-rename | Yes | – |
| ⌥ Add / drop keeps source names | Yes | – |
| Manual case conversion | Yes | – |
| Inline Finder-style rename | Yes | – |
| Cover art (0GDTEX.PVR) | Yes | Yes |
| CodeBreaker detection | Yes | Yes |
| `name.txt` compatibility | Yes | Yes |
| Immediate on-card writes | Yes | Save step |
| Undo | Yes | – |
| Duplicate detection | Yes | – |
| Sequel-aware name matching | Yes | – |
| Content hashing (SHA-256) | Yes | – |
| Bundled title database | Yes | – |
| Scan cache | Yes | – |
| Display-only column sorting | Yes | – |
| Toggleable / resizable columns | Yes | – |
| Multi-card recents | Yes | – |
| Read-only card detection | Yes | – |
| Eject on quit | Yes | – |
| In-app update check | Yes | – |
| Licence | MIT | GPL v3 |

For Windows or Linux, archive import, MDS support, or GDI shrinking, use GDMENU Card Manager.
