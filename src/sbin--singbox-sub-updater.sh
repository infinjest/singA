#!/bin/sh
# singbox-sub-updater v7.1 — vless (xhttp/ws/grpc/reality) & amneziawg/wireguard support

LOCKFILE="/var/run/singbox-sub.lock"
RESULT_FILE="/var/run/singbox-sub.result"
SUB_CACHE_DIR="/etc/sing-box/sub_cache"

# Usage: singbox-sub-updater [--no-reload] [section]
#   section      update only this subscription (default: all)
#   --no-reload  never reload sing-box (used by init.d: it is already (re)starting the service)
# When any node list changed and the service is enabled, sing-box is reloaded once at the end,
# so manual update, cron and "schedule enabled" all behave the same way.
NO_RELOAD=0
ONLY_SEC=""
for arg in "$@"; do
    case "$arg" in
        --no-reload) NO_RELOAD=1 ;;
        *)           ONLY_SEC="$arg" ;;
    esac
done

CHANGED=0
ERRORS=0
NODES_TOTAL=0

if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE" 2>/dev/null)
    kill -0 "$pid" 2>/dev/null && exit 0
fi
echo "$$" > "$LOCKFILE"
rm -f "$RESULT_FILE"
trap "rm -f $LOCKFILE /tmp/sub_parser.awk /tmp/sub_raw.tmp* /tmp/parsed_nodes.txt; exit" INT TERM EXIT

