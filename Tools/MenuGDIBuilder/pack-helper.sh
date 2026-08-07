#!/usr/bin/env bash
# Publish a universal (arm64 + x86_64) MenuGDIBuilder into BundledHelpers/
# with bundled brotli dylibs so the sandboxed app does not need Homebrew at runtime.
#
# Important: dylibs must NOT live under Katana/ (Xcode would link them into the app).
# The Xcode "Copy Menu Helper" phase copies BundledHelpers/* into Resources/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/Tools/MenuGDIBuilder"
HELPER_DIR="$ROOT/BundledHelpers"
WORK="${TMPDIR:-/tmp}/katana-mgdi-$$"
BROTLI_SRC_URL="https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"
export PATH="$DOTNET_ROOT:$PATH"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if ! command -v dotnet >/dev/null; then
  echo "error: dotnet not found (set DOTNET_ROOT or brew install dotnet)" >&2
  exit 1
fi
if ! command -v cmake >/dev/null; then
  echo "error: cmake not found (brew install cmake)" >&2
  exit 1
fi

mkdir -p "$WORK" "$HELPER_DIR"

publish_rid() {
  local rid="$1"
  local out="$2"
  echo "Publishing ${rid}..."
  dotnet publish "$TOOL/MenuGDIBuilder.csproj" -c Release -r "${rid}" --self-contained true \
    -p:PublishSingleFile=true \
    -p:EnableCompressionInSingleFile=false \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -o "${out}"
}

publish_rid "osx-arm64" "$WORK/arm64"
publish_rid "osx-x64" "$WORK/x64"

echo "Creating universal MenuGDIBuilder..."
lipo -create \
  "$WORK/arm64/MenuGDIBuilder" \
  "$WORK/x64/MenuGDIBuilder" \
  -output "$WORK/MenuGDIBuilder"
chmod +x "$WORK/MenuGDIBuilder"

echo "Building universal brotli from source..."
curl -sL "$BROTLI_SRC_URL" | tar -xz -C "$WORK"
cmake -S "$WORK/brotli-1.1.0" -B "$WORK/brotli-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$WORK/brotli-prefix" >/dev/null
cmake --build "$WORK/brotli-build" -j"$(sysctl -n hw.ncpu)" >/dev/null
cmake --install "$WORK/brotli-build" >/dev/null

# Prefer versioned .1 dylibs (matches .NET host linkage).
for name in libbrotlicommon libbrotlidec libbrotlienc; do
  src="$WORK/brotli-prefix/lib/${name}.1.dylib"
  if [[ ! -f "$src" ]]; then
    src="$WORK/brotli-prefix/lib/${name}.dylib"
  fi
  cp -f "$src" "$WORK/${name}.1.dylib"
done

# Map any brotli install name to our staged basename.
canonical_brotli_name() {
  case "$1" in
    *brotlidec*) echo "libbrotlidec.1.dylib" ;;
    *brotlienc*) echo "libbrotlienc.1.dylib" ;;
    *brotlicommon*) echo "libbrotlicommon.1.dylib" ;;
    *) echo "" ;;
  esac
}

# Rewrite every LC_LOAD_DYLIB that mentions brotli → @executable_path/<canonical>.
# Covers: absolute cmake prefix paths, Homebrew, @rpath, versioned names.
rewrite_brotli_deps() {
  local bin="$1"
  local line old base dest
  # otool -L prints "path (compat...)" — take first field; skip the ID line for this file.
  while IFS= read -r line; do
    old="$(echo "$line" | awk '{print $1}')"
    [[ -z "$old" ]] && continue
    [[ "$old" != *brotli* ]] && continue
    base="$(canonical_brotli_name "$old")"
    [[ -z "$base" ]] && continue
    dest="@executable_path/${base}"
    # Skip if already correct (also skips the dylib's own ID if we set it first)
    if [[ "$old" == "$dest" ]]; then
      continue
    fi
    echo "  $bin: $old -> $dest"
    install_name_tool -change "$old" "$dest" "$bin"
  done < <(otool -L "$bin" | tail -n +2)
}

echo "Rewriting install names..."
for dylib in libbrotlicommon.1.dylib libbrotlidec.1.dylib libbrotlienc.1.dylib; do
  install_name_tool -id "@executable_path/${dylib}" "$WORK/${dylib}"
done

for f in MenuGDIBuilder libbrotlicommon.1.dylib libbrotlidec.1.dylib libbrotlienc.1.dylib; do
  rewrite_brotli_deps "$WORK/$f"
done

# Stage into BundledHelpers
cp -f "$WORK/MenuGDIBuilder" "$HELPER_DIR/MenuGDIBuilder"
cp -f "$WORK/libbrotlicommon.1.dylib" "$HELPER_DIR/"
cp -f "$WORK/libbrotlidec.1.dylib" "$HELPER_DIR/"
cp -f "$WORK/libbrotlienc.1.dylib" "$HELPER_DIR/"
chmod +x "$HELPER_DIR/MenuGDIBuilder"

cd "$HELPER_DIR"
# Re-run rewrite after copy (paranoia) then sign
for f in MenuGDIBuilder libbrotlicommon.1.dylib libbrotlidec.1.dylib libbrotlienc.1.dylib; do
  rewrite_brotli_deps "$f"
done
codesign --force --sign - \
  libbrotlicommon.1.dylib libbrotlidec.1.dylib libbrotlienc.1.dylib MenuGDIBuilder

echo "Architectures:"
lipo -info MenuGDIBuilder
lipo -info libbrotlidec.1.dylib

echo "Dependency check:"
bad=0
for f in MenuGDIBuilder libbrotlicommon.1.dylib libbrotlidec.1.dylib libbrotlienc.1.dylib; do
  # Only LC_LOAD lines (indented); ignore fat-header lines like "libbrotli….dylib (architecture …):"
  bad_lines="$(otool -L "$f" | awk '/^\t/ && /brotli/ {print $1}' | grep -v '^@executable_path/' || true)"
  if [[ -n "$bad_lines" ]]; then
    echo "error: $f still has non-@executable_path brotli deps:" >&2
    echo "$bad_lines" >&2
    bad=1
  fi
done
if [[ "$bad" -ne 0 ]]; then
  exit 1
fi

# Smoke test from staged dir (same layout as Resources/)
./MenuGDIBuilder --help >/dev/null
echo "Staged universal helper into $HELPER_DIR"
ls -lh MenuGDIBuilder libbrotli*.dylib
echo "OK"
