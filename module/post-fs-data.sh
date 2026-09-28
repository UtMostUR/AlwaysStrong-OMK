MODPATH="${0%/*}"
. $MODPATH/common_func.sh

# Our PIF zygisk binary is binary-patched at build time to read its dex/config
# from /data/adb/modules/tricky_store (our module dir) instead of the upstream
# hardcoded /data/adb/modules/playintegrityfix. So there is NO separate
# playintegrityfix folder to create here — everything lives under our module.
[ -f "$MODPATH/common_setup.sh" ] && . $MODPATH/common_setup.sh

# --- OhMyKeymint runtime roots (must exist before keystore2 starts) --------
# Creates /data/misc/keystore/omk (keystore-owned, 0770) and /data/adb/omk,
# clears the stale pidfiles / restart flags, restores upstream's omkdata link,
# and seeds keybox.xml + injector.toml for a fresh install. omk-sync.sh takes
# over from there at the service stage.
[ -f "$MODPATH/omk-early.sh" ] && sh "$MODPATH/omk-early.sh" 2>/dev/null

# --- Pin the KeyMint instance OMK seals its boot-level key with -----------
# OMK protects its whole store with a boot-level key, and which KeyMint instance
# seals that key is inferred at every keymint start unless
# ro.keystore.boot_level_key.strategy says otherwise (OMK's boot_key.rs probes
# TEE first, then StrongBox). The inference is NOT stable on a device whose TEE
# reports KeyMint < 4.1 while a StrongBox instance is also present: that path
# asks StrongBox whether it is up yet, and we start keymint at the service
# stage, before boot_completed. When the answer flips, the boot-level key blob
# was sealed by the other instance and can no longer be decrypted, so keymint
# dies with
#   fatal startup error: failed to initialize boot-level key cache
# and omk-daemon's recovery drops the entire store — every app key goes with it,
# GMS's attestation keys included, which is what turns Play Integrity red.
#
# Pin the TEE: it is always present (StrongBox may not have registered yet) and
# MAX_USES_PER_BOOT is understood by every KeyMint version, where EARLY_BOOT_ONLY
# needs 4.1+. Only set it when the ROM left it unset — a value fixed at build
# time is the vendor's decision and must not be overridden.
if [ -z "$(getprop ro.keystore.boot_level_key.strategy 2>/dev/null)" ]; then
    resetprop ro.keystore.boot_level_key.strategy TRUSTED_ENVIRONMENT:MAX_USES_PER_BOOT 2>/dev/null || true
fi

# --- DenyList: intentionally NOT managed ---------------------------------
# We must never force "Enforce DenyList" on. With Zygisk Next / ReZygisk /
# NeoZygisk (the recommended setup) plus a hider like Shamiko, enforcement is
# meant to stay OFF — the Zygisk implementation does the hiding, and turning
# Magisk's enforcement on can actually break it. A previous version called
# `magisk --denylist enable` here, which flipped a toggle users deliberately
# keep off. Leave the user's DenyList state exactly as they set it.

# --- Security patch level (attestation + Build consistency) ---------------
# Record the ROM's own patch level first. This runs before anything pins the
# props, so resetprop still reports the untouched value here — every boot, and
# it tracks an OTA automatically. sync_patch.sh uses it as the floor (never move
# a device's patch backwards) and as the date to fall back to when the user opts
# out of patch spoofing.
_ROMSP=$(resetprop ro.build.version.security_patch 2>/dev/null)
[ -z "$_ROMSP" ] && _ROMSP=$(getprop ro.build.version.security_patch 2>/dev/null)
_ROMP=$(echo "$_ROMSP" | tr -cd '0-9')
if [ ${#_ROMP} -eq 8 ]; then
    mkdir -p /data/adb/tricky_store 2>/dev/null
    printf '%s\n' "$_ROMP" > /data/adb/tricky_store/.rom_security_patch 2>/dev/null
fi

# Writes /data/adb/tricky_store/security_patch.txt for the TEE attestation and
# pins ro.build.version.security_patch to match the spoofed fingerprint.
[ -f "$MODPATH/sync_patch.sh" ] && sh "$MODPATH/sync_patch.sh" boot 2>/dev/null

# --- Bootloader / verified boot props (required for STRONG, harmless if already correct) ---

# Samsung
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.vendor.boot.warranty_bit 0
resetprop_if_diff ro.vendor.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.boot.fmp_config 1
resetprop_if_diff ro.boot.dp_fw_check 1

# Realme
resetprop_if_diff ro.boot.realmebootstate green

# OnePlus
resetprop_if_diff ro.is_ever_orange 0

# Encryption state
resetprop_if_diff ro.crypto.state encrypted

# VBMeta integrity chain (helps some devices reach DEVICE verdict)
resetprop_if_diff ro.boot.vbmeta.hash_alg sha256
resetprop_if_diff ro.boot.vbmeta.avb_version 1.0
resetprop_if_diff ro.boot.vbmeta.invalidate_on_error yes
for p in /dev/block/by-name/vbmeta /dev/block/by-name/vbmeta_a /dev/block/bootdevice/by-name/vbmeta; do
    [ -e "$p" ] && VBMETA_BLK="$p" && break
done
if [ -n "$VBMETA_BLK" ]; then
    VBMETA_SIZE=$(blockdev --getsize64 "$VBMETA_BLK" 2>/dev/null)
    [ -n "$VBMETA_SIZE" ] && resetprop_if_diff ro.boot.vbmeta.size "$VBMETA_SIZE"
fi

# Build tags / type — all variants (system, vendor, product, system_ext, etc.)
for PROP in $(resetprop | grep -oE 'ro.*.build.tags'); do
    resetprop_if_diff $PROP release-keys
done
for PROP in $(resetprop | grep -oE 'ro.*.build.type'); do
    resetprop_if_diff $PROP user
done

resetprop_if_diff ro.adb.secure 1
if ! $SKIPDELPROP; then
    delprop_if_exist ro.boot.verifiedbooterror
    delprop_if_exist ro.boot.verifyerrorpart
fi
resetprop_if_diff ro.boot.veritymode.managed yes
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.force.debuggable 0
resetprop_if_diff ro.secure 1

# Strip custom-ROM build leaks (LineageOS, crDroid, etc.). These props are a
# tell to PI, BUT they are also what Settings → About phone reads to show the
# ROM version. Play Integrity relies on the fingerprint / bootloader / keybox
# and the zygisk's per-process Build.* spoof — NOT on these globally-visible
# props — so deleting them device-wide buys almost no integrity while it breaks
# the ROM-version display (shows "unknown"). Preserve them by default; only
# scrub when the user opts in via the WebUI Advanced tab.
#   Opt-in:  touch /data/adb/tricky_store/hide_rom_markers
if [ -f /data/adb/tricky_store/hide_rom_markers ]; then
    for PROP in ro.lineage.build.version ro.lineage.version ro.lineage.display.version \
                ro.modversion ro.cm.version \
                ro.crdroid.version ro.crdroid.display.version ro.crdroid.build.version; do
        delprop_if_exist "$PROP" 2>/dev/null || true
    done
fi

# Disable ROM-level spoof engines (PixelPropsUtils / pihooks / entryhooks)
# before GMS starts. Gated by /data/adb/tricky_store/no_rom_spoof_block flag.
if [ -x "$MODPATH/rom_spoof_block.sh" ]; then
    sh "$MODPATH/rom_spoof_block.sh" 2>/dev/null || true
fi
