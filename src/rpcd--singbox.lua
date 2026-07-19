#!/usr/bin/lua
local json = require "luci.jsonc"
local uci  = require "uci".cursor()
package.path = package.path .. ";/usr/lib/singbox/?.lua"
local validate = require "validate"

local SUB_CACHE_DIR = "/etc/sing-box/sub_cache"

local method = arg[1]
local action = arg[2]

if method == "list" then
    print('{"status":{},"get_config":{},"add_node":{"node":"table"},"del_node":{"section":"string"},"edit_node":{"section":"string","node":"table"},"set_settings":{"settings":"table"},"add_rule":{"rule":"table"},"del_rule":{"section":"string"},"add_dns_rule":{"rule":"table"},"del_dns_rule":{"section":"string"},"add_subscription":{"label":"string","url":"string"},"update_sub":{"section":"string"},"apply":{},"check_connectivity":{},"get_running_config":{},"get_log":{},"get_active_node":{}}')
    os.exit(0)
end

if method ~= "call" then os.exit(1) end

local input = io.read("*a")
local req   = (input and input ~= "") and json.parse(input) or {}

local function respond(data)
    print(json.stringify(data))
    os.exit(0)
end

if action == "status" then
    local r1 = os.execute("pidof sing-box >/dev/null 2>&1")
    local running = (r1 == 0 or r1 == true)
    local sub_updating = false
    local lf = io.open("/var/run/singbox-sub.lock", "r")
    if lf then
        local pid = lf:read("*n"); lf:close()
        if pid then
            local r2 = os.execute("kill -0 " .. pid .. " >/dev/null 2>&1")
            sub_updating = (r2 == 0 or r2 == true)
        end
    end
    -- sing-box version
    local sb_ver = ""
    local vf = io.popen("/usr/bin/sing-box version 2>/dev/null | head -1")
    if vf then sb_ver = vf:read("*l") or ""; vf:close() end
    sb_ver = sb_ver:match("sing%-box version (.+)") or sb_ver
    -- Database date: depends on route_mode (mode 2 → geosite-ru.srs, mode 3 → ru-blocked.srs)
    local route_mode_now = uci:get("singbox", "main", "route_mode") or "3"
    local db_mtime = ""
    local db_label = ""
    local db_file = nil
    if route_mode_now == "2" then
        db_file  = "/etc/sing-box/geosite-ru.srs"
        db_label = "Базы geosite:ru"
    elseif route_mode_now == "3" then
        db_file  = "/etc/sing-box/ru-blocked.srs"
        db_label = "Базы РКН"
    end
    if db_file then
        local mf = io.popen("date -r '" .. db_file .. "' +%s 2>/dev/null")
        if mf then db_mtime = (mf:read("*l") or ""):gsub("%s+$", ""); mf:close() end
    end
    respond({ running = running, sub_updating = sub_updating, sb_version = sb_ver, db_mtime = db_mtime, db_label = db_label })

elseif action == "get_config" then
    local cfg = { main = {}, nodes = {}, custom_rules = {}, dns_rules = {}, subscriptions = {}, sub_nodes = {} }
    uci:foreach("singbox", "main",         function(s) cfg.main = s end)
    uci:foreach("singbox", "node",         function(s) cfg.nodes[s[".name"]] = s end)
    uci:foreach("singbox", "custom_rule",  function(s) cfg.custom_rules[s[".name"]] = s end)
    uci:foreach("singbox", "dns_rule",     function(s) cfg.dns_rules[s[".name"]] = s end)
    uci:foreach("singbox", "subscription", function(sub)
        local sec = sub[".name"]
        cfg.subscriptions[sec] = sub
        local content
        for _, path in ipairs({ "/var/run/singbox_sub_" .. sec .. ".json", SUB_CACHE_DIR .. "/" .. sec .. ".json" }) do
            local f = io.open(path, "r")
            if f then content = f:read("*a"); f:close(); break end
        end
        if not content then return end
        local nodes = json.parse(content)
        if type(nodes) ~= "table" then return end
        for _, n in ipairs(nodes) do
            n._subscription = sec
            n._sub_label    = sub.label or sec
            table.insert(cfg.sub_nodes, n)
        end
    end)
    respond(cfg)

elseif action == "add_subscription" then
    if not req.label or not req.url then respond({ error = "Missing label or url" }) end
    local sname = uci:add("singbox", "subscription")
    uci:set("singbox", sname, "label",   req.label)
    uci:set("singbox", sname, "url",     req.url)
    uci:set("singbox", sname, "enabled", "1")
    uci:save("singbox")
    respond({ status = "ok", section = sname })

