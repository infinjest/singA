#!/bin/sh
# /etc/sing-box/update-rules.sh
# Updates the routing rule databases.
# Behavior is driven by singbox.main.route_mode:
#   Mode 2 → geosite-ru.srs (MetaCubeX), remove mode-3 files
#   Mode 3 → ru-blocked.srs + geoip-ru-blocked.srs (runetfreedom), remove mode-2 files
#   Mode 1 → no SRS needed, remove all
#
# IMPORTANT: every download goes through a temp file + a validity check
# (magic bytes, see check_srs_valid/check_zip_valid below), and only then an
# atomic mv over the live path. If a download fails validation, the working
# file is left untouched (compiler.lua keeps using the old but valid
# database instead of getting a corrupt rule_set and crashing sing-box).

# --no-reload: fetch/validate rule databases as usual but skip the final
# "reload sing-box if running" step. Used by compiler-test.sh, which calls
# this script per route_mode purely to get fresh SRS files for `sing-box
# check` — it must NOT push its temporary dummy-node/route_mode UCI state
# into the actually-running service via a real reload (see CHANGELOG).
NO_RELOAD=0
[ "$1" = "--no-reload" ] && NO_RELOAD=1

SING_BOX_DIR="/etc/sing-box"
# Mode 3 files (runetfreedom)
MODE3_FILES="ru-blocked.srs geoip-ru-blocked.srs"
MODE3_ZIP_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/sing-box.zip"
# Mode 2 file (MetaCubeX geosite:ru).
# IMPORTANT: the file in the repo is named category-ru.srs, not ru.srs —
# "ru.srs" returns a 404 (a github page, not the file itself), which used to
# make curl fail with -f (exit 22), or silently save garbage over the working
# file without -f.
MODE2_FILE="geosite-ru.srs"
MODE2_URL="https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/category-ru.srs"

TMP_ZIP="/tmp/sb-rules.$$.zip"
TMP_DIR="/tmp/sb-rules.$$"
TMP_SRS="/tmp/sb-rules.$$.srs"
trap "rm -rf '$TMP_ZIP' '$TMP_DIR' '$TMP_SRS'" EXIT

mkdir -p "$SING_BOX_DIR"
ROUTE_MODE=$(uci -q get singbox.main.route_mode 2>/dev/null || echo "3")
echo "route_mode=${ROUTE_MODE}"

# Validate an .srs file by its magic bytes ("SRS" at the start), not by size.
# Legitimate geosite categories can be just a few KB (e.g. category-ru.srs
# ~7.5KB), so a size threshold would either let garbage through or wrongly
# reject small-but-valid databases.
# IMPORTANT: uses `head -c`, not `od` — BusyBox od on the router formats
# output differently (`-An -c -N3` doesn't behave like GNU coreutils), so a
# magic-byte comparison against it would always fail, even on a valid file.
check_srs_valid() {
    f="$1"
    [ -s "$f" ] || return 1
    magic=$(head -c 3 "$f" 2>/dev/null)
    [ "$magic" = "SRS" ] || return 1
    return 0
}

# Validate a .zip file by its magic bytes ("PK").
check_zip_valid() {
    f="$1"
    [ -s "$f" ] || return 1
    magic=$(head -c 2 "$f" 2>/dev/null)
    [ "$magic" = "PK" ] || return 1
    return 0
}

