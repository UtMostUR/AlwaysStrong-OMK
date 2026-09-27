#!/system/bin/sh
# Attestation-engine adapter — OhMyKeymint (--engine omk).
#
# customize.sh sources it and calls attest_install (with $ABI_DIR / $ARCH /
# $ZIPFILE / $MODPATH and install_file() + ui_print() in scope). service.sh and
# action.sh source it and call attest_early / attest_start / attest_alive /
# attest_sync (with $MODDIR in scope).
#
# OMK replaces the keystore2 keymaster backend the same way TEESimulator-RS
# does, but its layout is its own:
#   - the KeyMint RPC server + the ptrace injector are ELFs under libs/<abi>/
#     (the injector embeds its own payload, so nothing else ships with them);
#   - the two supervisor loops are plain shell scripts, not a forked binary.
#     omk-daemon also owns the one recovery OMK itself lacks: a store it cannot
#     decrypt — the [crypto] seeds changed under it after an engine swap or a
#     config migration — kills startup outright, so the daemon drops and rebuilds
#     the store instead of restarting a dying keymint for the rest of the boot;
#   - runtime state is rooted at /data/misc/keystore/omk (keybox.xml,
#     injector.toml, config.toml, rpc.sock, logs) and /data/adb/omk (pidfiles,
#     restart flags, injector.payload) — BOTH paths are hardcoded in the
#     binaries, so the module must keep them exactly.
#
# Everything the user configures lives under AlwaysStrong's own config dir
# (/data/adb/tricky_store: keybox.xml, target.txt, security_patch.txt). OMK
# cannot read any of it, so omk-sync.sh mirrors that state into OMK's runtime
# dir on every boot / Action / hourly pass and when the watchdog sees a change.
# engine.sh (the PIF adapter) keeps spoofProvider off for this engine too: the
# attestation layer here is what supplies the hardware-attested keystore.

ATTEST=omk
ATTEST_NAME="OhMyKeymint"

OMK_STATE_DIR=/data/adb/omk
OMK_RUN_DIR=/data/misc/keystore/omk
OMK_KEYBOX="$OMK_RUN_DIR/keybox.xml"
OMK_CONFIG="$OMK_RUN_DIR/config.toml"
OMK_INJECTOR="$OMK_RUN_DIR/injector.toml"
OMK_INJECT_PAYLOAD="$OMK_STATE_DIR/injector.payload"

# Install the native OMK stack out of the flashed module zip. Upstream ships
# arm64-v8a only, so there is no engine to fall back to on another ABI —
# aborting beats a module that installs and silently never attests.
attest_install() {
    case "$ABI_DIR" in
        arm64-v8a) ;;
        *) abort "OhMyKeymint ships arm64-v8a binaries only (device ABI: $ABI_DIR)" ;;
    esac
    mkdir -p "$MODPATH/libs/$ABI_DIR"
    install_file "libs/$ABI_DIR/keymint" "$MODPATH/libs/$ABI_DIR"
    install_file "libs/$ABI_DIR/inject"  "$MODPATH/libs/$ABI_DIR"
    install_file "injector.toml" "$MODPATH"
    install_file "omk-daemon"    "$MODPATH"
    install_file "omk-injector"  "$MODPATH"
    install_file "omk-early.sh"  "$MODPATH"
    install_file "omk-sync.sh"   "$MODPATH"
    chmod 755 "$MODPATH/libs/$ABI_DIR/keymint" "$MODPATH/libs/$ABI_DIR/inject" \
              "$MODPATH/omk-daemon" "$MODPATH/omk-injector" \
              "$MODPATH/omk-early.sh" "$MODPATH/omk-sync.sh" 2>/dev/null
    # OMK's own hot-update slot. Upstream's daemon prefers it over the module
    # copy, and a stale binary left there by a previous OMK install would win
    # over the one we just shipped.
    rm -f "$OMK_STATE_DIR/keymint" "$OMK_STATE_DIR/inject" "$OMK_STATE_DIR/injector"
    ui_print "OhMyKeymint installed ($ABI_DIR)"
}

# OMK hijacks keystore2 and must win the race against it, so the supervisor
# loops start at the service stage — before sys.boot_completed — rather than
# after it. The injector then keeps re-checking keystore2, and keymint's RPC
# socket is already up by the time the first injection lands. (TEESimulator-RS
# returns 1 here because its Java daemon needs a fully booted system; OMK's
# stack is native and has no such dependency.)
attest_early() { return 0; }

