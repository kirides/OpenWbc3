-- Loopback checks for the UDP layer (cookie handshake, spoofing, roaming): `love game --nettest`.
local udp = require("src.game.udp")
local socket = require("socket")

local M = {}

-- A UDP event as pump hands it out: tagged with the index of its host.
---@class NetTestEvent: UdpEvent
---@field host integer index in the `hosts` given to pump

-- Services the hosts for up to `seconds` (or until `until_(events)` is true) and returns every event.
---@param hosts UdpHost[]
---@param seconds number
---@param until_ (fun(events: NetTestEvent[]): any)?
---@return NetTestEvent[]
local function pump(hosts, seconds, until_)
    local t0 = love.timer.getTime()
    local events = {}
    while love.timer.getTime() - t0 < seconds do
        for i, h in ipairs(hosts) do
            for _, e in ipairs(h:service()) do
                ---@cast e NetTestEvent
                e.host = i; events[#events + 1] = e
            end
        end
        if until_ and until_(events) then break end
        love.timer.sleep(0.005)
    end
    return events
end

---@param events NetTestEvent[]
---@param host integer index in the `hosts` given to pump
---@param kind string event type ("connect", "receive", "disconnect")
---@return NetTestEvent?
local function find(events, host, kind)
    for _, e in ipairs(events) do if e.host == host and e.type == kind then return e end end
end

---@return integer exit code: 0 when every check passed
function M.run()
    local fails = 0
    local function check(name, ok)
        print((ok and "ok    " or "FAIL  ") .. name)
        if not ok then fails = fails + 1 end
    end

    local server = assert(udp.host({ port = 24990, ipv6 = false }))
    local client = assert(udp.host({ port = 0, ipv6 = false }))
    local peer = assert(client:connect("127.0.0.1", 24990))
    local ev = pump({ server, client }, 2, function(e) return find(e, 1, "connect") and find(e, 2, "connect") end)
    local sp = find(ev, 1, "connect") and find(ev, 1, "connect").peer
    check("cookie handshake connects both sides", sp and find(ev, 2, "connect"))
    if not sp then return 1 end

    peer:send({ hello = "world" })
    ev = pump({ server, client }, 1, function(e) return find(e, 1, "receive") end)
    check("data flows", find(ev, 1, "receive") and find(ev, 1, "receive").data.hello == "world")

    -- an outsider: raw packets with a guessed token / nonce must not do anything
    local evil = socket.udp()
    evil:setsockname("127.0.0.1", 0)
    evil:settimeout(0)
    local function evilSend(pkt) evil:sendto(pkt, "127.0.0.1", 24990) end
    for _ = 1, 3 do evilSend("WS" .. string.char(6) .. string.rep("\1", 8)) end                  -- DISCONNECT, wrong token
    evilSend("WS" .. string.char(6) .. string.rep("\0", 8))
    evilSend("WS" .. string.char(1) .. string.rep("\2", 8) .. string.rep("\0", 60))              -- CONNECT, no cookie
    evilSend("WS" .. string.char(1) .. string.rep("\2", 8) .. string.rep("\7", 16) .. string.rep("\0", 40))  -- bad cookie
    ev = pump({ server, client }, 0.5)
    local peers = 0
    for _ in pairs(server.peers) do peers = peers + 1 end
    check("forged DISCONNECT / bad cookie are ignored", sp.state == "connected" and peers == 1 and not find(ev, 1, "disconnect"))

    -- amplification guard: short CONNECT gets no answer, full one gets a short CHALLENGE
    while evil:receive() do end   -- drop the CHALLENGEs answering the forged CONNECTs above
    evilSend("WS" .. string.char(1) .. string.rep("\3", 8))
    ev = pump({ server, client }, 0.3)
    local reply = evil:receive()
    check("short CONNECT is not answered", reply == nil)
    evilSend("WS" .. string.char(1) .. string.rep("\3", 8) .. string.rep("\0", 60))
    pump({ server, client }, 0.3)
    local r = evil:receive()
    check("CONNECT without cookie only yields a smaller CHALLENGE", r ~= nil and #r < 64 and r:byte(3) == 7)

    -- roaming: the client's source port changes; the session must follow, and the data keeps flowing
    for _, s in pairs(client.socks) do s:close() end
    client.socks = {}
    local fresh = socket.udp()
    fresh:setsockname("0.0.0.0", 0)
    fresh:settimeout(0)
    client.socks.v4 = fresh
    local oldPort = sp.port
    peer:send({ after = "roam" })
    ev = pump({ server, client }, 2, function(e) return find(e, 1, "receive") end)
    check("session survives a source port change", find(ev, 1, "receive") and find(ev, 1, "receive").data.after == "roam"
        and sp.port ~= oldPort and sp.state == "connected")
    sp:send({ back = "to client" })
    ev = pump({ server, client }, 2, function(e) return find(e, 2, "receive") end)
    check("host reaches the client on its new address", find(ev, 2, "receive") ~= nil)

    -- a short outage: nothing is exchanged for a few seconds, then it resumes
    pump({}, 3)
    peer:send({ again = 1 })
    ev = pump({ server, client }, 2, function(e) return find(e, 1, "receive") end)
    check("session survives a short outage", find(ev, 1, "receive") ~= nil)

    -- chat beside the lockstep turns: the client's message goes through the host to the listed sides only
    local lockstep = require("src.game.lockstep")
    local hs = lockstep.host(server, { sides = { 0, 1, 2 }, localSide = 0, peers = { [1] = sp } })
    local cs = lockstep.client(client, { sides = { 0, 1, 2 }, localSide = 1, server = peer })
    cs:chat("hello team", { 0 })
    hs:chat("to the client only", { 1 })
    local t0 = love.timer.getTime()
    while love.timer.getTime() - t0 < 2 and not (#hs.chatInbox >= 2 and #cs.chatInbox >= 2) do
        hs:pump()
        cs:pump()
        love.timer.sleep(0.005)
    end
    check("chat from a client reaches the host and the sender", #hs.chatInbox == 2 and hs.chatInbox[2].text == "hello team"
        and hs.chatInbox[2].side == 1 and #cs.chatInbox == 2)
    check("chat respects the recipient list", cs.chatInbox[1].text:find("^hello") ~= nil or cs.chatInbox[2].text:find("^hello") ~= nil)

    server:close()
    client:close()

    require("src.tools.lobbytest").run(check)
    print(fails == 0 and "all network tests passed" or (fails .. " network test(s) failed"))
    return fails == 0 and 0 or 1
end

return M
