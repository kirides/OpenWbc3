-- LAN networking on top of src/game/udp.lua (reliable UDP, IPv4 + IPv6): the game port, and
-- discovery beacons so hosts show up in the "join" list. A later matchmaking / hole punching
-- server only has to produce (ip, port) pairs for Host:connect and use Host:sendRaw on the same socket.
local serialize = require("src.core.serialize")
local udp = require("src.game.udp")

local M = { PORT = 24850, DISCOVERY_PORT = 24851, VERSION = 3 }

function M.available() return udp.available() end

-- The game host: listens for players (and can connect out, for clients).
---@param port integer?
---@return UdpHost?
---@return string? err
function M.host(port)
    return udp.host({ port = port or M.PORT })
end

-- A client endpoint (ephemeral port).
---@return UdpHost?
---@return string? err
function M.client()
    return udp.host({ port = 0 })
end

-- Hosts announce themselves with beacons (raw datagrams, not part of the reliable protocol).
---@param host UdpHost
---@return {send: fun(self: table, info: table, now: number)}
function M.announcer(host)
    local last = 0
    return {
        send = function(self, info, now)
            if now - last < 1 then return end
            last = now
            info.version = M.VERSION
            info.port = host.port
            host:broadcast(serialize.encode(info), M.DISCOVERY_PORT)
        end,
    }
end

-- Listens for beacons; poll() returns the hosts heard of during the last 4 seconds:
-- { {ip, port, name, map, players, max}, ... }
---@return {poll: fun(self: table): table[], close: fun()}?
function M.listener()
    local h = udp.host({ port = M.DISCOVERY_PORT, accept = false })
    if not h then return nil end
    local hosts = {}
    h.onRaw = function(data, ip, port)
        local info = serialize.decode(data)
        if type(info) == "table" and info.version == M.VERSION and info.port then
            info.ip = ip
            info.seen = love.timer.getTime()
            hosts[ip .. "|" .. info.port] = info
        end
    end
    return {
        poll = function(self)
            h:service()
            local now = love.timer.getTime()
            local list = {}
            for key, e in pairs(hosts) do
                if now - e.seen > 4 then hosts[key] = nil else list[#list + 1] = e end
            end
            table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
            return list
        end,
        close = function() h:close() end,
    }
end

M.localAddresses = udp.localAddresses

return M
