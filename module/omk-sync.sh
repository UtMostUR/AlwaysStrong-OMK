#!/system/bin/sh
# OhMyKeymint — mirror AlwaysStrong's config dir into OMK's runtime dir.
#
# Everything the user configures lives under /data/adb/tricky_store (keybox.xml,
# target.txt, security_patch.txt). OMK cannot read any of it: its two files are
# hardcoded to /data/misc/keystore/omk and are written in its own formats. This
# script is the bridge, and it runs on every boot, on every [Action] tap, on the
# hourly pass, and from service.sh's watchdog.
#
# It is idempotent and safe at any boot stage:
#   - the keybox half is a plain file comparison;
#   - the scoop half only rewrites injector.toml when the package set actually
#     changed;
#   - the config.toml half is skipped entirely until keymint has created that
#     file (it generates the [crypto] secrets, and those must never be touched).
#
# Exit code: 0 when something was changed and OMK needs to re-read it, 1 when
# nothing changed. Callers may ignore it.
#
# Only the keybox and config.toml need a keymint restart — keymint reads both
# once at start. injector.toml is watched and hot-applied to new requests, so a
# target-list edit must NOT bounce keymint (that would drop in-flight keystore
# operations for every app, for a change OMK picks up on its own).

MODDIR=${0%/*}
CONFIG_DIR=/data/adb/tricky_store
OMK_RUN_DIR=/data/misc/keystore/omk
OMK_STATE_DIR=/data/adb/omk
OMK_KEYBOX="$OMK_RUN_DIR/keybox.xml"
OMK_INJECTOR="$OMK_RUN_DIR/injector.toml"
OMK_CONFIG="$OMK_RUN_DIR/config.toml"

# Packages OMK must always route: the Google trio has to use the hardware keybox
# to reach STRONG, keyattestation is the reference checker, and duckdetector is
# OMK's own upstream default. Unioned with target.txt below.
OMK_BASE_SCOOP="io.github.vvb2060.keyattestation
com.google.android.gsf
com.google.android.gms
com.android.vending
com.eltavine.duckdetector"

CHANGED=0
NEED_KM=0
mkdir -p "$OMK_RUN_DIR" 2>/dev/null

sha_of() {
    [ -s "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v sha >/dev/null 2>&1; then
        sha "$1" 2>/dev/null | awk '{print $1}'
    else
        cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'
    fi
}

own_omk() {
    chmod 0600 "$1" 2>/dev/null
    chown 1017:1017 "$1" 2>/dev/null
}

# --- 1. keybox ------------------------------------------------------------
# AlwaysStrong's keybox_fetch.sh / the WebUI write $CONFIG_DIR/keybox.xml. Copy
# it across only when the content differs, so a working runtime keybox is never
# rewritten (and never restarted) for nothing.
SRC_KB="$CONFIG_DIR/keybox.xml"
if [ -s "$SRC_KB" ] && head -c 4096 "$SRC_KB" 2>/dev/null | grep -q "Keybox"; then
    _s=$(sha_of "$SRC_KB")
    _d=$(sha_of "$OMK_KEYBOX")
    if [ -n "$_s" ] && [ "$_s" != "$_d" ]; then
        # Stage + own before the rename: mv within the dir keeps the inode, so the
        # keystore uid can read the new file the instant it appears. Copying
        # straight over the live path would leave a root-owned window where
        # keymint's watcher reads EACCES and rejects the change.
        _kbtmp="$OMK_KEYBOX.as.tmp"
        if cp -f "$SRC_KB" "$_kbtmp" 2>/dev/null; then
            own_omk "$_kbtmp"; mv -f "$_kbtmp" "$OMK_KEYBOX"
            CHANGED=1
            NEED_KM=1
        fi
    fi
fi

# --- 2. scoop (target.txt -> injector.toml) ------------------------------
# target.txt is TrickyStore's format: one package per line, an optional `!`
# (generate) or `?` (hack) suffix, and `[file.xml]` section headers for apps
# pinned to another keybox. OMK's scoop is a flat list of exact package names
# with no suffixes and no sections, so the suffixes are stripped and the header
# lines are rejected by the package-name filter below.
#
# Apps sitting inside a `[file.xml]` section are kept, deliberately. OMK has one
# runtime keybox and no per-app keybox, so the alternative — dropping them —
# would leave exactly the apps the user asked to attest on the system backend,
# which is the failure this engine exists to avoid. Attesting them with OMK's
# keybox is the closest faithful behaviour available; a user who needs a truly
# different keybox per app has to run OMK on its own.
desired_scoop() {
    {
        printf '%s\n' "$OMK_BASE_SCOOP"
        [ -s "$CONFIG_DIR/target.txt" ] && \
            sed -e 's/[!?][[:space:]]*$//' \
                -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                "$CONFIG_DIR/target.txt" 2>/dev/null
    } | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' | sort -u
}

current_scoop() {
    [ -s "$OMK_INJECTOR" ] || return 0
    awk '
        /^[[:space:]]*scoop[[:space:]]*=/ { inscoop = 1; next }
        inscoop && /^[[:space:]]*\]/ { inscoop = 0; next }
        inscoop {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/[",]/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") print line
        }
    ' "$OMK_INJECTOR" 2>/dev/null | sort -u
}

WANT_SCOOP=$(desired_scoop)
HAVE_SCOOP=$(current_scoop)

if [ -n "$WANT_SCOOP" ] && [ "$WANT_SCOOP" != "$HAVE_SCOOP" ]; then
    if [ ! -s "$OMK_INJECTOR" ] && [ -s "$MODDIR/injector.toml" ]; then
        cp -f "$MODDIR/injector.toml" "$OMK_INJECTOR" 2>/dev/null
    fi
    if [ -s "$OMK_INJECTOR" ]; then
        _tmp="$OMK_INJECTOR.as.tmp"
        _want="$OMK_INJECTOR.as.want"
        printf '%s\n' "$WANT_SCOOP" > "$_want" 2>/dev/null
        awk '
            NR == FNR { pkg[++n] = $0; next }
            /^[[:space:]]*scoop[[:space:]]*=/ {
                print "scoop = ["
                for (i = 1; i <= n; i++) printf "  \"%s\",\n", pkg[i]
                print "]"
                inscoop = 1
                next
            }
            inscoop && /^[[:space:]]*\]/ { inscoop = 0; next }
            inscoop { next }
            { print }
        ' "$_want" "$OMK_INJECTOR" > "$_tmp" 2>/dev/null
        rm -f "$_want" 2>/dev/null
        if [ -s "$_tmp" ] && ! cmp -s "$_tmp" "$OMK_INJECTOR"; then
            own_omk "$_tmp"; mv -f "$_tmp" "$OMK_INJECTOR"
            CHANGED=1
        else
            rm -f "$_tmp" 2>/dev/null
        fi
    fi
fi

# --- 3. config.toml [trust] ---------------------------------------------
# The two switches OMK reports through key attestation, plus os_version. This is
# the half that actually moves DEVICE/STRONG: without device_locked=true OMK
# reports an unlocked bootloader and the verdict stays red no matter how good
# the keybox is.
#
# The four patch-level fields stay on "auto" on purpose. AlwaysStrong's
# sync_patch.sh already pins ro.build.version.security_patch /
# ro.vendor.build.security_patch to the attested date, and OMK's "auto" reads
# exactly those props. Writing an explicit date here would make OMK overwrite
# the property itself, which fights sync_patch.sh's "never move a device's patch
# backwards" rule on an OTA-fresh device.
#
# [crypto] and [device] are never rewritten: the crypto seeds are generated once
# by keymint and protect every key it has created.
if [ -s "$OMK_CONFIG" ]; then
    _tmp="$OMK_CONFIG.as.tmp"
    awk \
        -v dl="true" -v vbs="true" \
        -v osv='"auto"' -v sp='"auto"' \
        -v opl='"auto"' -v vpl='"auto"' -v bpl='"auto"' '
        BEGIN {
            want["device_locked"]     = dl
            want["verified_boot_state"] = vbs
            want["os_version"]        = osv
            want["security_patch"]    = sp
            want["os_patchlevel"]     = opl
            want["vendor_patchlevel"] = vpl
            want["boot_patchlevel"]   = bpl
            n = split("device_locked verified_boot_state os_version security_patch os_patchlevel vendor_patchlevel boot_patchlevel", order, " ")
        }
        function flush_missing(   i, k) {
            for (i = 1; i <= n; i++) {
                k = order[i]
                if (!(k in done)) printf "%s = %s\n", k, want[k]
            }
        }
        /^[[:space:]]*\[/ {
            if (intrust) { flush_missing(); intrust = 0 }
            if ($0 ~ /^[[:space:]]*\[trust\][[:space:]]*(#.*)?$/) { intrust = 1; seen = 1 }
            print
            next
        }
        intrust {
            key = $0
            sub(/[[:space:]]*=.*/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key in want) {
                done[key] = 1
                printf "%s = %s\n", key, want[key]
                next
            }
            print
            next
        }
        { print }
        END {
            if (intrust) flush_missing()
            else if (!seen) {
                print ""
                print "[trust]"
                flush_missing()
            }
        }
    ' "$OMK_CONFIG" > "$_tmp" 2>/dev/null

    if [ -s "$_tmp" ] && ! cmp -s "$_tmp" "$OMK_CONFIG"; then
        own_omk "$_tmp"; mv -f "$_tmp" "$OMK_CONFIG"
        CHANGED=1
        NEED_KM=1
    else
        rm -f "$_tmp" 2>/dev/null
    fi
fi

# --- 4. make OMK re-read what we wrote -----------------------------------
# keymint reads keybox.xml / config.toml once at start; the injector watches
# injector.toml and applies a valid change to new requests on its own. So only
# the keybox/config half asks for the bounce — the daemon consumes the flag
# within ~2 s and re-reads both files on the way up.
if [ "$CHANGED" = 1 ]; then
    if [ "$NEED_KM" = 1 ]; then
        mkdir -p "$OMK_STATE_DIR" 2>/dev/null
        : > "$OMK_STATE_DIR/restart.keymint" 2>/dev/null
    fi
    exit 0
fi
exit 1