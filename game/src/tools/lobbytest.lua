-- End-to-end checks of the internet lobby (docs/lobby.md) against the real lobby server (server/lobby), on loopback:
-- publish, list, join through an introduction, join through the relay, unlisted games, unpublish. Called by
-- nettest.lua. The server binary comes from OPENWBC3_LOBBY_BIN, server/lobby/openwbc3-lobby(.exe), or is built with
-- `go build` when Go is installed; without any of these the checks are skipped.
local udp = require("src.game.udp")
local lobby = require("src.game.lobby")
local log = require("src.core.log")

local M = {}

local SERVER_PORT, HOST_PORT = 24991, 24992
local windows = package.config:sub(1, 1) == "\\"

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- The lobby server executable, building it when needed; nil when there is none.
---@param root string the repository root
---@return string?
local function serverBinary(root)
    local exe = windows and ".exe" or ""
    local env = os.getenv("OPENWBC3_LOBBY_BIN")
    if env and exists(env) then return env end
    local local_ = root .. "/server/lobby/openwbc3-lobby" .. exe
    if exists(local_) then return local_ end
    local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
    local out = tmp .. "/openwbc3-lobby-test" .. exe
    local cmd = ('cd "%s/server/lobby" && go build -o "%s" .'):format(root, out)
    if windows then cmd = 'cmd /c "' .. cmd .. '"' end
    local ok = os.execute(cmd .. (windows and " >NUL 2>&1" or " >/dev/null 2>&1"))
    if (ok == 0 or ok == true) and exists(out) then return out end
    return nil
end

local function startServer(bin)
    local args = ('-listen 127.0.0.1:%d -webListen "" -exitAfter 40 -gameTimeout 20 -refreshMs 1000'):format(SERVER_PORT)
    if windows then
        os.execute(('start "" /B "%s" %s >NUL 2>&1'):format(bin, args))
    else
        os.execute(('"%s" %s >/dev/null 2>&1 &'):format(bin, args))
    end
end

