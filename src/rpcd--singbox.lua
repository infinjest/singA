#!/usr/bin/lua
local json = require "luci.jsonc"
local uci  = require "uci".cursor()

local SUB_CACHE_DIR = "/etc/sing-box/sub_cache"

local method = arg[1]
local action = arg[2]

if method == "list" then
    -- Hardcoded JSON: json.stringify({}) → "[]", ломает UBUS-интроспекцию
	print('{"status":{},"get_config":{},"add_node":{"node":"table"},"del_node":{"section":"string"},"edit_node":{"section":"string","node":"table"},"set_settings":{"settings":"table"},"add_rule":{"rule":"table"},"del_rule":{"section":"string"},"set_rules":{"force_proxy":"table","force_direct":"table"},"add_subscription":{"label":"string","url":"string"},"update_sub":{"section":"string"},"apply":{},"change_password":{"password":"string"}}')
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
    respond({ running = running, sub_updating = sub_updating })

elseif action == "get_config" then
    local cfg = { main = {}, nodes = {}, rules = {}, custom_rules = {}, subscriptions = {}, sub_nodes = {} }
    uci:foreach("singbox", "main",         function(s) cfg.main = s end)
    uci:foreach("singbox", "node",         function(s) cfg.nodes[s[".name"]] = s end)
    uci:foreach("singbox", "rule",         function(s) cfg.rules[s[".name"]] = s end)
    uci:foreach("singbox", "custom_rule",  function(s) cfg.custom_rules[s[".name"]] = s end)
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
        h1=true, h2=true, h3=true, h4=true,
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
        h1=true, h2=true, h3=true, h4=true,
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
    for k, v in pairs(req.settings or {}) do uci:set("singbox", "main", k, tostring(v)) end
    uci:save("singbox")
    
    -- Динамическое управление Cron с защитой от инъекций (Белый список символов)
    local cron = (req.settings or {}).cron or uci:get("singbox", "main", "cron") or "0 4 * * 1"
    local safe_cron = cron:gsub("'", ""):gsub("[^%d%*/,%-% ]", "")

    -- Атомарное обновление cron: sed -i на busybox ненадёжен
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
    
    respond({ status = "ok" })

elseif action == "change_password" then
	if type(req.password) ~= "string" or req.password == "" then 
		respond({ error = "Пароль не может быть пустым" }) 
	end
	-- Устранение уязвимости Newline Injection и экранирование кавычек
	local safe_pass = req.password:gsub("[\n\r]", ""):gsub("'", "'\\''")
	
	-- [ ПАТЧ ]: Замена echo на printf для защиты от инъекции управляющих флагов (-e, -n)
	local cmd = "printf 'root:%s\\n' '" .. safe_pass .. "' | chpasswd 2>/dev/null"
	
	local res = os.execute(cmd)
	if res == 0 or res == true then 
		respond({ status = "ok" }) 
	else 
		respond({ error = "Ошибка при смене пароля" }) 
	end

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
    local res = os.execute("/etc/init.d/sing-box reload")
    if res == 0 or res == true then respond({ status = "ok" }) else respond({ error = "Reload failed" }) end

else
    respond({ error = "Unknown action: " .. tostring(action) })
end