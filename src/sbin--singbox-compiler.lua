#!/usr/bin/lua
local uci  = require "uci".cursor()
local json = require "luci.jsonc"

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
        final = "direct",
        auto_detect_interface = true
    },
    dns = { 
        servers = {}, 
        rules = {}, 
        final = "dns-local"
    },
        experimental = { clash_api = { external_controller = "0.0.0.0:9090", secret = clash_secret } }
}

local enabled = uci:get("singbox", "main", "enabled") or "0"
if enabled ~= "1" then os.exit(0) end

local tproxy_port = tonumber(uci:get("singbox", "main", "tproxy_port")) or 7893
sb.inbounds[1].listen_port = tproxy_port
local rdbypass   = uci:get("singbox", "main", "rdbypass")   or "0"
local failover   = uci:get("singbox", "main", "failover")   or "0"
local custom_dns = uci:get("singbox", "main", "custom_dns") or "https://dns.cloudflare.com/dns-query"
local local_dns  = uci:get("singbox", "main", "local_dns")  or "tcp://77.88.8.8"

table.insert(sb.dns.servers, { tag = "dns-remote", address = custom_dns, detour = "proxy", address_resolver = "dns-local" })
table.insert(sb.dns.servers, { tag = "dns-local", address = local_dns, detour = "direct" })

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
        e.detour = "direct"
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

if failover == "1" and #proxy_tags > 1 then
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
local rt_force  = {}
local rt_geo    = {}

local dns_custom = {}
local dns_force  = {}
local dns_geo    = {}
local dns_base   = {
    { outbound = "direct", server = "dns-local", disable_cache = true }
}

-- Priority 1: user routing matrix
uci:foreach("singbox", "custom_rule", function(r)
    local rule_item = {}
    local dns_item  = {}
    local has_cond  = false

    if r.source and r.source ~= "" then
        rule_item.source_ip_cidr = {}
        for s in r.source:gmatch("[^, ]+") do table.insert(rule_item.source_ip_cidr, s) end
        has_cond = true
    end
    if r.domain and r.domain ~= "" then
        rule_item.domain_suffix = {}; dns_item.domain_suffix = {}
        for d in r.domain:gmatch("[^, ]+") do
            table.insert(rule_item.domain_suffix, d)
            table.insert(dns_item.domain_suffix, d)
        end
        has_cond = true
    end
    if r.ip and r.ip ~= "" then
        rule_item.ip_cidr = {}
        for i in r.ip:gmatch("[^, ]+") do table.insert(rule_item.ip_cidr, i) end
        has_cond = true
    end
    if has_cond then
        rule_item.outbound = r.outbound or "direct"
        table.insert(rt_custom, rule_item)
        if dns_item.domain_suffix then
            dns_item.server = (rule_item.outbound == "proxy") and "dns-remote" or "dns-local"
            table.insert(dns_custom, dns_item)
        end
    end
end)

-- Priority 2: force_proxy / force_direct
uci:foreach("singbox", "rule", function(r)
    if r.force_direct then
        local d = type(r.force_direct) == "table" and r.force_direct or { r.force_direct }
        table.insert(rt_force,  { domain_suffix = d, outbound = "direct" })
        table.insert(dns_force, { domain_suffix = d, server   = "dns-local" })
    end
    if r.force_proxy then
        local p = type(r.force_proxy) == "table" and r.force_proxy or { r.force_proxy }
        table.insert(rt_force,  { domain_suffix = p, outbound = "proxy" })
        table.insert(dns_force, { domain_suffix = p, server   = "dns-remote" })
    end
end)

-- Priority 3: geo-blocked lists
if rdbypass == "1" then
    local ru_path = "/etc/sing-box/ru-blocked.srs"
    local geoip_path = "/etc/sing-box/geoip-ru-blocked.srs"
    
    local f_ru = io.open(ru_path, "r")
    local f_geo = io.open(geoip_path, "r")
    
    if f_ru and f_geo then
        f_ru:close()
        f_geo:close()
        sb.route.rule_set = {
            { tag = "geosite-blocked", type = "local", format = "binary", path = ru_path },
            { tag = "geoip-blocked",   type = "local", format = "binary", path = geoip_path }
        }
        table.insert(rt_geo,  { rule_set = { "geosite-blocked", "geoip-blocked" }, outbound = "proxy" })
        table.insert(dns_geo, { rule_set = { "geosite-blocked" }, server = "dns-remote" })
    else
        if f_ru then f_ru:close() end
        if f_geo then f_geo:close() end
        os.execute("logger -t singbox-compiler 'WARNING: SRS files missing. RDBypass rules skipped.'")
    end
end

sb.route.rules = { { action = "sniff" }, { protocol = "dns", action = "hijack-dns" } }
for _, r in ipairs(rt_custom) do table.insert(sb.route.rules, r) end
for _, r in ipairs(rt_force)  do table.insert(sb.route.rules, r) end
for _, r in ipairs(rt_geo)    do table.insert(sb.route.rules, r) end

sb.dns.rules = {}
for _, r in ipairs(dns_custom) do table.insert(sb.dns.rules, r) end
for _, r in ipairs(dns_force)  do table.insert(sb.dns.rules, r) end
for _, r in ipairs(dns_geo)    do table.insert(sb.dns.rules, r) end
for _, r in ipairs(dns_base)   do table.insert(sb.dns.rules, r) end

local json_output = json.stringify(sb)
if not json.parse(json_output) then 
    io.stderr:write("singbox-compiler: generated JSON is invalid, aborting\n")
    os.exit(1) 
end
local f = io.open(TMP_CONFIG, "w")
if f then f:write(json_output); f:close(); os.execute("mv " .. TMP_CONFIG .. " " .. RUN_CONFIG) end