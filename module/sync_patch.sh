#!/system/bin/sh
# AlwaysStrong — keep the security patch level consistent across three places:
#   1. /data/adb/tricky_store/security_patch.txt  — the patch level a
#      TrickyStore-style engine stamps into the hardware attestation.
#   2. *.security_patch in the active pif file    — what PIF's zygisk reports to
#      GMS and to every app it hooks.
#   3. ro.build.version.security_patch system props — what Build.VERSION and the
#      apps PIF does NOT hook read. OhMyKeymint's config.toml keeps its patch
#      fields on "auto", so the engine's attestation follows these props too.
#
# All three must carry the SAME date: attestation checkers flag a mismatch
# between the OS patch (props) and the attested osPatchLevel (security_patch.txt
# / the engine). Earlier versions could drift apart two ways — the hourly
# refresh only rewrote security_patch.txt, and turning patch spoofing off moved
# the props to the real date while the other two stayed spoofed. Both are gone:
# every landing point is written from one computed value, EFF.
#
# Which date EFF is:
#   - default: the fingerprint's SECURITY_PATCH, but never older than the ROM's
#     own patch (an OTA that outruns the fingerprint keeps the newer real date).
#   - opt-out (/data/adb/tricky_store/no_spoof_patch_props): the ROM's real date
#     everywhere — nothing is spoofed on any of the three.
#
# The ROM's real patch is captured by post-fs-data.sh before anything pins the
# props, into $CONFIG_DIR/.rom_security_patch.
#
# Usage:
#   sh sync_patch.sh         # security_patch.txt + pif only (install / hourly)
#   sh sync_patch.sh boot    # also pin the system props (post-fs-data / Action)

