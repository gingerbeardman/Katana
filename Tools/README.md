# Tools

Repo helpers only — **not** part of the Katana app target.

| Path | Purpose |
| --- | --- |
| `MenuAssets/gdMenu` | Unpacked stock GDmenu tree for bake unit tests |
| `MenuAssets/openMenu` | Unpacked stock openMenu tree for bake unit tests |
| `scripts/build-gamedb.py` | Rebuild `Katana/Resources/GameDB/dreamcast-titles.json` |
| `licenses/` | Third-party license texts (e.g. DiscUtils MIT) |

The shipping app uses **zipped** menu assets from `Katana/Resources/MenuAssets/` and bakes with native Swift (`Katana/Services/MenuBake/`). No .NET tooling is required.
