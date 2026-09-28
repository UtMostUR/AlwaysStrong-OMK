#!/system/bin/sh
MODDIR="${0%/*}"
MODPATH="$MODDIR"
cd "$MODDIR"

set +o standalone 2>/dev/null
unset ASH_STANDALONE

[ -f "$MODDIR/common_func.sh" ] && . "$MODDIR/common_func.sh"

# --- Play Integrity engine adapter ---
# Which prop file the zygisk reads, and what its spoof flags are called, is all
# that differs between the two builds. engine.sh owns it; everything below is
# identical in both.
CONFIG_DIR=/data/adb/tricky_store
if [ -f "$MODDIR/engine.sh" ]; then
    . "$MODDIR/engine.sh"
else
    log -t "AlwaysStrong" "engine.sh missing — no fingerprint handling this boot"
    engine_autopif()       { return 1; }
    engine_install_pif()   { return 1; }
    engine_enforce_spoof() { return 0; }
    ENGINE=none
fi

# --- Attestation engine adapter (OhMyKeymint) ------------------------------
# attest.sh owns the engine's install / start / liveness / sync logic; every
# call below goes through it. The fallbacks keep the shared half of this script
# (props, conflict scan, watchdog, hourly refresh) working if it is somehow
# missing, without pretending an engine is up.
if [ -f "$MODDIR/attest.sh" ]; then
    . "$MODDIR/attest.sh"
else
    log -t "AlwaysStrong" "attest.sh missing — no attestation engine this boot"
    attest_early() { return 1; }
    attest_start() { :; }
    attest_alive() { return 1; }
    attest_sync() { return 0; }
    attest_ensure_injection() { return 0; }
fi

# An engine that hijacks keystore2 must start at the service stage, before
# sys.boot_completed: keystore2 comes up early, and a supervisor started after
# the boot-completed wait below misses the window it has to win. OMK returns
# true here for exactly that reason.
#
# The engine also reads the verified-boot state when it builds the attestation
# rootOfTrust, and those lock-state props are otherwise only asserted in the late
# block below (after boot_completed). Pin them here first so the engine reads
# green/locked from its very first request; the late block re-asserts them for
# OEMs that reset them during boot.
if attest_early 2>/dev/null; then
    resetprop_if_diff ro.boot.verifiedbootstate green
    resetprop_if_diff vendor.boot.verifiedbootstate green
    resetprop_if_diff ro.boot.vbmeta.device_state locked
    resetprop_if_diff vendor.boot.vbmeta.device_state locked
    resetprop_if_diff ro.boot.flash.locked 1
    resetprop_if_diff ro.secureboot.lockstate locked
    resetprop_if_diff ro.boot.veritymode enforcing
    resetprop_if_diff vendor.boot.veritymode enforcing
    attest_start
fi

# --- Recovery mode guard ---
resetprop_if_match ro.boot.mode recovery unknown
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match ro.boot.bootmode recovery unknown
resetprop_if_match vendor.boot.mode recovery unknown
resetprop_if_match vendor.boot.bootmode recovery unknown

# --- SELinux enforcement ---
resetprop_if_diff ro.boot.selinux enforcing
if ! ${SKIPDELPROP:-false}; then
    delprop_if_exist ro.build.selinux 2>/dev/null || true
fi
if [ "$(toybox cat /sys/fs/selinux/enforce 2>/dev/null)" = "0" ]; then
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
fi

# --- Late properties (after boot_completed) — required for some OEMs ---
{
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# Verified-boot / bootloader-lock fingerprint
resetprop_if_diff ro.secureboot.lockstate locked
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.realme.lockstate 1
resetprop_if_diff ro.boot.vbmeta.device_state locked
resetprop_if_diff vendor.boot.verifiedbootstate green
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff vendor.boot.veritymode enforcing
resetprop_if_diff vendor.boot.vbmeta.device_state locked
resetprop_if_diff sys.oem_unlock_allowed 0
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.secure 1
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.adb.secure 1
resetprop_if_diff service.adb.root 0
resetprop_if_diff ro.boot.vbmeta.invalidate_on_error yes

# --- LineageOS prop scrub (hide derivative-ROM markers from PI checks) ---
# Low-risk cosmetic strips (vendor name prefix, Aperture camera package list)
# run always — they don't affect any Settings UI. The riskier deletes that can
# break ROM features are gated behind the opt-in hide_rom_markers flag.
LV=$(getprop ro.product.vendor.name 2>/dev/null)
case "$LV" in
    lineage_*) resetprop -n ro.product.vendor.name "${LV#lineage_}" ;;
