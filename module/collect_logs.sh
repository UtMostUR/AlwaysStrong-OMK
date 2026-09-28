#!/system/bin/sh
# AlwaysStrong — log collector.
#
# Dumps a diagnostic bundle to /sdcard so a user can attach it to a GitHub
# issue. Deliberately does NOT include the keybox contents (it holds private
# keys) — only its name, size and hash. The spoofed Pixel fingerprint IS
# included: it is fake by design and is exactly what a support request needs.
#
# Run it three ways:
#   - the "Collect logs" button in the WebUI (KSU / APatch / the standalone app)
#   - sh /data/adb/modules/tricky_store/collect_logs.sh   (root shell)
#   - sh action.sh logs
#
# Prints the output path on the last line so callers can show it.

MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
# fall back to the install path if run from a copy elsewhere (so the Module
# section isn't blank when someone runs the script from /sdcard or /tmp)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/tricky_store
CFG=/data/adb/tricky_store
KEY_HOST="${KEYBOX_BASE_URL:-http://evoker.qzz.io}"

# The engine identifier is a plain assignment in attest.sh. This script is run by
# hand or by the WebUI and is never sourced by the module, so nothing ever puts
# it in the environment — read it out of the file, or the section below prints an
# empty "?" no matter which engine is installed.
ATTEST=$(sed -n 's/^ATTEST=//p' "$MODDIR/attest.sh" 2>/dev/null | head -n 1)

# Timestamped filename so repeated collections don't overwrite each other. If
# date is somehow unavailable, fall back to a fixed name.
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null)
[ -n "$STAMP" ] && OUT="/sdcard/AlwaysStrong-log-$STAMP.txt" || OUT="/sdcard/AlwaysStrong-log.txt"

# busybox for the tools toybox may lack (sha256sum on old devices, etc.)
BB=""
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox; do
    [ -x "$bb" ] && BB="$bb" && break
done
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif [ -n "$BB" ]; then "$BB" sha256sum; else echo "n/a"; fi; }

# asfetch, the same native fetcher the module uses — the one that fails on some
# ROMs, so it's exactly what we want to test here.
case "$(uname -m)" in
    aarch64) ABI=arm64-v8a ;; armv7*|armv8l) ABI=armeabi-v7a ;;
    x86_64) ABI=x86_64 ;; i?86) ABI=x86 ;; *) ABI="" ;;
esac
ASFETCH="$MODDIR/bin/$ABI/asfetch"

sec() { echo ""; echo "===== $* ====="; }

{
echo "AlwaysStrong diagnostic log"
echo "generated: $(date 2>/dev/null)"

sec "Module"
grep -E '^(name|version|versionCode)=' "$MODDIR/module.prop" 2>/dev/null
[ -f "$MODDIR/engine.sh" ] && grep -E '^ENGINE(_NAME)?=' "$MODDIR/engine.sh"
[ -f "$MODDIR/attest.sh" ] && grep -E '^ATTEST(_NAME)?=' "$MODDIR/attest.sh"

sec "Device / ROM"
for p in ro.product.brand ro.product.model ro.product.device \
         ro.build.version.release ro.build.version.sdk ro.build.fingerprint \
         ro.build.version.security_patch ro.product.cpu.abi; do
    echo "$p=$(getprop $p)"
done

sec "Root manager / Zygisk"
echo "KSU: $([ -d /data/adb/ksu ] && echo yes || echo no)"
echo "APatch: $([ -d /data/adb/ap ] && echo yes || echo no)"
echo "Magisk: $([ -d /data/adb/magisk ] && echo yes || echo no)"
echo "ZygiskNext: $([ -d /data/adb/modules/zygisksu ] && echo yes || echo no)"
echo "ReZygisk: $([ -d /data/adb/modules/rezygisk ] && echo yes || echo no)"

sec "TEE / daemon processes"
for proc in keymint TEESimulator supervisor daemon aswatcher; do
    echo "$proc: $(pidof "$proc" 2>/dev/null || echo 'not running')"
done
# OMK's two supervisor loops are plain shell scripts, so pidof can't see them by
# name — match them on the command line instead.
for s in omk-daemon omk-injector; do
    p=$(pgrep -f "$s" 2>/dev/null | tr '\n' ' ')
    echo "$s: ${p:-not running}"
done

sec "OhMyKeymint runtime"
OMK_RUN=/data/misc/keystore/omk
OMK_STATE=/data/adb/omk
echo "ATTEST=${ATTEST:-?} (expect omk)"
echo "injected into keystore2: $(pidof keystore2 2>/dev/null | head -1 | while read p; do
    [ -n "$p" ] && grep -qE 'inject|omk' "/proc/$p/maps" 2>/dev/null && echo yes || echo NO; done)"
