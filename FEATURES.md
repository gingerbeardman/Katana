# Katana — Features

Native macOS manager for **GDEMU** SD cards (Sega Dreamcast), with **GDmenu** and **openMenu** support.

Open a card, browse the numbered game folders, rename / reorder / delete with immediate on-card writes, inspect disc metadata and cover art, find duplicates, hash content, and rebuild the slot-01 menu image so the console list matches the card.

---

## Cards

- **Open a GDEMU root** — point Katana at the folder containing the numbered slots (`01`, `02`, …). Works with a mounted SD card under `/Volumes` or any local folder with the same layout
- **Recents** — security-scoped bookmarks reopen cards across launches without re-picking
- **Multipass** (optional) — a Recent list in the sidebar for switching between cards. Off by default: one card at a time, but the last card still reopens on launch
- **Session restore** — the last card reopens automatically at launch, painted from cache before the SD card is touched
- **Volume identity** — cards are tracked by volume UUID, so a Finder rename doesn't lose the cache, sort order, or duplicate marks
- **Capacity meter** — free / total with a colour band (green → amber under 25% → red under 10%), plus trash size
- **Read-only detection** — an SD lock switch is caught up front with a clear warning instead of failed writes
- **Eject** — from the toolbar, sidebar, or `⇧``⌘``E`; optional automatic eject on quit

## Scanning

- **Fast lazy scan** — lists file names, finds the disc image, reads `name.txt` / `serial.txt`, and stats the image. No IP.BIN parsing on the fast path
- **Background enrichment** — folder and payload sizes plus stored hash sidecars fill in afterwards
- **Snapshot cache** — if the saved snapshot matches the live slot folders exactly, the card opens with no per-folder I/O
- **Batched progress** — entries arrive in batches of 24 so the table fills smoothly; live progress in the window subtitle and as a 2pt edge bar
- **Tuned concurrency** — 8 concurrent folder workers, deliberately moderate because FAT/exFAT on SD hates high fan-out
- **Off the main actor** — all card I/O is detached, so the UI never beachballs
- **Rescan** and **Clear Cache and Rescan** for when you've changed the card behind Katana's back
- **Last Scan** readout — entries scanned, cache hits, and wall-clock duration

## Game List

- **Multi-select table** — Title, Serial, Format, Size, and slot number columns
- **Display-only sorting** — click a column header to sort the view. Slot numbers on the card are never touched. A status strip spells this out whenever a non-slot sort is active, with one-click **Newest First** / **Slot Order**
- **Sort remembered per card** — each volume keeps its own display sort across sessions
- **Apply A–Z to Disc** — the deliberate, separate action that actually renumbers folders on the SD card
- **Search** — filter by name, serial, or slot number
- **Format badges** — GDI, CDI, CCD
- **Reveal in Finder** for any selection
- **Optional scroll-to-new-rows** while scanning and after adding games

## Renaming

