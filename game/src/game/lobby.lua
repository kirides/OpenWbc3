-- Client of the openwbc3 lobby server (docs/lobby.md, server/lobby/): hosts publish their game, players list the
-- published games, join one (hole punching through an introduction) and fall back to a relay. Runs on the game's own
-- UDP host (udp.lua), so the server sees the NAT mapping the game itself uses; it takes the datagrams that start
-- with "OWL" from the lobby server off the host (host.onRaw) and is driven by the host's service loop (host.onTick),
-- so a published game keeps its listing and its relays alive during the battle too.
--   local c = lobby.client(host, "lobby.example.org")      -- host: a udp.host
--   c:publish(info)  c:unpublish()                           -- host side; c.gameId once registered
--   c:list(page, version)  c.games / c.pageCount             -- player side, refreshed while listing
--   c:join(gameId, onJoined)  c:requestRelay(gameId, onRelay)
-- Wire format: an 8-byte header ("OWL", type, u32 version), little-endian integers, 18-byte addresses (IPv6 or
-- IPv4-mapped, port), u8-length strings, u8-count address lists.
local udp = require("src.game.udp")
local log = require("src.core.log")
local bit = require("bit")

local M = {}

M.DEFAULT_PORT = 24860
M.VERSION = 1
M.FLAG_PASSWORD, M.FLAG_PRIVATE, M.FLAG_STARTED, M.FLAG_RELAY = 1, 2, 4, 8
M.STATUS_OK, M.STATUS_NO_GAME, M.STATUS_NOT_JOINABLE, M.STATUS_NO_RELAY = 0, 1, 2, 3

local RETRY = 1.0           -- seconds before a request without an answer is sent again
local LIST_EVERY = 2.0      -- the list is refreshed this often while it is shown
local MAX_STRING, MAX_ADDRS = 48, 4
local PUNCH_TIMES = { 0, 0.1, 0.3, 0.7 }   -- seconds after an introduction the host sends a punch datagram

-- Encoding ---------------------------------------------------------------------------------------------------------

local char, byte = string.char, string.byte

local function u8(n) return char(n % 256) end
local function u16(n) return char(n % 256, math.floor(n / 256) % 256) end
local function u32(n) return char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end

