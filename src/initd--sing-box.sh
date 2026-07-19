#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG="/usr/bin/sing-box"
COMPILER="/usr/sbin/singbox-compiler"
RUN_CONFIG="/var/run/sing-box_running.json"

TPROXY_MARK="0x100"
TPROXY_TABLE="100"
INFRA_LOCAL_PORT="57321-57325"

_port_bound() {
    if command -v ss >/dev/null 2>&1; then
        ss -tnlp 2>/dev/null | grep -qE ":${1}[^0-9]"
    else
        netstat -an 2>/dev/null | grep -qE ":${1}[^0-9]"
    fi
}

init_routing() {
    local tproxy_port=$(uci -q get singbox.main.tproxy_port || echo "7893")
    local timeout=20 success=0

    while [ "$timeout" -gt 0 ]; do
        if _port_bound "${tproxy_port}"; then
            success=1; break
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    if [ "$success" -eq 0 ]; then
        logger -t sing-box -p daemon.err "Fatal: TProxy port :${tproxy_port} not bound. Routing NOT activated."
        clean_routing
        return 1
    fi

    if ! ip rule show | grep -q "lookup ${TPROXY_TABLE}"; then
        ip rule  add fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}"
        ip route add local default dev lo   table "${TPROXY_TABLE}"
    fi
    if ! ip -6 rule show | grep -q "lookup ${TPROXY_TABLE}"; then
        ip -6 rule  add fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}" 2>/dev/null || true
        ip -6 route add local default dev lo   table "${TPROXY_TABLE}" 2>/dev/null || true
    fi

    if nft list table inet singbox >/dev/null 2>&1; then
        nft flush chain inet singbox prerouting 2>/dev/null || true
        nft flush chain inet singbox output     2>/dev/null || true
        nft flush set   inet singbox bypass_v4  2>/dev/null || true
        nft flush set   inet singbox bypass_v6  2>/dev/null || true
        # known_resolvers_v4/v6 may be missing from a table inherited from a
        # pre-0.10.5 version — flushing a nonexistent set is silently
        # swallowed (`|| true`), but the add element/add rule below is not.
        # `add set` is idempotent (no error if the set already exists with the
        # same schema), so it's safe to guarantee the set exists before
        # flushing rather than assume the upgrade already recreated the whole
        # table.
        nft add     set inet singbox known_resolvers_v4 { type ipv4_addr \; flags interval \; } 2>/dev/null || true
        nft add     set inet singbox known_resolvers_v6 { type ipv6_addr \; flags interval \; } 2>/dev/null || true
        nft flush   set inet singbox known_resolvers_v4 2>/dev/null || true
        nft flush   set inet singbox known_resolvers_v6 2>/dev/null || true
    else
        nft add table inet singbox
        nft add set   inet singbox bypass_v4 { type ipv4_addr \; flags interval \; }
        nft add set   inet singbox bypass_v6 { type ipv6_addr \; flags interval \; } 2>/dev/null || true
        nft add set   inet singbox known_resolvers_v4 { type ipv4_addr \; flags interval \; }
        nft add set   inet singbox known_resolvers_v6 { type ipv6_addr \; flags interval \; } 2>/dev/null || true
        nft add chain inet singbox prerouting { type filter hook prerouting priority mangle \; policy accept \; }
        nft add chain inet singbox output     { type route   hook output    priority mangle \; policy accept \; }
    fi

    nft add element inet singbox bypass_v4 { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
    nft add element inet singbox bypass_v6 { ::1/128, fc00::/7, fe80::/10, 2001:db8::/32, ::ffff:0:0/96 } 2>/dev/null || true

    nft add rule inet singbox prerouting meta mark 0xff return
    nft add rule inet singbox prerouting socket transparent 1 meta mark set "${TPROXY_MARK}" accept

    nft add rule inet singbox prerouting ip  protocol tcp th dport 53 tproxy ip  to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept
    nft add rule inet singbox prerouting ip  protocol udp th dport 53 tproxy ip  to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept
    nft add rule inet singbox prerouting ip6 nexthdr  tcp th dport 53 tproxy ip6 to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept 2>/dev/null || true
    nft add rule inet singbox prerouting ip6 nexthdr  udp th dport 53 tproxy ip6 to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept 2>/dev/null || true

    # Known public DNS resolvers (Cloudflare/Google/Quad9/AdGuard/OpenDNS/
    # Yandex/AliDNS/CleanBrowsing/NextDNS anycast). List is not exhaustive
    # (newer providers aren't covered) and is checked against well-known
    # addresses — update as needed.
    nft add element inet singbox known_resolvers_v4 { 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9, 149.112.112.112, 94.140.14.14, 94.140.15.15, 208.67.222.222, 208.67.220.220, 77.88.8.8, 77.88.8.1, 223.5.5.5, 223.6.6.6, 185.228.168.9, 185.228.169.9, 45.90.28.0/24, 45.90.30.0/24 }
    nft add element inet singbox known_resolvers_v6 { 2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844, 2620:fe::fe, 2620:fe::9, 2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff, 2620:119:35::35, 2620:119:53::53, 2a02:6b8::feed:0ff, 2a02:6b8:0:1::feed:0ff, 2a07:a8c0::/32, 2a07:a8c1::/32 } 2>/dev/null || true

    nft add rule inet singbox prerouting ip  daddr @bypass_v4 return
    nft add rule inet singbox prerouting ip6 daddr @bypass_v6 return 2>/dev/null || true

    # Public DoT/DoQ/DoH (including plain port 443): reject by resolver IP,
    # not by tproxy/SNI. IP-based is simpler and more reliable than the two
    # previous mechanisms (an nft rule on port 853 + a separate SNI
    # domain_suffix reject in sing-box route.rules) — it depends on neither
    # the port nor sing-box's ability to see SNI at all (survives ECH, which
    # Cloudflare increasingly uses to hide SNI by default). Reject (TCP
    # RST/ICMP unreachable, not drop) so the client sees the failure right
    # away and falls back to plain DNS (already intercepted above via the
    # port 53 tproxy rule) instead of hanging on a timeout.
    # This rule sits AFTER the bypass-return — LAN addresses/own resolvers in
    # bypass_v4/v6 are not blocked, only external traffic is cut off.
    # If a client has Private DNS set to "Hostname" mode (Strict, not
    # Automatic), there's no system fallback to plain DNS — Private DNS has
    # to be turned off manually on the device; this patch doesn't cover that.
    if [ "$(uci -q get singbox.main.block_dot || echo 1)" = "1" ]; then
        nft add rule inet singbox prerouting ip  daddr @known_resolvers_v4 reject
        nft add rule inet singbox prerouting ip6 daddr @known_resolvers_v6 reject 2>/dev/null || true
    fi

    nft add rule inet singbox prerouting ip  protocol { tcp, udp } tproxy ip  to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept
    nft add rule inet singbox prerouting ip6 nexthdr  { tcp, udp } tproxy ip6 to :"${tproxy_port}" meta mark set "${TPROXY_MARK}" accept 2>/dev/null || true

    nft add rule inet singbox output tcp sport "${INFRA_LOCAL_PORT}" return

    nft add rule inet singbox output ip daddr @bypass_v4 return
    nft add rule inet singbox output meta mark 0xff return
    nft add rule inet singbox output ip protocol { tcp, udp } meta mark set "${TPROXY_MARK}" accept

    nft add rule inet singbox output ip6 daddr @bypass_v6 return 2>/dev/null || true
    nft add rule inet singbox output ip6 nexthdr { tcp, udp } meta mark set "${TPROXY_MARK}" accept 2>/dev/null || true

    logger -t sing-box "Routing activated on port ${tproxy_port}"
}