elseif action == "add_rule" then
    if type(req.rule) ~= "table" or not req.rule.outbound then respond({ error = "Invalid rule data" }) end
    if req.rule.outbound ~= "proxy" and req.rule.outbound ~= "direct" then
        respond({ error = "outbound must be 'proxy' or 'direct'" })
    end
    if req.rule.domain then
        local ok, err = validate.domain_list(req.rule.domain)
        if not ok then respond({ error = "Домен: " .. err }) end
    end
    if req.rule.source then
        local ok, err = validate.ip_cidr_list(req.rule.source)
        if not ok then respond({ error = "Источник: " .. err }) end
    end
    if req.rule.ip then
        local ok, err = validate.ip_cidr_list(req.rule.ip)
        if not ok then respond({ error = "IP назначения: " .. err }) end
    end
    -- Download any missing geosite:<category> rule-sets (MetaCubeX/meta-rules-dat, sing-box format)
    if req.rule.domain then
        os.execute("mkdir -p /etc/sing-box/rule-sets")
        for cat in tostring(req.rule.domain):gmatch("geosite:([%w%-%_%.]+)") do
            local safe_cat = cat:gsub("[^%w%-%_%.]", "")
            local dest = "/etc/sing-box/rule-sets/geosite-" .. safe_cat .. ".srs"
            local f = io.open(dest, "r")
            if f then
                f:close()
            else
                local tmp = dest .. ".tmp"
                local url = "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/" .. safe_cat .. ".srs"
                os.execute("wget -q -T 15 -O '" .. tmp .. "' '" .. url .. "' 2>/dev/null")
                local tf = io.open(tmp, "r")
                local size = tf and tf:seek("end") or 0
                if tf then tf:close() end
                if size and size > 8 then
                    os.execute("mv '" .. tmp .. "' '" .. dest .. "'")
                else
                    os.execute("rm -f '" .. tmp .. "'")
                    respond({ error = "Категория geosite:" .. safe_cat .. " не найдена или недоступна" })
                end
            end
        end
    end
    local allowed = { source = true, domain = true, ip = true, outbound = true }
    local sname = uci:add("singbox", "custom_rule")
    for k, v in pairs(req.rule) do
        if allowed[k] and v ~= "" then
            local safe = tostring(v):gsub("['\"\\\n\r\t]", "")
            uci:set("singbox", sname, k, safe)
        end
    end
    uci:save("singbox")
    respond({ status = "ok", section = sname })

elseif action == "del_rule" then
    if not req.section then respond({ error = "Missing section" }) end
    local sec_type = uci:get("singbox", req.section)
    if sec_type ~= "custom_rule" then respond({ error = "Invalid section type" }) end
    uci:delete("singbox", req.section)
    uci:save("singbox")
    respond({ status = "ok" })

elseif action == "del_node" then
    if not req.section then respond({ error = "Missing section" }) end
    local sec_type = uci:get("singbox", req.section)
    if sec_type ~= "node" and sec_type ~= "subscription" then
        respond({ error = "Invalid section type" })
    end
    if sec_type == "subscription" then
        -- Subscription-derived nodes only ever live in the tmpfs/sub_cache JSON
        -- cache below, never as their own "node" UCI sections, so there is
        -- nothing further to hunt down in UCI here.
        os.remove("/var/run/singbox_sub_" .. req.section .. ".json")
        os.remove(SUB_CACHE_DIR .. "/" .. req.section .. ".json")
    end
    uci:delete("singbox", req.section)
    uci:save("singbox")
    respond({ status = "ok" })

elseif action == "add_node" then
    if type(req.node) ~= "table" or not req.node.type or not req.node.tag then respond({ error = "Invalid or missing node data" }) end
    local allowed = {
        type=true, tag=true, server=true, server_port=true, uuid=true, security=true, sni=true, pbk=true, sid=true,
        private_key=true, peer_public_key=true, local_address=true, jc=true, jmin=true, jmax=true, s1=true, s2=true,
        s3=true, s4=true, pre_shared_key=true, h1=true, h2=true, h3=true, h4=true,
        transport=true, path=true, thost=true, mode=true, enabled=true
    }
    if req.node.server then
        local ok, err = validate.dns_addr(req.node.server)
        if not ok then respond({ error = "Сервер: " .. err }) end
    end
    local sname = uci:add("singbox", "node")
    for k, v in pairs(req.node) do
        if allowed[k] then
            local safe = tostring(v):gsub("['\"\\\n\r\t]", "")
            uci:set("singbox", sname, k, safe)
        end
    end
    uci:save("singbox")
    respond({ status = "ok", section = sname })