cat << 'EOF' > /tmp/sub_parser.awk
function hex2dec(h,   i, l, d, n) {
    l = length(h); n = 0;
    for(i=1; i<=l; i++) {
        d = index("0123456789abcdef", tolower(substr(h, i, 1))) - 1;
        n = n * 16 + d;
    }
    return n;
}
function url_decode(str,    res, i, c, hex) {
    res = ""
    for (i = 1; i <= length(str); i++) {
        c = substr(str, i, 1)
        if (c == "%") {
            hex = substr(str, i + 1, 2)
            res = res sprintf("%c", hex2dec(hex))
            i += 2
        } else if (c == "+") { res = res " "
        } else               { res = res c }
    }
    return res
}
BEGIN {
    # amneziawg:// query params beyond the basic set above → node field names. Values go
    # through verbatim (base64 keys must not be url-decoded: "+" would become a space)
    xn = split("s3:s3 s4:s4 mtu:mtu presharedkey:pre_shared_key headerprotectionkey:header_protection_key " \
               "contentpaddingaddition:content_padding_addition rekeyaftertime:rekey_after_time " \
               "rekeytimeout:rekey_timeout rejectaftertime:reject_after_time keepalivetimeout:keepalive_timeout " \
               "maxhandshakeattempts:max_handshake_attempts randomtrailers:random_trailers " \
               "disablecookies:disable_cookies persistentkeepalive:persistent_keepalive", xpairs, " ")
    for (xi = 1; xi <= xn; xi++) { split(xpairs[xi], xp, ":"); AWG_X[xp[1]] = xp[2] }
}
{
    sub(/\r$/, "", $0)
    if (!match($0, /^(vless|amneziawg|wireguard):\/\//)) next

    type = "vless"
    if (match($0, /^amneziawg:\/\//)) type = "amneziawg"
    if (match($0, /^wireguard:\/\//)) type = "wireguard"

    sub(/^(vless|amneziawg|wireguard):\/\//, "", $0)
    line = $0
    tag = ""; query = ""; uuid = ""; host = ""; port = "443"

    idx = index(line, "#")
    if (idx > 0) { tag = url_decode(substr(line, idx + 1)); line = substr(line, 1, idx - 1) }

    idx = index(line, "?")
    if (idx > 0) { query = substr(line, idx + 1); line = substr(line, 1, idx - 1) }

    idx = index(line, "@")
    if (idx > 0) { uuid = substr(line, 1, idx - 1); addr = substr(line, idx + 1) } else { addr = line }
    # "host:8443/" (slash before "?") is valid: drop the path, else the port becomes "8443/"
    sub(/\/.*$/, "", addr)

    # Safe IPv6 parsing (strip square brackets)
    if (match(addr, /^\[.*\]/)) {
        cb = index(addr, "]")
        host = substr(addr, 2, cb - 2)
        if (substr(addr, cb + 1, 1) == ":") port = substr(addr, cb + 2)
    } else {
        idx = index(addr, ":")
        if (idx > 0) { host = substr(addr, 1, idx - 1); port = substr(addr, idx + 1) } else host = addr
    }
    sub(/[^0-9].*$/, "", port)
    if (port == "") port = "443"

    if (tag == "") tag = "Node_" host "_" port

    security = "none"; sni = ""; pbk = ""; sid = ""
    transport = "none"; path = ""; thost = ""; mode = ""; flow = ""; service_name = ""

    awg_pubkey = ""; awg_addr = ""; awg_jc = "0"
    awg_jmin = "0"; awg_jmax = "0"
    awg_s1 = "0"; awg_s2 = "0"
    awg_h1 = "0"; awg_h2 = "0"; awg_h3 = "0"; awg_h4 = "0"
    awg_extra = ""

    if (query != "") {
        n = split(query, params, "&")
        for (i = 1; i <= n; i++) {
            # split at the FIRST "=" only: base64 keys end with "=" and must stay intact
            eq = index(params[i], "=")
            if (eq > 0) { kv[1] = substr(params[i], 1, eq - 1); kv[2] = substr(params[i], eq + 1) }
            else        { kv[1] = params[i]; kv[2] = "" }
            if (kv[1] == "security") security = kv[2]
            if (kv[1] == "sni")      sni = url_decode(kv[2])
            if (kv[1] == "pbk")      pbk = kv[2]
            if (kv[1] == "sid")      sid = kv[2]
            if (kv[1] == "type")     transport = kv[2]
            if (kv[1] == "path")     path = url_decode(kv[2])
            if (kv[1] == "host")     thost = url_decode(kv[2])
            if (kv[1] == "mode")     mode = kv[2]
            if (kv[1] == "flow")     flow = kv[2]
            if (kv[1] == "serviceName") service_name = url_decode(kv[2])

            if (kv[1] == "publickey") awg_pubkey = kv[2]
            if (kv[1] == "address")   awg_addr   = url_decode(kv[2])
            if (kv[1] == "jc")        awg_jc     = kv[2]
            if (kv[1] == "jmin")      awg_jmin   = kv[2]
            if (kv[1] == "jmax")      awg_jmax   = kv[2]
            if (kv[1] == "s1")        awg_s1     = kv[2]
            if (kv[1] == "s2")        awg_s2     = kv[2]
            if (kv[1] == "h1")        awg_h1     = kv[2]
            if (kv[1] == "h2")        awg_h2     = kv[2]
            if (kv[1] == "h3")        awg_h3     = kv[2]
            if (kv[1] == "h4")        awg_h4     = kv[2]
            if (type == "amneziawg" && (kv[1] in AWG_X) && kv[2] != "") {
                xv = kv[2]
                gsub(/["\\]/, "\\\\&", xv)
                awg_extra = awg_extra ",\"" AWG_X[kv[1]] "\":\"" xv "\""
            }
        }
    }

    # gRPC: the compiler takes the service name from "path"
    if (transport == "grpc" && path == "") path = service_name

    # Escape everything that could break out of a JSON string
    gsub(/["\\]/, "\\\\&", tag)
    gsub(/["\\]/, "\\\\&", host)
    gsub(/["\\]/, "\\\\&", uuid)
    gsub(/["\\]/, "\\\\&", security)
    gsub(/["\\]/, "\\\\&", sni)
    gsub(/["\\]/, "\\\\&", pbk)
    gsub(/["\\]/, "\\\\&", sid)
    gsub(/["\\]/, "\\\\&", transport)
    gsub(/["\\]/, "\\\\&", path)
    gsub(/["\\]/, "\\\\&", thost)
    gsub(/["\\]/, "\\\\&", mode)
    gsub(/["\\]/, "\\\\&", flow)
    gsub(/["\\]/, "\\\\&", awg_pubkey)
    gsub(/["\\]/, "\\\\&", awg_addr)
    gsub(/["\\]/, "\\\\&", awg_jc)
    gsub(/["\\]/, "\\\\&", awg_jmin)
    gsub(/["\\]/, "\\\\&", awg_jmax)
    gsub(/["\\]/, "\\\\&", awg_s1)
    gsub(/["\\]/, "\\\\&", awg_s2)
    gsub(/["\\]/, "\\\\&", awg_h1)
    gsub(/["\\]/, "\\\\&", awg_h2)
    gsub(/["\\]/, "\\\\&", awg_h3)
    gsub(/["\\]/, "\\\\&", awg_h4)

    print "BEGIN_NODE"
    print "type=" type
    print "tag="  tag
    print "server=" host
    print "server_port=" port
    print "uuid=" uuid
    print "security=" security
    print "sni=" sni
    print "pbk=" pbk
    print "sid=" sid
    print "transport=" transport
    print "path=" path
    print "thost=" thost
    print "mode=" mode
    print "flow=" flow
    print "peer_public_key=" awg_pubkey
    print "local_address="   awg_addr
    print "jc=" awg_jc
    print "jmin=" awg_jmin
    print "jmax=" awg_jmax
    print "s1="   awg_s1
    print "s2="   awg_s2
    print "h1="   awg_h1
    print "h2="   awg_h2
    print "h3="   awg_h3
    print "h4="   awg_h4
    print "awg_extra=" awg_extra
    print "END_NODE"
}
EOF

fetch_and_decode() {
    local url="$1"
    local raw="/tmp/sub_raw.tmp"
    curl -sL --max-filesize 2097152 --connect-timeout 10 --max-time 30 "$url" > "$raw"
    [ $? -eq 0 ] && [ -s "$raw" ] || { rm -f "$raw"; return 1; }

    if ! grep -qE "(vless|amneziawg|wireguard)://" "$raw"; then
        if command -v base64 >/dev/null 2>&1; then
            base64 -d "$raw" > "${raw}.dec" 2>/dev/null
        else
            openssl enc -d -base64 -A -in "$raw" > "${raw}.dec" 2>/dev/null
        fi
        [ -s "${raw}.dec" ] && mv "${raw}.dec" "$raw"
    fi
    echo "$raw"
}

build_nodes_json() {
    local parsed_file="$1"
    local json_out="["
    local first=1

    while read -r line; do
        case "$line" in
            BEGIN_NODE)
                n_t=""; n_tag=""; n_srv=""; n_port="443"
                n_id=""; n_sec="none"; n_sni=""; n_pbk=""; n_sid=""
                n_trn="none"; n_path=""; n_thost=""; n_mode=""; n_flow=""
                n_pub=""; n_addr=""; n_jm="0"; n_jx="0"
                n_jc="0"; n_s1="0"; n_s2="0"; n_h1="0"; n_h2="0"; n_h3="0"; n_h4="0"
                n_ex=""
                ;;
            type=*)            n_t="${line#*=}"    ;;
            tag=*)             n_tag="${line#*=}"  ;;
            server=*)          n_srv="${line#*=}"  ;;
            server_port=*)     n_port="${line#*=}" ;;
            uuid=*)            n_id="${line#*=}"   ;;
            security=*)        n_sec="${line#*=}"  ;;
            sni=*)             n_sni="${line#*=}"  ;;
            pbk=*)             n_pbk="${line#*=}"  ;;
            sid=*)             n_sid="${line#*=}"  ;;
            transport=*)       n_trn="${line#*=}"  ;;
            path=*)            n_path="${line#*=}" ;;
            thost=*)           n_thost="${line#*=}" ;;
            mode=*)            n_mode="${line#*=}" ;;
            flow=*)            n_flow="${line#*=}" ;;
            peer_public_key=*) n_pub="${line#*=}"  ;;
            local_address=*)   n_addr="${line#*=}" ;;
            jc=*)              n_jc="${line#*=}"   ;;
            jmin=*)            n_jm="${line#*=}"   ;;
            jmax=*)            n_jx="${line#*=}"   ;;
            s1=*)              n_s1="${line#*=}"   ;;
            s2=*)              n_s2="${line#*=}"   ;;
            h1=*)              n_h1="${line#*=}"   ;;
            h2=*)              n_h2="${line#*=}"   ;;
            h3=*)              n_h3="${line#*=}"   ;;
            h4=*)              n_h4="${line#*=}"   ;;
            awg_extra=*)       n_ex="${line#*=}"   ;;
            END_NODE)
                if [ -n "$n_tag" ] && [ -n "$n_srv" ]; then
                    [ "$first" -eq 0 ] && json_out="${json_out},"
                    if [ "$n_t" = "amneziawg" ]; then
                        json_out="${json_out}{\"type\":\"${n_t}\",\"tag\":\"${n_tag}\",\"server\":\"${n_srv}\",\"server_port\":\"${n_port}\",\"uuid\":\"${n_id}\",\"security\":\"${n_sec}\",\"sni\":\"${n_sni}\",\"pbk\":\"${n_pbk}\",\"sid\":\"${n_sid}\",\"transport\":\"${n_trn}\",\"path\":\"${n_path}\",\"thost\":\"${n_thost}\",\"mode\":\"${n_mode}\",\"peer_public_key\":\"${n_pub}\",\"local_address\":\"${n_addr}\",\"jc\":\"${n_jc}\",\"jmin\":\"${n_jm}\",\"jmax\":\"${n_jx}\",\"s1\":\"${n_s1}\",\"s2\":\"${n_s2}\",\"h1\":\"${n_h1}\",\"h2\":\"${n_h2}\",\"h3\":\"${n_h3}\",\"h4\":\"${n_h4}\"${n_ex}}"
                    else
                        json_out="${json_out}{\"type\":\"${n_t}\",\"tag\":\"${n_tag}\",\"server\":\"${n_srv}\",\"server_port\":\"${n_port}\",\"uuid\":\"${n_id}\",\"security\":\"${n_sec}\",\"sni\":\"${n_sni}\",\"pbk\":\"${n_pbk}\",\"sid\":\"${n_sid}\",\"transport\":\"${n_trn}\",\"path\":\"${n_path}\",\"thost\":\"${n_thost}\",\"mode\":\"${n_mode}\",\"flow\":\"${n_flow}\",\"peer_public_key\":\"${n_pub}\",\"local_address\":\"${n_addr}\"}"
                    fi
                    first=0
                fi
                ;;
        esac
    done < "$parsed_file"

    json_out="${json_out}]"
    echo "$json_out"
}

process_subscription() {
    local sub_sec="$1"
    local url=$(uci -q get singbox."$sub_sec".url) || return 0
    [ -n "$url" ] || return 0
    logger -t singbox-sub "Updating subscription: ${sub_sec}"

    local file_path=$(fetch_and_decode "$url")
    [ -n "$file_path" ] || { logger -t singbox-sub "Fetch failed: ${sub_sec}"; return 1; }

    awk -f /tmp/sub_parser.awk "$file_path" > /tmp/parsed_nodes.txt
    rm -f "$file_path"

    local node_count=$(grep -c "^BEGIN_NODE$" /tmp/parsed_nodes.txt 2>/dev/null)
    node_count=${node_count:-0}
    if [ "$node_count" -eq 0 ]; then
        logger -t singbox-sub "No nodes parsed from: ${sub_sec}"
        rm -f /tmp/parsed_nodes.txt
        return 1
    fi

    local json_data=$(build_nodes_json /tmp/parsed_nodes.txt)
    rm -f /tmp/parsed_nodes.txt

    NODES_TOTAL=$((NODES_TOTAL + node_count))

    local tmpfs_path="/var/run/singbox_sub_${sub_sec}.json"
    local cache_path="${SUB_CACHE_DIR}/${sub_sec}.json"

    # Previous node list: the tmpfs copy, or the flash copy right after a reboot
    local old_path="" old_data=""
    if [ -f "$tmpfs_path" ]; then old_path="$tmpfs_path"
    elif [ -f "$cache_path" ]; then old_path="$cache_path"
    fi
    [ -n "$old_path" ] && old_data=$(cat "$old_path" 2>/dev/null)

    # Always rewrite the tmpfs copy: its mtime is the "last updated" time shown in the UI
    printf '%s' "$json_data" > "${tmpfs_path}.tmp" && mv "${tmpfs_path}.tmp" "$tmpfs_path"

    if [ -n "$old_data" ] && [ "$old_data" = "$json_data" ]; then
        # Nothing changed: no flash write, no reload
        if [ ! -f "$cache_path" ]; then
            mkdir -p "$SUB_CACHE_DIR"
            cp "$tmpfs_path" "$cache_path"
        fi
        logger -t singbox-sub "OK: ${node_count} nodes, unchanged: ${sub_sec}"
    else
        mkdir -p "$SUB_CACHE_DIR"
        cp "$tmpfs_path" "$cache_path"
        CHANGED=1
        logger -t singbox-sub "OK: ${node_count} nodes cached for ${sub_sec}"
    fi
}

if [ -n "$ONLY_SEC" ]; then
    process_subscription "$ONLY_SEC" || ERRORS=$((ERRORS + 1))
else
    # -X: real section names (cfgXXXXXX). Without it uci prints anonymous sections as
    # @subscription[0]; the cache was then written as singbox_sub_@subscription[0].json,
    # which neither rpcd nor the compiler ever read (scheduled update "did nothing").
    for sub in $(uci -X show singbox 2>/dev/null | awk -F'[.=]' '/^singbox\.[^.]+=subscription$/ {print $2}'); do
        process_subscription "$sub" || ERRORS=$((ERRORS + 1))
    done
fi

# Apply the new nodes: one reload for all subscriptions, only if something changed.
# The lock is still held, so the updater that init.d runs during the reload exits immediately.
APPLIED=0
if [ "$CHANGED" -eq 1 ] && [ "$NO_RELOAD" -eq 0 ] && [ "$(uci -q get singbox.main.enabled)" = "1" ]; then
    logger -t singbox-sub "Nodes changed, reloading sing-box"
    /etc/init.d/sing-box reload >/dev/null 2>&1 && APPLIED=1
fi

# Result for the UI (rpcd "status" -> sub_result); written last, right before the lock is released
printf 'changed=%s\napplied=%s\nerrors=%s\nnodes=%s\n' "$CHANGED" "$APPLIED" "$ERRORS" "$NODES_TOTAL" > "$RESULT_FILE"

rm -f "$LOCKFILE" /tmp/sub_parser.awk