esac
for LP in vendor.camera.aux.packagelist persist.vendor.camera.privapp.list; do
    LCV=$(getprop "$LP" 2>/dev/null)
    case "$LCV" in
        *org.lineageos.aperture*)
            LCV=$(echo "$LCV" | sed -e 's/,org\.lineageos\.aperture//g' \
                                    -e 's/org\.lineageos\.aperture,//g' \
                                    -e 's/^org\.lineageos\.aperture$//')
            resetprop -n "$LP" "$LCV"
            ;;
    esac
done
# Lineage Health HAL: LineageOS Settings shows the "Fast charging" / charging
# control toggles only when init.svc.vendor.lineage_health reports "running";
# deleting the prop makes Settings believe the HAL is down and HIDES the whole
# toggle (reported on LineageOS — the fast-charging switch disappears). The
# "lineage" in the prop name is a PI tell, but PI doesn't read init.svc.*, so
# dropping it costs the user a real feature for no integrity gain. Preserve by
# default; only delete when the user opts into aggressive marker hiding. See
# issue #7.
#   Opt-in:  touch /data/adb/tricky_store/hide_rom_markers
[ -f "$CONFIG_DIR/hide_rom_markers" ] && \
    resetprop --delete init.svc.vendor.lineage_health 2>/dev/null
}&

# --- Conflict re-scan on every boot ---
# A user can install a conflicting module AFTER they've installed AlwaysStrong
# (the install-time scan in customize.sh only fires once). Re-run the same
# disable-known-conflicts pass at every boot so a fresh install of e.g.
# playintegrityfix doesn't silently break our hooks.
if [ -x "$MODDIR/conflict_scan.sh" ]; then
    MODPATH="$MODDIR" sh "$MODDIR/conflict_scan.sh" >/dev/null 2>&1
    n=$?
    [ "$n" -gt 0 ] && log -t "AlwaysStrong" "disabled $n conflicting module(s) at boot"
fi

# --- Wait for boot, then start the attestation engine ---
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done

# Kill stale processes left by a previous engine or service run. The active
# engine's own daemons are deliberately NOT in this list: they were started
# early (above), and killing one would drop a live keystore2 injection that a
# post-boot restart cannot cleanly recover. OMK's supervisor loops are shell
# scripts whose process name is just "sh", so a name match never catches them
# here anyway.
for proc in supervisor daemon TEESimulator aswatcher; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# (Re)start the active engine's daemon whenever it isn't alive — keyed on
# liveness, not on attest_early. An engine the sweep or a crash took down is
# revived immediately instead of waiting on the ~2 min watchdog.
if ! attest_alive 2>/dev/null; then
    attest_start
fi

# Mirror the config dir into the engine's own runtime dir. Cheap and idempotent
# (see omk-sync.sh): a fresh install is still waiting for keymint to create
# config.toml here, which the settle block below handles.
attest_sync 2>/dev/null

# --- OhMyKeymint: settle the config once the engine is up ------------------
# OMK's config.toml only exists after keymint has written it, and omk-sync.sh
# skips that half until then. keymint starts at the service stage, so the single
# sync above usually lands before the file exists. Poll briefly instead of
# leaving it to the hourly pass, so a fresh install reaches DEVICE / STRONG on
# the first boot rather than an hour later.
if [ "${ATTEST:-}" = omk ]; then
{
    i=0
    while [ $i -lt 20 ]; do
        sleep 6
        attest_sync 2>/dev/null
        if [ -n "$OMK_CONFIG" ] && [ -s "$OMK_CONFIG" ] && \
           grep -qE '^[[:space:]]*device_locked[[:space:]]*=[[:space:]]*true' "$OMK_CONFIG" 2>/dev/null; then
            break
        fi
        i=$((i+1))
    done
    attest_ensure_injection 2>/dev/null
}&
fi