- **Finder-style inline rename** — double-click, right-click → Rename, or press Return on a selected row
- **Inspector rename** — edit the title field and press Return
- **Manual case conversion** — Sentence Case, Title Case, Uppercase, Lowercase, applied in bulk to any selection
- **Automatic rename** from three sources, applied in bulk:
  - **IP.BIN info** — GameDB title for the disc serial, falling back to the product name in the disc header
  - **Folder name** — the on-card folder name (skipped when it's just a slot number)
  - **File name** — the disc image base name, tidied (underscores and dots become spaces)
- **Writes `name.txt` immediately** — compatible with other GDEMU managers
- **Undo** — `⌘``Z` for renames, bulk renames, deletes, and reorders, with proper action names in the Edit menu

## Adding & Removing Games

- **Add Games** (`⇧``⌘``N`) — drop discs into the next free slots
- **Formats** — GDI (whole track set), CDI, CCD (plus `.img` / `.sub` / `.cue` companions), or a folder already laid out as a GDEMU game
- **Automatic renumbering** — existing folders are widened first when the digit count has to grow (99 → 100)
- **Import naming** — source file or folder name first (so variants stay distinguishable), then GameDB / IP.BIN
- **Hashes on import** — content hashes are computed as files are copied, so new games arrive already deduplicated
- **Soft delete** — deleted games move to `.katana-trash` on the card and can be undone; remaining slots pack down with single-pass renames
- **Empty Card Trash** — permanently reclaim the space, with the trash size shown in the sidebar

## Reordering

- **Move Up / Move Down on Disc** — renumber the selection, one slot at a time
- **Apply A–Z Order to Disc** — alphabetical renumber of the whole card
- **Compact packing** — after deletes, remaining games only move down into freed slots, one rename each, with a two-phase fallback when a destination is still occupied
- **Correct folder width** — numbering width follows the card's magnitude, matching GDEMU conventions

## Inspector

Collapsible sections, each remembering its expanded state:

- **Title** — editable display name, slot number, format, size
- **Duplicate** — grade, matching signals, position in the group, group member list, and group-selection actions
- **IP.BIN** — product title (only when it differs from the display name), version, disc number, VGA flag, serial, region, CRC, and Code Breaker detection
- **Cover** — the disc's `0GDTEX.PVR` artwork, decoded natively
- **On Card** — image file name and full on-disk path, selectable
- **Actions** — rename menus, Reveal in Finder, delete
- **Multi-select** — count, combined size, a preview list, and bulk actions

## Cover Art

- **Native PVR decoding** — no external tools. RGB565, ARGB1555, and ARGB4444, in square-twiddled, rectangle, and rectangle-twiddled layouts
- **Loose `0GDTEX.PVR`** next to the disc image is used when present
- **Extracted from GDI** — for GDI sets, Katana reads the high-density ISO track directly and pulls the texture out

## Duplicate Detection

- **Four grades**, each with its own badge:
  - **Exact** — SHA-256 of the disc payload matches
  - **Strong** — same payload size plus serial and/or a strong name match
  - **Likely** — same payload size alone, or serial plus a similar name
  - **Weak** — serial alone, or name similarity alone (where fake serials tend to land)
- **Signals shown** — which of hash / size / serial / name actually matched
- **Multi-disc aware** — sets that share a serial are ignored unless size or hash also match
- **Keep candidate** — the lowest slot in each group is marked primary; the rest are extras
- **Sidebar metrics** — groups, flagged, exact, extras, ignored, unhashed
- **Selection helpers** — Select All Duplicates, Select Exact Extras, Select All Extras, Select Redundant in Group
- **"Not a duplicate" marks** — per card, saved with the volume, with Select Ignored and Clear Ignored
- **Markers and filtering** — grade chips in the list, and a Show Duplicates Only mode that dims non-duplicates in place without reflowing the table
- **Fully optional** — the whole duplicate toolset can be switched off once the card is clean

## Content Hashing

- **Background SHA-256** of the disc payload, filling in gradually
- **Sidecars** — hashes are written to the card so they survive across sessions and machines
- **Live progress** — completed / pending count, bytes hashed, throughput, percentage, and ETA
- **Stop at any time**, resuming later from where it left off
- **Mutually exclusive with menu rebuild** — both need exclusive access to the card, and the UI says so rather than letting them collide

## Menu Rebuild

- **Native Swift bake** — GDmenu (`LIST.INI`) or openMenu (`OPENMENU.INI`) written into slot 01
- **Real GDI output** — ISO 9660 Level 1, multi-track GDI at LBA 45000, with truncate and CDDA handling, MIL-CD-safe
- **No helper binaries** — no .NET runtime, no nested executables, no brotli dylibs in the app bundle
- **Menu type picker** — switch between GDmenu and openMenu from Settings or the Card menu
- **Out-of-date banner** — a warning strip appears above the list when names or order no longer match the baked menu
- **Prompt on quit** — you're asked before leaving with a stale menu image
- **Progress** — header reading, bake, and install phases reported on the edge bar
- **Bundled stock assets** — GDmenu and openMenu asset trees ship inside the app

## Game Database

- **4,208 title mappings** (1,400 primary titles plus aliases) from IP.BIN product and Redump serials
- **Title resolution order** — `name.txt` → GameDB by serial or product → IP.BIN product name → folder or image base name
- **Warmed off the main actor** at launch so the first card scan doesn't hitch
- **Regenerable** from upstream via a bundled script

## Safety

- **No Save button** — the SD card is the source of truth, and every change is written immediately
- **Undo** for renames, deletes, and reorders
- **Soft delete** to on-card trash before anything is destroyed
- **Read-only cards** detected up front
- **Operations serialised** — hashing, rebuilding, scanning, and importing never overlap
- **Sandboxed file access** — Katana only touches the card you explicitly open

## Mac Native

- **SwiftUI** with a NavigationSplitView: sidebar, table, and trailing inspector
- **Customisable toolbar** — the default set is Open · Add · Delete · Rebuild · A–Z · Eject · Inspector, with Move Up, Move Down, and Duplicates available in the palette
- **Full keyboard support** — `⌘``O` open, `⇧``⌘``N` add, `⌘``S` rebuild, `⇧``⌘``E` eject, `⌫` delete, Return to rename, `⌥``⌘``I` inspector, `⌥``⌘``D` duplicate markers, `⌘``Z` undo
- **Context menus** throughout the game list
- **Dark Mode**, full screen, and window state restoration
- **Welcome window** on first launch, reopenable from the Help menu
- **Settings** — General (duplicates, list, units) and SD Card (menu type, multipass, cache, eject)
- **Unit preference** — whole megabytes or adaptive KB/MB, with GB for card capacity
- **Non-blocking status** — flash messages, an inline error banner you can dismiss, and progress in the window subtitle

## Distribution

- **Universal binary** — arm64 and x86_64
- **Notarized** Developer ID build, stapled and `spctl`-verified
- **macOS 14 Sonoma** or later
- **No dependencies** — no .NET, no helper processes, no bundled third-party runtimes

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
| Zip / rar / 7z import | – | Yes |
| GDI shrinking | – | Yes |
| Add / delete / rename | Yes | Yes |
| Sort alphabetically | Yes | Yes |
| Drag-and-drop manual order | – | Yes |
| Move up / down on disc | Yes | – |
| Auto-rename from IP.BIN / folder / file | Yes | Yes |
| Manual case conversion | Yes | – |
| Inline Finder-style rename | Yes | – |
| Cover art (0GDTEX.PVR) | Yes | Yes |
| CodeBreaker detection | Yes | Yes |
| `name.txt` compatibility | Yes | Yes |
| Immediate on-card writes | Yes | Save step |
| Undo | Yes | – |
| Soft delete / on-card trash | Yes | – |
| Duplicate detection | Yes | – |
| Content hashing (SHA-256) | Yes | – |
| Bundled title database | Yes | – |
| Scan cache | Yes | – |
| Display-only column sorting | Yes | – |
| Multi-card recents | Yes | – |
| Read-only card detection | Yes | – |
| Eject on quit | Yes | – |
| Licence | Proprietary | GPL v3 |

For Windows or Linux, archive import, MDS support, or GDI shrinking, use GDMENU Card Manager.
