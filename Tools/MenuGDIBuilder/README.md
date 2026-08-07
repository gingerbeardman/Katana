# MenuGDIBuilder

CLI helper that rebuilds a GDmenu / openMenu GDI image using the same
DiscUtils GDromBuilder path as GDMENUCardManager.

## Build

```bash
export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
export PATH="$DOTNET_ROOT:$PATH"
dotnet publish -c Release -r osx-arm64 --self-contained true \
  -p:PublishSingleFile=true \
  -p:EnableCompressionInSingleFile=true \
  -o ./publish
cp publish/MenuGDIBuilder ../../Katana/Resources/Helpers/
```

## Usage

```
MenuGDIBuilder --kind gdMenu --list LIST.INI --assets ./assets/gdMenu --out ./menu_gdi
```