local function str(s)
    s = s or ""
    if #s > MAX_STRING then
        s = s:sub(1, MAX_STRING)
        while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, -2) end   -- no cut UTF-8 sequence
        if #s > 0 and s:byte(#s) >= 0xC0 then s = s:sub(1, -2) end
    end
    return char(#s) .. s
end

-- "1.2.3.4" / "2001:db8::1" -> 16 bytes (IPv4 as ::ffff:a.b.c.d); nil for anything else
local function ipBytes(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a then
        local o = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) } --[[@as integer[] ]]
        for i = 1, 4 do if o[i] > 255 then return nil end end
        return string.rep("\0", 10) .. "\255\255" .. char(o[1], o[2], o[3], o[4])
    end
    if not ip:find(":", 1, true) then return nil end
    ip = ip:gsub("%%.*$", "")                                    -- zone index
    local head, tail = ip:match("^(.-)::(.*)$")
    local function groups(s)
        local out = {}
        for g in s:gmatch("[^:]+") do out[#out + 1] = g end
        return out
    end
    local h, t = groups(head or ip), groups(tail or "")
    if #h + #t > 8 then return nil end
    local all = {}
    for _, g in ipairs(h) do all[#all + 1] = g end
    if head then for _ = 1, 8 - #h - #t do all[#all + 1] = "0" end end
    for _, g in ipairs(t) do all[#all + 1] = g end
    if #all ~= 8 then return nil end
    local out = {}
    for i, g in ipairs(all) do
        local n = tonumber(g, 16)
        if not n or n > 0xffff then return nil end
        out[i] = char(math.floor(n / 256), n % 256)
    end
    return table.concat(out)
end

local function addr(a)
    local b = a and ipBytes(a.ip)
    if not b then return string.rep("\0", 18) end
    return b .. u16(a.port)
end

local function addrs(list)
    local out = {}
    for i = 1, math.min(#list, MAX_ADDRS) do out[i] = addr(list[i]) end
    return char(#out) .. table.concat(out)
end

local function header(kind) return "OWL" .. kind .. u32(M.VERSION) end

-- A reader over a message; any read past the end sets `bad` and returns zeros / empty strings.
local Reader = {}
Reader.__index = Reader
local function reader(s, pos) return setmetatable({ s = s, pos = pos, bad = false }, Reader) end
function Reader:take(n)
    if self.pos + n - 1 > #self.s then self.bad = true; return string.rep("\0", n) end
    local v = self.s:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return v
end
function Reader:u8() return byte(self:take(1)) end
function Reader:u16() local a, b = byte(self:take(2), 1, 2); return a + b * 256 end
function Reader:u32() local a, b, c, d = byte(self:take(4), 1, 4); return a + b * 256 + c * 65536 + d * 16777216 end
function Reader:str()
    local n = self:u8()
    if n > MAX_STRING then self.bad = true; return "" end
    return (self:take(n):gsub("[%z\1-\31\127]", "?"))
end
function Reader:addr()
    local b = self:take(18)
    if b == string.rep("\0", 18) then return nil end
    local port = byte(b, 17) + byte(b, 18) * 256
    if b:sub(1, 12) == string.rep("\0", 10) .. "\255\255" then
        return { ip = ("%d.%d.%d.%d"):format(byte(b, 13, 16)), port = port }
    end
    local g = {}
    for i = 0, 7 do g[#g + 1] = ("%x"):format(byte(b, 1 + 2 * i) * 256 + byte(b, 2 + 2 * i)) end
    return { ip = table.concat(g, ":"), port = port }
end
function Reader:addrs()
    local n, out = self:u8(), {}
    if n > MAX_ADDRS then self.bad = true; return out end
    for _ = 1, n do out[#out + 1] = self:addr() end
    return out
end

M.ipBytes = ipBytes     -- for the tests

-- Client -----------------------------------------------------------------------------------------------------------

---@class LobbyAddress
---@field ip string
---@field port integer

---@class LobbyGameInfo
---@field name string the game's name (UTF-8, at most 48 bytes are sent)
---@field map string the map's name
---@field players integer
---@field maxPlayers integer
---@field version integer the game's network protocol version (net.VERSION)
---@field content string? the content hash (hex or raw); the first 8 bytes are published
---@field password boolean? the host asks for a password
---@field unlisted boolean? not listed: players join with the game id
---@field started boolean? in battle: listed, not joinable
---@field relay boolean? the host accepts relayed players (default true)

---@class LobbyGame: LobbyGameInfo
---@field id integer the game id (also the join code of a private game)
---@field age integer seconds since the game was published

---@class LobbyJoin
---@field status integer M.STATUS_*
---@field flags integer
---@field candidates LobbyAddress[] the host's public addresses first, then its LAN addresses

---@class LobbyClient
---@field host UdpHost the game's UDP endpoint the client runs on
---@field server LobbyAddress[] the lobby server's addresses (A and AAAA)
---@field cookie table<string, string> cookie per server address family ("v4" / "v6")
---@field pending table<integer, table> requests waiting for an answer, by nonce
---@field gameId integer? host: the id of the published game
---@field observed LobbyAddress? host: its public address as the server sees it
---@field games LobbyGame[] player: the games of the last listed page
---@field pageCount integer player: pages of the last list
---@field relays table<string, boolean> relay sessions (hex) this host or player uses
---@field onIntroduce fun(player: LobbyAddress, lan: LobbyAddress[])? host: a player is about to connect
---@field error string? the last problem (cannot resolve the server ...)
---@field t number the host clock at the last update
---@field key string? host: the 16-byte secret that owns the published game
---@field publishing string? host: the REGISTER body while published
---@field nextRegister number host: when the next refresh is due
---@field refresh number? host: seconds between refreshes (from the server)
---@field listing {page: integer, version: integer}? player: the page being listed
---@field nextList number player: when the list is refreshed next
---@field punches {t: number, to: LobbyAddress}[] host: punch datagrams waiting for their time
---@field registerReq table? the REGISTER in flight
---@field listReq table? the LIST in flight
---@field joinReq table? the JOIN being repeated
---@field relayReq table? the RELAY in flight
---@field restore fun() gives the UDP host back the handlers it had before this client
local Client = {}
Client.__index = Client

local function family(ip) return ip:find(":", 1, true) and "v6" or "v4" end

local function randomNonce() return math.random(1, 0x7fffffff) end

-- Parses "host[:port]" / "[v6]:port"; returns name, port.
---@param text string
---@return string? name
---@return integer port
function M.parseServer(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil, M.DEFAULT_PORT end
    local v6, p = text:match("^%[(.+)%]:(%d+)$")
    if v6 then return v6, tonumber(p) --[[@as integer]] end
    v6 = text:match("^%[(.+)%]$")
    if v6 then return v6, M.DEFAULT_PORT end
    local name, port = text:match("^([^:]+):(%d+)$")
    if name then return name, tonumber(port) --[[@as integer]] end
    return text, M.DEFAULT_PORT
end

-- A lobby client on `host` for the server `text` ("name[:port]"). Resolving the name happens once, here (a short
-- blocking DNS query when the screen opens). Returns nil and a message when the server cannot be resolved.
---@param host UdpHost
---@param text string
---@return LobbyClient?
---@return string? err
function M.client(host, text)
    local name, port = M.parseServer(text)
    if not name then return nil, "no lobby server set ([net] lobby= in openwbc3.ini)" end
    local ips = udp.resolve(name)
    if not ips or #ips == 0 then return nil, "cannot resolve the lobby server " .. name end
    local c = setmetatable({ host = host, server = {}, cookie = {}, pending = {}, games = {}, pageCount = 0,
                             relays = {}, punches = {}, t = 0, publishing = nil, nextRegister = 0, listing = nil,
                             nextList = 0 }, Client)
    for _, ip in ipairs(ips) do
        -- only families the host has a socket for
        if host.socks[family(ip)] then c.server[#c.server + 1] = { ip = ip, port = port } end
    end
    if #c.server == 0 then return nil, "the lobby server is not reachable over this machine's networks" end
    local prevRaw, prevTick = host.onRaw, host.onTick
    host.onRaw = function(data, ip, p)
        if not c:handle(data, ip, p) and prevRaw then prevRaw(data, ip, p) end
    end
    host.onTick = function(t)
        c:update(t)
        if prevTick then prevTick(t) end
    end
    host.relay = function(ip, data) return c:sendData(ip, data) end
    c.restore = function() host.onRaw, host.onTick, host.relay = prevRaw, prevTick, nil end
    return c
end

function Client:isServer(ip, port)
    for _, s in ipairs(self.server) do
        if s.ip == ip and s.port == port then return true end
    end
    return false
end

-- Sends a request to every server address (both families: the host is registered in each it can reach). `build`
-- gets the request prefix (nonce + cookie of that family) and returns the message.
function Client:request(kind, body, onReply, opts)
    opts = opts or {}
    local nonce = randomNonce()
    local req = { kind = kind, body = body, onReply = onReply, nonce = nonce, sent = -1, keep = opts.keep,
                  once = opts.once }
    self.pending[nonce] = req
    self:send(req)
    return req
end

function Client:send(req)
    for _, s in ipairs(self.server) do
        local cookie = self.cookie[family(s.ip)] or string.rep("\0", 16)
        self.host:sendRaw(header(req.kind) .. u32(req.nonce) .. cookie .. req.body, s.ip, s.port)
    end
    req.sent = self.t
end

function Client:cancel(req)
    if req then self.pending[req.nonce] = nil end
end

-- Host side ------------------------------------------------------------------------------------------------------

local function contentBytes(content)
    content = content or ""
    if #content >= 16 and content:match("^%x+$") then
        local out = {}
        for i = 1, 16, 2 do out[#out + 1] = char(tonumber(content:sub(i, i + 1), 16)) end
        return table.concat(out)
    end
    return (content .. string.rep("\0", 8)):sub(1, 8)
end

-- The host's LAN candidates: its primary local addresses with the game port.
local function lanAddresses(host)
    local out, la = {}, udp.localAddresses()
    if la.v4 and host.socks.v4 then out[#out + 1] = { ip = la.v4, port = host.port } end
    if la.v6 and host.socks.v6 then out[#out + 1] = { ip = la.v6, port = host.port } end
    return out
end
M.lanAddresses = lanAddresses

-- Publishes the game (and refreshes it every few seconds until unpublish). Call again when the info changes.
---@param info LobbyGameInfo
function Client:publish(info)
    if not self.key then
        self.key = udp.randomBytes(16)
    end
    local flags = (info.password and M.FLAG_PASSWORD or 0) + (info.unlisted and M.FLAG_PRIVATE or 0)
        + (info.started and M.FLAG_STARTED or 0) + (info.relay ~= false and M.FLAG_RELAY or 0)
    self.publishing = self.key .. u16(flags) .. u16(info.version or 0) .. u8(info.players or 0) .. u8(info.maxPlayers or 0)
        .. contentBytes(info.content) .. str(info.name) .. str(info.map) .. addrs(lanAddresses(self.host))
    self.nextRegister = 0          -- now
end

function Client:unpublish()
    if self.publishing then
        self:request("U", self.key, nil, { once = true })
        self.publishing, self.gameId = nil, nil
    end
end

function Client:register()
    if self.registerReq then self:cancel(self.registerReq) end
    self.registerReq = self:request("R", self.publishing, function(r)
        self.gameId = r:u32()
        self.refresh = math.max(1, r:u32() / 1000)
        self.observed = r:addr()
        self.nextRegister = self.t + self.refresh
    end)
end

-- Player side ----------------------------------------------------------------------------------------------------

-- Shows `page` of the public games of `version` (0: all), refreshed every couple of seconds; nil stops listing.
---@param page integer?
---@param version integer?
function Client:list(page, version)
    if page == nil then self.listing = nil; return end
    self.listing = { page = page, version = version or 0 }
    self.nextList = 0
end

function Client:refreshList()
    local l = self.listing
    if not l then return end
    if self.listReq then self:cancel(self.listReq) end
    self.listReq = self:request("L", u16(l.page) .. u16(l.version), function(r)
        local page, count = r:u16(), r:u16()
        local n, games = r:u8(), {}
        for i = 1, n do
            local g = { id = r:u32() }
            local flags = r:u16()
            g.version, g.players, g.maxPlayers = r:u16(), r:u8(), r:u8()
            g.content = r:take(8)
            g.name, g.map, g.age = r:str(), r:str(), r:u32()
            g.password = bit.band(flags, M.FLAG_PASSWORD) ~= 0
            g.started = bit.band(flags, M.FLAG_STARTED) ~= 0
            g.relay = bit.band(flags, M.FLAG_RELAY) ~= 0
            games[i] = g
        end
        if not r.bad and self.listing and page == self.listing.page then self.games, self.pageCount = games, count end
    end)
end

-- Asks the lobby to introduce this player to game `id`; `onJoined(join)` gets the host's candidates. The request is
-- repeated every second until `stopJoining` (each repeat re-introduces us: a lost introduction is retried).
---@param id integer
---@param onJoined fun(join: LobbyJoin)
function Client:join(id, onJoined)
    self:stopJoining()
    local body = u32(id) .. addrs(lanAddresses(self.host))
    local answered = false
    self.joinReq = self:request("J", body, function(r)
        local j = { id = r:u32(), status = r:u8(), flags = r:u16(), candidates = {} }
        local h4, h6 = r:addr(), r:addr()
        for _, a in ipairs({ h4, h6 }) do j.candidates[#j.candidates + 1] = a end
        for _, a in ipairs(r:addrs()) do j.candidates[#j.candidates + 1] = a end
        if r.bad then return end
        if not answered or j.status ~= M.STATUS_OK then
            answered = true
            onJoined(j)
        end
    end, { keep = true })
end

function Client:stopJoining()
    self:cancel(self.joinReq)
    self.joinReq = nil
end

-- Asks for a relay to game `id`; `onRelay(address)` gets the relay pseudo-address ("relay:<session>") to connect
-- to, or nil and a status when the lobby refuses.
---@param id integer
---@param onRelay fun(address: string?, status: integer)
function Client:requestRelay(id, onRelay)
    self:cancel(self.relayReq)
    self.relayReq = self:request("Y", u32(id), function(r)
        local status, session = r:u8(), r:take(8)
        if r.bad then return end
        if status ~= M.STATUS_OK then onRelay(nil, status); return end
        local key = M.relayAddress(session)
        self.relays[key] = true
        onRelay(key, status)
    end)
end

-- "relay:<16 hex digits>" for a session id (8 bytes, little endian on the wire, kept as bytes here).
function M.relayAddress(session)
    return "relay:" .. (session:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end

local function sessionBytes(address)
    local hexs = address:match("^relay:(%x+)$")
    if not hexs or #hexs ~= 16 then return nil end
    return (hexs:gsub("%x%x", function(h) return char(tonumber(h, 16)) end))
end

-- Wraps a game datagram for a relayed peer (udp.lua calls this through host.relay).
function Client:sendData(address, data)
    local session = sessionBytes(address)
    if not session or not self.relays[address] then return false end
    local frame = header("D") .. session .. data
    for _, s in ipairs(self.server) do
        self.host:sendRaw(frame, s.ip, s.port)
        break                                   -- the first server address: the session is bound to it
    end
    return true
end

-- Incoming ----------------------------------------------------------------------------------------------------------

-- Takes a datagram off the host when it belongs to the lobby protocol; returns true when it was consumed.
function Client:handle(data, ip, port)
    if #data < 8 or data:sub(1, 3) ~= "OWL" then return false end
    if not self:isServer(ip, port) then
        return data:byte(4) == 80             -- a peer's punch ('P'): it opened the NAT, nothing to do
    end
    local kind = data:sub(4, 4)
    local r = reader(data, 9)
    if kind == "D" then
        local session = r:take(8)
        local key = M.relayAddress(session)
        if not r.bad and self.relays[key] then self.host:handle(data:sub(17), key, 0) end
        return true
    end
    if kind == "I" then
        local id, player, lan = r:u32(), r:addr(), r:addrs()
        if not r.bad and id == self.gameId and player then self:punch(player, lan) end
        return true
    end
    if kind == "V" then
        local id, session = r:u32(), r:take(8)
        if not r.bad and id == self.gameId then
            local key = M.relayAddress(session)
            if not self.relays[key] then log.info("lobby: a player comes through the relay (%s)", key) end
            self.relays[key] = true
        end
        return true
    end
    local nonce = r:u32()
    local req = self.pending[nonce]
    if not req then return true end
    if kind == "C" then
        self.cookie[family(ip)] = r:take(16)
        self:send(req)
        return true
    end
    if not req.keep then self.pending[nonce] = nil end
    if req.onReply then req.onReply(r) end
    return true
end

-- Host: punch datagrams to the player's public and LAN addresses, a few times over the next second.
function Client:punch(player, lan)
    local targets = { player }
    for _, a in ipairs(lan) do targets[#targets + 1] = a end
    if self.onIntroduce then self.onIntroduce(player, lan) end
    for _, at in ipairs(PUNCH_TIMES) do
        for _, a in ipairs(targets) do self.punches[#self.punches + 1] = { t = self.t + at, to = a } end
    end
end

---@param t number the host's clock (seconds)
function Client:update(t)
    self.t = t
    if self.publishing and t >= self.nextRegister then
        self.nextRegister = t + (self.refresh or 5)
        self:register()
    end
    if self.listing and t >= self.nextList then
        self.nextList = t + LIST_EVERY
        self:refreshList()
    end
    for _, req in pairs(self.pending) do
        if t - req.sent >= RETRY then
            if req.once then self.pending[req.nonce] = nil else self:send(req) end
        end
    end
    local keep = {}
    for _, p in ipairs(self.punches) do
        if t >= p.t then self.host:sendRaw(header("P"), p.to.ip, p.to.port) else keep[#keep + 1] = p end
    end
    self.punches = keep
end

-- Stops everything and gives the host back its own handlers.
function Client:close()
    self:unpublish()
    self.pending, self.listing, self.punches = {}, nil, {}
    self.restore()
end

return M
