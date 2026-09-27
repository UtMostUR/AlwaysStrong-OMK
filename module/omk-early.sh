#!/system/bin/sh
# OhMyKeymint — early (post-fs-data stage) setup.
#
# post-fs-data.sh calls this before anything else touches keystore2. It mirrors
# upstream OMK's own post-fs-data.sh plus the state-dir half of its
# customize.sh, so the supervisor loops that start at the service stage find a
# usable runtime instead of creating one mid-boot.
#
# Two roots are hardcoded inside the OMK binaries and cannot be relocated:
#   /data/misc/keystore/omk   runtime state — keybox.xml, injector.toml,
#                             config.toml, rpc.sock, logs/. Must be owned by the
#                             keystore uid (1017) at mode 0770 or keystore2
#                             cannot reach the RPC socket.
#   /data/adb/omk             supervisor state — pidfiles, restart flags,
#                             injector.payload. Upstream also links
#                             omkdata -> /data/misc/keystore/omk from here.

MODDIR=${0%/*}
OMK_RUN_DIR=/data/misc/keystore/omk
OMK_STATE_DIR=/data/adb/omk
CONFIG_DIR=/data/adb/tricky_store

mkdir -p "$OMK_RUN_DIR" "$OMK_RUN_DIR/logs"
chmod 0770 "$OMK_RUN_DIR" "$OMK_RUN_DIR/logs" 2>/dev/null
chown 1017:1017 "$OMK_RUN_DIR" "$OMK_RUN_DIR/logs" 2>/dev/null

mkdir -p "$OMK_STATE_DIR"
rm -f "$OMK_STATE_DIR/keymint-daemon.pid" "$OMK_STATE_DIR/injector-daemon.pid"
rm -f "$OMK_STATE_DIR/restart.keymint" "$OMK_STATE_DIR/restart.injector" "$OMK_STATE_DIR/restart.all"

# omk-daemon parks the crash trail here when it has to rebuild an undecryptable
# store. This runs before keymint starts, so clearing it now makes the file's
# presence mean "the rebuild happened this boot" — otherwise a boot that needed
# no recovery would still carry the previous boot's marker and the diagnostic
# would report a rebuild that never happened.
rm -f "$OMK_RUN_DIR/logs/keymint.log.store-reset"

# Upstream's hot-update slot. Its daemon prefers a binary here over the module
# copy, so a leftover from a previous OMK install would shadow the one we ship.
rm -f "$OMK_STATE_DIR/keymint" "$OMK_STATE_DIR/inject" "$OMK_STATE_DIR/injector"

# Upstream's own alias for the runtime dir. Recreate it when missing or pointing
# somewhere else, so tools that only know the /data/adb/omk path still work.
if [ ! -L "$OMK_STATE_DIR/omkdata" ] || \
   [ "$(readlink "$OMK_STATE_DIR/omkdata" 2>/dev/null)" != "$OMK_RUN_DIR" ]; then
    rm -f "$OMK_STATE_DIR/omkdata" 2>/dev/null
    ln -s "$OMK_RUN_DIR" "$OMK_STATE_DIR/omkdata" 2>/dev/null
fi

# Seed the two files keymint/injector read at startup, so a fresh install is not
# silently unconfigured. AlwaysStrong's own config dir is the source of truth for
# the keybox; omk-sync.sh owns both files from here on. config.toml is
# deliberately NOT pre-created: keymint generates its [crypto] secrets when it
# writes the file the first time, and inventing them ourselves would break every
# key created before the next reinstall.
if [ ! -f "$OMK_RUN_DIR/keybox.xml" ]; then
    if [ -s "$CONFIG_DIR/keybox.xml" ]; then
        cp -f "$CONFIG_DIR/keybox.xml" "$OMK_RUN_DIR/keybox.xml" 2>/dev/null
    elif [ -s "$MODDIR/keybox.xml" ]; then
        cp -f "$MODDIR/keybox.xml" "$OMK_RUN_DIR/keybox.xml" 2>/dev/null
    fi
fi
if [ ! -f "$OMK_RUN_DIR/injector.toml" ] && [ -s "$MODDIR/injector.toml" ]; then
    cp -f "$MODDIR/injector.toml" "$OMK_RUN_DIR/injector.toml" 2>/dev/null
fi

for f in "$OMK_RUN_DIR/keybox.xml" "$OMK_RUN_DIR/injector.toml"; do
    [ -f "$f" ] || continue
    chmod 0600 "$f" 2>/dev/null
    chown 1017:1017 "$f" 2>/dev/null
done