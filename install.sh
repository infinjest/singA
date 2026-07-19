#!/bin/sh
# singA — Transparent Proxy Gateway Installer
# Supports: OpenWrt snapshot (apk-based), MT7981/arm64 (Netis NX31, Xiaomi AX3000T, etc.)
# Usage:    sh install.sh [--dry-run]

set -e

DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

# ── REPOSITORY SETUP FOR AUTO-DOWNLOADING UTILITIES ───────────────────────────
GITHUB_USER="infinjest"
REPO_NAME="singA"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}"
SINGA_VERSION="0.10.5"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[singA] $*"; }
ok()  { echo "        ✓ $*"; }
die() { echo "        ✗ $*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "        ~ $*"
    else
        eval "$*"
    fi
}

inst() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "        ~ install -m $1 $2 → $3"
    else
        cp "$2" "$3"
        chmod "$1" "$3"
    fi
}

# Flexible deploy: prefer local files, fall back to downloading from GitHub
deploy_utility() {
    local file_name="$1" system_path="$2" mode="$3"
    if [ -f "${SCRIPT_DIR}/${file_name}" ]; then
        inst "$mode" "${SCRIPT_DIR}/${file_name}" "$system_path"
    elif [ -f "${SRC}/${file_name}" ]; then
        inst "$mode" "${SRC}/${file_name}" "$system_path"
    else
        log "       File ${file_name} not found locally. Downloading from GitHub..."
        if [ "$DRY_RUN" != "1" ]; then
            mkdir -p "$(dirname "$system_path")"
            curl -sL --http1.1 --max-time 30 --retry 5 --retry-delay 3 --retry-connrefused \
                "${RAW_BASE}/${file_name}" -o "$system_path" || die "Failed to download ${file_name}"
            chmod "$mode" "$system_path"
        else
            echo "        ~ curl -sL ${RAW_BASE}/${file_name} -o $system_path"
        fi
    fi
}

# ── Configuration & Arch Detection ────────────────────────────────────────────
UNAME_M=$(uname -m)
case "$UNAME_M" in
    aarch64|arm64) ARCH="linux-arm64" ;;
    # x86_64/armv7 are not built here: .github/workflows/mirror-singbox.yml
    # only mirrors linux-arm64 from upstream, so a TARBALL_URL for any other
    # arch would 404 and fail this installer with a confusing "binary not
    # found in archive" further down. Fail clearly here instead — see
    # README "Поддерживаемое оборудование" for what's actually tested.
    *) die "Unsupported architecture: $UNAME_M — only arm64 is currently built/mirrored. Supported hardware: MT7981/arm64 (Netis NX31, Xiaomi AX3000T, etc.)" ;;
esac

log "Detected architecture: ${UNAME_M} -> Target build: ${ARCH}"

SB_REPO="infinjest/singA"
SING_BOX_DIR="/etc/sing-box"
RPCD_DIR="/usr/libexec/rpcd"
ACL_DIR="/usr/share/rpcd/acl.d"
WWW_DIR="/www/singbox"
UI_PORT="1104"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/src"

# ── 1. Dependencies (apk vs opkg) ─────────────────────────────────────────────
log "[1/8] Checking dependencies..."
PKGS="curl ca-bundle kmod-nft-tproxy kmod-nft-socket lua luac libuci-lua libubus-lua unzip luci-lib-jsonc rpcd-mod-rpcsys uhttpd openssl-util coreutils-base64"

if command -v apk >/dev/null 2>&1; then
    log "       Detected 'apk' package manager (OpenWrt snapshot / Alpine Linux)"
    run "apk update >/dev/null 2>&1 || true"
    for pkg in $PKGS; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            log "       Installing ${pkg} via apk..."
            run "apk add ${pkg} >/dev/null 2>&1" || \
                echo "       WARNING: failed to install ${pkg}, continuing..."
        fi
    done
elif command -v opkg >/dev/null 2>&1; then
    log "       Detected 'opkg' package manager (Standard OpenWrt)"
    run "opkg update >/dev/null 2>&1 || true"
    for pkg in $PKGS; do
        if ! opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
            log "       Installing ${pkg} via opkg..."
            run "opkg install ${pkg} >/dev/null 2>&1" || \
                echo "       WARNING: failed to install ${pkg}, continuing..."
        fi
    done
