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
#   - default: the fingerprint's own SECURITY_PATCH — the pre-r3 behaviour, and
#     the only combination that is internally consistent for a canary
#     fingerprint (its patch can never postdate its own build).
#   - opt-in (/data/adb/tricky_store/unified_patch_date — the WebUI's "Unified
#     patch date" test row): the newer of the fingerprint's date and the ROM's
#     real one, so an OTA that outruns the fingerprint keeps the newer real date.
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
# UNIFIED is the WebUI's "Unified patch date" row turned ON. It is opt-in and
# OFF by default, so a fresh install and an upgrade both behave exactly like
# r2fix: the fingerprint's own date, never the ROM's newer one.
UNIFIED=0; [ -f "$CONFIG_DIR/unified_patch_date" ] && UNIFIED=1
# r4 shipped this switch with the opposite polarity (the flag meant "strict").
# It is gone; drop a stray copy so an upgrade can't carry a dead state around.
rm -f "$CONFIG_DIR/spoof_patch_props" 2>/dev/null

# --- EFF: the one value every landing point is written from ---------------
if [ "$OPTOUT" = 1 ]; then
    # user wants the untouched ROM date everywhere
    EFF="$REAL"; [ -z "$EFF" ] && EFF="$PACKED"
elif [ "$UNIFIED" = 1 ] && [ -n "$REAL" ] && [ "$REAL" -ge "$PACKED" ]; then
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
#
# This write is the one that used to fail silently: on some ROMs the bare
# toybox `sed -i` used here does not modify the file (the same edit through the
# busybox sed engine.sh prefers does), and nothing noticed while EFF still
# equalled the fingerprint's own date — migrate.sh had already written that
# value, so the file looked right either way. The moment the unified date
# differed, the PIF kept the fingerprint's date while security_patch.txt and the
# props moved, which is the three-way mismatch that goes red on all three Play
# Integrity verdicts. So: use the busybox sed, then read the value back, and
# rebuild the file outright if the edit did not land.
BB=""
for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
           /data/adb/modules/busybox-ndk/system/*/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$_bb" ] && [ -x "$_bb" ] && BB="$_bb" && break
done
SED_I="sed -i"; [ -n "$BB" ] && SED_I="$BB sed -i"

set_pif_patch() {  # set_pif_patch <pif file> <YYYY-MM-DD>
    _f="$1"; _d="$2"
    [ -s "$_f" ] || return 0
    if grep -qE '^[#]?\*\.security_patch=' "$_f"; then
        $SED_I "s|^[#]\?\*\.security_patch=.*|*.security_patch=$_d|" "$_f" 2>/dev/null
    else
        printf '*.security_patch=%s\n' "$_d" >> "$_f"
    fi
    [ "$(grep -m1 -E '^\*\.security_patch=' "$_f" | cut -d= -f2- | tr -d ' \r')" = "$_d" ] && return 0
    # In-place edit didn't take: rewrite the file without an editor. The rest of
    # the prop (fingerprint, spoof flags) is preserved; only the patch lines are
    # regenerated. `cat` back over the same inode keeps its mode and context.
    _t="$_f.tmp.$$"
    grep -vE '^[#]?\*\.security_patch=' "$_f" > "$_t" 2>/dev/null || cp -f "$_f" "$_t"
    printf '*.security_patch=%s\n' "$_d" >> "$_t"
    cat "$_t" > "$_f" 2>/dev/null
    rm -f "$_t"
}
for pf in "$MODPATH/custom.pif.prop" "$CONFIG_DIR/custom.pif.prop"; do
    set_pif_patch "$pf" "$EFF_DOT"
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