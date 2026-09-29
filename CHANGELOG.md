# Changelog

Scratchpad for notes to publish with the **next** release. Keep user-facing and succinct.

Current release is **4.0.1** (GitHub `v4.0.1`, build **8**). New work lands under **Unreleased**.

## Unreleased

### add
- (none)

### change
- (none)

### fix
- (none)

### remove
- (none)

---

## 4.0.1

Shipped as **v4.0.1** on GitHub (universal notarized DMG). Build **8**.

### add
- **Cover column** — the game list can show None, Disc, or Custom for each game’s cover. Hidden until you turn the column on

### change
- (none)

### fix
- **Cover** — a JPEG or PNG saved as the cover keeps its orientation instead of being mirrored
- **Cover on the Dreamcast** — rebuilding an openMenu card copies each loose `0GDTEX.PVR` into `BOX.DAT` and `ICON.DAT`, which is where the menu looks up artwork

### remove
- (none)

---

## 4.0

Shipped as **v4.0** on GitHub (universal notarized DMG). Build **7**.

### add
- **Katana on GitHub** — Help menu opens the project page
- **Custom cover** — Change Cover Image… saves a picture as a loose `0GDTEX.PVR` next to the game. A PVR file is copied unchanged when Katana can read it. Remove Custom Cover deletes that file

### change
- **Menu inspector** — slot 01 shows the installed menu, with Rebuild and Reveal in Finder. Rename, cover, and delete stay on games
- **openMenu 1.7.0-ateam** — bundled menu pack is the current Virtual Folder Bundle (Dreamcast Now, mouse, scrollbar, multi-controller navigation)

### fix
- **Stale disc details** — replacing a game or the menu drops the previous serial, version, and date instead of keeping them after the files have changed
- **Menu type follows the card** — opening a card detects GDmenu, stock openMenu, or openMenu Extended from slot 01. A stock openMenu card stays on openMenu instead of switching to Extended
- **Menu rebuild** — slot 01 files, including preserved cover data, are written where the menu looks for them
- **Cover** — a game with no `0GDTEX.PVR` shows the openMenu box art from the card, matched by serial, instead of “File not found”

### remove
- (none)

---

## 3.0.1

Shipped as **v3.0.1** on GitHub (universal notarized DMG). Build **6**.

### add
- (none)

### change
- App category is **Utilities**, not Games — macOS no longer turns on Game Mode

### fix
- (none)

### remove
- (none)

---

## 3.0

Shipped as **v3.0** on GitHub (universal notarized DMG).

### add
- **Arrange list** — drag selected rows (or Move Up/Down / Top / Bottom) in the **current table sort**; **Apply** renames numbered folders once. Newest First stays newest-first. The menu stays in slot 01. Cancel discards the pending order.
- **Move to Top / Bottom** — ⌥⌘↑ / ⌥⌘↓ jump the selection to slot 02 or the last slot (staged in Arrange until Apply)
- **Assign Folder** — inspector Folder is an editable combo (type a path or autocomplete from ones already on the card); right-click **Assign Folder** sets the same path on a multi-select (**None**, existing paths, **Type a Path…** with the same autocomplete)
- **Three menu types** — GDmenu, openMenu, and openMenu Extended (ateam). Folder and Type columns (and Assign Folder) only appear for Extended; GDmenu and stock openMenu hide them. Cards that were already using ateam stay on Extended.
- **openMenu virtual folders and disc types** — Folder / Type columns, inspector fields, and `folder.txt` / `type.txt` / `folder_altN.txt` sidecars matching GDMENU Card Manager; rebuild writes `folder=`, `folder_altN=`, and `type=` into `OPENMENU.INI` so ateam cards survive a Katana bake
- **Disc, region, and serial overrides** — editable inspector fields (and a Disc column) write `disc.txt` / `region.txt` / `serial.txt`; rebuild honours them in `OPENMENU.INI` so multi-disc Compact grouping and PAL/region flags survive. GCM IP cache files (`vga.txt`, `version.txt`, `date.txt`) are read on scan so rebuild can skip re-opening the disc image
- **openMenu 1.6.3-ateam** — bundled menu pack is the Virtual Folder Bundle build (Folders themes, cheats, Bleemcast/Bloom), not stock openMenu

### change
- **Move Up / Down follow the list** — ⌘↑ / ⌘↓ move the row you see (in Newest First, up is a higher slot). Reorders stay in Arrange until you Apply, so one command cannot rewrite the card. Drag selected rows to reorder; dragging unselected rows still extends the selection

