#!/bin/sh
# singA — Compiled JSON Validity Test
# Runs the compiler for every route_mode (1, 2, 3) and validates the compiled
# sing-box JSON via `sing-box check`.
# Doesn't touch the user's existing nodes — adds two temporary dummy nodes
# (VLESS → sb.outbounds, AmneziaWG → sb.endpoints, different compiler
# branches), removes them afterwards, and restores route_mode and the SRS
# files once the test is done.
#
# Usage: sh compiler-test.sh [--verbose]

VERBOSE=0
[ "$1" = "--verbose" ] && VERBOSE=1

PASS=0
FAIL=0

grn() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS+1)); grn "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); red "  ✗ $1"; [ "$VERBOSE" = "1" ] && echo "    $2"; }

COMPILER="/usr/sbin/singbox-compiler"
COMPILED_JSON="/var/run/sing-box_running.json"
TEST_SECTION_VLESS="__json_valid_test_vless"
TEST_SECTION_AWG="__json_valid_test_awg"

# ── Save current state ────────────────────────────────────────────────────────
ORIG_ROUTE_MODE=$(uci -q get singbox.main.route_mode 2>/dev/null || echo "3")
ORIG_ENABLED=$(uci -q get singbox.main.enabled 2>/dev/null || echo "0")

cleanup() {
    uci -q delete singbox.${TEST_SECTION_VLESS} 2>/dev/null
    uci -q delete singbox.${TEST_SECTION_AWG} 2>/dev/null
    uci set singbox.main.route_mode="$ORIG_ROUTE_MODE" 2>/dev/null
    uci set singbox.main.enabled="$ORIG_ENABLED" 2>/dev/null
    uci commit singbox 2>/dev/null
    echo ""
    ylw "Restoring original route_mode=${ORIG_ROUTE_MODE}, updating SRS files..."
    /etc/sing-box/update-rules.sh
    ylw "Done, state restored."
}
trap cleanup EXIT

if [ ! -x "$COMPILER" ]; then
    red "Compiler not found at $COMPILER — install singA first"
    exit 1
fi
if ! command -v sing-box >/dev/null 2>&1 && [ ! -x /usr/bin/sing-box ]; then
    red "sing-box binary not found — cannot validate"
    exit 1
fi
SING_BOX_BIN="/usr/bin/sing-box"
command -v sing-box >/dev/null 2>&1 && SING_BOX_BIN="sing-box"

# ── Temporary test nodes: VLESS (outbounds) + AmneziaWG (endpoints) ──────────
# Dummy data is only used to pass the structural `sing-box check` — the test
# never establishes a real connection.
uci set singbox.${TEST_SECTION_VLESS}=node
uci set singbox.${TEST_SECTION_VLESS}.type="vless"
uci set singbox.${TEST_SECTION_VLESS}.tag="json-valid-test-vless"
uci set singbox.${TEST_SECTION_VLESS}.server="127.0.0.1"
uci set singbox.${TEST_SECTION_VLESS}.server_port="443"
uci set singbox.${TEST_SECTION_VLESS}.uuid="00000000-0000-0000-0000-000000000000"
uci set singbox.${TEST_SECTION_VLESS}.security="none"
uci set singbox.${TEST_SECTION_VLESS}.enabled="1"

uci set singbox.${TEST_SECTION_AWG}=node
uci set singbox.${TEST_SECTION_AWG}.type="amneziawg"
uci set singbox.${TEST_SECTION_AWG}.tag="json-valid-test-awg"
uci set singbox.${TEST_SECTION_AWG}.server="127.0.0.1"
uci set singbox.${TEST_SECTION_AWG}.server_port="51820"
uci set singbox.${TEST_SECTION_AWG}.private_key="47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
uci set singbox.${TEST_SECTION_AWG}.peer_public_key="47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
uci set singbox.${TEST_SECTION_AWG}.local_address="10.0.0.2/32"
uci set singbox.${TEST_SECTION_AWG}.enabled="1"

uci set singbox.main.enabled="1"
uci commit singbox

echo ""
echo "── Compiler output validity per route_mode ──────────────────"

for MODE in 1 2 3; do
    uci set singbox.main.route_mode="$MODE"
    uci commit singbox

    ylw "route_mode=$MODE: updating SRS files (if needed)..."
    # --no-reload: this call only needs fresh SRS files to validate against;
    # a live reload here would push the temporary dummy VLESS/AmneziaWG test
    # nodes (and this loop's test route_mode) into an actually-running
    # sing-box instance, disrupting real traffic mid-test. The final
    # cleanup() call below (no flag) does the one real, wanted reload once
    # the original UCI state has been restored.
    /etc/sing-box/update-rules.sh --no-reload >/tmp/rules_mode${MODE}.log 2>&1

    if "$COMPILER" >/tmp/compiler_mode${MODE}.log 2>&1; then
        :
    else
        fail "route_mode=$MODE: compiler exited with error" "$(cat /tmp/compiler_mode${MODE}.log)"
        continue
    fi

    if [ ! -s "$COMPILED_JSON" ]; then
        fail "route_mode=$MODE: $COMPILED_JSON missing or empty"
        continue
    fi

    if "$SING_BOX_BIN" check -c "$COMPILED_JSON" >/tmp/sb_check_mode${MODE}.log 2>&1; then
        ok "route_mode=$MODE: compiled JSON is valid (VLESS outbound + AmneziaWG endpoint)"
    else
        fail "route_mode=$MODE: sing-box check failed" "$(cat /tmp/sb_check_mode${MODE}.log)"
    fi
    rm -f /tmp/compiler_mode${MODE}.log /tmp/sb_check_mode${MODE}.log /tmp/rules_mode${MODE}.log
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
grn "  Passed: $PASS / $TOTAL"
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL / $TOTAL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "(UCI state and SRS files restored automatically)"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1