# --- aswatcher native daemon (inotify target.txt + Xposed + conflict) ---
case "$(uname -m)" in
    aarch64)       AS_ABI=arm64-v8a ;;
    armv7*|armv8l) AS_ABI=armeabi-v7a ;;
    x86_64)        AS_ABI=x86_64 ;;
    i?86)          AS_ABI=x86 ;;
    *)             AS_ABI="" ;;
esac
AS_BIN="$MODDIR/bin/$AS_ABI/aswatcher"
if [ -x "$AS_BIN" ]; then
    {
        sleep 5
        "$AS_BIN" &
        log -t "AlwaysStrong" "aswatcher launched ($AS_ABI)"
    } &
fi

# --- Anti-detection hardening (each opt-out via a no_* flag) --------------
# Runs after the engine + aswatcher daemons are up. All three degrade quietly if
# their prerequisites are missing (no pif yet, SELinux blocks /proc writes).
{
    CFG=/data/adb/tricky_store
    sleep 8   # let the engine daemons + aswatcher come up first

    # NOTE: prop_unify.sh (global resetprop of ro.product.*) ships but is
    # deliberately never invoked, on either engine. Both spoof Build/ro.product.*
    # where Play Integrity looks, so a global resetprop buys no integrity — and it
    # leaks the spoofed model to every process, so the device shows up as e.g.
    # "Pixel 10" in scrcpy/ADB. It stays in the tree for manual use only.

    # Suppress our log tags + scrub ANR/tombstone traces (self-daemonizes).
    if [ ! -f "$CFG/no_logcat_cleanup" ] && [ -f "$MODDIR/logcat_cleanup.sh" ]; then
        MODPATH="$MODDIR" sh "$MODDIR/logcat_cleanup.sh" >/dev/null 2>&1 &
    fi
} &

