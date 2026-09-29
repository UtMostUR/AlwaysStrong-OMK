#!/system/bin/sh
# AlwaysStrong uninstall — clean every artifact we created.

MODDIR=${0%/*}
CONFIG_DIR=/data/adb/tricky_store

# Kill every process this module's attestation engine may have started. OMK's
# two supervisor loops are shell scripts, so they are matched by command line;
# its keymint binary is matched by name.
for proc in keymint TEESimulator supervisor daemon TrickyStoreOSS; do
    for pid in $(pidof "$proc" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null
    done
done
pkill -9 -f 'omk-daemon' 2>/dev/null || true
pkill -9 -f 'omk-injector' 2>/dev/null || true
pkill -9 -f TEESimulator 2>/dev/null || true
pkill -9 -f org.matrix.TEESimulator 2>/dev/null || true
pkill -9 -f io.github.beakthoven.TrickyStoreOSS 2>/dev/null || true

# Kill GMS + Vending so they reload without our hooks
killall -9 com.google.android.gms.unstable 2>/dev/null
killall -9 com.google.android.gms 2>/dev/null
am force-stop com.android.vending 2>/dev/null

# --- OMK runtime state: keep the key store --------------------------------
# Do NOT delete OMK's two roots here. /data/misc/keystore/omk/data is OMK's key
# store: every key OMK minted lives in it, including the attestation key GMS
# uses for Play Integrity, sealed by the [crypto] seeds in the config.toml
# beside it. Removing the module does not put those keys back on the system
# backend, so deleting the store destroys them for good.
#
# That mattered here because this module is routinely uninstalled and reinstalled
# across builds: every version bump done that way threw the store away, GMS lost
# its attestation key, and Play Integrity stayed red until GMS re-provisioned —
# which reads exactly like a regression in the build that happened to be installed
# at the time. Keeping the store also keeps config.toml and its seeds, so a
# reinstall finds a decryptable store instead of dropping and rebuilding one.
#
# Only our own transient state is cleared; omk-early.sh recreates anything else
# it needs on the next boot. A user who genuinely wants a clean slate can still
# delete /data/misc/keystore/omk and /data/adb/omk by hand.
rm -f /data/adb/omk/keymint-daemon.pid /data/adb/omk/injector-daemon.pid 2>/dev/null
rm -f /data/adb/omk/restart.keymint /data/adb/omk/restart.injector \
      /data/adb/omk/restart.all 2>/dev/null
rm -rf "$CONFIG_DIR/persistent_keys"
rm -f "$CONFIG_DIR/tee_status.txt"
rm -f "$CONFIG_DIR/boot_hash.bin" "$CONFIG_DIR/boot_key.bin"
# ROM real patch cache captured by post-fs-data.sh — pure cache, rebuilt on the
# next install/boot.
rm -f "$CONFIG_DIR/.rom_security_patch"

# Global PIF prop we dropped for the TEE PatchLevelManager (sync_patch.sh)
rm -f /data/adb/pif.prop

# A stale playintegrityfix folder from a very old shim-based AlwaysStrong build
# can be cleaned up here — but this exact path is ALSO where a user's OWN
# standalone PlayIntegrityFork / Fix inject-s lives (the module id is shared, and
# the "Lite" line depends on that separate module). Never delete the user's real
# module on uninstall: on the Lite line (ENGINE=none) the folder is always theirs,
# and on any line a folder whose module.prop identifies a real Fork / Fix inject-s
# / Integrity Box is theirs too. Only remove a folder that is clearly not a live
# third-party module (a true leftover shim with no recognizable module.prop).
PIF_MOD=/data/adb/modules/playintegrityfix
if [ -d "$PIF_MOD" ]; then
    keep_pif=0
    [ -f "$MODDIR/engine.sh" ] && grep -q '^ENGINE=none' "$MODDIR/engine.sh" 2>/dev/null && keep_pif=1
    if [ "$keep_pif" = 0 ] && [ -f "$PIF_MOD/module.prop" ]; then
        grep -qiE 'Fork|osm0sis|PlayIntegrityFix|inject|chiteroman|KOWX712|MeowDump|ntegrity.?[Bb]ox|webuiIcon' \
            "$PIF_MOD/module.prop" 2>/dev/null && keep_pif=1
    fi
    [ "$keep_pif" = 0 ] && rm -rf "$PIF_MOD" 2>/dev/null
fi

# Restore ROM-level spoof engines that rom_spoof_block.sh disabled, so removing
# AlwaysStrong frees the ROM's own PixelProps / pihooks / entryhooks again.
# Only clear a prop if it STILL holds the exact "disabled" value we wrote — that
# way we never clobber a value the ROM set for itself. Takes effect next boot.
revert_spoof() {
    [ "$(resetprop "$1" 2>/dev/null)" = "$2" ] && resetprop -p --delete "$1" 2>/dev/null
}
revert_spoof persist.sys.pihooks.disable.gms_props                 true
revert_spoof persist.sys.pihooks.disable.gms_key_attestation_block true
revert_spoof persist.sys.entryhooks_enabled                        false
revert_spoof persist.sys.spoof.gms                                 false
revert_spoof persist.sys.pixelprops.gms                            false
revert_spoof persist.sys.pixelprops.gapps                          false
revert_spoof persist.sys.pixelprops.google                         false
revert_spoof persist.sys.pixelprops.pi                             false
revert_spoof persist.sys.pp.gms                                    false
revert_spoof persist.sys.pp.finsky                                 false
revert_spoof persist.sys.pihooks.first_api_level                   ""
revert_spoof persist.sys.pihooks.security_patch                    ""

# Keep keybox.xml and security_patch.txt — user may want them for reinstall.
