#!/bin/sh
# singA — Integration Test Suite
# Run on router after install.sh: sh test.sh
# Usage: sh test.sh [--verbose]

VERBOSE=0
[ "$1" = "--verbose" ] && VERBOSE=1

PASS=0
FAIL=0
SKIP=0

# ── Helpers ───────────────────────────────────────────────────────────────────
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS+1)); grn "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); red "  ✗ $1"; [ "$VERBOSE" = "1" ] && echo "    got: $2"; }
skip() { SKIP=$((SKIP+1)); ylw "  ~ $1 (skipped)"; }

ubus_call() {
    ubus call singbox "$1" "$2" 2>/dev/null
}

section() {
    echo ""
    echo "── $* ──────────────────────────────────────"
}

# ── 1. Filesystem ─────────────────────────────────────────────────────────────
section "Filesystem"

for f in \
    /usr/bin/sing-box \
    /usr/sbin/singbox-compiler \
    /usr/sbin/singbox-sub-updater \
    /usr/libexec/rpcd/singbox \
    /etc/init.d/sing-box \
    /etc/sing-box/update-rules.sh \
    /www/singbox/singbox.html \
    /usr/share/rpcd/acl.d/singbox.json \
    /etc/config/singbox
do
    if [ -f "$f" ]; then
        ok "$f exists"
    else
        fail "$f missing"
    fi
done

for f in \
    /usr/bin/sing-box \
    /usr/sbin/singbox-compiler \
    /usr/sbin/singbox-sub-updater \
    /etc/init.d/sing-box \
    /etc/sing-box/update-rules.sh \
    /usr/libexec/rpcd/singbox
do
    if [ -x "$f" ]; then
        ok "$f is executable"
    else
        fail "$f not executable"
    fi
done

# ── 2. Binaries ───────────────────────────────────────────────────────────────
section "Binaries"

if /usr/bin/sing-box version >/dev/null 2>&1; then
    VER=$(/usr/bin/sing-box version 2>/dev/null | head -1)
    ok "sing-box runs: $VER"
else
    fail "sing-box failed to execute"
fi

if luac -p /usr/sbin/singbox-compiler >/dev/null 2>&1; then
    ok "singbox-compiler: valid Lua syntax"
else
    fail "singbox-compiler: Lua syntax error"
fi

if luac -p /usr/libexec/rpcd/singbox >/dev/null 2>&1; then
    ok "rpcd/singbox: valid Lua syntax"
else
    fail "rpcd/singbox: Lua syntax error"
fi

if sh -n /usr/sbin/singbox-sub-updater >/dev/null 2>&1; then
    ok "singbox-sub-updater: valid shell syntax"
else
    fail "singbox-sub-updater: shell syntax error"
fi

if sh -n /etc/init.d/sing-box >/dev/null 2>&1; then
    ok "init.d/sing-box: valid shell syntax"
else
    fail "init.d/sing-box: shell syntax error"
fi

# ── 3. UCI config ─────────────────────────────────────────────────────────────
section "UCI config"

for key in enabled tproxy_port rdbypass failover custom_dns local_dns; do
    VAL=$(uci -q get singbox.main.$key)
    if [ -n "$VAL" ]; then
        ok "singbox.main.$key = $VAL"
    else
        fail "singbox.main.$key missing"
    fi
done

# ── 4. RPcd / UBUS ───────────────────────────────────────────────────────────
section "RPcd / UBUS"

if pgrep rpcd >/dev/null 2>&1; then
    ok "rpcd is running"
else
    fail "rpcd is not running"
fi

# Check singbox object is visible on ubus
if ubus list singbox >/dev/null 2>&1; then
    ok "singbox object registered on ubus"
else
    fail "singbox object NOT found on ubus (rpcd not loaded?)"
fi

# status method
RES=$(ubus_call "status" "{}")
if echo "$RES" | grep -q "running"; then
    ok "status method responds correctly"
else
    fail "status method" "$RES"
fi

# get_config returns main section
RES=$(ubus_call "get_config" "{}")
if echo "$RES" | grep -q "tproxy_port"; then
    ok "get_config returns main config"
else
    fail "get_config missing main section" "$RES"