# ── Mode 2: geosite:ru (everything via proxy except RU) ──────────────────────
if [ "$ROUTE_MODE" = "2" ]; then
    # Remove mode-3 files if they're still around
    for f in $MODE3_FILES; do
        rm -f "${SING_BOX_DIR}/${f}" && echo "Removed: ${f}"
    done

    echo "Downloading geosite-ru.srs (MetaCubeX)..."

    MODE2_OK=0
    MODE2_CURL_RC=0
    if curl -fsL --local-port 57321-57325 --connect-timeout 15 --max-time 60 "$MODE2_URL" -o "$TMP_SRS"; then
        MODE2_OK=1
    else
        MODE2_CURL_RC=$?
        if curl -fsL --local-port 57330-57334 --connect-timeout 15 --max-time 60 "$MODE2_URL" -o "$TMP_SRS"; then
            # raw.githubusercontent.com can itself be flaky in RU directly (unrelated
            # to node health) — retry over the currently active proxy node, as before
            echo "Direct download failed, succeeded via the current proxy node"
            MODE2_OK=1
        else
            MODE2_CURL_RC=$?
        fi
    fi
    if [ "$MODE2_OK" = "1" ]; then

        if check_srs_valid "$TMP_SRS"; then
            sz=$(wc -c < "$TMP_SRS")
            mv "$TMP_SRS" "${SING_BOX_DIR}/${MODE2_FILE}"
            echo "OK: ${MODE2_FILE} (${sz} bytes)"
        else
            sz=$( [ -f "$TMP_SRS" ] && wc -c < "$TMP_SRS" || echo 0 )
            echo "ERROR: downloaded ${MODE2_FILE} is not a valid SRS file (${sz} bytes, bad magic). Keeping previous file untouched."
            exit 1
        fi
    else
        echo "ERROR: download failed for $MODE2_URL (curl exit ${MODE2_CURL_RC}). Keeping previous file untouched."
        exit 1
    fi

# ── Mode 3: ru-blocked (default, bypass RKN blocking) ─────────────────────────
elif [ "$ROUTE_MODE" = "3" ]; then
    # Remove the mode-2 file if it's still around
    rm -f "${SING_BOX_DIR}/${MODE2_FILE}" && echo "Removed: ${MODE2_FILE}"

    echo "Downloading sing-box.zip (runetfreedom)..."
    if ! curl -fsL --local-port 57321-57325 --connect-timeout 15 --max-time 180 "$MODE3_ZIP_URL" -o "$TMP_ZIP"; then
        echo "Direct download failed, retrying via the current proxy node..."
        if ! curl -fsL --local-port 57330-57334 --connect-timeout 15 --max-time 180 "$MODE3_ZIP_URL" -o "$TMP_ZIP"; then
            echo "ERROR: download failed for $MODE3_ZIP_URL. Keeping previous files untouched."
            exit 1
        fi
    fi
    if ! check_zip_valid "$TMP_ZIP"; then
        echo "ERROR: downloaded sing-box.zip looks invalid (bad magic). Keeping previous files untouched."
        exit 1
    fi

    mkdir -p "$TMP_DIR"
    if ! unzip -o -q "$TMP_ZIP" \
        "rule-set-geosite/geosite-ru-blocked.srs" \
        "rule-set-geoip/geoip-ru-blocked.srs" \
        -d "$TMP_DIR"; then
        echo "ERROR: unzip failed. Keeping previous files untouched."
        exit 1
    fi

    NEW_GEOSITE="$TMP_DIR/rule-set-geosite/geosite-ru-blocked.srs"
    NEW_GEOIP="$TMP_DIR/rule-set-geoip/geoip-ru-blocked.srs"

    if check_srs_valid "$NEW_GEOSITE" && check_srs_valid "$NEW_GEOIP"; then
        mv "$NEW_GEOSITE" "${SING_BOX_DIR}/ru-blocked.srs"
        mv "$NEW_GEOIP"   "${SING_BOX_DIR}/geoip-ru-blocked.srs"
        for f in $MODE3_FILES; do
            echo "OK: ${f} ($(wc -c < "${SING_BOX_DIR}/${f}") bytes)"
        done
    else
        echo "ERROR: extracted SRS files are not valid (bad magic). Keeping previous files untouched."
        exit 1
    fi

# ── Mode 1 (and any other value): no SRS needed ───────────────────────────────
else
    echo "route_mode=${ROUTE_MODE}: no SRS files needed"
    for f in $MODE3_FILES $MODE2_FILE; do
        rm -f "${SING_BOX_DIR}/${f}" && echo "Removed: ${f}"
    done
fi

# ── Reload sing-box if it's running ───────────────────────────────────────────
if [ "$NO_RELOAD" != "1" ] && pidof sing-box > /dev/null 2>&1; then
    echo "Reloading sing-box..."
    /etc/init.d/sing-box reload
fi
echo "Done."