-- Services the hosts (which also drives their lobby clients) until `done()` or `seconds`; returns the events.
---@param hosts UdpHost[]
---@param seconds number
---@param done (fun(): any)?
---@return UdpEvent[][] events per host
local function pump(hosts, seconds, done)
    local t0 = love.timer.getTime()
    local events = {}
    for i = 1, #hosts do events[i] = {} end
    while love.timer.getTime() - t0 < seconds do
        for i, h in ipairs(hosts) do
            for _, e in ipairs(h:service()) do events[i][#events[i] + 1] = e end
        end
        if done and done() then break end
        love.timer.sleep(0.005)
    end
    return events
end

---@param list UdpEvent[]
---@param kind string
---@return UdpEvent?
local function find(list, kind)
    for _, e in ipairs(list) do if e.type == kind then return e end end
end

---@param check fun(name: string, ok: any)
function M.run(check)
    -- encoding checks that need no server
    check("lobby: IPv4 / IPv6 addresses encode as the server expects",
        lobby.ipBytes("203.0.113.5") == string.rep("\0", 10) .. "\255\255\203\0\113\5"
        and lobby.ipBytes("::1") == string.rep("\0", 15) .. "\1" and lobby.ipBytes("1.2.3.256") == nil
        and #lobby.ipBytes("2001:db8::5") == 16)
    local name, port = lobby.parseServer("[::1]:3000")
    check("lobby: server addresses parse", name == "::1" and port == 3000 and select(2, lobby.parseServer("x")) == 24860)

    local root = love.filesystem.getSource():gsub("\\", "/"):gsub("/game/?$", "")
    local bin = serverBinary(root)
    if not bin then
        print("skip  lobby end-to-end (no server: build server/lobby, set OPENWBC3_LOBBY_BIN or install Go)")
        return
    end
    startServer(bin)
    love.timer.sleep(0.6)
    local serverText = "127.0.0.1:" .. SERVER_PORT

    -- the host publishes
    local host = assert(udp.host({ port = HOST_PORT, ipv6 = false }))
    local hc = assert(lobby.client(host, serverText))
    local introduced = 0
    hc.onIntroduce = function() introduced = introduced + 1 end
    hc:publish({ name = "Loopback test", map = "Bridges", players = 1, maxPlayers = 4, version = 3,
                 content = "0123456789abcdef", password = true })
    pump({ host }, 3, function() return hc.gameId end)
    check("lobby: the host's game is registered", hc.gameId ~= nil and hc.observed ~= nil)
    if not hc.gameId then host:close(); return end

    -- a player lists it: name, map, players, flags, no address
    local player = assert(udp.host({ port = 0, ipv6 = false }))
    local pc = assert(lobby.client(player, serverText))
    pc:list(0, 0)
    pump({ host, player }, 3, function() return #pc.games > 0 end)
    local g = pc.games[1]
    check("lobby: the player lists the game", g and g.id == hc.gameId and g.name == "Loopback test" and g.map == "Bridges"
        and g.players == 1 and g.maxPlayers == 4 and g.password and not g.started and g.relay)
    pc:list(nil)

    -- join through an introduction: the handshake goes to every candidate, the host punches towards the player
    local joined
    pc:join(hc.gameId, function(j) joined = j end)
    pump({ host, player }, 3, function() return joined end)
    check("lobby: JOINED gives the host's public and LAN candidates", joined and joined.status == lobby.STATUS_OK
        and #joined.candidates >= 1 and joined.candidates[1].port == HOST_PORT)
    local ev = { {}, {} }
    if joined then
        player:connectTo(joined.candidates)
        ev = pump({ host, player }, 4, function() return introduced > 0 and #player.peers > 0 and next(host.peers) end)
        ev = pump({ host, player }, 2, function() return find(ev[2], "connect") end)
    end
    pc:stopJoining()
    check("lobby: the host was introduced and the player connects", introduced > 0 and next(host.peers) ~= nil)

    -- a second player comes through the relay only
    local p2 = assert(udp.host({ port = 0, ipv6 = false }))
    local rc = assert(lobby.client(p2, serverText))
    local relayAddr, relayStatus
    rc:requestRelay(hc.gameId, function(a, s) relayAddr, relayStatus = a, s end)
    pump({ host, player, p2 }, 3, function() return relayStatus ~= nil end)
    check("lobby: the relay is granted", relayAddr ~= nil and relayAddr:find("^relay:%x+$") ~= nil)
    if relayAddr then
        local rp = p2:connectTo({ { ip = relayAddr, port = 0 } })
        local got
        ev = pump({ host, player, p2 }, 5, function() return rp.state == "connected" end)
        rp:send({ through = "relay" })
        ev = pump({ host, player, p2 }, 3, function()
            for _, e in ipairs(ev[1]) do if e.type == "receive" and e.data.through == "relay" then got = e end end
            return got
        end)
        for _, e in ipairs(ev[1]) do if e.type == "receive" and e.data.through == "relay" then got = e end end
        check("lobby: a relayed player connects and its messages arrive", rp.state == "connected" and got ~= nil
            and got.peer.ip == relayAddr)
    end

    -- an unlisted game is joinable by its id but not listed
    local host2 = assert(udp.host({ port = HOST_PORT + 1, ipv6 = false }))
    local hc2 = assert(lobby.client(host2, serverText))
    hc2:publish({ name = "Secret", map = "Circles", players = 1, maxPlayers = 2, version = 3, unlisted = true })
    pump({ host2 }, 3, function() return hc2.gameId end)
    pc:list(0, 0)
    pc.games = {}
    pump({ host, host2, player }, 2.5, function() return #pc.games > 0 end)
    local listed = false
    for _, e in ipairs(pc.games) do listed = listed or e.name == "Secret" end
    local j2
    pc:join(hc2.gameId or 0, function(j) j2 = j end)
    pump({ host2, player }, 3, function() return j2 end)
    pc:stopJoining()
    check("lobby: an unlisted game is hidden but joinable by its id", hc2.gameId ~= nil and not listed and #pc.games == 1
        and j2 and j2.status == lobby.STATUS_OK)

    -- unpublish: gone from the list
    hc:unpublish()
    hc2:unpublish()
    pump({ host, host2, player }, 0.5)
    pc.games = { { id = -1, name = "", map = "", players = 0, maxPlayers = 0, version = 0, age = 0 } }  -- replaced by the next list
    pump({ host, host2, player }, 2.5, function() return #pc.games == 0 end)
    check("lobby: unpublished games disappear", #pc.games == 0)

    for _, c in ipairs({ hc, hc2, pc, rc }) do c:close() end
    for _, h in ipairs({ host, host2, player, p2 }) do h:close() end
    log.info("lobby: end-to-end checks done against %s", bin)
end

return M