elseif action == "edit_node" then
    if not req.section then respond({ error = "Missing section" }) end
    local sec_type = uci:get("singbox", req.section)
    if sec_type ~= "node" then respond({ error = "Invalid section type" }) end
    if type(req.node) ~= "table" then respond({ error = "Invalid node data" }) end
    if req.node.server and req.node.server ~= "" then
        local ok, err = validate.dns_addr(req.node.server)
        if not ok then respond({ error = "Сервер: " .. err }) end
    end
    local allowed = {
        tag=true, server=true, server_port=true, uuid=true, security=true, sni=true, pbk=true, sid=true,
        private_key=true, peer_public_key=true, local_address=true, jc=true, jmin=true, jmax=true, s1=true, s2=true,
        s3=true, s4=true, pre_shared_key=true, h1=true, h2=true, h3=true, h4=true,
        transport=true, path=true, thost=true, mode=true, enabled=true
    }
    for k, v in pairs(req.node) do
        if allowed[k] then
            local safe = tostring(v):gsub("['\"\\\n\r\t]", "")
            if safe == "" then
                uci:delete("singbox", req.section, k)
            else
                uci:set("singbox", req.section, k, safe)
            end
        end
    end
    uci:save("singbox")
    respond({ status = "ok" })

elseif action == "set_settings" then
    local allowed = { enabled=true, route_mode=true, custom_dns=true, local_dns=true, cron_schedule=true, dns_remote_detour=true, block_dot=true, block_quic=true }
    if req.settings and req.settings.custom_dns then
        local ok, err = validate.dns_addr(req.settings.custom_dns)
        if not ok then respond({ error = "Upstream DNS: " .. err }) end
    end
    if req.settings and req.settings.local_dns then
        local ok, err = validate.dns_addr(req.settings.local_dns)
        if not ok then respond({ error = "Local DNS: " .. err }) end
    end
    if req.settings and req.settings.cron_schedule then
        local ok, err = validate.cron(req.settings.cron_schedule)
        if not ok then respond({ error = "Cron: " .. err }) end
    end
    local old_mode = uci:get("singbox", "main", "route_mode") or "3"
    local new_mode = (req.settings or {}).route_mode
    for k, v in pairs(req.settings or {}) do
        if allowed[k] then uci:set("singbox", "main", k, tostring(v)) end
    end
    uci:save("singbox")

    -- Cron: read cron_schedule from UCI (already saved above)
    local cron = uci:get("singbox", "main", "cron_schedule") or "0 4 * * 1"
    local safe_cron = cron:gsub("'", ""):gsub("[^%d%*/,%-% ]", "")
    os.execute("mkdir -p /etc/crontabs && touch /etc/crontabs/root")
    if cron ~= "disable" and safe_cron ~= "" then
        os.execute("grep -v 'update-rules.sh' /etc/crontabs/root > /etc/crontabs/root.tmp; echo '"
            .. safe_cron .. " /etc/sing-box/update-rules.sh >/dev/null 2>&1' >> /etc/crontabs/root.tmp"
            .. " && mv /etc/crontabs/root.tmp /etc/crontabs/root")
    else
        os.execute("grep -v 'update-rules.sh' /etc/crontabs/root > /etc/crontabs/root.tmp"
            .. " && mv /etc/crontabs/root.tmp /etc/crontabs/root")
    end
    os.execute("/etc/init.d/cron restart 2>/dev/null")

    if new_mode and tostring(new_mode) ~= old_mode then
        os.execute("(/etc/sing-box/update-rules.sh) </dev/null >/dev/null 2>&1 &")
    end
    respond({ status = "ok" })

elseif action == "add_dns_rule" then
    if type(req.rule) ~= "table" or not req.rule.domain or not req.rule.server then
        respond({ error = "Missing domain or server" })
    end
    if req.rule.domain == "" or req.rule.server == "" then
        respond({ error = "domain and server must not be empty" })
    end
    do
        local ok, err = validate.domain_list(req.rule.domain)
        if not ok then respond({ error = "Домен: " .. err }) end
    end
    do
        local ok, err = validate.dns_addr(req.rule.server)
        if not ok then respond({ error = "DNS-сервер: " .. err }) end
    end
    local sname = uci:add("singbox", "dns_rule")
    uci:set("singbox", sname, "domain", (tostring(req.rule.domain):gsub("['\"\\]", "")))
    uci:set("singbox", sname, "server", (tostring(req.rule.server):gsub("['\"\\]", "")))
    uci:set("singbox", sname, "via_proxy", (req.rule.via_proxy and "1" or "0"))
    uci:save("singbox")
    respond({ status = "ok", section = sname })

elseif action == "del_dns_rule" then
    if not req.section then respond({ error = "Missing section" }) end
    if uci:get("singbox", req.section) ~= "dns_rule" then respond({ error = "Invalid section type" }) end
    uci:delete("singbox", req.section)
    uci:save("singbox")
    respond({ status = "ok" })

