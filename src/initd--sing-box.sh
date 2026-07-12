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
    else
        nft add table inet singbox
        nft add set   inet singbox bypass_v4 { type ipv4_addr \; flags interval \; }
        nft add set   inet singbox bypass_v6 { type ipv6_addr \; flags interval \; } 2>/dev/null || true
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

    nft add rule inet singbox prerouting ip  daddr @bypass_v4 return
    nft add rule inet singbox prerouting ip6 daddr @bypass_v6 return 2>/dev/null || true

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

    # Фоновая пересинхронизация подписок на "тёплом" кэше — должна отработать
    # только один раз за жизнь сервиса. Раньше условием было только has_cache,
    # а reload_service() тоже вызывает start_service(), поэтому каждый reload
    # порождал новый такой фоновый job, который сам в конце снова дёргал
    # reload -> start_service -> новый job, и так по кругу бесконечно.
    if [ "$has_cache" -eq 1 ] && [ ! -f /var/run/singbox-bg-synced ] \
        && [ -x "/usr/sbin/singbox-sub-updater" ]; then
        touch /var/run/singbox-bg-synced
        (
            /usr/sbin/singbox-sub-updater >/dev/null 2>&1
            /etc/init.d/sing-box reload   >/dev/null 2>&1
        ) &
    fi

    procd_open_instance "sing-box"
    procd_set_param command "$PROG" run -c "$RUN_CONFIG"
    # Без этого procd сравнивает только параметры инстанса (командную строку и
    # т.п.), которые от reload'а к reload'у не меняются, и решает, что
    # перезапуск не нужен — реально запущенный sing-box продолжает работать со
    # старым конфигом, хотя compiler уже переписал файл на диске. Именно из-за
    # этого новые custom_rule/dns_rule "применялись" только после ручного
    # restart, а не через кнопку "Применить" (apply -> reload).
    procd_set_param file "$RUN_CONFIG"
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="65535 65535" core="0"
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_set_param env ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
    procd_close_instance

    init_routing &
}

stop_service() {
    clean_routing
    rm -f "$RUN_CONFIG"
    rm -f /var/run/singbox-bg-synced
}

reload_service() {
    exec 9>/var/run/singbox-reload.lock
    if ! flock -n 9; then
        logger -t sing-box "reload уже выполняется, пропускаю повторный вызов"
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