else
    echo "       WARNING: No known package manager found (neither apk nor opkg). Skipping."
fi
ok "Dependencies handling complete"

# ── 2. Download sing-box-lx ─────────────────────────────────────────────
log "[2/8] Downloading sing-box-lx..."
LATEST=$(curl -sL --max-time 15 \
    "https://api.github.com/repos/${SB_REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[ -n "$LATEST" ] || die "Cannot reach GitHub API — check internet connection"
log "       Version: ${LATEST}"

if [ "$DRY_RUN" != "1" ]; then
    AVAIL_KB=$(df /overlay 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 30720 ]; then
        die "Not enough space in /overlay: ${AVAIL_KB} KB available, at least 30 MB required. Free up space and try again."
    fi
    [ -n "$AVAIL_KB" ] && log "       Free space in /overlay: ${AVAIL_KB} KB — OK"
fi

TARBALL_URL="https://github.com/${SB_REPO}/releases/download/${LATEST}/sing-box-${LATEST#v}-${ARCH}.tar.gz"
run "curl -sL --max-time 120 '${TARBALL_URL}' -o /tmp/sb.tar.gz" || die "Download failed"
run "tar -xzf /tmp/sb.tar.gz -C /tmp/ 2>/dev/null"

if [ "$DRY_RUN" != "1" ]; then
    SB_BIN=$(find /tmp -name "sing-box" -type f 2>/dev/null | head -1)
    [ -n "$SB_BIN" ] || die "sing-box binary not found in archive"
    cp "$SB_BIN" /usr/bin/sing-box
    chmod 755 /usr/bin/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*/
    ok "$(/usr/bin/sing-box version 2>/dev/null | head -1)"
else
    ok "sing-box binary (dry-run)"
fi

# ── 3. Create directory tree ──────────────────────────────────────────────────
log "[3/8] Creating directories..."
run "mkdir -p ${SING_BOX_DIR} ${WWW_DIR} /usr/lib/singbox"

if [ "$DRY_RUN" != "1" ]; then
    rm -rf "${SING_BOX_DIR}/sub_cache"
    ln -sf /var/run/sing-box/sub_cache "${SING_BOX_DIR}/sub_cache"
else
    echo "        ~ rm -rf ${SING_BOX_DIR}/sub_cache && ln -sf /var/run/sing-box/sub_cache ${SING_BOX_DIR}/sub_cache"
fi
ok "Directories ready (sub_cache → RAM, SRS → Flash)"

# ── 4. Install project files from src/ ───────────────────────────────────────
log "[4/8] Installing project files and automation tools..."

SRC_TARBALL_URL="https://codeload.github.com/${SB_REPO}/tar.gz/refs/heads/${BRANCH}"
if [ "$DRY_RUN" != "1" ]; then
    if curl -sL --http1.1 --max-time 30 --retry 3 --retry-delay 3 --retry-connrefused \
        "${SRC_TARBALL_URL}" -o /tmp/singa-src.tar.gz; then
        mkdir -p /tmp/singa-src
        tar -xzf /tmp/singa-src.tar.gz -C /tmp/singa-src
        SRC=$(find /tmp/singa-src -mindepth 1 -maxdepth 1 -type d | head -1)
        ok "Project files archive downloaded"
    else
        echo "       WARNING: archive download failed, falling back to per-file download"
    fi
fi

deploy_utility "src/rpcd--singbox.lua"            "${RPCD_DIR}/singbox"              "755"
deploy_utility "src/sbin--singbox-compiler.lua"   "/usr/sbin/singbox-compiler"       "755"
deploy_utility "src/sbin--singbox-sub-updater.sh" "/usr/sbin/singbox-sub-updater"    "755"

# ── singbox-logtail (inlined) ─────────────────────────────────────────────
# Was a separate src/sbin--singbox-logtail.lua deployed via deploy_utility
# like everything else above. Folded directly into install.sh instead — same
# reasoning as the RPCD ACL and UCI defaults below: one fewer file to keep in
# sync between here, GitHub, and a local checkout, and no separate raw-file
# download path for it to silently fall out of.
# Now runs as its own independent procd instance tailing `logread -f`,
# decoupled from sing-box's own process — see initd--sing-box.sh's
# start_service() for why (sing-box used to be piped through this script
# directly, which meant procd only tracked the wrapping shell's PID; if the
# shell died without the signal propagating to sing-box inside the pipe, it
# could survive as an untracked orphan still routing traffic after "stop").
# See the comments inside the heredoc below for the strip_ansi() fix itself
# (0.10.5 shipped with a color-only pattern that let non-color escape
# sequences through).
if [ "$DRY_RUN" != "1" ]; then
cat > "/usr/sbin/singbox-logtail" << 'SINGBOX_LOGTAIL_LUA'
#!/usr/bin/lua
-- Deployed inline from install.sh (see the "singbox-logtail" section there)
-- rather than as a separate src/sbin--singbox-logtail.lua — same reasoning
-- as the RPCD ACL / UCI defaults just below it in install.sh: one fewer file
-- to keep in sync, no separate GitHub raw-file fallback path for it to fall
-- out of. Installed as /usr/sbin/singbox-logtail.
--
-- Runs as its own procd instance ("sing-box-logtail" in initd--sing-box.sh),
-- independent of the "sing-box" instance:
--     logread -f -e sing-box | singbox-logtail
-- sing-box's own instance still writes to syslog via stdout/stderr=1
-- (unchanged); this just follows that same syslog stream, filtered to
-- sing-box's own tag, instead of sitting directly in sing-box's own stdout
-- pipe — deliberately, so that if this pipe ever loses a process to procd's
-- pipe/signal-propagation limits, the sing-box process itself (and thus
-- actual routing) is never affected, only the log viewer. See
-- initd--sing-box.sh for the far more important situation this replaced
-- (sing-box itself used to be the one wrapped in a pipe like this).
--
-- Keeps the last MAX_LINES lines in memory and rewrites LOG_FILE (tmpfs) on
-- every new line. rpcd's get_log reads LOG_FILE directly instead of
-- shelling out to `logread -e sing-box | tail -50` on every request — this
-- file only ever contains sing-box's own output (nothing else can write to
-- it), whereas logread mixes in every other service tagged similarly and
-- needs a broader tail to compensate.
--
-- LOG_FILE lives on /var/run (tmpfs) — a full-file rewrite per line is a
-- RAM-only operation, no flash wear, and at 100 lines the CPU cost is
-- negligible even on every single line on low-power routers.