case "$0" in
    */*) MODPATH=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
    *)   MODPATH="$PWD" ;;
esac
[ -z "$MODPATH" ] && MODPATH="$PWD"
CONFIG_DIR=/data/adb/tricky_store
MODE="${1:-}"

# --- find the dotted patch (YYYY-MM-DD) from a pif file -------------------
SP=""
SRC=""
for f in "$CONFIG_DIR/custom.pif.prop" "$CONFIG_DIR/pif.prop" \
         "$MODPATH/custom.pif.prop" "$MODPATH/pif.prop"; do
    [ -s "$f" ] || continue
    SP=$(grep -m1 '^SECURITY_PATCH=' "$f" | cut -d= -f2- | tr -d ' "'\''\r')
    [ -n "$SP" ] && { SRC="$f"; break; }
done

# Feed TEESimulator's PatchLevelManager its expected PIF prop at the global
# path it watches (/data/adb/pif.prop). It auto-derives the attestation patch
# level + resetprops ro.build.version.security_patch from this file, keeping
# the keystore attestation in lock-step with the Build/* fingerprint PIF
# spoofs. (The module-folder path it also checks no longer exists by design.)
# Only TEESimulator-RS's PatchLevelManager reads this global path. Every other
# engine — OhMyKeymint included — would just see a stray, world-readable copy of
# the spoofed pif, so write it only when RS is active and clear any stale copy
# left from a previous engine.
if grep -q '^ATTEST=tee$' "$MODPATH/attest.sh" 2>/dev/null; then
    if [ -n "$SRC" ] && [ "$SRC" != "/data/adb/pif.prop" ]; then
        cp -f "$SRC" /data/adb/pif.prop 2>/dev/null && chmod 644 /data/adb/pif.prop 2>/dev/null
    fi
else
    rm -f /data/adb/pif.prop 2>/dev/null
fi
# fall back to whatever the device already reports
[ -z "$SP" ] && SP=$(getprop ro.build.version.security_patch 2>/dev/null)
[ -z "$SP" ] && exit 1

# normalise: RAW = 8 digits, PACKED = YYYYMMDD, DOT = YYYY-MM-DD
RAW=$(echo "$SP" | tr -cd '0-9')
[ ${#RAW} -ne 8 ] && exit 1
PACKED="$RAW"
DOT="$(echo "$RAW" | cut -c1-4)-$(echo "$RAW" | cut -c5-6)-$(echo "$RAW" | cut -c7-8)"

# --- the ROM's own patch level (captured before the props were ever pinned) --
REAL=$(cat "$CONFIG_DIR/.rom_security_patch" 2>/dev/null | tr -cd '0-9')
[ ${#REAL} -ne 8 ] && REAL=""

OPTOUT=0; [ -f "$CONFIG_DIR/no_spoof_patch_props" ] && OPTOUT=1
# FORCE is the WebUI's "Unified patch date" row turned OFF: pin the fingerprint's
# own date even when the ROM's real patch is newer. That is the pre-r3 behaviour,
# kept as an experimental A/B probe — not a fix for a Tampered Attestation Key
# verdict, which is normally a keybox problem.
FORCE=0;  [ -f "$CONFIG_DIR/spoof_patch_props" ] && FORCE=1

# --- EFF: the one value every landing point is written from ---------------
if [ "$OPTOUT" = 1 ]; then
    # user wants the untouched ROM date everywhere
    EFF="$REAL"; [ -z "$EFF" ] && EFF="$PACKED"
elif [ "$FORCE" = 0 ] && [ -n "$REAL" ] && [ "$REAL" -ge "$PACKED" ]; then
    # never move a device's patch backwards: keep the newer real date
    EFF="$REAL"
else
    EFF="$PACKED"
fi
EFF_DOT="$(echo "$EFF" | cut -c1-4)-$(echo "$EFF" | cut -c5-6)-$(echo "$EFF" | cut -c7-8)"

mkdir -p "$CONFIG_DIR"

# --- 1. attestation patch level (TrickyStore / TEESimulator-RS / OhMyKeymint)
# `all=<YYYY-MM-DD>` overrides every partition's patch level in the generated
# attestation chain. Dotted form matches what autopif4 writes and what the
# working reference module ships, so the two never fight over format.
NEW_SP="all=$EFF_DOT"
OLD_SP=$(cat "$CONFIG_DIR/security_patch.txt" 2>/dev/null)
printf '%s\n' "$NEW_SP" > "$CONFIG_DIR/security_patch.txt"

# OMK resolves its patch level from the system props when keymint starts (its
# config.toml fields stay on "auto" so it follows this same date), so a patch
# that moved after startup only reaches the attestation on a keymint restart.
# Bounce it here, and only when it actually moved — the post-fs-data call runs
# before keymint exists and is skipped by the pidof guard.
if [ "$OLD_SP" != "$NEW_SP" ] && pidof keymint >/dev/null 2>&1 && \
   grep -q '^ATTEST=omk$' "$MODPATH/attest.sh" 2>/dev/null; then
    : > /data/adb/omk/restart.keymint 2>/dev/null
fi

# --- 2. PIF wildcard prop: spoof ro.build/ro.vendor/ro.system .security_patch
# A single `*.security_patch=<date>` line makes PIF's zygisk hook report the
# patch consistently to every app (this is what GMS / Play Integrity reads).
for pf in "$MODPATH/custom.pif.prop" "$CONFIG_DIR/custom.pif.prop"; do
    [ -f "$pf" ] || continue
    if grep -qE '^[#]?\*\.security_patch=' "$pf"; then
        sed -i "s|^[#]\?\*\.security_patch=.*|*.security_patch=$EFF_DOT|" "$pf"
    else
        printf '*.security_patch=%s\n' "$EFF_DOT" >> "$pf"
    fi
done

# --- 3. real system props (boot only — needs resetprop) -------------------
# What every app that PIF does NOT hook reads: Build.VERSION.SECURITY_PATCH,
# getprop. Banking apps and attestation checkers compare that against the
# osPatchLevel in the hardware attestation (security_patch.txt above) and flag a
# mismatch. EFF is already the newer of {fingerprint patch, ROM patch}, so this
# is idempotent: on a default boot it pins the spoofed date, and with the
# opt-out set it restores the ROM's real date.
if [ "$MODE" = "boot" ] && command -v resetprop >/dev/null 2>&1; then
    if [ "$OPTOUT" = 1 ] && [ -z "$REAL" ]; then
        # opted out but the ROM date was never captured — nothing safe to write
        :   # leave the props alone; the next boot captures it
    else
        for p in ro.build.version.security_patch \
                 ro.vendor.build.security_patch \
                 ro.system.build.version.security_patch; do
            cur=$(resetprop "$p" 2>/dev/null)
            [ -n "$cur" ] || continue
            [ "$cur" = "$EFF_DOT" ] && continue
            resetprop -n "$p" "$EFF_DOT"
        done
    fi
fi

echo "$EFF_DOT"