# Start whichever of OMK's two supervisor loops is not already running.
# Mirrors upstream service.sh's start_daemon(): the pidfile is only trusted
# when the pid is alive AND its cmdline still names the script, so a recycled
# pid never blocks a restart.
attest_start() {
    _omk_start_one() {
        _s="$1"; _pf="$2"
        if [ -f "$_pf" ]; then
            _p=$(cat "$_pf" 2>/dev/null)
            if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && \
               tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -F "$_s" >/dev/null 2>&1; then
                return 0
            fi
            rm -f "$_pf"
        fi
        mkdir -p "$OMK_STATE_DIR"
        sh "$_s" &
        echo $! > "$_pf"
    }
    _omk_start_one "$MODDIR/omk-daemon"   "$OMK_STATE_DIR/keymint-daemon.pid"
    _omk_start_one "$MODDIR/omk-injector" "$OMK_STATE_DIR/injector-daemon.pid"
}

# True while both halves of the engine are up: the KeyMint RPC server and the
# injector supervisor. A dead keymint means keystore2 falls back to the system
# backend, so it counts as "not alive" and the watchdog restarts the pair.
attest_alive() {
    pidof keymint >/dev/null 2>&1 || return 1
    _p=$(cat "$OMK_STATE_DIR/injector-daemon.pid" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

# Ask OMK's own daemon to bounce keymint (it owns the child and re-reads
# config.toml / keybox.xml on start). config.toml's patch-level fields hot-apply
# through OMK's own file watcher, but every other [trust]/[device] field only
# takes effect on a restart — that is what this is for.
attest_restart_keymint() {
    mkdir -p "$OMK_STATE_DIR"
    : > "$OMK_STATE_DIR/restart.keymint"
}

# Ask the injector supervisor to re-inject (it stops keystore2 first, so init
# respawns a clean process that gets the library before it serves anything).
attest_restart_injector() {
    mkdir -p "$OMK_STATE_DIR"
    : > "$OMK_STATE_DIR/restart.injector"
}

# Mirror AlwaysStrong's config dir into OMK's runtime dir. Safe at any stage:
# the keybox/injector halves are file-level, and the config.toml half is skipped
# until keymint has created that file. See omk-sync.sh.
attest_sync() {
    [ -f "$MODDIR/omk-sync.sh" ] || return 0
    sh "$MODDIR/omk-sync.sh" 2>/dev/null
}

# --- Injection watchdog ---------------------------------------------------
# keystore2 starts early in boot; keymint's RPC server only comes up at the
# service stage. The injector's own retry loop keys off "is my library mapped
# into keystore2", which is already true after a successful ptrace — so when the
# injection lands before the socket exists, the 10s connect timeout expires, the
# injector believes it is done, and keystore2 silently serves the system
# backend for the rest of the boot. That is the "config.toml is right but the
# verdict never changes" failure. Detect the mismatch and re-inject once.
#
# Signals, cheapest first:
#   1. the recorded payload is newer than the RPC socket by >10s (injection
#      raced ahead of the server);
#   2. keymint is up but the RPC socket does not exist at all;
#   3. the injector log's most recent event is a failed RPC connect.
# Cooldown is 15 min per boot so a genuinely broken setup cannot loop.
attest_ensure_injection() {
    pidof keymint >/dev/null 2>&1 || return 0
    [ -f "$OMK_STATE_DIR/injector-daemon.pid" ] || return 0

    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) return 0 ;; esac
    _cool="$OMK_STATE_DIR/.as_inject_retry"
    _last=$(cat "$_cool" 2>/dev/null)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    [ $((_now - _last)) -lt 900 ] && return 0

    _need=0

    if [ -s "$OMK_INJECT_PAYLOAD" ]; then
        if [ ! -e "$OMK_RUN_DIR/rpc.sock" ]; then
            _need=1
        else
            _pm=$(stat -c %Y "$OMK_INJECT_PAYLOAD" 2>/dev/null || echo 0)
            _sm=$(stat -c %Y "$OMK_RUN_DIR/rpc.sock" 2>/dev/null || echo 0)
            case "$_pm$_sm" in *[!0-9]*) _pm=0; _sm=0 ;; esac
            [ "$_pm" -gt $((_sm + 10)) ] && _need=1
        fi
    fi

    if [ "$_need" = 0 ]; then
        _log="$OMK_RUN_DIR/logs/injector.log"
        if [ -s "$_log" ]; then
            _last_evt=$(grep -E 'injecting into keystore2|injector exited with code|failed to connect OMK RPC socket' \
                        "$_log" 2>/dev/null | tail -n 1)
            case "$_last_evt" in
                *"failed to connect OMK RPC socket"*) _need=1 ;;
            esac
        fi
    fi

    [ "$_need" = 1 ] || return 0
    echo "$_now" > "$_cool" 2>/dev/null
    log -t "AlwaysStrong" "OMK: injection missed the RPC window, re-injecting"
    attest_restart_injector
}