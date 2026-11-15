-- src/lib--singbox-validate.lua  →  /usr/lib/singbox/validate.lua
-- Shared validation module: used by rpcd (pre-submit) and by compiler
-- (defense-in-depth — the frontend is not assumed to be the only writer of UCI).
local M = {}

local VALID_DNS_SCHEMES = { udp=true, tcp=true, tls=true, https=true, quic=true, h3=true, http3=true }

local function is_ipv4(s)
    local a,b,c,d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, o in ipairs({a,b,c,d}) do
        local n = tonumber(o)
        if not n or n > 255 then return false end
    end
    return true
end

local function is_ipv6(s)
    return s:find(":") ~= nil and s:match("^[%x:]+$") ~= nil
end

local function is_hostname(s)
    if not s:match("^[%w%-%.]+$") or not s:match("%.%a%a+$") then return false end
    for label in s:gmatch("[^%.]+") do
        if #label == 0 or #label > 63 or label:match("^%-") or label:match("%-$") then return false end
    end
    return true
end

-- scheme://host[:port][/path], or a bare host/IP → { scheme, host, port, path }.
-- port is already coerced to a number. On error: nil, message.
function M.parse_dns_addr(addr)
    if not addr or addr == "" then return nil, "не указан адрес сервера" end
    local scheme, rest = addr:match("^(%a[%a%d]*)://(.+)$")
    if not scheme then scheme = "udp"; rest = addr end
    if not VALID_DNS_SCHEMES[scheme:lower()] then
        return nil, 'неизвестная схема "' .. scheme .. '" (udp/tcp/tls/https/quic/h3/http3)'
    end
    local hostport, path = rest:match("^([^/]*)(/.*)$")
    if not hostport then hostport = rest end
    local host, port
    local v6, v6rest = hostport:match("^%[([^%]]+)%](.*)$")
    if v6 then
        host = v6; port = v6rest:match("^:(%d+)$")
        if not is_ipv6(host) then return nil, '"' .. host .. '" не похож на IPv6' end
    elseif select(2, hostport:gsub(":", "")) == 1 then
        host, port = hostport:match("^([^:]+):(%d+)$")
        if not host then return nil, "порт после \":\" должен быть числом" end
    elseif select(2, hostport:gsub(":", "")) > 1 then
        return nil, "IPv6 без скобок — оберните в [ ]"
    else
        host = hostport
    end
    if not host or host == "" then return nil, "не указан адрес сервера" end
    if not (is_ipv4(host) or is_hostname(host) or is_ipv6(host)) then
        return nil, '"' .. host .. '" не похоже на IP или домен'
    end
    if port then
        local p = tonumber(port)
        if not p or p < 1 or p > 65535 then return nil, "порт " .. port .. " вне диапазона 1-65535" end
        port = p
    end
    return { scheme = scheme:lower(), host = host, port = port, path = path }
end

function M.dns_addr(addr)
    if not addr or addr == "" then return true end
    local parsed, err = M.parse_dns_addr(addr)
    if not parsed then return false, err end
    return true
end

-- Domain list, including geosite:<category>
function M.domain_list(v)
    if not v or v == "" then return true end
    for item in v:gmatch("[^,%s]+") do
        if item:match("^geosite:") then
            if not item:match("^geosite:[%w%-%_%.]+$") then
                return false, 'некорректное имя категории в "' .. item .. '"'
            end
        elseif not is_hostname(item) then
            return false, '"' .. item .. '" не похоже на домен (и не geosite:<категория>)'
        end
    end
    return true
end

-- IP/CIDR list
function M.ip_cidr_list(v)
    if not v or v == "" then return true end
    for item in v:gmatch("[^,%s]+") do
        local addr, prefix = item:match("^([^/]+)/?(%d*)$")
        if not addr then return false, '"' .. item .. '" не похоже на IP/CIDR' end
        local is4 = is_ipv4(addr)
        if not is4 and not is_ipv6(addr) then return false, '"' .. addr .. '" не похоже на IP' end
        if prefix ~= "" then
            local p, max = tonumber(prefix), (is4 and 32 or 128)
            if not p or p > max then return false, '"' .. item .. '" — маска вне диапазона 0-' .. max end
        end
    end
    return true
end

-- Single TCP/UDP port: "443". On error: false, message.
function M.port(v)
    local s = tostring(v or "")
    if not s:match("^%d+$") then return false, '"' .. s .. '" не похоже на порт' end
    local p = tonumber(s)
    if p < 1 or p > 65535 then return false, "порт " .. s .. " вне диапазона 1-65535" end
    return true
end

-- Hysteria2 port list / port hopping: "443", "20000-50000", "443,5000-6000".
-- "from:to" (sing-box notation) is accepted as well as "from-to".
function M.port_list(v)
    if v == nil or v == "" then return true end
    local n = 0
    for item in tostring(v):gmatch("[^,%s]+") do
        n = n + 1
        local a, b = item:match("^(%d+)[%-:](%d+)$")
        if not a then a = item:match("^(%d+)$") end
        if not a then
            return false, '"' .. item .. '" не похоже на порт или диапазон (пример: 443,20000-50000)'
        end
        a = tonumber(a); b = b and tonumber(b) or a
        if a < 1 or a > 65535 or b < 1 or b > 65535 then
            return false, 'порт в "' .. item .. '" вне диапазона 1-65535'
        end
        if a > b then return false, 'в диапазоне "' .. item .. '" начало больше конца' end
    end
    if n == 0 then return false, "пустой список портов" end
    return true