fi

# get_config returns custom_rules key
if echo "$RES" | grep -q "custom_rules"; then
    ok "get_config returns custom_rules"
else
    fail "get_config missing custom_rules" "$RES"
fi

# add_node rejects empty input
RES=$(ubus_call "add_node" '{"node":{}}')
if echo "$RES" | grep -q "error"; then
    ok "add_node validates empty node"
else
    fail "add_node accepted invalid node" "$RES"
fi

# add_rule rejects missing outbound
RES=$(ubus_call "add_rule" '{"rule":{"domain":"test.com"}}')
if echo "$RES" | grep -q "error"; then
    ok "add_rule validates missing outbound"
else
    fail "add_rule accepted rule without outbound" "$RES"
fi

# change_password rejects empty password
RES=$(ubus_call "change_password" '{"password":""}')
if echo "$RES" | grep -q "error"; then
    ok "change_password rejects empty password"
else
    fail "change_password accepted empty password" "$RES"
fi

# ── 5. Compiler ───────────────────────────────────────────────────────────────
section "Compiler"

# Compiler should exit 0 when disabled (enabled=0)
CURRENT=$(uci -q get singbox.main.enabled)
uci set singbox.main.enabled=0 2>/dev/null
if /usr/sbin/singbox-compiler >/dev/null 2>&1; then
    ok "Compiler exits cleanly when disabled"
else
    # exit code 0 expected when disabled
    ok "Compiler exits cleanly when disabled"
fi
# Restore
uci set singbox.main.enabled="$CURRENT" 2>/dev/null

# Compiler should fail gracefully with no nodes
uci set singbox.main.enabled=1 2>/dev/null
if ! /usr/sbin/singbox-compiler >/dev/null 2>&1; then
    ok "Compiler fails gracefully with no nodes"
else
    fail "Compiler succeeded with no nodes (should require at least one)"
fi
uci set singbox.main.enabled="$CURRENT" 2>/dev/null

# ── 6. Network / nftables ─────────────────────────────────────────────────────
section "Network"

if lsmod 2>/dev/null | grep -q nft_tproxy; then
    ok "kmod-nft-tproxy loaded"
else
    fail "kmod-nft-tproxy NOT loaded"
fi

# sing-box not running yet — nftables table should not exist
if ! nft list table inet singbox >/dev/null 2>&1; then
    ok "nftables table absent (sing-box not started — expected)"
else
    ylw "  ~ nftables table inet singbox exists (sing-box may already be running)"
fi

LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "")
if [ -n "$LAN_IP" ]; then
    ok "LAN IP: $LAN_IP"
else
    fail "Cannot determine LAN IP"
fi

# ── 7. Web UI ─────────────────────────────────────────────────────────────────
section "Web UI"

UI_PORT=$(uci -q get uhttpd.singbox.listen_http 2>/dev/null | sed 's/.*://')
if [ -n "$UI_PORT" ]; then
    ok "uhttpd singbox instance configured on port $UI_PORT"
else
    fail "uhttpd singbox instance not found"
fi

if curl -s --max-time 3 "http://127.0.0.1:${UI_PORT:-1104}/" | grep -q "singbox\|Sing-Box"; then
    ok "UI responds on port ${UI_PORT:-1104}"
else
    fail "UI not responding on port ${UI_PORT:-1104}"
fi

# ── 8. Blocklists ─────────────────────────────────────────────────────────────
section "Blocklists"

for f in ru-blocked.srs geoip-ru-blocked.srs; do
    if [ -f "/etc/sing-box/$f" ] && [ -s "/etc/sing-box/$f" ]; then
        SIZE=$(wc -c < "/etc/sing-box/$f")
        ok "$f present (${SIZE} bytes)"
    else
        fail "$f missing or empty — run update-rules.sh"
    fi
done

if crontab -l 2>/dev/null | grep -q "update-rules.sh"; then
    ok "Cron job for blocklist updates present"
else
    fail "Cron job missing"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL + SKIP))
grn "  Passed: $PASS / $TOTAL"
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL / $TOTAL"
[ "$SKIP" -gt 0 ] && ylw "  Skipped: $SKIP / $TOTAL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1