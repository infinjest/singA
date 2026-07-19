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