end

-- Hysteria2 obfuscation type: "" (off), "salamander" or "gecko".
function M.hy2_obfs(v)
    if v == nil or v == "" or v == "salamander" or v == "gecko" then return true end
    return false, 'неизвестный тип обфускации "' .. tostring(v) .. '" (salamander/gecko)'
end

-- Gecko min/max on-wire packet size (either may be empty = core default).
function M.gecko_sizes(minv, maxv)
    local function one(v, name)
        if v == nil or v == "" then return true end
        local s = tostring(v)
        local n = s:match("^%d+$") and tonumber(s)
        if not n or n < 1 or n > 65535 then
            return false, name .. ": ожидается целое число 1-65535"
        end
        return true
    end
    local ok, err = one(minv, "мин. размер пакета")
    if not ok then return false, err end
    ok, err = one(maxv, "макс. размер пакета")
    if not ok then return false, err end
    if minv and minv ~= "" and maxv and maxv ~= "" and tonumber(minv) > tonumber(maxv) then
        return false, "мин. размер пакета больше максимального"
    end
    return true
end

-- Node server address (NOT a DNS address): IPv4, IPv6 (bare or in [ ]) or a hostname.
-- ASCII only, punycode (xn--…) is fine; no scheme, no port.
function M.node_host(v)
    local s = tostring(v or "")
    if s == "" then return false, "не указан адрес сервера" end
    if s:find("://", 1, true) then return false, 'адрес сервера указывается без схемы ("' .. s .. '")' end
    local inner = s:match("^%[([^%]]+)%]$")
    if inner or s:find(":", 1, true) then
        if is_ipv6(inner or s) then return true end
        if s:match("^[^:/%[%]]+:%d+$") then return false, "порт указывается в отдельном поле, а не в адресе" end
        return false, '"' .. s .. '" не похоже на IPv6-адрес'
    end
    if s:match("^[%d%.]+$") then
        if is_ipv4(s) then return true end
        return false, '"' .. s .. '" не похоже на IPv4-адрес'
    end
    local host = s:gsub("%.$", "")
    if host == "" or #host > 253 then return false, '"' .. s .. '" не похоже на домен' end
    for label in (host .. "."):gmatch("([^%.]*)%.") do
        if #label == 0 or #label > 63 or not label:match("^[%w_%-]+$") or label:match("^%-") or label:match("%-$") then
            local hint = s:find("[\128-\255]") and " (для IDN используйте punycode, xn--…)" or ""
            return false, '"' .. s .. '" не похоже на IP или домен' .. hint
        end
    end
    return true
end

-- WireGuard/AmneziaWG key: base64 of 32 bytes = 43 chars + "=".
function M.wg_key(v)
    local s = tostring(v or "")
    if #s == 44 and s:match("^[A-Za-z0-9+/]+=$") then return true end
    return false, "ключ должен быть в base64, 44 символа (оканчивается на =)"
end

-- Non-negative integer in [min, max]; empty = not set.
function M.uint(v, min, max)
    if v == nil or v == "" then return true end
    local s = tostring(v)
    local n = s:match("^%d+$") and tonumber(s)
    if not n or n < (min or 0) or n > (max or 4294967295) then
        return false, "ожидается целое число " .. (min or 0) .. "-" .. (max or 4294967295)
    end
    return true
end

-- AmneziaWG 2.0 magic header / AmneziaWG 3.x timing, padding and keepalive:
-- number or "from-to" range; empty = not set. max defaults to uint32 (the
-- keepalive interval is uint16, its caller passes 65535).
function M.awg_h(v, max)
    max = max or 4294967295
    if v == nil or v == "" then return true end
    local s = tostring(v)
    local a, b = s:match("^(%d+)%-(%d+)$")
    if not a then a = s:match("^(%d+)$") end
    if not a then return false, 'ожидается число или диапазон "от-до"' end
    a = tonumber(a); b = b and tonumber(b) or a
    if a > max or b > max then return false, "значение больше " .. string.format("%.0f", max) end
    if a > b then return false, "начало диапазона больше конца" end
    return true
end

-- AmneziaWG 3.x header_protection_key: a 32-byte base64 key like any WireGuard one,
-- but the core reads an all-zero key as "off" and refuses it; empty = not set.
function M.awg_hpk(v)
    if v == nil or v == "" then return true end
    local ok, err = M.wg_key(v)
    if not ok then return false, err end
    if tostring(v) == string.rep("A", 43) .. "=" then
        return false, "нулевой ключ означает «выключено» — оставьте поле пустым"
    end
    return true
end

function M.cron(v)
    if not v or v == "disable" then return true end
    local fields = {}
    for f in v:gmatch("%S+") do table.insert(fields, f) end
    if #fields ~= 5 then return false, "нужно 5 полей: минута час день месяц день_недели" end
    for _, f in ipairs(fields) do
        if not f:match("^[%d%*,%-/]+$") then return false, 'поле "' .. f .. '" содержит недопустимые символы' end
    end
    return true
end

return M