# --- VBMeta digest (deferred, bounded) ---
# Reading the whole vbmeta partition during early boot can hang the boot
# animation on some Xiaomi devices. Skip if already set, only read 64KiB.
{
sleep 60
CURRENT_DIGEST=$(resetprop ro.boot.vbmeta.digest)
if [ -z "$CURRENT_DIGEST" ] || echo "$CURRENT_DIGEST" | grep -qE '^0+$'; then
    for p in /dev/block/by-name/vbmeta /dev/block/by-name/vbmeta_a /dev/block/bootdevice/by-name/vbmeta; do
        [ -e "$p" ] && VBMETA_BLK="$p" && break
    done
    if [ -n "$VBMETA_BLK" ]; then
        DIGEST=$(dd if="$VBMETA_BLK" bs=4096 count=16 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
        if [ -n "$DIGEST" ]; then
            resetprop -n ro.boot.vbmeta.digest "$DIGEST"
            log -t "AlwaysStrong" "VBMeta digest set: ${DIGEST:0:16}..."
        fi
    fi
fi
}&

# --- Housekeeping in background ---
{
    sleep 3
    # Hide TWRP-style recovery folders on /sdcard if empty
    for rdir in TWRP Fox OrangeFox PBRP PitchBlack Recovery; do
        target="/sdcard/$rdir"
        if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
            mv "$target" "/data/adb/.recovery_backup_${rdir}" 2>/dev/null
        elif [ -d "$target" ]; then
            rmdir "$target" 2>/dev/null
        fi
    done
    rm -f /sdcard/.twrps 2>/dev/null
}&

# --- attestation engine + aswatcher watchdog ---
{
    while true; do
        sleep 120
        if ! attest_alive; then
            log -t "AlwaysStrong" "attestation daemon died, restarting..."
            attest_start
        fi
        # Re-mirror the config dir into the engine's runtime dir, and catch an
        # injection that lost the race against keystore2's RPC socket. Both are
        # cheap no-ops when there is nothing to do; see attest.sh.
        attest_sync 2>/dev/null
        attest_ensure_injection 2>/dev/null
        if [ -x "$AS_BIN" ] && ! pidof aswatcher >/dev/null 2>&1; then
            log -t "AlwaysStrong" "aswatcher died, restarting..."
            "$AS_BIN" &
        fi
    done
}&

# --- First-boot auto-action (once per install) ---------------------------
# One automatic press of [Action] on the FIRST boot after install, so a fresh
# install lands STRONG without the user ever opening the WebUI. First boot only
# on purpose — a plain reboot does NOT re-run it; ongoing refresh is the hourly
# loop's job.
#
# It runs the real action.sh, the exact same path a manual press takes: build
# the target list, fetch the fingerprint with all three sources (native crawl,
# upstream fetcher, then the shipped local props as a guaranteed fallback),
# enforce the STRONG spoof flags, sync the security patch, and restart PI. The
# old inline copy here skipped the target-list build and the local fingerprint
# fallback, so on a first boot where the network crawl wasn't ready yet it left
# no usable fingerprint and the device sat at BASIC until a manual press —
# which is exactly the "first-boot Action doesn't happen" bug. Calling action.sh
# means there is only one copy of that logic and no weaker duplicate to drift.
#
# The .bootstrapped marker lives in MODDIR, which is wiped on uninstall/update,
# so a reinstall re-bootstraps but a reboot doesn't.
if [ ! -f "$MODDIR/.bootstrapped" ]; then
{
    # Right as the device comes up — no long pre-wait. Only a short settle so
    # GMS has started, then a brief network probe (cap ~12s) and go: action.sh
    # has a guaranteed local-fingerprint fallback, so it reaches STRONG even
    # before the network is ready, and the hourly loop later refreshes to a
    # freshly fetched fingerprint. (Lite's standalone-PIF timing is handled by
    # the separate every-boot re-sync below, so no extra wait is needed here.)
    sleep 5
    j=0
    until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
        j=$((j+1)); [ $j -gt 6 ] && break
        sleep 2
    done
    log -t "AlwaysStrong-boot" "first boot: auto-pressing Action"

    # Run action.sh under busybox ash: its `set +o standalone` line needs ash,
    # and toybox sh (some ROMs' default) aborts there. Fall back to plain sh
    # (this service already runs under the manager's ash) if no busybox is found.
    BB=""
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
              /data/adb/modules/busybox-ndk/system/*/busybox; do
        [ -x "$bb" ] && BB="$bb" && break
    done
    if [ -n "$BB" ]; then
        AS_FAST=1 "$BB" sh "$MODDIR/action.sh" >/data/adb/tricky_store/.action_boot.log 2>&1
    else
        AS_FAST=1 sh "$MODDIR/action.sh" >/data/adb/tricky_store/.action_boot.log 2>&1
    fi

    touch "$MODDIR/.bootstrapped"
    log -t "AlwaysStrong-boot" "first boot: Action done"
}&
fi

# --- Lite + standalone PIF: re-sync shortly after every boot -------------
# Separate from the first-boot Action above and NOT one-shot: a standalone
# PlayIntegrityFork/Fix re-runs its own autopif on every boot and resets the
# spoof flags to weak defaults (Fork: spoofVendingFinger 1 -> 0), which would
# drop the Lite verdict after a plain reboot. Once its boot autopif has had time
# to land, mirror its fingerprint into the attested identity and re-assert the
# STRONG flags. No-op on the other lines and when no PIF is installed; the hourly
# loop keeps it in sync from there.
if grep -q '^ENGINE=none' "$MODDIR/engine.sh" 2>/dev/null; then
    { sleep 90; sh "$MODDIR/lite_pif_sync.sh" 2>&1 | log -t "AlwaysStrong-boot"; } &
fi

# --- Hourly refresh (fingerprint + keybox, each toggle-able from WebUI) --
# WebUI writes flag files into /data/adb/tricky_store/ to opt OUT:
#   no_auto_fp      -> skip the fingerprint refresh
#   no_auto_keybox  -> skip the keybox fetch
# The patch refresh runs in boot mode so a fingerprint that moved the security
# patch re-pins the system props too, not just security_patch.txt — otherwise the
# props kept the old date until the next reboot and the OS-patch / osPatchLevel
# check flagged a mismatch. sync_patch.sh is idempotent, so this is a no-op on
# the hours where nothing moved.
# Keybox-only restarts PI when it actually changed (exit 0); fingerprint
# updates are picked up naturally on the next PI invocation, so we don't
# kick running banking apps for cosmetic refreshes.
{
    CFG=/data/adb/tricky_store
    export MODPATH="$MODDIR"
    while true; do
        # Interval is user-configurable from the WebUI. Default 1h, floor 60s
        # so a misconfigured 0/-1/garbage doesn't busy-spin the loop.
        INT=$(cat "$CFG/hourly_interval_sec" 2>/dev/null)
        case "$INT" in
            ''|*[!0-9]*) INT=3600 ;;
        esac
        [ "$INT" -lt 60 ] && INT=60
        sleep "$INT"
        if [ ! -f "$CFG/no_auto_fp" ] && [ "${ENGINE:-none}" != "none" ]; then
            FP_DONE=0
            if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
                sh "$MODDIR/pif_native_fetch.sh" >"$CFG/autopif.log" 2>&1 && FP_DONE=1
                cat "$CFG/autopif.log" 2>/dev/null | log -t "AlwaysStrong-hourly"
            fi
            if [ "$FP_DONE" = 0 ]; then
                engine_autopif 2>&1 | log -t "AlwaysStrong-hourly"
            fi
            [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" boot 2>&1 | log -t "AlwaysStrong-hourly"
            # upstream's fetcher resets these to a WEAK config (Fork's
            # migrate.sh writes spoofProvider=1 / spoofVendingFinger=0), which
            # would silently drop the verdict an hour after boot.
            engine_enforce_spoof
        elif [ "${ENGINE:-none}" = "none" ] && [ ! -f "$CFG/no_auto_fp" ]; then
            # Lite line: no bundled engine to autopif, but if the user runs their
            # own standalone PlayIntegrityFork, mirror its fingerprint into the
            # attested identity and re-assert the STRONG spoof flags it keeps
            # resetting (spoofVendingFinger 1 -> 0). No-op with no PIF present.
            sh "$MODDIR/lite_pif_sync.sh" 2>&1 | log -t "AlwaysStrong-hourly"
        fi
        if [ ! -f "$CFG/custom_keybox" ] && [ ! -f "$CFG/no_auto_keybox" ] && [ -x "$MODDIR/keybox_fetch.sh" ]; then
            kbout=$(sh "$MODDIR/keybox_fetch.sh" 2>&1)
            kbrc=$?
            [ -n "$kbout" ] && echo "$kbout" | log -t "AlwaysStrong-hourly"
            if [ "$kbrc" = "0" ]; then
                log -t "AlwaysStrong-hourly" "keybox updated, restarting PI"
                killall -9 com.google.android.gms.unstable 2>/dev/null
                killall -9 com.android.vending 2>/dev/null
            fi
        fi
        # Mirror whatever the pass above changed (keybox, target list, patch
        # level) into the attestation engine's own runtime dir. No-op when
        # nothing moved, so it never bounces the engine for free.
        attest_sync 2>/dev/null
        # Status — independent of toggles; cheap GET, idempotent module.prop write
        if [ -x "$MODDIR/status_fetch.sh" ]; then
            sh "$MODDIR/status_fetch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
        fi
        # Engine hook for anything that has to be regenerated from target.txt
        # (e.g. an engine that caches its own target list). attest_sync above
        # already covers OMK; this stays for engines that need more.
        command -v attest_gen_config >/dev/null 2>&1 && attest_gen_config
    done
}&
