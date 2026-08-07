#!/usr/bin/env bash
# Build a universal (arm64 + x86_64), Developer ID–signed, notarized Katana.dmg.
#
# Pattern follows ~/Projects/BtnQ/scripts/notarize.sh (notarytool keychain profile,
# HFS compression into UDZO DMG, staple app + DMG, spctl verify).
#
# Prerequisites:
#   1. Developer ID Application cert in keychain (team Q3Z639YB49)
#   2. Keychain profile:
#        xcrun notarytool store-credentials "notarytool-password" \
#          --apple-id "you@example.com" --team-id "Q3Z639YB49" --password "xxxx-xxxx-xxxx-xxxx"
#   3. Xcode
#
# Usage:
#   Scripts/make-notarized-dmg.sh
#   SCHEME=Katana KEYCHAIN_PROFILE=notarytool-password Scripts/make-notarized-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Katana}"
APP_NAME="${APP_NAME:-Katana}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-Q3Z639YB49}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Matt Sephton ($TEAM_ID)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-password}"
VOLNAME="${VOLNAME:-Katana}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
EXPORT_OPTS="$ROOT/ExportOptions.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
print_step()    { echo -e "\n${GREEN}▶ $1${NC}"; }
print_error()   { echo -e "${RED}✖ $1${NC}"; }
print_success() { echo -e "${GREEN}✔ $1${NC}"; }

check_prerequisites() {
    print_step "Checking prerequisites..."
    if ! command -v xcodebuild &>/dev/null; then
        print_error "xcodebuild not found"; exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        print_error "No Developer ID Application identity in keychain"; exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
        print_error "Keychain profile '$KEYCHAIN_PROFILE' not found."
        echo "Create it with:"
        echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
        echo "    --apple-id \"your-email@example.com\" \\"
        echo "    --team-id \"$TEAM_ID\" \\"
        echo "    --password \"xxxx-xxxx-xxxx-xxxx\""
        exit 1
    fi
    if [[ ! -f "$EXPORT_OPTS" ]]; then
        print_error "ExportOptions.plist missing at $EXPORT_OPTS"; exit 1
    fi
    print_success "Prerequisites OK"
}

clean_build() {
    print_step "Cleaning previous build..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    print_success "Clean complete"
}

archive_app() {
    print_step "Archiving universal Release ($SCHEME)..."
    xcodebuild archive \
        -project "$ROOT/Katana.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="arm64 x86_64" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        | grep -E "^(Archive|error:|warning:|\*\*|    export)" || true
    [[ -d "$ARCHIVE_PATH" ]] || { print_error "Archive failed"; exit 1; }
    print_success "Archive: $ARCHIVE_PATH"
}

export_app() {
    print_step "Exporting Developer ID…"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTS" \
        | grep -E "^(Export|error:|warning:|\*\*)" || true
    [[ -d "$APP_PATH" ]] || { print_error "Export failed — no $APP_PATH"; ls -la "$EXPORT_PATH" 2>/dev/null || true; exit 1; }
    print_success "Exported: $APP_PATH"
}

verify_export() {
    print_step "Verifying signature + architectures..."
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    codesign -dvvv "$APP_PATH" 2>&1 | grep -E "Authority|Timestamp|Flags" || true
    if [[ -f "$APP_PATH/Contents/MacOS/$APP_NAME" ]]; then
        lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME" || true
    else
        lipo -info "$APP_PATH/Contents/MacOS/"* 2>/dev/null || true
    fi
    print_success "Signature OK"
}

notarize_app() {
    print_step "Notarizing app (zip → notarytool — may take several minutes)…"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    print_success "App notarized and stapled"
}

create_dmg() {
    print_step "Creating DMG (HFS-compressed app + Applications symlink)…"
    rm -f "$DMG_PATH"
    local stage="$BUILD_DIR/dmg-root"
    rm -rf "$stage"
    mkdir -p "$stage"
    # HFS+ decmpfs compression (BtnQ pattern): smaller download; transparent to codesign/stapler.
    ditto --hfsCompression "$APP_PATH" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create \
        -volname "$VOLNAME" \
        -srcfolder "$stage" \
        -ov -format UDZO \
        "$DMG_PATH"
    rm -rf "$stage"
    print_success "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

    print_step "Signing + notarizing DMG…"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    print_success "DMG notarized and stapled"
}

verify_gatekeeper() {
    print_step "Gatekeeper assessment…"
    echo "App:"
    spctl -a -vv "$APP_PATH" 2>&1 || true
    echo "DMG:"
    spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" 2>&1 || true
    print_success "Verification complete"
}

main() {
    echo "========================================="
    echo "  Katana notarized DMG"
    echo "========================================="
    cd "$ROOT"
    check_prerequisites
    clean_build
    archive_app
    export_app
    verify_export
    notarize_app
    create_dmg
    verify_gatekeeper
    echo ""
    print_success "Build complete!"
    echo "  App: $APP_PATH"
    echo "  DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
    # Also copy to dist/ for consistency with older docs
    mkdir -p "$ROOT/dist"
    cp -f "$DMG_PATH" "$ROOT/dist/$APP_NAME.dmg"
    echo "  Copy: $ROOT/dist/$APP_NAME.dmg"
}

main "$@"
