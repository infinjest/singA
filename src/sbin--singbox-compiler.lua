#!/usr/bin/lua
local uci  = require "uci".cursor()
local json = require "luci.jsonc"
package.path = package.path .. ";/usr/lib/singbox/?.lua"
local validate = require "validate"

local RUN_CONFIG    = "/var/run/sing-box_running.json"
local pid_f = io.popen("awk '/^Pid:/{print $2; exit}' /proc/self/status 2>/dev/null")
local pid   = pid_f and pid_f:read("*l") or ""
if pid_f then pid_f:close() end
if not pid or pid == "" or not pid:match("^%d+$") then pid = tostring(os.time()) end
local TMP_CONFIG    = "/var/run/sing-box_tmp_" .. pid .. ".json"
local SUB_CACHE_DIR = "/etc/sing-box/sub_cache"

local clash_secret = uci:get("singbox", "main", "clash_secret")
if not clash_secret or clash_secret == "" then
    local sf = io.open("/var/run/singbox_clash.sec", "r")
    if sf then clash_secret = sf:read("*a"):gsub("%s+",""); sf:close() end
end
if not clash_secret or clash_secret == "" then
    local f = io.popen("head -c 18 /dev/urandom | base64 | tr -d '/+=\\n' | head -c 24")
    clash_secret = f and f:read("*a"):gsub("%s+", "") or ("sb-" .. tostring(os.time()))
    if f then f:close() end
    uci:set("singbox", "main", "clash_secret", clash_secret)
    uci:commit("singbox")
    local sf = io.open("/var/run/singbox_clash.sec", "w")
    if sf then sf:write(clash_secret); sf:close() end
end

local sb = {
    log      = { level = "info" },
    inbounds = { {
        type = "tproxy", tag = "tproxy-in", listen = "::",
        listen_port = 7893,
    } },
    outbounds = {
        { type = "direct", tag = "direct", routing_mark = 255 }
    },
    endpoints = {},
    route = {
        rules = {},
        rule_set = {},
        final = "direct",
        auto_detect_interface = true
    },
    dns = {
        servers = {},
        rules = {},
        final = "dns-local",
        -- A-records only: nft routing (init_routing) treats IPv4 as primary,
        -- IPv6 rules are best-effort ("|| true") and not guaranteed on every
        -- target — an AAAA answer could silently route a connection around
        -- tproxy/tproxy6. ipv4_only removes this whole class of leak.
        strategy = "ipv4_only"
    },
    experimental = { clash_api = { external_controller = "0.0.0.0:9090", secret = clash_secret } }
}

local enabled = uci:get("singbox", "main", "enabled") or "0"
if enabled ~= "1" then os.exit(0) end

local route_mode = uci:get("singbox", "main", "route_mode") or "3"
-- QUIC (UDP/443) blocked by default: some Android clients prefer QUIC-first
-- and stall/hang rather than falling back cleanly to TCP when QUIC works
-- poorly over the tunnel, even with packet_encoding=xudp on the outbound
-- (see build_outbound below). Rejecting it (not dropping) pushes those
-- clients to fall back to HTTP/2 over TCP immediately instead of hanging.
local block_quic = uci:get("singbox", "main", "block_quic") or "1"
if block_quic ~= "0" then block_quic = "1" end
local rule_set_seen = {}
local custom_dns = uci:get("singbox", "main", "custom_dns") or "https://dns.cloudflare.com/dns-query"
local local_dns  = uci:get("singbox", "main", "local_dns")  or "tcp://1.1.1.1"
-- direct by default: both local_dns and custom_dns now default to Cloudflare
-- (1.1.1.1 / DoH on the same network), so the upstream DoH endpoint is far
-- less likely to be singled out and blocked than a niche resolver would be —
-- the risk that made "proxy" the safer-but-slower default no longer applies
-- to the out-of-the-box config. Still overridable per-install: set
-- dns_remote_detour=proxy if your provider does block Cloudflare's DoH.
local dns_remote_detour = uci:get("singbox", "main", "dns_remote_detour") or "direct"
if dns_remote_detour ~= "proxy" then dns_remote_detour = "direct" end
if custom_dns == "" then custom_dns = "https://dns.cloudflare.com/dns-query" end
if local_dns  == "" then local_dns  = "tcp://1.1.1.1" end