local LOG_FILE  = "/var/run/sing-box_log.txt"
local MAX_LINES = 100

-- sing-box's own logger emits ANSI escape codes even when stdout isn't a
-- TTY, and passing --disable-color on the command line does not reliably
-- suppress all of them (confirmed by testing: cursor hide/show
-- "ESC[?25l"/"ESC[?25h", erase-line "ESC[2K", and cursor-movement sequences
-- still show up around its startup banner even with the flag set) — fine on
-- a real terminal, garbage ("[36mINFO[0m...", "[2K", stray carriage
-- returns) when dumped as plain text into the log modal. logread's own
-- timestamp/tag prefix on each line is untouched by any of this — only what
-- sing-box itself wrote is affected.
--
-- Matches the general CSI grammar (ESC '[' + parameter bytes 0-9;:<=>? + a
-- single final letter) rather than a color-only "ESC[<digits/;>m" pattern,
-- so cursor/erase-line codes get caught too, not just "...m" SGR/color
-- codes. Also drops stray carriage returns left behind by erase-line/redraw
-- sequences, so a mid-line "\r" can't make two log lines visually collapse
-- into one in the <pre> log viewer.
local function strip_ansi(s)
    s = s:gsub("\27%[[%d;:<=>?]*%a", "")
    return (s:gsub("\r", ""))
end

local buf = {}

local function flush_to_disk()
    local f = io.open(LOG_FILE, "w")
    if not f then return end
    f:write(table.concat(buf, "\n"))
    if #buf > 0 then f:write("\n") end
    f:close()
end

for line in io.stdin:lines() do
    table.insert(buf, strip_ansi(line))
    if #buf > MAX_LINES then table.remove(buf, 1) end
    flush_to_disk()
end
SINGBOX_LOGTAIL_LUA
chmod 755 "/usr/sbin/singbox-logtail"
else
    echo "        ~ install -m 755 (inlined) -> /usr/sbin/singbox-logtail"
