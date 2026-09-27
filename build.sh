#!/usr/bin/env bash
# AlwaysStrong-OMK build script.
#
# Assembles the flashable module ZIP out of three pieces:
#
#   module/                 our sources (AlwaysStrong v1.0.4 + the OhMyKeymint swap)
#   attest/omk.sh           the attestation-engine adapter, overlaid as attest.sh
#   native/*/prebuilt/      AlwaysStrong's own native helpers (asfetch, aswatcher)
#
# plus two upstream release payloads, which are never committed here:
#
#   OhMyKeymint 1.2.0-preview-a1f3241   libs/arm64-v8a/{keymint,inject},
#                                       injector.toml, keybox.xml
#   PlayIntegrityFork v18               classes.dex, zygisk/*.so, the PIF scripts
#
# Usage:
#   ./build.sh                      download both payloads, then build
#   ./build.sh --omk-file PATH      use a local OhMyKeymint zip, skip the download
#   ./build.sh --pif-file PATH      use a local PlayIntegrityFork zip, skip the download
#   ./build.sh --clean              wipe build/ and out/ first
#
# Output: out/AlwaysStrong-<version>.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/module"
OUT="$ROOT/out"

OMK_TAG="1.2.0-preview-a1f3241"
OMK_ASSET="OhMyKeymint-release-arm64-v8a-1.2.0-a1f3241.zip"
OMK_URL="https://github.com/qwq233/OhMyKeymint/releases/download/$OMK_TAG/$OMK_ASSET"

PIF_TAG="v18"
PIF_ASSET="PlayIntegrityFork-v18.zip"
PIF_URL="https://github.com/osm0sis/PlayIntegrityFork/releases/download/$PIF_TAG/$PIF_ASSET"

# Files lifted out of the PlayIntegrityFork zip into the module.
PIF_FILES="autopif4.sh killpi.sh migrate.sh common_setup.sh example.pif.prop app_replace_list.txt"

# ABIs that get AlwaysStrong's native helpers. OhMyKeymint itself is arm64-v8a
# only, which is why attest/omk.sh aborts the install on any other ABI.
ABIS="arm64-v8a armeabi-v7a x86 x86_64"
OMK_ABI="arm64-v8a"

OMK_FILE=""
PIF_FILE=""
CLEAN=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok()   { echo "    $*"; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --omk-file) OMK_FILE="$2"; shift 2 ;;
        --pif-file) PIF_FILE="$2"; shift 2 ;;
        --clean)    CLEAN=1; shift ;;
        -h|--help)  usage ;;
        *)          die "unknown option: $1" ;;
    esac
done

command -v unzip >/dev/null 2>&1 || die "unzip not found"
command -v zip   >/dev/null 2>&1 || die "zip not found"

fetch() {  # fetch <dest> <url>
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$1" "$2"
    else
        die "neither curl nor wget is available"
    fi
}

[ "$CLEAN" = 1 ] && { info "Cleaning"; rm -rf "$BUILD" "$OUT"; }

VERSION="$(sed -n 's/^version=//p' "$ROOT/module/module.prop" | head -n 1)"
[ -n "$VERSION" ] || die "module/module.prop has no version="
VERSION="${VERSION%% (*}"

# ---------- 1) our own files ----------
info "Staging module/ (AlwaysStrong $VERSION, OhMyKeymint engine)"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$ROOT/module/." "$STAGE/"

# The engine adapter is kept outside module/ so the swap stays visible.
cp "$ROOT/attest/omk.sh" "$STAGE/attest.sh"
ok "attestation engine: omk (attest/omk.sh -> attest.sh)"

if [ -f "$ROOT/banner.png" ]; then
    cp "$ROOT/banner.png" "$STAGE/banner.png"
    ok "bundled banner.png"
fi

# Native helper -> source path. The watcher's binary is called aswatcher but its
# crate directory is native/watcher, so the name is not enough to find it.
native_src() {  # native_src <bin> <abi>
    case "$1" in
        asfetch)   echo "$ROOT/native/asfetch/prebuilt/$2/asfetch" ;;
        aswatcher) echo "$ROOT/native/watcher/prebuilt/$2/aswatcher" ;;
        *)         echo "" ;;
    esac
}

for abi in $ABIS; do
    for bin in asfetch aswatcher; do
        src="$(native_src "$bin" "$abi")"
        if [ -n "$src" ] && [ -f "$src" ]; then
            mkdir -p "$STAGE/bin/$abi"
            cp "$src" "$STAGE/bin/$abi/$bin"
        fi
    done
done