-- Modes 1 and 2: final=proxy; mode 3: final=direct
if route_mode == "1" or route_mode == "2" then
    sb.route.final = "proxy"
    sb.dns.final   = "dns-remote"
else
    sb.route.final = "direct"
    sb.dns.final   = "dns-local"
end
sb.route.default_domain_resolver = "dns-local"

-- Known public resolvers: bare IP → correct SNI/Host for their TLS cert.
-- Only needed if the user manually enters tls://<IP>/https://<IP> as
-- custom_dns/local_dns (no such preset in the UI anymore, see 0.10.5
-- CHANGELOG) — without an SNI override, tls://77.88.8.8 fails certificate
-- validation (the cert is issued for common.dot.dns.yandex.net, not the IP).
-- SNI values checked against provider docs (Yandex confirmed directly via
-- dns.yandex.com/ru; AdGuard/Cloudflare/Google are common knowledge).
local KNOWN_DNS_SNI = {
    ["77.88.8.8"]    = "common.dot.dns.yandex.net",
    ["94.140.14.14"] = "dns.adguard-dns.com",
    ["1.1.1.1"]      = "cloudflare-dns.com",
    ["8.8.8.8"]      = "dns.google",
}

-- DNS server address → new sing-box 1.12+ format. Parsing (host/port/path,
-- bracketed IPv6) is delegated to validate.parse_dns_addr — the same parser
-- used when writing to UCI (rpcd), no need to duplicate it here.
-- If the UCI value is somehow malformed anyway (manual edit bypassing rpcd),
-- don't fail the whole config — fall back to the literal host; sing-box will
-- report it at startup if the result doesn't work.
-- "https://dns.cloudflare.com/dns-query" → { type="https", server="dns.cloudflare.com", path="/dns-query" }
-- "tls://host.example:8853"              → { type="tls", server="host.example", server_port=8853 }
local function build_dns_server(tag, addr, detour, resolver_tag)
    local parsed, err = validate.parse_dns_addr(addr)
    if not parsed then
        os.execute("logger -t singbox-compiler 'WARNING: DNS server address invalid, using as-is: " ..
            tostring(addr) .. " (" .. tostring(err) .. ")'")
        parsed = { scheme = "udp", host = addr }
    end

    local obj = { type = parsed.scheme, tag = tag, server = parsed.host, detour = detour }
    if parsed.port then obj.server_port = parsed.port end
    if parsed.path and (parsed.scheme == "https" or parsed.scheme == "h3" or parsed.scheme == "http3") then
        obj.path = parsed.path
    end
    if resolver_tag then obj.domain_resolver = resolver_tag end

    local sni = KNOWN_DNS_SNI[parsed.host]
    if sni and (parsed.scheme == "tls" or parsed.scheme == "https" or parsed.scheme == "quic") then
        obj.tls = { enabled = true, server_name = sni }
        if parsed.scheme == "https" then obj.headers = { Host = sni } end
    end

    return obj
end

table.insert(sb.dns.servers, build_dns_server("dns-remote", custom_dns, dns_remote_detour, (dns_remote_detour == "proxy") and "dns-local" or nil))
table.insert(sb.dns.servers, build_dns_server("dns-local",  local_dns,  "direct", nil))

-- Routing DNS through the node is more expensive (extra RTT into the tunnel) —
-- smooth out the first-resolve latency: serve a stale cache entry immediately,
-- refresh in the background. With direct this latency is small enough that
-- the added risk of a stale answer isn't worth it.
if dns_remote_detour == "proxy" then
    sb.dns.optimistic = true
    sb.dns.independent_cache = true -- cache races with optimistic if this is off