fi
ok "/usr/sbin/singbox-logtail (inlined)"
deploy_utility "src/initd--sing-box.sh"           "/etc/init.d/sing-box"             "755"
deploy_utility "src/etc-singbox--update-rules.sh" "${SING_BOX_DIR}/update-rules.sh"  "755"
deploy_utility "src/lib--singbox-validate.lua"    "/usr/lib/singbox/validate.lua"    "644"
deploy_utility "src/www--singbox.html"            "${WWW_DIR}/singbox.html"           "644"
if [ "$DRY_RUN" != "1" ]; then
    sed -i "s/@@SINGA_VERSION@@/${SINGA_VERSION}/g" "${WWW_DIR}/singbox.html"
fi
deploy_utility "integrity-test.sh"          "/usr/sbin/singbox-integrity-test"    "755"
deploy_utility "compiler-test.sh"           "/usr/sbin/singbox-compiler-test"     "755"
deploy_utility "uninstall.sh"  "/usr/sbin/singbox-uninstall"  "755"
ok "Core files and automation utilities installed successfully"

# ── 5. Write RPcd ACL (inlined) ───────────────────────────────────────────────
log "[5/8] Writing RPcd ACL..."
if [ "$DRY_RUN" != "1" ]; then
cat > "${ACL_DIR}/singbox.json" << 'EOF'
{
  "singbox-ui": {
    "description": "Sing-Box Control Plane UI access",
    "read": {
      "ubus": { "singbox": ["status", "get_config", "get_active_node"] },
      "uci":  { "singbox": ["*"] }
    },
    "write": {
      "ubus": { "singbox": [
        "add_node", "edit_node", "del_node", "set_settings",
        "add_rule", "del_rule",
        "add_dns_rule", "del_dns_rule",
        "add_subscription", "update_sub",
        "apply", "check_connectivity", "get_running_config", "get_log"
      ]},
      "uci": { "singbox": ["*"] }
    }
  }
}
EOF
fi
ok "${ACL_DIR}/singbox.json"

# ── 6. UCI default config (inlined, preserved if exists) ─────────────────────
log "[6/8] Setting up UCI config..."
if command -v uci >/dev/null 2>&1; then
    if ! uci -q get singbox.main >/dev/null 2>&1; then
        if [ "$DRY_RUN" != "1" ]; then
            touch /etc/config/singbox
            uci batch << 'UCI'
set singbox.main=main
set singbox.main.enabled=0
set singbox.main.route_mode=3
set singbox.main.custom_dns=https://dns.cloudflare.com/dns-query
set singbox.main.local_dns=tcp://1.1.1.1
set singbox.main.dns_remote_detour=direct
set singbox.main.block_dot=1
set singbox.main.block_quic=1
set singbox.main.cron_schedule="0 4 * * 1"
commit singbox
UCI
        else
            echo "        ~ uci batch: create singbox.main defaults"
        fi
        ok "Default config created"
    else
        # Upgrade — migrate rdbypass → route_mode if needed
        if [ -z "$(uci -q get singbox.main.route_mode 2>/dev/null)" ]; then
            uci set singbox.main.route_mode=3
            uci -q delete singbox.main.rdbypass   2>/dev/null || true
            uci -q delete singbox.main.tproxy_port 2>/dev/null || true
            [ -z "$(uci -q get singbox.main.cron_schedule 2>/dev/null)" ] && \
                uci set singbox.main.cron_schedule="0 4 * * 1"
            uci commit singbox
            ok "Migrated: rdbypass → route_mode=$(uci -q get singbox.main.route_mode)"
        else
            ok "Existing config up to date (route_mode=$(uci -q get singbox.main.route_mode))"
        fi
        # 0.10.3: the failover option was retired — URLtest kicks in automatically with 2+ nodes
        if [ -n "$(uci -q get singbox.main.failover 2>/dev/null)" ]; then
            uci -q delete singbox.main.failover 2>/dev/null || true
            uci commit singbox
            ok "Removed deprecated singbox.main.failover"
        fi
        # 0.10.5: block_dot (blocks known public DNS resolvers by IP)
        # is NOT written to UCI on upgrade — it's a pure nft add-on (unlike
        # block_quic below, it doesn't touch sing-box's own route.rules), so
        # only initd reads it, via `uci -q get ... || echo 1`, and the filter
        # turns on right after the upgrade even for existing configs, without
        # an explicit uci set. This is a deliberate departure from the usual
        # "don't touch someone else's config silently" policy — can be
        # disabled with: uci set singbox.main.block_dot=0
        if [ -z "$(uci -q get singbox.main.block_dot 2>/dev/null)" ]; then
            log "       0.10.5: blocking of known public DNS resolvers is enabled by default,"
            log "       including for this existing configuration. Disable with: uci set singbox.main.block_dot=0"
        fi
        # 0.10.5: block_quic — unlike block_dot above, this one changes
        # sing-box's own route.rules (structural, not just an nft add-on), so
        # it gets an explicit uci set on upgrade rather than a silent
        # code-level fallback default.
        if [ -z "$(uci -q get singbox.main.block_quic 2>/dev/null)" ]; then
            uci set singbox.main.block_quic=1
            uci commit singbox
            ok "Migrated: block_quic=1 (QUIC blocked by default; disable with: uci set singbox.main.block_quic=0)"
        fi
    fi