### fix
- **⌘S after editing a field** — Rebuild Menu keeps its shortcut; text fields only take editing keys (⌘A / ⌫ / ⌘Z), not Save
- **openMenu no longer looks stale after a previous bake** — slot-01 type is remembered and detected from the menu name on open, so a rebuilt ateam card is not flagged out of date on the next launch
- **Add fills the lowest free slot** — deleting the last games (e.g. 283 and 284) no longer leaves a hole; the next add reuses 283, including leftover empty numbered folders
- **openMenu cover art survives rebuild** — `BOX.DAT`, `ICON.DAT`, `META.DAT`, and folder artwork (`FOLDRART.DAT` / `FOLDRART.MAP`) are copied out of the current slot-01 GDI and baked back in, so switching to ateam openMenu no longer wipes assigned covers
- **Warm rebuilds no longer crawl “Reading game headers”** — when every IP header is already cached the list is written immediately; openMenu.zip is extracted once and reused; artwork DATs are read in one ISO pass with the track file kept open (the ateam pack + BOX.DAT on SD made Save/Rebuild feel stuck at 220/283)
- **Move Up/Down no longer empties the card** — overlapping renumbers (⌘↓ key-repeat) and rewriting every `001`→`01` folder as a side effect of swapping two slots could park the library in `.katana-tmp`. Moves wait their turn, only folders whose slot number changes are renamed, and parked games are restored on the next scan

### remove
- (none)

---

## 2.0

Shipped as **v2.0** on GitHub (universal notarized DMG).

### add
- **Grant Access…** when card write access expires (re-select the card root without losing the list)
- Multi-select / drag-and-drop **GDI + tracks** (and CCD companions) grouped into one game
- **ZIP** import for add-games (in-process extract; folders or disc-image sets inside the archive)
- **Delete Immediately** (⌥⌫; hold ⌥ so **Delete** swaps in menus) — permanent on-card erase with progress; skips soft-trash; cannot be undone
- Shared **chunked edge progress** (scan / rebuild / import / delete): markers per work unit, fill tracks real I/O; import uses size/time-weighted file chunks and holds under 100% until finalize
- **Automatically rename added games** (Settings → General, on by default) — new games named from the GameDB via IP.BIN serial, falling back to the IP.BIN name
- Keyboard shortcuts: **⌘I** Add Games, **⌘R** Clear Cache and Rescan, **⌘D** toggle duplicate tools
- **Remembered transfer rates** — card write and hash speeds measured during imports and reused so the import bar stays honest through finalize
- **IP.BIN header cache** — headers remembered on each game and in the on-disk card cache so menu rebuilds skip re-reading every GDI; status shows **“N cached · M from card”**
- **Check for Updates** — Help → Check for Updates… and a quiet launch check against GitHub Releases; banner when a newer version is available

### change
- Duplicate tools default to **off** (opt-in in Settings / View)
- GDI import copies only the cue + referenced tracks (not the whole parent folder)
- Menu rebuild progress weighted to real work (headers dominate; bake/install are short tails) and finishes at **full** width
- Card security scope held for the whole open session (2UP-style); stop only on eject, switch card, or quit
- Trash size never shows **0 GB** for non-empty trash (minimum **0.1 GB**)
- Renumber / move actions say **Card**, not Disc; “disc” reserved for disc images, IP.BIN, multi-disc titles
- Bulk rename source **“Using IP.BIN Info”** → **“Using GameDB Lookup”**
- Card copies bypass the macOS write cache so progress tracks what has landed on the card
- Menu dirty tracking is **fingerprint-based** — reverse a change (add then delete, undo rename) and the rebuild prompt clears
- Quit-time rebuild skips UI thrash and SD size walks so exit is snappier

### fix
- `/Volumes/` sandbox temporary exception so SD cards stay writable after remount
- App-scoped security bookmarks (`bookmarks.app-scope`, same as 2UP/Brutify)
- Card writes keep the live security-scoped root (path-only / standardized URLs dropped access)
- Error banner shows full write-failure detail (selectable, multi-line)
- Empty Trash after import/delete (cancel hashing first; scoped wipe; quarantine xattrs)
- Trash summary no longer falsely empty when items exist
- FAT write probe (non-atomic create/delete)
- First inline rename of a session focuses correctly
- Sequels no longer weak name-only duplicates (e.g. Virtua Tennis / Virtua Tennis 2)
- Menu rebuild under App Sandbox (in-process zip extract)
- LIST.INI / OPENMENU.INI match GCM: menu **`01`**, games card-wide width (`002`… on 100+ cards)
- Redump GDI cues with **quoted track names** — IP.BIN serial, titles, and cover extract work
- Update checks reach GitHub (network client entitlement)
- Empty Trash / Card actions no longer stay disabled after adding games
- **Restore (undo delete)** shows real progress instead of sitting on “Restoring…”
- Card cache survives edits (add / delete / reorder / rebuild / hash update in place)
- **Rescan keeps cached data** — fingerprints reflect on-disk identity, not display names
- Cache saves after an edit no longer re-walk every folder on the card
- Menu install fills the bar by bytes written

### remove
- **Scroll to new rows** setting and behaviour

---

## 1.1

Shipped (see GitHub Releases). Highlights:

### add
- Transparent Add Games (live rows, edge progress, per-row spinner)
- Finder drag-and-drop add (AppKit pasteboard destination)
- Toggleable table columns
- Check for Updates (GitHub Releases)

### change
- Edge progress bar instead of centre busy card for disk mutations
- Title bar shows percent used
- Narrower minimum window size
