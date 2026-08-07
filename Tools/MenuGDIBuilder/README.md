# MenuGDIBuilder (reference only)

Katana now bakes the menu GDI **natively in Swift**
(`Katana/Services/MenuBake/`). This folder is kept as:

- Stock **gdMenu / openMenu** assets used by the app (and tests)
- A DiscUtils / GDromBuilder **reference implementation** matching GDMENUCardManager

You do **not** need to build or ship the .NET helper for the app.

## Optional: run the reference CLI

```bash
# Requires: brew install dotnet
dotnet run -c Release -- \
  --kind gdMenu --list LIST.INI --assets ./assets/gdMenu --out ./menu_gdi
```

Or use a previously published binary:

```
MenuGDIBuilder --kind gdMenu --list LIST.INI --assets ./assets/gdMenu --out ./menu_gdi
```