echo "rpc.sock: $([ -S "$OMK_RUN/rpc.sock" ] && echo present || echo MISSING)"
echo "injector.payload: $(ls -l "$OMK_STATE/injector.payload" 2>/dev/null | awk '{print $5" bytes "$6" "$7" "$8}')"
echo "restart flags: $(ls "$OMK_STATE"/restart.* 2>/dev/null | tr '\n' ' ')"
# keymint's private store — the SQLite DB holding every key blob plus the
# secure-deletion state file. It is sealed with the [crypto] seeds in config.toml,
# so a store left behind by a different seed is exactly what makes keymint die at
# startup with "fatal startup error". omk-daemon rebuilds it when that happens and
# parks the crash trail in keymint.log.store-reset.
echo "--- private store"
ls -l "$OMK_RUN/data" 2>/dev/null || echo "  no store yet (keymint has not started)"
# keymint writes a session UUID and a count, on two lines.
if [ -f "$OMK_RUN/crash_count" ]; then
    echo "crash_count (session, count): $(tr '\n' ' ' < "$OMK_RUN/crash_count" 2>/dev/null)"
fi
# omk-early.sh clears this marker every boot, so its presence means the rebuild
# happened *this* boot. The lines that triggered it are printed too: they are the
# proof the store really was undecryptable rather than a false positive.
if [ -f "$OMK_RUN/logs/keymint.log.store-reset" ]; then
    echo "store was dropped and rebuilt this boot — pre-reset log: logs/keymint.log.store-reset"
    echo "--- reset trigger (last 5 key-material failures)"
    _why=$(grep -E 'fatal startup error|failed to initialize boot-level key cache|failed to decrypt keyblob' \
           "$OMK_RUN/logs/keymint.log.store-reset" 2>/dev/null | tail -n 5)
    echo "${_why:-none}"
fi
# keymint's DT_NEEDED carries no libc++, so libc++_shared.so reaches it as a
# dependency of liblog.so and LD_LIBRARY_PATH decides which copy wins. Listing
# the candidates separates "the loader picked the wrong libc++" from "the binary
# cannot run at all", which is otherwise only visible as a one-line logcat error.
echo "--- loader candidates"
for f in /apex/com.android.runtime/lib64/liblog.so /system/lib64/liblog.so \
         /vendor/lib64/liblog.so /apex/com.android.runtime/lib64/libc++_shared.so \
         /system/lib64/libc++_shared.so /vendor/lib64/libc++_shared.so; do
    if [ -e "$f" ]; then
        echo "  present  $(ls -l "$f" 2>/dev/null | awk '{print $5" bytes"}')  $f"
    else
        echo "  absent   $f"
    fi
done
if [ -x "$MODDIR/libs/arm64-v8a/keymint" ] && [ -x /system/bin/linker64 ]; then
    echo "--- keymint resolved libraries (linker64 --list)"
    /system/bin/linker64 --list "$MODDIR/libs/arm64-v8a/keymint" 2>&1 | sed 's/^/  /'
fi
ls -l "$OMK_RUN" 2>/dev/null
# config.toml holds generated [crypto] secrets — print only the [trust] section.
if [ -s "$OMK_RUN/config.toml" ]; then
    echo "--- config.toml [trust] (secrets withheld)"
    awk '/^[[:space:]]*\[/ { intrust = ($0 ~ /\[trust\]/) } intrust' "$OMK_RUN/config.toml" 2>/dev/null
else
    echo "no config.toml yet (keymint has not started)"
fi
echo "--- injector.toml scoop"
awk '/^[[:space:]]*scoop[[:space:]]*=/ { ins = 1; next } ins && /^[[:space:]]*\]/ { ins = 0 } ins' "$OMK_RUN/injector.toml" 2>/dev/null
echo "--- keymint.log (last 25)"
tail -25 "$OMK_RUN/logs/keymint.log" 2>/dev/null || echo "none"
# Any of these means keymint never reached its RPC server, which is the one
# failure that leaves keystore2 on the system backend for the whole boot — and
# the decrypt half is what tells a dead store apart from a bad keybox.
echo "--- keymint startup failures (last 3)"
_fatal=$(grep -E 'fatal startup error|failed to initialize boot-level key cache|failed to decrypt keyblob' \
         "$OMK_RUN/logs/keymint.log" 2>/dev/null | tail -n 3)
echo "${_fatal:-none}"
echo "--- injector.log (last 25)"
tail -25 "$OMK_RUN/logs/injector.log" 2>/dev/null || echo "none"

