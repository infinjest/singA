#!/bin/sh
# singbox-sub-updater v7.1 — vless (xhttp/ws/grpc/reality) & amneziawg/wireguard support

LOCKFILE="/var/run/singbox-sub.lock"
SUB_CACHE_DIR="/etc/sing-box/sub_cache"

if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE" 2>/dev/null)
    kill -0 "$pid" 2>/dev/null && exit 0
fi
echo "$$" > "$LOCKFILE"
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

    # Safe IPv6 parsing (strip square brackets)
    if (match(addr, /^\[.*\]/)) {
        cb = index(addr, "]")
        host = substr(addr, 2, cb - 2)
        if (substr(addr, cb + 1, 1) == ":") port = substr(addr, cb + 2)
    } else {
        idx = index(addr, ":")
        if (idx > 0) { host = substr(addr, 1, idx - 1); port = substr(addr, idx + 1) } else host = addr
    }

    if (tag == "") tag = "Node_" host "_" port

    security = "none"; sni = ""; pbk = ""; sid = ""
    transport = "none"; path = ""; thost = ""; mode = ""

    awg_pubkey = ""; awg_addr = ""; awg_jc = "0"
    awg_jmin = "0"; awg_jmax = "0"
    awg_s1 = "0"; awg_s2 = "0"
    awg_h1 = "0"; awg_h2 = "0"; awg_h3 = "0"; awg_h4 = "0"

    if (query != "") {
        n = split(query, params, "&")
        for (i = 1; i <= n; i++) {
            split(params[i], kv, "=")
            if (kv[1] == "security") security = kv[2]
            if (kv[1] == "sni")      sni = url_decode(kv[2])
            if (kv[1] == "pbk")      pbk = kv[2]
            if (kv[1] == "sid")      sid = kv[2]
            if (kv[1] == "type")     transport = kv[2]
            if (kv[1] == "path")     path = url_decode(kv[2])
            if (kv[1] == "host")     thost = url_decode(kv[2])
            if (kv[1] == "mode")     mode = kv[2]

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
        }
    }

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
                n_trn="none"; n_path=""; n_thost=""; n_mode=""
                n_pub=""; n_addr=""; n_jm="0"; n_jx="0"
                n_jc="0"; n_s1="0"; n_s2="0"; n_h1="0"; n_h2="0"; n_h3="0"; n_h4="0"
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
            END_NODE)
                if [ -n "$n_tag" ] && [ -n "$n_srv" ]; then
                    [ "$first" -eq 0 ] && json_out="${json_out},"
                    if [ "$n_t" = "amneziawg" ]; then
                        json_out="${json_out}{\"type\":\"${n_t}\",\"tag\":\"${n_tag}\",\"server\":\"${n_srv}\",\"server_port\":\"${n_port}\",\"uuid\":\"${n_id}\",\"security\":\"${n_sec}\",\"sni\":\"${n_sni}\",\"pbk\":\"${n_pbk}\",\"sid\":\"${n_sid}\",\"transport\":\"${n_trn}\",\"path\":\"${n_path}\",\"thost\":\"${n_thost}\",\"mode\":\"${n_mode}\",\"peer_public_key\":\"${n_pub}\",\"local_address\":\"${n_addr}\",\"jc\":\"${n_jc}\",\"jmin\":\"${n_jm}\",\"jmax\":\"${n_jx}\",\"s1\":\"${n_s1}\",\"s2\":\"${n_s2}\",\"h1\":\"${n_h1}\",\"h2\":\"${n_h2}\",\"h3\":\"${n_h3}\",\"h4\":\"${n_h4}\"}"
                    else
                        json_out="${json_out}{\"type\":\"${n_t}\",\"tag\":\"${n_tag}\",\"server\":\"${n_srv}\",\"server_port\":\"${n_port}\",\"uuid\":\"${n_id}\",\"security\":\"${n_sec}\",\"sni\":\"${n_sni}\",\"pbk\":\"${n_pbk}\",\"sid\":\"${n_sid}\",\"transport\":\"${n_trn}\",\"path\":\"${n_path}\",\"thost\":\"${n_thost}\",\"mode\":\"${n_mode}\",\"peer_public_key\":\"${n_pub}\",\"local_address\":\"${n_addr}\"}"
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

    local tmpfs_path="/var/run/singbox_sub_${sub_sec}.json"
    printf '%s' "$json_data" > "${tmpfs_path}.tmp" && mv "${tmpfs_path}.tmp" "$tmpfs_path"

    mkdir -p "$SUB_CACHE_DIR"
    cp "$tmpfs_path" "${SUB_CACHE_DIR}/${sub_sec}.json"
    logger -t singbox-sub "OK: ${node_count} nodes cached for ${sub_sec}"
}

if [ -n "$1" ]; then
    process_subscription "$1"
else
    for sub in $(uci show singbox 2>/dev/null | grep "=subscription" | awk -F'[.=]' '{print $2}'); do
        process_subscription "$sub"
    done
fi

rm -f "$LOCKFILE" /tmp/sub_parser.awk