elseif action == "get_active_node" then
    local function clash_secret()
        local s = uci:get("singbox", "main", "clash_secret")
        if s and s ~= "" then return s end
        local f = io.open("/var/run/singbox_clash.sec", "r")
        if f then local v = f:read("*a"):gsub("%s+", ""); f:close(); return v end
        return ""
    end
    local function clash_get(path)
        local secret = clash_secret()
        local cmd = "wget -q -T 3 -O - --header='Authorization: Bearer " .. secret .. "' "
                  .. "'http://127.0.0.1:9090" .. path .. "' 2>/dev/null"
        local p = io.popen(cmd)
        if not p then return nil end
        local body = p:read("*a"); p:close()
        if not body or body == "" then return nil end
        local ok, data = pcall(json.parse, body)
        if not ok then return nil end
        return data
    end
    local proxy = clash_get("/proxies/proxy")
    if not proxy or not proxy.now then respond({ error = "Clash API недоступен" }) end
    local now = proxy.now
    if now == "proxy-auto" then
        local auto = clash_get("/proxies/proxy-auto")
        if auto and auto.now then now = auto.now end
    end
    respond({ node = now })

elseif action == "check_connectivity" then
    local rc = os.execute("wget -q --spider -T 5 https://rutracker.org >/dev/null 2>&1")
    local ok_flag = (rc == 0 or rc == true)
    respond({ reachable = ok_flag, http_code = ok_flag and "200" or "нет ответа", target = "rutracker.org" })

elseif action == "get_running_config" then
    local f = io.open("/var/run/sing-box_running.json", "r")
    if not f then respond({ error = "Config not found — apply first" }) end
    local data = f:read("*a"); f:close()
    respond({ config = data })

elseif action == "get_log" then
    local lines = ""
    -- singbox-logtail (see initd) keeps this file as a 100-line ring buffer
    -- of sing-box's own output. Fall back to the old logread-based lookup if
    -- the file doesn't exist yet (service just started, not a single line
    -- has arrived through the pipe) so the panel doesn't show an empty log.
    local lf = io.open("/var/run/sing-box_log.txt", "r")
    if lf then lines = lf:read("*a") or ""; lf:close() end
    if lines == "" then
        local pf = io.popen("logread -e sing-box 2>/dev/null | tail -50")
        if pf then lines = pf:read("*a") or ""; pf:close() end
        -- logread returns sing-box's raw output, ANSI escape codes included
        -- (singbox-logtail only strips these for LOG_FILE above) — strip
        -- them here too so this fallback path doesn't leak "[36mINFO[0m"
        -- garbage into the log modal.
        -- NOTE: this used to only match "ESC[<digits/;>m" (plain SGR/color
        -- codes). sing-box's logger — even started with --disable-color —
        -- has been observed to still emit non-color CSI sequences around its
        -- startup banner when stdout isn't a TTY (cursor hide/show
        -- "ESC[?25l"/"ESC[?25h", erase-line "ESC[2K", cursor moves), which
        -- the old pattern let straight through. Match the general CSI
        -- grammar (ESC '[' + params 0-9;:<=>? + a final letter) instead, and
        -- also drop stray carriage returns left behind by erase-line/redraw
        -- sequences. Keep this in sync with strip_ansi() inlined in
        -- install.sh (see "singbox-logtail" section) — no shared module
        -- between the two on purpose, to keep this file dependency-free.
        lines = lines:gsub("\27%[[%d;:<=>?]*%a", ""):gsub("\r", "")
    end
    respond({ log = lines })

elseif action == "update_sub" then
    local sec = ""
    if req.section then
        local safe_sec = tostring(req.section):gsub("[^%w_%-]", "")
        if safe_sec ~= "" then sec = " " .. safe_sec end
    end
    os.execute("/usr/sbin/singbox-sub-updater" .. sec .. " </dev/null >/dev/null 2>&1 &")
    respond({ status = "processing" })

elseif action == "apply" then
    uci:commit("singbox")
    local enabled = uci:get("singbox", "main", "enabled") or "0"
    if enabled ~= "1" then
        os.execute("/etc/init.d/sing-box stop")
        respond({ status = "ok" })
    else
        local res = os.execute("/etc/init.d/sing-box reload")
        -- Flush DNS cache: without this, domain_suffix rules won't apply to
        -- already-cached resolutions (the packet would go out on the old IP,
        -- bypassing the rule)
        os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
        if res == 0 or res == true then respond({ status = "ok" }) else respond({ error = "Reload failed" }) end
    end

else
    respond({ error = "Unknown action: " .. tostring(action) })
end