sec "Spoofed fingerprint (pif.prop — safe to share)"
for f in "$CFG/pif.prop" "$MODDIR/pif.prop" "$MODDIR/custom.pif.prop"; do
    [ -s "$f" ] && { echo "--- $f"; cat "$f"; break; }
done

sec "Spoof overrides + effective flags"
if [ -s "$CFG/spoof.conf" ]; then
    echo "--- $CFG/spoof.conf"
    cat "$CFG/spoof.conf"
    # These three drive the verdicts: when on, the PIF zygisk intercepts the
    # keystore calls the attestation engine answers, the two fight, and all three
    # Play Integrity verdicts go red. Say so, so a red verdict isn't chased in the
    # wrong place.
    for _lk in spoofProvider spoofSignature spoofVendingSdk; do
        _v=$(sed -n "s/^${_lk}=//p" "$CFG/spoof.conf" 2>/dev/null | head -1 | tr -d ' \t\r')
        case "$_v" in
            1|true|on|yes)
                echo "WARN: ${_lk}=${_v} is ON — this fights the attestation engine and turns all three Play Integrity verdicts red" ;;
        esac
    done
    echo "inherited-key purge: $([ -f "$CFG/.spoof_keys_purged" ] && echo done || echo pending)"
else
    echo "no spoof.conf (engine defaults only)"
fi
# The flags the zygisk actually reads, module dir first — spoof.conf feeds these
# through engine_enforce_spoof, so this is what the verdicts are decided on.
for f in "$MODDIR/custom.pif.prop" "$CFG/custom.pif.prop" "$MODDIR/pif.prop" "$CFG/pif.prop"; do
    [ -s "$f" ] && { echo "--- $f (effective spoof flags)"; grep -iE '^(spoof|DEBUG)' "$f"; break; }
done

sec "Security patch consistency"
# The OS patch prop, the attested patch (security_patch.txt) and the PIF date all
# have to agree, or an attestation checker flags "OS patch differs". Print all
# three plus the ROM's captured real date, and name any mismatch outright.
echo "patch spoof: $([ -f "$CFG/no_spoof_patch_props" ] && echo "off (ROM real date everywhere)" || echo on)"
echo "date mode: $([ -f "$CFG/spoof_patch_props" ] && echo "strict fingerprint (experimental toggle OFF)" || echo "unified, newest of fingerprint/ROM (default)")"
echo "ROM real (captured at boot): $(cat "$CFG/.rom_security_patch" 2>/dev/null | tr -cd '0-9')"
_sp=$(cat "$CFG/security_patch.txt" 2>/dev/null | sed 's/^all=//' | tr -d ' \r')
echo "security_patch.txt: ${_sp:-missing}"
_pifsp=""
for f in "$CFG/custom.pif.prop" "$MODDIR/custom.pif.prop" "$CFG/pif.prop" "$MODDIR/pif.prop"; do
    [ -s "$f" ] || continue
    _pifsp=$(grep -m1 '^[#]\?\*\.security_patch=' "$f" 2>/dev/null | cut -d= -f2- | tr -d ' \r')
    [ -n "$_pifsp" ] && { echo "pif *.security_patch: $_pifsp  ($f)"; break; }
done
_pr=$(getprop ro.build.version.security_patch 2>/dev/null)
echo "ro.build.version.security_patch: ${_pr:-unset}"
echo "ro.vendor.build.security_patch: $(getprop ro.vendor.build.security_patch 2>/dev/null)"
[ -n "$_sp" ] && [ -n "$_pr" ] && [ "$_sp" != "$_pr" ] && \
    echo "WARN: security_patch.txt ($_sp) != ro.build.version.security_patch ($_pr) — OS-patch / osPatchLevel mismatch, checkers flag this"
[ -n "$_sp" ] && [ -n "$_pifsp" ] && [ "$_sp" != "$_pifsp" ] && \
    echo "WARN: security_patch.txt ($_sp) != pif *.security_patch ($_pifsp) — PIF and the engine report different patch dates"

sec "Keybox (metadata only — contents withheld)"
KB="$CFG/keybox.xml"
if [ -s "$KB" ]; then
    echo "path: $KB"
    echo "size: $(wc -c < "$KB") bytes"
    echo "sha256: $(sha < "$KB" | awk '{print $1}')"
    echo "looks-like-keybox: $(head -c 4096 "$KB" | grep -q Keybox && echo yes || echo NO)"
    echo "custom-keybox mode: $([ -f "$CFG/custom_keybox" ] && echo on || echo off)"