clean_routing() {
    nft delete table inet singbox                                               2>/dev/null || true
    while ip rule show | grep -q "lookup ${TPROXY_TABLE}"; do
        ip rule del fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}" 2>/dev/null
    done
    ip    route del local default dev lo    table "${TPROXY_TABLE}"             2>/dev/null || true
    ip -6 rule  del fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}"             2>/dev/null || true
    ip -6 route del local default dev lo   table "${TPROXY_TABLE}"              2>/dev/null || true
}

start_service() {
    mkdir -p /var/run/sing-box/sub_cache
    mkdir -p /var/run/sing-box/rules

    local has_cache=0

    ls /var/run/sing-box/sub_cache/*.json >/dev/null 2>&1 && has_cache=1

    if [ "$has_cache" -eq 0 ] && [ -x "/usr/sbin/singbox-sub-updater" ]; then
        logger -t sing-box "First run: syncing subscriptions synchronously..."
        /usr/sbin/singbox-sub-updater || true
    fi

    [ -x "$COMPILER" ] && "$COMPILER" || return 1
    [ -f "$RUN_CONFIG" ] || return 0

    # Background subscription resync on a warm cache — must run only once per
    # service lifetime. It used to be gated on has_cache alone, and since
    # reload_service() also calls start_service(), every reload spawned a new
    # background job, which at the end triggered reload -> start_service ->
    # another job, looping forever.
    if [ "$has_cache" -eq 1 ] && [ ! -f /var/run/singbox-bg-synced ] \
        && [ -x "/usr/sbin/singbox-sub-updater" ]; then
        touch /var/run/singbox-bg-synced
        (
            /usr/sbin/singbox-sub-updater >/dev/null 2>&1
            /etc/init.d/sing-box reload   >/dev/null 2>&1
        ) &
    fi

    procd_open_instance "sing-box"
    # sing-box is started directly — no "sh -c '... | singbox-logtail'"
    # wrapper. It used to be piped through singbox-logtail so the latter
    # could ring-buffer sing-box's own output into /var/run/sing-box_log.txt
    # for rpcd's get_log — but with that wrapper, procd only tracks the PID
    # of the wrapping shell, not sing-box itself. If the shell ever exits
    # without the SIGTERM it received propagating to sing-box and
    # singbox-logtail inside the pipe (which is not guaranteed — a
    # non-interactive `sh -c "cmd1 | cmd2"` has no job control and does not
    # forward signals to its pipeline children by default), both survive as
    # untracked orphans: still holding the tproxy port and the Clash API
    # port, still routing traffic, invisible to every future stop/reload —
    # "Выключить прокси" then stops whatever procd is (still) tracking while
    # the actual traffic keeps flowing through the orphan, and a newly
    # started instance (after adding/enabling a node) can't bind those same
    # ports and never becomes the one actually serving traffic, so the new
    # node never shows as active. This was flagged as an unverified risk in
    # an earlier version of this comment ("NOT YET VERIFIED ON REAL
    # HARDWARE") and has since been confirmed in the field. Running sing-box
    # directly means procd's stop/respawn/reload signal the real PID, full
    # stop.
    procd_set_param command "$PROG" run -c "$RUN_CONFIG"
    # Without this, procd only compares instance parameters (command line,
    # etc.), which don't change between reloads, and decides no restart is
    # needed — the actually-running sing-box keeps using the old config even
    # though compiler already rewrote the file on disk. This is exactly why
    # new custom_rule/dns_rule entries only "applied" after a manual restart,
    # not through the "Apply" button (apply -> reload).
    procd_set_param file "$RUN_CONFIG"
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="65535 65535" core="0"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param env ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
    procd_close_instance

    # singbox-logtail as a second, fully independent procd instance: it tails
    # syslog (which sing-box's own instance above still writes to via
    # stdout/stderr = 1, same as before) filtered to sing-box's own tag,
    # instead of sitting inside sing-box's own stdout pipe. This is
    # deliberately decoupled from the "sing-box" instance's lifecycle — if
    # this pipe ever orphans the same way the old combined one could, the
    # worst case is a stale/duplicate log-tailer wasting a little RAM, not a
    # proxy that silently keeps routing traffic after being switched off.
    # stop_service below also best-effort pkills strays on every stop, since
    # unlike the routing-critical case above, "mostly mitigated" is an
    # acceptable bar here.
    procd_open_instance "sing-box-logtail"
    procd_set_param command /bin/sh -c "exec logread -f -e sing-box | /usr/sbin/singbox-logtail"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance

    init_routing &
}

stop_service() {
    clean_routing
    rm -f "$RUN_CONFIG"
    rm -f /var/run/singbox-bg-synced
    # Best-effort cleanup of orphans from the old piped-command instance
    # (`sh -c "... sing-box run ... | singbox-logtail"`, versions before this
    # fix) plus, defensively, any stray singbox-logtail left over from the
    # new decoupled instance above if that pipe ever orphans too. procd
    # already stops both instances it currently tracks — this only catches
    # what procd was never tracking to begin with. Safe to run unconditionally:
    # it only matches these two exact command lines, and matching zero
    # processes is a normal, harmless outcome.
    ( ps w 2>/dev/null || ps ) | grep -F "$PROG run -c" | grep -v grep | \
        awk '{print $1}' | while read -r pid; do kill "$pid" 2>/dev/null; done
    ( ps w 2>/dev/null || ps ) | grep -F "/usr/sbin/singbox-logtail" | grep -v grep | \
        awk '{print $1}' | while read -r pid; do kill "$pid" 2>/dev/null; done
}

reload_service() {
    exec 9>/var/run/singbox-reload.lock
    if ! flock -n 9; then
        logger -t sing-box "Reload already in progress, skipping this call"
        return 0
    fi
    "$COMPILER" || { flock -u 9; return 1; }
    if [ ! -f "$RUN_CONFIG" ]; then flock -u 9; return 0; fi
    rc_procd start_service
    flock -u 9
}

service_triggers() {
    procd_add_reload_trigger "singbox"
    procd_add_reload_trigger "firewall"
}