else
    echo "        ~ Skipping UCI setup (command 'uci' not found — pure Docker context?)"
fi

# ── 7. Configure uhttpd on dedicated port ────────────────────────────────────
log "[7/8] Configuring UI on port ${UI_PORT}..."
if command -v uci >/dev/null 2>&1; then
    if ! uci -q get uhttpd.singbox >/dev/null 2>&1; then
        run "uci set uhttpd.singbox=uhttpd"
        run "uci set uhttpd.singbox.listen_http='0.0.0.0:${UI_PORT}'"
        run "uci set uhttpd.singbox.home='${WWW_DIR}'"
        run "uci set uhttpd.singbox.index_page='singbox.html'"
        run "uci set uhttpd.singbox.rfc1918_filter='1'"
        run "uci set uhttpd.singbox.ubus_prefix='/ubus'"
        run "uci commit uhttpd"
        ok "UI on port ${UI_PORT} (LAN only)"
    else
        # Upgrade: make sure ubus_prefix is set
        run "uci set uhttpd.singbox.ubus_prefix='/ubus'"
        run "uci commit uhttpd"
        ok "uhttpd instance updated"
    fi
else
    echo "        ~ Skipping uhttpd config (command 'uci' not found)"
fi

# ── 8. Blocklists, services, cron ─────────────────────────────────────────────
log "[8/8] Final setup..."

if [ "$DRY_RUN" != "1" ]; then
    "${SING_BOX_DIR}/update-rules.sh" && ok "Blocklists downloaded" \
        || echo "        WARNING: blocklist download failed — run update-rules.sh manually later"
else
    echo "        ~ ${SING_BOX_DIR}/update-rules.sh"
fi

if [ -x "/etc/init.d/sing-box" ] && [ -x "/etc/init.d/rpcd" ]; then
    run "/etc/init.d/sing-box enable"
    run "/etc/init.d/rpcd restart"
    run "/etc/init.d/uhttpd restart"
else
    echo "        ~ Skipping service management (not a fully booted OpenWrt system)"
fi

if command -v crontab >/dev/null 2>&1; then
    if ! crontab -l 2>/dev/null | grep -qF "update-rules.sh"; then
        run "(crontab -l 2>/dev/null; echo '0 4 * * 1 ${SING_BOX_DIR}/update-rules.sh >/dev/null 2>&1') | crontab -"
        run "/etc/init.d/cron restart 2>/dev/null || true"
        ok "Weekly blocklist update scheduled (Mon 04:00)"
    fi
else
    echo "        ~ Skipping crontab setup (command 'crontab' not found)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
LAN_IP="127.0.0.1"
if command -v uci >/dev/null 2>&1; then
    LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null | cut -d/ -f1 || echo "192.168.1.1")
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DRY_RUN" = "1" ]; then
echo "  Dry-run complete — no changes were made"
else
echo "  singA installed successfully"
echo "  → http://${LAN_IP}:${UI_PORT}/singbox.html"
echo ""
echo "  Useful commands:"
echo "  Integration tests (only right after a clean install):  sh /usr/sbin/singbox-integrity-test"
echo "  Check compiled JSON for every route_mode: sh /usr/sbin/singbox-compiler-test"
echo "  Update rule databases manually: sh /etc/sing-box/update-rules.sh"
echo "  Uninstall (--purge to also remove the UCI config):   sh /usr/sbin/singbox-uninstall"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