else
    echo "no keybox.xml present"
fi

sec "Target list (count + first 15)"
if [ -s "$CFG/target.txt" ]; then
    echo "apps: $(grep -cvE '^[[:space:]]*$' "$CFG/target.txt")"
    grep -vE '^[[:space:]]*$' "$CFG/target.txt" | head -15
else
    echo "no target.txt"
fi

sec "Config dir"
ls -l "$CFG" 2>/dev/null

sec "Network (most keybox/fingerprint failures are here)"
# raw IP reachability — no DNS involved
for ip in 1.1.1.1 8.8.8.8; do
    if ping -c1 -W2 "$ip" >/dev/null 2>&1; then echo "ping $ip: ok"; else echo "ping $ip: FAIL"; fi
done
# DNS: can the keybox host be resolved? Resolver often comes up late on some
# AOSP ROMs, which is what leaves them with no keybox on first boot.
HOST=$(echo "$KEY_HOST" | sed -e 's#^[a-z]*://##' -e 's#/.*##' -e 's#:.*##')
if command -v getent >/dev/null 2>&1 && getent hosts "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok ($(getent hosts "$HOST" | awk '{print $1}' | tr '\n' ' '))"
elif [ -n "$BB" ] && "$BB" nslookup "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok (via nslookup)"
else
    echo "dns $HOST: FAIL — cannot resolve (resolver not up / blocked)"
fi
# actual keybox fetch, one attempt per engine, with timing — shows which
# downloader works on this ROM and how long it takes.
NT="$CFG/.netcheck.$$"; mkdir -p "$NT"; trap 'rm -rf "$NT"' EXIT INT TERM
test_engine() {
    _name="$1"; shift
    _t0=$(date +%s 2>/dev/null)
    rm -f "$NT/out"
    "$@" >/dev/null 2>&1
    _t1=$(date +%s 2>/dev/null)
    if [ -s "$NT/out" ]; then
        echo "$_name: ok ($(wc -c < "$NT/out") bytes, ~$((_t1 - _t0))s)"
    else
        echo "$_name: FAIL (~$((_t1 - _t0))s)"
    fi
}
KURL="$KEY_HOST/key"
# short timeouts: this is a reachability probe, not the real fetch, and long
# per-engine stalls are what made pressing the button feel like a freeze.
[ -n "$ABI" ] && [ -x "$ASFETCH" ] && test_engine "asfetch    $KURL" "$ASFETCH" -T 5 -o "$NT/out" "$KURL" || echo "asfetch: not available for $ABI"
[ -n "$BB" ] && test_engine "busybox-wget" "$BB" wget -q -T 5 -O "$NT/out" "$KURL"
command -v curl >/dev/null 2>&1 && test_engine "curl       " curl -fsSL --connect-timeout 5 --max-time 8 -o "$NT/out" "$KURL"
command -v wget >/dev/null 2>&1 && test_engine "wget       " wget -q -T 5 -O "$NT/out" "$KURL"
echo "last-good engine (cached): $(cat "$CFG/.kb_engine" 2>/dev/null || echo none)"
rm -rf "$NT"; trap - EXIT INT TERM

sec "autopif.log (fingerprint fetch)"
cat "$CFG/autopif.log" 2>/dev/null | tail -40 || echo "none"

sec "Conflicting modules present"
for c in playintegrityfix playintegrityfork tricky_store_v2 TrickyStore \
         tee_simulator TEESimulator oh_my_keymint OhMyKeymint omk \
         safetynet-fix MagiskHidePropsConf Yurikey; do
    [ -d "/data/adb/modules/$c" ] && echo "present: $c"
done

sec "logcat (our tags, last 200 lines)"
# -t 3000 reads only the tail of the ring buffer; a full `logcat -d` dump can be
# tens of MB and takes seconds, which is most of the button's perceived lag.
logcat -d -t 3000 2>/dev/null | grep -iE 'AlwaysStrong|TEESimulator|tricky_store|aswatcher|libinject|PlayIntegrity|omk|keymint' | tail -200 || echo "logcat unavailable"

sec "dmesg (our tags)"
dmesg 2>/dev/null | grep -iE 'TEESimulator|tricky_store|aswatcher|omk|keymint' | tail -40 || echo "dmesg unavailable"

echo ""
echo "===== end ====="
} > "$OUT" 2>&1

chmod 664 "$OUT" 2>/dev/null
# leave a pointer to the newest log so the WebUI can launch this detached (no UI
# freeze) and poll for the path instead of waiting on the whole run.
echo "$OUT" > "$CFG/.last_log" 2>/dev/null
echo "$OUT"
