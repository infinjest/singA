#!/bin/sh
# singA — Transparent Proxy Gateway Installer
# Supports: OpenWrt snapshot (apk-based), MT7981/arm64 (Netis NX31, Xiaomi AX3000T, etc.)
# Usage:    sh install.sh [--dry-run]

set -e

DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

# ── НАСТРОЙКА РЕПОЗИТОРИЯ ДЛЯ АВТОСКАЧИВАНИЯ УТИЛИТ ───────────────────────────
GITHUB_USER="infinjest"
REPO_NAME="singA"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}"
SINGA_VERSION="0.10.3"

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

# Функция гибкого деплоя: приоритет локальным файлам, фолбек на скачивание с GitHub
deploy_utility() {
    local file_name="$1" system_path="$2" mode="$3"
    if [ -f "${SCRIPT_DIR}/${file_name}" ]; then
        inst "$mode" "${SCRIPT_DIR}/${file_name}" "$system_path"
    elif [ -f "${SRC}/${file_name}" ]; then
        inst "$mode" "${SRC}/${file_name}" "$system_path"
    else
        log "       Файл ${file_name} не найден локально. Скачиваю с GitHub..."
        if [ "$DRY_RUN" != "1" ]; then
            mkdir -p "$(dirname "$system_path")"
            curl -sL --http1.1 --max-time 30 --retry 5 --retry-delay 3 --retry-connrefused \
                "${RAW_BASE}/${file_name}" -o "$system_path" || die "Не удалось скачать ${file_name}"
            chmod "$mode" "$system_path"
        else
            echo "        ~ curl -sL ${RAW_BASE}/${file_name} -o $system_path"
        fi
    fi
}

# ── Configuration & Arch Detection ────────────────────────────────────────────
UNAME_M=$(uname -m)
case "$UNAME_M" in
    x86_64)   ARCH="linux-amd64"  ;;
    aarch64|arm64) ARCH="linux-arm64" ;;
    armv7l|armv8l) ARCH="linux-armv7" ;;
    *) die "Unsupported architecture detected: $UNAME_M" ;;
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
        die "Недостаточно места в /overlay: ${AVAIL_KB} KB доступно, требуется минимум 30 MB. Освободите место и повторите."
    fi
    [ -n "$AVAIL_KB" ] && log "       Свободно в /overlay: ${AVAIL_KB} KB — OK"
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
run "mkdir -p ${SING_BOX_DIR} ${WWW_DIR}"

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
        TOPDIR=$(find /tmp/singa-src -mindepth 1 -maxdepth 1 -type d | head -1)
        mv "${TOPDIR}"/* /tmp/singa-src/
        rmdir "${TOPDIR}"
        SRC="/tmp/singa-src"
        ok "Project files archive downloaded"
    else
        echo "       WARNING: archive download failed, falling back to per-file download"
    fi
fi

deploy_utility "src/rpcd--singbox.lua"            "${RPCD_DIR}/singbox"              "755"
deploy_utility "src/sbin--singbox-compiler.lua"   "/usr/sbin/singbox-compiler"       "755"
deploy_utility "src/sbin--singbox-sub-updater.sh" "/usr/sbin/singbox-sub-updater"    "755"
deploy_utility "src/initd--sing-box.sh"           "/etc/init.d/sing-box"             "755"
deploy_utility "src/etc-singbox--update-rules.sh" "${SING_BOX_DIR}/update-rules.sh"  "755"
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
        "add_rule", "del_rule", "set_rules",
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
set singbox.main.local_dns=tcp://77.88.8.8
set singbox.main.dns_remote_detour=direct
set singbox.main.cron_schedule=0 4 * * 1
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
        # 0.10.3: опция failover упразднена — URLtest включается автоматически при 2+ узлах
        if [ -n "$(uci -q get singbox.main.failover 2>/dev/null)" ]; then
            uci -q delete singbox.main.failover 2>/dev/null || true
            uci commit singbox
            ok "Removed deprecated singbox.main.failover"
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
        # Апгрейд: убеждаемся что ubus_prefix выставлен
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
echo "  Полезные команды:"
echo "  Запуск интеграционных тестов:  sh /usr/sbin/singbox-integrity-test"
echo "  Проверка JSON для всех режимов: sh /usr/sbin/singbox-compiler-test"
echo "  Полное, бесследное удаление:   sh /usr/sbin/singbox-uninstall"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
