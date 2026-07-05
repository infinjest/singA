#!/usr/bin/lua
local json = require "luci.jsonc"
local uci  = require "uci".cursor()

local SUB_CACHE_DIR = "/etc/sing-box/sub_cache"

local method = arg[1]
local action = arg[2]

if method == "list" then
    print('{"status":{},"get_config":{},"add_node":{"node":"table"},"del_node":{"section":"string"},"edit_node":{"section":"string","node":"table"},"set_settings":{"settings":"table"},"add_rule":{"rule":"table"},"del_rule":{"section":"string"},"set_rules":{"force_proxy":"table","force_direct":"table"},"add_dns_rule":{"rule":"table"},"del_dns_rule":{"section":"string"},"add_subscription":{"label":"string","url":"string"},"update_sub":{"section":"string"},"apply":{},"check_connectivity":{},"get_running_config":{},"get_log":{}}')
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
    -- Версия sing-box
    local sb_ver = ""
    local vf = io.popen("/usr/bin/sing-box version 2>/dev/null | head -1")
    if vf then sb_ver = vf:read("*l") or ""; vf:close() end
    sb_ver = sb_ver:match("sing%-box version (.+)") or sb_ver
    -- Дата баз: зависит от route_mode (режим 2 — geosite-ru.srs, режим 3 — ru-blocked.srs)
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
    local cfg = { main = {}, nodes = {}, rules = {}, custom_rules = {}, dns_rules = {}, subscriptions = {}, sub_nodes = {} }
    uci:foreach("singbox", "main",         function(s) cfg.main = s end)
    uci:foreach("singbox", "node",         function(s) cfg.nodes[s[".name"]] = s end)
    uci:foreach("singbox", "rule",         function(s) cfg.rules[s[".name"]] = s end)
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

elseif action == "set_rules" then
    if type(req.force_proxy)  ~= "table" and type(req.force_proxy)  ~= "nil" then respond({ error = "force_proxy must be array" }) end
    if type(req.force_direct) ~= "table" and type(req.force_direct) ~= "nil" then respond({ error = "force_direct must be array" }) end
    local rsec
    uci:foreach("singbox", "rule", function(s) rsec = s[".name"] end)
    if not rsec then rsec = uci:add("singbox", "rule") end
    if req.force_proxy  ~= nil then uci:set("singbox", rsec, "force_proxy",  req.force_proxy) end
    if req.force_direct ~= nil then uci:set("singbox", rsec, "force_direct", req.force_direct) end
    uci:save("singbox")
    respond({ status = "ok" })

elseif action == "del_node" then
    if not req.section then respond({ error = "Missing section" }) end
    local sec_type = uci:get("singbox", req.section)
    if sec_type ~= "node" and sec_type ~= "subscription" then
        respond({ error = "Invalid section type" })
    end
    if sec_type == "subscription" then
        os.remove("/var/run/singbox_sub_" .. req.section .. ".json")
        os.remove(SUB_CACHE_DIR .. "/" .. req.section .. ".json")
        local to_delete = {}
        uci:foreach("singbox", "node", function(s)
            if s.subscription == req.section then table.insert(to_delete, s[".name"]) end
        end)
        for _, name in ipairs(to_delete) do uci:delete("singbox", name) end
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
    local allowed = { enabled=true, route_mode=true, custom_dns=true, local_dns=true, failover=true, cron_schedule=true }
    local old_mode = uci:get("singbox", "main", "route_mode") or "3"
    local new_mode = (req.settings or {}).route_mode
    for k, v in pairs(req.settings or {}) do
        if allowed[k] then uci:set("singbox", "main", k, tostring(v)) end
    end
    uci:save("singbox")

    -- Cron: читаем cron_schedule из UCI (уже сохранён выше)
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

    -- При смене route_mode обновляем SRS в фоне
    if new_mode and new_mode ~= old_mode then
        os.execute("/etc/sing-box/update-rules.sh </dev/null >/dev/null 2>&1 &")
    end
    respond({ status = "ok" })

elseif action == "add_dns_rule" then
    if type(req.rule) ~= "table" or not req.rule.domain or not req.rule.server then
        respond({ error = "Missing domain or server" })
    end
    if req.rule.domain == "" or req.rule.server == "" then
        respond({ error = "domain and server must not be empty" })
    end
    local sname = uci:add("singbox", "dns_rule")
    uci:set("singbox", sname, "domain", (tostring(req.rule.domain):gsub("['\"\\]", "")))
    uci:set("singbox", sname, "server", (tostring(req.rule.server):gsub("['\"\\]", "")))
    uci:save("singbox")
    respond({ status = "ok", section = sname })

elseif action == "del_dns_rule" then
    if not req.section then respond({ error = "Missing section" }) end
    if uci:get("singbox", req.section) ~= "dns_rule" then respond({ error = "Invalid section type" }) end
    uci:delete("singbox", req.section)
    uci:save("singbox")
    respond({ status = "ok" })

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
    local lf = io.popen("logread -e sing-box 2>/dev/null | tail -50")
    if lf then lines = lf:read("*a") or ""; lf:close() end
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
        -- Сброс DNS-кэша: без этого правила по domain_suffix не сработают для
        -- уже закэшированных резолвов (пакет уйдёт по старому IP, минуя правило)
        os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
        if res == 0 or res == true then respond({ status = "ok" }) else respond({ error = "Reload failed" }) end
    end

else
    respond({ error = "Unknown action: " .. tostring(action) })
end