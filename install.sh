#!/bin/sh
# singA — Transparent Proxy Gateway Installer
# Supports: OpenWrt 23.x+, MT7981/arm64 (Netis NX31, Xiaomi AX3000T, etc.), x86_64 Docker
# Usage:    sh install.sh [--dry-run]

set -e

DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

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
    # inst <mode> <src> <dst>
    if [ "$DRY_RUN" = "1" ]; then
        echo "        ~ install -m $1 $2 → $3"
    else
        install -m "$1" "$2" "$3"
    fi
}

# ── Configuration & Arch Detection ────────────────────────────────────────────
UNAME_M=$(uname -m)
case "$UNAME_M" in
    x86_64)
        ARCH="linux-amd64"
        ;;
    aarch64|arm64)
        ARCH="linux-arm64"
        ;;
    armv7l|armv8l)
        ARCH="linux-armv7"
        ;;
    *)
        die "Unsupported architecture detected: $UNAME_M"
        ;;
esac

log "Detected architecture: ${UNAME_M} -> Target build: ${ARCH}"

SB_REPO="shtorm-7/sing-box-extended"   # TODO: replace with your mirror repo
SING_BOX_DIR="/etc/sing-box"
SUB_CACHE_DIR="/etc/sing-box/sub_cache"
RPCD_DIR="/usr/libexec/rpcd"
ACL_DIR="/usr/share/rpcd/acl.d"
WWW_DIR="/www/singbox"
UI_PORT="1104"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/src"

# ── 1. Dependencies (apk vs opkg) ─────────────────────────────────────────────
log "[1/8] Checking dependencies..."
PKGS="curl ca-bundle kmod-nft-tproxy luci-lib-jsonc rpcd-mod-rpcsys uhttpd openssl-util coreutils-base64 iproute2-ss"

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

# ── 2. Download sing-box-extended ─────────────────────────────────────────────
log "[2/8] Downloading sing-box-extended..."
LATEST=$(curl -sL --max-time 15 \
    "https://api.github.com/repos/${SB_REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[ -n "$LATEST" ] || die "Cannot reach GitHub API — check internet connection"
log "       Version: ${LATEST}"

TARBALL_URL="https://github.com/${SB_REPO}/releases/download/${LATEST}/sing-box-${LATEST#v}-${ARCH}.tar.gz"
run "curl -sL --max-time 120 '${TARBALL_URL}' -o /tmp/sb.tar.gz" || die "Download failed"
run "tar -xzf /tmp/sb.tar.gz -C /tmp/ 2>/dev/null"

if [ "$DRY_RUN" != "1" ]; then
    SB_BIN=$(find /tmp -name "sing-box" -type f 2>/dev/null | head -1)
    [ -n "$SB_BIN" ] || die "sing-box binary not found in archive"
    install -m 755 "$SB_BIN" /usr/bin/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*/
    ok "$(/usr/bin/sing-box version 2>/dev/null | head -1)"
else
    ok "sing-box binary (dry-run)"
fi

# ── 3. Create directory tree ──────────────────────────────────────────────────
log "[3/8] Creating directories..."
run "mkdir -p ${SING_BOX_DIR} ${SUB_CACHE_DIR} ${WWW_DIR}"
ok "${SING_BOX_DIR}, ${SUB_CACHE_DIR}, ${WWW_DIR}"

# ── 4. Install project files from src/ ───────────────────────────────────────
log "[4/8] Installing project files..."
inst 755 "${SRC}/rpcd--singbox.lua"            "${RPCD_DIR}/singbox"
inst 755 "${SRC}/sbin--singbox-compiler.lua"   "/usr/sbin/singbox-compiler"
inst 755 "${SRC}/sbin--singbox-sub-updater.sh" "/usr/sbin/singbox-sub-updater"
inst 755 "${SRC}/initd--sing-box.sh"           "/etc/init.d/sing-box"
inst 755 "${SRC}/etc-singbox--update-rules.sh" "${SING_BOX_DIR}/update-rules.sh"
inst 644 "${SRC}/www--singbox.html"            "${WWW_DIR}/singbox.html"
ok "6 files installed"

# ── 5. Write RPcd ACL (inlined) ───────────────────────────────────────────────
log "[5/8] Writing RPcd ACL..."
if [ "$DRY_RUN" != "1" ]; then
cat > "${ACL_DIR}/singbox.json" << 'EOF'
{
  "singbox-ui": {
    "description": "Sing-Box Control Plane UI access",
    "read": {
      "ubus": { "singbox": ["status", "get_config"] },
      "uci":  { "singbox": ["*"] }
    },
    "write": {
      "ubus": { "singbox": [
        "add_node", "edit_node", "del_node", "set_settings",
        "add_rule", "del_rule", "set_rules",
        "add_subscription", "update_sub",
        "apply", "change_password"
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
        uci batch << 'UCI'
set singbox.main=main
set singbox.main.enabled=0
set singbox.main.tproxy_port=7893
set singbox.main.rdbypass=0
set singbox.main.failover=0
set singbox.main.custom_dns=https://dns.cloudflare.com/dns-query
set singbox.main.local_dns=tcp://77.88.8.8
commit singbox
UCI
        else
            echo "        ~ uci batch: create singbox.main defaults"
        fi
        ok "Default config created"
    else
        ok "Existing config preserved (not overwritten)"
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
        run "uci commit uhttpd"
        ok "UI on port ${UI_PORT} (LAN only)"
    else
        ok "uhttpd instance already configured"
    fi
else
    echo "        ~ Skipping uhttpd config (command 'uci' not found)"
fi

# ── 8. Blocklists, services, cron ─────────────────────────────────────────────
log "[8/8] Final setup..."

# Blocklists — non-fatal if no internet yet
if [ "$DRY_RUN" != "1" ]; then
    "${SING_BOX_DIR}/update-rules.sh" && ok "Blocklists downloaded" \
        || echo "        WARNING: blocklist download failed — run update-rules.sh manually later"
else
    echo "        ~ ${SING_BOX_DIR}/update-rules.sh"
fi

# Services (only if init.d commands exist)
if [ -x "/etc/init.d/sing-box" ] && [ -x "/etc/init.d/rpcd" ]; then
    run "/etc/init.d/sing-box enable"
    run "/etc/init.d/rpcd restart"
    run "/etc/init.d/uhttpd restart"
else
    echo "        ~ Skipping service management (not a fully booted OpenWrt system)"
fi

# Weekly cron: every Monday at 04:00
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
    LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DRY_RUN" = "1" ]; then
echo "  Dry-run complete — no changes were made"
else
echo "  singA installed successfully"
echo "  → http://${LAN_IP}:${UI_PORT}"
echo "  1. Add nodes or subscriptions"
echo "  2. Enable TProxy"
echo "  3. Press Apply"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"