# The module only installs on arm64-v8a (see attest/omk.sh), so a missing
# arm64-v8a helper means the native/ layout moved and the zip would silently
# ship without the fingerprint crawler or the watcher.
for bin in asfetch aswatcher; do
    [ -f "$STAGE/bin/$OMK_ABI/$bin" ] || die "native/$bin for $OMK_ABI was not staged — native/ layout changed"
done
ok "staged native helpers (asfetch, aswatcher)"

# ---------- 2) OhMyKeymint payload ----------
mkdir -p "$BUILD"
OMK_ZIP="$BUILD/$OMK_ASSET"
if [ -n "$OMK_FILE" ]; then
    [ -f "$OMK_FILE" ] || die "--omk-file not found: $OMK_FILE"
    OMK_ZIP="$OMK_FILE"
    ok "local OhMyKeymint zip: $OMK_ZIP"
elif [ ! -f "$OMK_ZIP" ]; then
    info "Downloading OhMyKeymint $OMK_TAG"
    fetch "$OMK_ZIP" "$OMK_URL"
fi

OMK_X="$BUILD/omk_extracted"
rm -rf "$OMK_X"; mkdir -p "$OMK_X"
unzip -qq -o "$OMK_ZIP" -d "$OMK_X"

for f in keymint inject; do
    [ -f "$OMK_X/libs/$OMK_ABI/$f" ] || die "OhMyKeymint zip missing libs/$OMK_ABI/$f — upstream layout changed"
done
[ -f "$OMK_X/injector.toml" ] || die "OhMyKeymint zip missing injector.toml — upstream layout changed"

mkdir -p "$STAGE/libs/$OMK_ABI"
cp "$OMK_X/libs/$OMK_ABI/keymint" "$STAGE/libs/$OMK_ABI/keymint"
cp "$OMK_X/libs/$OMK_ABI/inject"  "$STAGE/libs/$OMK_ABI/inject"
cp "$OMK_X/injector.toml"         "$STAGE/injector.toml"

# Default keybox, used only when the user has none of their own.
[ -f "$OMK_X/keybox.xml" ] && cp "$OMK_X/keybox.xml" "$STAGE/keybox.xml"
ok "staged OhMyKeymint payload ($OMK_ABI)"

# ---------- 3) PlayIntegrityFork payload ----------
PIF_ZIP="$BUILD/$PIF_ASSET"
if [ -n "$PIF_FILE" ]; then
    [ -f "$PIF_FILE" ] || die "--pif-file not found: $PIF_FILE"
    PIF_ZIP="$PIF_FILE"
    ok "local PlayIntegrityFork zip: $PIF_ZIP"
elif [ ! -f "$PIF_ZIP" ]; then
    info "Downloading PlayIntegrityFork $PIF_TAG"
    fetch "$PIF_ZIP" "$PIF_URL"
fi

PIF_X="$BUILD/pif_extracted"
rm -rf "$PIF_X"; mkdir -p "$PIF_X"
unzip -qq -o "$PIF_ZIP" -d "$PIF_X"

[ -f "$PIF_X/classes.dex" ] || die "PlayIntegrityFork zip missing classes.dex — upstream layout changed"
cp "$PIF_X/classes.dex" "$STAGE/classes.dex"

if [ -d "$PIF_X/zygisk" ]; then
    mkdir -p "$STAGE/zygisk"
    cp "$PIF_X/zygisk"/*.so "$STAGE/zygisk/"
fi

for f in $PIF_FILES; do
    [ -f "$PIF_X/$f" ] || die "PlayIntegrityFork zip missing $f — upstream layout changed"
    cp "$PIF_X/$f" "$STAGE/$f"
done
ok "staged PlayIntegrityFork payload"

# ---------- 4) permissions + package ----------
chmod 0755 "$STAGE"/*.sh 2>/dev/null || true
chmod 0755 "$STAGE/omk-daemon" "$STAGE/omk-injector" 2>/dev/null || true
chmod 0755 "$STAGE/libs/$OMK_ABI/keymint" "$STAGE/libs/$OMK_ABI/inject" 2>/dev/null || true
for abi in $ABIS; do
    chmod 0755 "$STAGE/bin/$abi/asfetch"  2>/dev/null || true
    chmod 0755 "$STAGE/bin/$abi/aswatcher" 2>/dev/null || true
done

mkdir -p "$OUT"
ZIP="$OUT/AlwaysStrong-${VERSION}.zip"
rm -f "$ZIP"
info "Packaging $ZIP"
( cd "$STAGE" && zip -qr9 "$ZIP" . )

ok "$(du -h "$ZIP" | cut -f1)  $ZIP"