end

local function build_outbound(s, tag)
    local o = {
        type         = s.type,
        tag          = tag,
        server       = s.server,
        server_port  = tonumber(s.server_port) or 443,
        routing_mark = 255,
        tcp_fast_open = false,
        multiplex = { enabled = false }
    }

    if s.type == "vless" then
        o.uuid = s.uuid
        -- Without this, sing-box's VLESS outbound has UDP relay disabled by
        -- default — QUIC (UDP/443) connections through this node simply
        -- never establish. Clients that prefer QUIC-first and retry it
        -- before falling back to TCP (notably YouTube on Android) see this
        -- as slow-loading video rather than an outright failure. Requires
        -- the remote server to support xudp (virtually all modern
        -- Xray-core/sing-box nodes do); if it doesn't, switch to
        -- "packetaddr" (IPv4-only, but this project already runs
        -- dns.strategy=ipv4_only, so that's not a new restriction).
        o.packet_encoding = "xudp"
        if s.security == "reality" then
            o.tls = {
                enabled     = true,
                server_name = s.sni,
                reality     = { enabled = true, public_key = s.pbk, short_id = s.sid },
                utls        = { enabled = true, fingerprint = "chrome" }
            }
        elseif s.security == "tls" then
            o.tls = { enabled = true, server_name = s.sni }
        end

        if s.transport and s.transport ~= "" and s.transport ~= "none" then
            o.transport = { type = s.transport }
            if s.path and s.path ~= "" then o.transport.path = s.path end
            if s.transport == "ws" then
                local h = (s.thost and s.thost ~= "" and s.thost) or s.sni
                if h and h ~= "" then o.transport.headers = { Host = h } end
            elseif s.transport == "http" then
                local h = (s.thost and s.thost ~= "" and s.thost) or s.sni
                if h and h ~= "" then o.transport.host = { h } end
            elseif s.transport == "xhttp" then
                local h = (s.thost and s.thost ~= "" and s.thost) or s.sni
                if h and h ~= "" then o.transport.host = h end
                if s.mode and s.mode ~= "" then o.transport.mode = s.mode end
                o.transport.x_padding_bytes = "100-1000"
            elseif s.transport == "grpc" then
                if s.path and s.path ~= "" then
                    o.transport.service_name = s.path
                    o.transport.path = nil
                end
            end
        end
    end
    return o
end
local function build_endpoint(s, tag)
    local e = {
        routing_mark = 255,
        type = "wireguard",
        tag = tag,
        system = false,
        private_key = s.private_key or s.uuid,
        peers = {
            {
                address = s.server,
                port = tonumber(s.server_port) or 51820,
                public_key = s.peer_public_key,
                allowed_ips = { "0.0.0.0/0", "::/0" }
            }
        }
    }
    if type(s.local_address) == "table" then
        e.address = {}
        for _, addr in ipairs(s.local_address) do
            if not addr:find("/") then
                addr = addr .. (addr:find(":") and "/128" or "/32")
            end
            table.insert(e.address, addr)
        end
    else
        e.address = {}
        for addr in (s.local_address or ""):gmatch("[^,%s]+") do
            if not addr:find("/") then
                addr = addr .. (addr:find(":") and "/128" or "/32")
            end
            table.insert(e.address, addr)
        end
    end
    if s.type == "amneziawg" then
        local function pick(v)
            local n = tonumber(v)
            if n then return n end
            return 0
        end
        local function pick_str(v)
            if type(v) == "string" and v ~= "" then return v end
            return nil
        end
		-- Tried `e.detour = "direct"` to mark the endpoint's own handshake
        -- traffic like build_outbound's "direct" (avoid tproxy loop-back),
        -- but sing-box can't resolve "direct" as a detour for the
        -- amneziawg/wireguard *endpoint* type and the node fails to start:
        --   ERROR endpoint/wireguard[...]: outbound detour not found: direct
        -- Left disabled on purpose — don't re-enable without re-testing.
        -- e.detour = "direct"
        e.jc   = pick(s.jc)
        e.jmin = pick(s.jmin)
        e.jmax = pick(s.jmax)
        e.s1   = pick(s.s1)
        e.s2   = pick(s.s2)
        e.s3   = pick(s.s3)
        e.s4   = pick(s.s4)
        e.h1   = pick_str(s.h1)
        e.h2   = pick_str(s.h2)
        e.h3   = pick_str(s.h3)
        e.h4   = pick_str(s.h4)
        e.i1   = pick_str(s.i1)
        e.i2   = pick_str(s.i2)
        e.i3   = pick_str(s.i3)
        e.i4   = pick_str(s.i4)
        e.i5   = pick_str(s.i5)
        if s.pre_shared_key and s.pre_shared_key ~= "" then
            e.peers[1].pre_shared_key = s.pre_shared_key
        end
    end
    return e
end

local proxy_tags = {}
local node_count = 0

uci:foreach("singbox", "node", function(s)
    if not (s.tag and s.type and s.server) then return end
    if s.enabled == "0" then return end
    node_count = node_count + 1
    local t = "node_" .. node_count .. "_" .. s.tag
    if s.type == "amneziawg" or s.type == "wireguard" then
        table.insert(sb.endpoints, build_endpoint(s, t))
    else
        table.insert(sb.outbounds, build_outbound(s, t))
    end
    table.insert(proxy_tags, t)
end)

uci:foreach("singbox", "subscription", function(sub)
    local sec = sub[".name"]
    local content
    for _, path in ipairs({ "/var/run/singbox_sub_" .. sec .. ".json", SUB_CACHE_DIR .. "/" .. sec .. ".json" }) do
        local f = io.open(path, "r")
        if f then content = f:read("*a"); f:close(); break end
    end
    if not content then return end

    local nodes = json.parse(content)
    if type(nodes) ~= "table" then return end

    for _, s in ipairs(nodes) do
        if s.tag and s.type and s.server then
            node_count = node_count + 1
            local t = "sub_" .. node_count .. "_" .. s.tag
            if s.type == "amneziawg" or s.type == "wireguard" then
                table.insert(sb.endpoints, build_endpoint(s, t))
            else
                table.insert(sb.outbounds, build_outbound(s, t))
            end
            table.insert(proxy_tags, t)
        end
    end
end)
if #proxy_tags == 0 then os.exit(1) end

if #proxy_tags > 1 then
    table.insert(sb.outbounds, 1, {
        type = "selector", tag = "proxy",
        outbounds = { "proxy-auto", "direct" }, default = "proxy-auto"
    })
    table.insert(sb.outbounds, 2, {
        type = "urltest", tag = "proxy-auto", outbounds = proxy_tags,
        url = "http://cp.cloudflare.com/generate_204", interval = "3m", tolerance = 50, interrupt_exist_connections = false
    })
else
    local sel_tags = {}
    for _, t in ipairs(proxy_tags) do table.insert(sel_tags, t) end
    table.insert(sel_tags, "direct")
    table.insert(sb.outbounds, 1, {
        type = "selector", tag = "proxy", outbounds = sel_tags, default = sel_tags[1]
    })
end

local rt_custom = {}
local rt_geo    = {}

local dns_custom = {}
local dns_geo    = {}

-- Priority 0: domain-specific DNS servers (dns_rule sections) — mode 3 only
local dns_domain = {}
if route_mode == "3" then
    uci:foreach("singbox", "dns_rule", function(r)
        if not (r.domain and r.domain ~= "" and r.server and r.server ~= "") then return end
        local srv_tag = "dns-domain-" .. (r[".name"] or tostring(#dns_domain + 1))
        local detour = (r.via_proxy == "1") and "proxy" or "direct"
        table.insert(sb.dns.servers, build_dns_server(srv_tag, r.server, detour, (detour == "proxy") and "dns-local" or nil))
        local dns_item = { server = srv_tag, domain_suffix = {} }
        for d in r.domain:gmatch("[^, ]+") do table.insert(dns_item.domain_suffix, d) end
        table.insert(dns_domain, dns_item)
    end)
end

-- Priority 1: user routing matrix
if route_mode == "3" then
    uci:foreach("singbox", "custom_rule", function(r)
        local rule_item = {}
        local dns_item  = {}
        local has_cond  = false

        if r.source and r.source ~= "" and not validate.ip_cidr_list(r.source) then
            os.execute("logger -t singbox-compiler 'WARNING: custom_rule source invalid, skipping: " .. r.source .. "'")
            return
        end
        if r.ip and r.ip ~= "" and not validate.ip_cidr_list(r.ip) then
            os.execute("logger -t singbox-compiler 'WARNING: custom_rule ip invalid, skipping: " .. r.ip .. "'")
            return
        end
        if r.source and r.source ~= "" then
            rule_item.source_ip_cidr = {}
            for s in r.source:gmatch("[^, ]+") do table.insert(rule_item.source_ip_cidr, s) end
            has_cond = true
        end
        if r.domain and r.domain ~= "" then
            rule_item.domain_suffix = {}; dns_item.domain_suffix = {}
            local rs_tags = {}
            for d in r.domain:gmatch("[^, ]+") do
                local cat = d:match("^geosite:([%w%-%_%.]+)$")
                if cat then
                    local rtag  = "geosite-x-" .. cat
                    local rpath = "/etc/sing-box/rule-sets/geosite-" .. cat .. ".srs"
                    local f = io.open(rpath, "r")
                    if f then
                        f:close()
                        if not rule_set_seen[rtag] then
                            rule_set_seen[rtag] = true
                            table.insert(sb.route.rule_set, { tag = rtag, type = "local", format = "binary", path = rpath })
                        end
                        table.insert(rs_tags, rtag)
                    else
                        os.execute("logger -t singbox-compiler 'WARNING: geosite category \"" .. cat .. "\" file missing, skipping rule'")
                    end
                else
                    table.insert(rule_item.domain_suffix, d)
                    table.insert(dns_item.domain_suffix, d)
                end
            end
            if #rs_tags > 0 then
                rule_item.rule_set = rs_tags
                -- IMPORTANT: dns_item must get an INDEPENDENT copy of the tags, not a
                -- reference to the same rs_tags array. Otherwise rule_item.rule_set
                -- and dns_item.rule_set point at the same Lua object, and
                -- json.stringify writes null instead of the tag array the second
                -- time it encounters an already-serialized table — the DNS rule
                -- silently loses its condition.
                local dns_rs_tags = {}
                for _, t in ipairs(rs_tags) do table.insert(dns_rs_tags, t) end
                dns_item.rule_set = dns_rs_tags
            end
            if #rule_item.domain_suffix == 0 then rule_item.domain_suffix = nil end
            if #dns_item.domain_suffix  == 0 then dns_item.domain_suffix  = nil end
            if rule_item.domain_suffix or rule_item.rule_set then has_cond = true end
        end
        if r.ip and r.ip ~= "" then
            rule_item.ip_cidr = {}
            for i in r.ip:gmatch("[^, ]+") do table.insert(rule_item.ip_cidr, i) end
            has_cond = true
        end
        if has_cond then
            rule_item.outbound = r.outbound or "direct"
            table.insert(rt_custom, rule_item)
            if dns_item.domain_suffix or dns_item.rule_set then
                dns_item.server = (rule_item.outbound == "proxy") and "dns-remote" or "dns-local"
                table.insert(dns_custom, dns_item)
            end
        end
    end)
end

-- Priority 2: geo-blocked lists (depends on route_mode)
if route_mode == "2" then
    -- Mode 2: everything via proxy except RU → geosite-ru.srs → direct
    local ru_path = "/etc/sing-box/geosite-ru.srs"
    local f_ru = io.open(ru_path, "r")
    if f_ru then
        f_ru:close()
        table.insert(sb.route.rule_set, { tag = "geosite-ru", type = "local", format = "binary", path = ru_path })
        table.insert(rt_geo,  { rule_set = { "geosite-ru" }, outbound = "direct" })
        table.insert(dns_geo, { rule_set = { "geosite-ru" }, server   = "dns-local" })
    else
        os.execute("logger -t singbox-compiler 'WARNING: geosite-ru.srs missing — mode 2 geo rules skipped'")
    end
elseif route_mode == "3" then
    -- Mode 3: bypass RKN blocking → ru-blocked + geoip-ru-blocked → proxy
    local ru_path    = "/etc/sing-box/ru-blocked.srs"
    local geoip_path = "/etc/sing-box/geoip-ru-blocked.srs"
    local f_ru  = io.open(ru_path,    "r")
    local f_geo = io.open(geoip_path, "r")
    if f_ru and f_geo then
        f_ru:close(); f_geo:close()
        table.insert(sb.route.rule_set, { tag = "geosite-blocked", type = "local", format = "binary", path = ru_path    })
        table.insert(sb.route.rule_set, { tag = "geoip-blocked",   type = "local", format = "binary", path = geoip_path })
        table.insert(rt_geo, { rule_set = { "geosite-blocked" }, outbound = "proxy" })
        table.insert(rt_geo, {
            type = "logical", mode = "and",
            rules = {
                { protocol = { "tls", "http", "quic" }, invert = true },
                { rule_set = { "geoip-blocked" } }
            },
            outbound = "proxy"
        })
        table.insert(dns_geo, { rule_set = { "geosite-blocked" }, server = "dns-remote" })
    else
        if f_ru  then f_ru:close()  end
        if f_geo then f_geo:close() end
        os.execute("logger -t singbox-compiler 'WARNING: SRS files missing — mode 3 geo rules skipped'")
    end
end
-- Mode 1: no geo-rules needed

if #sb.route.rule_set == 0 then sb.route.rule_set = nil end

sb.route.rules = { { action = "sniff" } }
if block_quic == "1" then
    -- method="default" (not "drop") — a clean reject lets the client's own
    -- QUIC-then-fallback logic kick in immediately instead of waiting out a
    -- timeout first.
    table.insert(sb.route.rules, { protocol = "quic", action = "reject", method = "default" })
end
table.insert(sb.route.rules, { protocol = "dns", action = "hijack-dns" })
-- update-rules.sh: if the direct download (port 57321) fails, the retry
-- goes out on the 57330-57334 range — this rule must come before any
-- generic routing decisions, or mode 3 (final=direct) would route it right
-- back where it just failed from.
table.insert(sb.route.rules, { source_port_range = { "57330:57334" }, outbound = "proxy" })
for _, r in ipairs(rt_custom) do table.insert(sb.route.rules, r) end
for _, r in ipairs(rt_geo)    do table.insert(sb.route.rules, r) end

sb.dns.rules = {}
for _, r in ipairs(dns_domain) do table.insert(sb.dns.rules, r) end
for _, r in ipairs(dns_custom) do table.insert(sb.dns.rules, r) end
for _, r in ipairs(dns_geo)    do table.insert(sb.dns.rules, r) end

local json_output = json.stringify(sb)
if not json.parse(json_output) then
    io.stderr:write("singbox-compiler: generated JSON is invalid, aborting\n")
    os.exit(1)
end
local f = io.open(TMP_CONFIG, "w")
if f then f:write(json_output); f:close(); os.execute("mv " .. TMP_CONFIG .. " " .. RUN_CONFIG) end
