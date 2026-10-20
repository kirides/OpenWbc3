-- Deterministic lockstep for network games. The simulation advances in fixed ticks (30 per
-- second); every TURN_TICKS ticks form a turn. All players send the commands they give during a
-- turn to the host, which collects them and sends back one package per turn with every player's
-- commands; all peers apply the same package at the start of the same turn. Commands are delayed
-- by DELAY turns so that the network has time to deliver them.
--
--   local ls = lockstep.host(udpHost, { sides = {0,1,2}, local = 0, seed = 123 })   -- or lockstep.client(...)
--   ls:submit(cmd)                         -- a command of the local player (gets side set by the caller)
--   ls:update(dt, applyFn, tickFn, hashFn) -- runs as many ticks as time and packages allow
local log = require("src.core.log")

local M = { TICK = 1 / 30, TURN_TICKS = 3, DELAY = 2, HASH_EVERY = 40 }

-- A lockstep session of a network game (host or client).
---@class Session
---@field role "host"|"client"
---@field host UdpHost?             the udp host (udp.lua)
---@field localSide integer
---@field sides integer[]           the sides played by humans
---@field seed integer
---@field tick integer              ticks run so far
---@field acc number                time not yet run (s)
---@field sentTurn integer          the last turn whose commands were sent
---@field outbox Command[]          local commands of the current turn
---@field inputs table<integer, table<integer, Command[]>> host: turn -> side -> commands
---@field pkgs table<integer, table> turn -> package of every player's commands
---@field dropped table<integer, boolean> sides that left
---@field pendingDrops integer[]?   host: drops for the next package
---@field peers table<integer, table> host: side -> udp peer
---@field server table?             client: the host's udp peer
---@field assembled integer         host: the last turn packaged
---@field hashes table<integer, integer> turn -> own checksum
---@field peerHashes table<integer, table<integer, integer>> host: turn -> side -> reported checksum
---@field stalled boolean           waiting for a package
---@field stallTime number
---@field desync string|false       what went out of sync
---@field lastHeard table<integer, number> host: side -> time of the last message
---@field names table<integer, string> player names by side
---@field chatInbox {side: integer, text: string}[]
---@field hostSide integer?
---@field netStats table<integer, {[1]: number, [2]: number}>? side -> { ping, reliability }
---@field statsAt number?
---@field lost boolean?             client: the host is gone
local Session = {}
Session.__index = Session

-- Common state. peers: host: side -> udp peer; client: .server = the host's udp peer.
---@param role "host"|"client"
---@param udpHost UdpHost?
---@param cfg {localSide: integer, sides: integer[], seed: integer?, peers: table<integer, table>?, server: table?, names: table<integer, string>?, hostSide: integer?}
---@return Session
local function new(role, udpHost, cfg)
    ---@type Session
    local s = setmetatable({
        role = role, host = udpHost, localSide = cfg.localSide, sides = cfg.sides, seed = cfg.seed or 1,
        tick = 0, acc = 0, sentTurn = M.DELAY - 1,
        outbox = {}, inputs = {}, pkgs = {}, dropped = {}, peers = cfg.peers or {}, server = cfg.server,
        assembled = -1, hashes = {}, stalled = false, stallTime = 0, desync = false, lastHeard = {},
        names = cfg.names or {}, peerHashes = {}, chatInbox = {}, hostSide = cfg.hostSide,
    }, Session)
    for side, peer in pairs(s.peers) do peer.side = side end
    -- the first turns have no commands
    for turn = 0, M.DELAY - 1 do
        s.inputs[turn] = {}
        for _, side in ipairs(s.sides) do s.inputs[turn][side] = {} end
    end
    return s
end

---@param udpHost UdpHost?
---@return Session
function M.host(udpHost, cfg) return new("host", udpHost, cfg) end
---@param udpHost UdpHost?
---@return Session
function M.client(udpHost, cfg) return new("client", udpHost, cfg) end

-- The udp peer this machine talks to for `side`: the host knows every client, a client only the host (side 0 in
-- openwbc3's lobby, which always seats the host there).
function Session:peerOf(side)
    if self.role == "host" then return self.peers[side] end
    if side == (self.hostSide or 0) then return self.server end
    return nil
end

-- Link figures for the network statistics dialog. Not part of the simulation (they bypass the turns and nothing in
-- the world reads them, so they cannot change world:hash or the lockstep). The host measures every client and, once a
-- second, sends the table { [side] = { ping, reliability } } to all of them (the host itself is a perfect link), so
-- every machine can show every player. A client keeps the table in `netStats`.
M.STATS_EVERY = 1

function Session:sendStats()
    local t = {}
    for _, side in ipairs(self.sides) do
        local peer = self.peers[side]
        if side == self.localSide then t[side] = { 0, 100 }
        elseif peer and not self.dropped[side] then
            local ping, rel = peer:stats()
            t[side] = { ping, rel }
        end
    end
    self.netStats = t
    for side, peer in pairs(self.peers) do
        if not self.dropped[side] then peer:send({ t = "netstats", stats = t }) end
    end
end

-- { ping, reliability } of `side` as known on this machine: the host's table (own measurements on the host, the
-- relayed ones on a client); before the first table arrives a client only knows its own link to the host.
function Session:statsOf(side)
    if side == self.localSide and self.role == "host" then return 0, 100 end
    local e = self.netStats and self.netStats[side]
    if e then return e[1], e[2] end
    local peer = self:peerOf(side)
    if side == self.localSide then peer = self.server end        -- a client's own link is its link to the host
    if peer and not self.dropped[side] then return peer:stats() end
    return nil
end

---@param cmd Command
function Session:submit(cmd)
    self.outbox[#self.outbox + 1] = cmd
end

-- Chat messages (not part of the simulation, so they bypass the turns): a client sends "chat" to the host, the host
-- forwards it to the listed sides (the sender is always among them, as in the original) and hands it to its own
-- inbox if it is listed. `sides` is a list of side numbers chosen by the sender (everybody, allies or enemies).
local CHAT_LENGTH = 79          -- the original's chat line less its terminator (not traced in the 1.04 binary yet)

function Session:relayChat(from, text, sides)
    text = tostring(text or ""):sub(1, CHAT_LENGTH)
    if text == "" then return end
    local want = {}
    for _, side in ipairs(sides or {}) do want[side] = true end
    want[from] = true
    for side, peer in pairs(self.peers) do
        if want[side] and not self.dropped[side] then peer:send({ t = "chat", side = from, text = text }) end
    end
    if want[self.localSide] then self.chatInbox[#self.chatInbox + 1] = { side = from, text = text } end
end

function Session:chat(text, sides)
    if self.role == "host" then self:relayChat(self.localSide, text, sides)
    else self.server:send({ t = "chat", text = text, sides = sides }) end
end

function Session:activeSides()
    local out = {}
    for _, side in ipairs(self.sides) do
        if not self.dropped[side] then out[#out + 1] = side end
    end
    return out
end

-- Host: builds the package of every turn whose inputs have all arrived.
function Session:assemble()
    while true do
        local turn = self.assembled + 1
        local ins = self.inputs[turn]
        if not ins then return end
        local cmds = {}
        for _, side in ipairs(self.sides) do
            if not self.dropped[side] then
                if not ins[side] then return end
                for _, c in ipairs(ins[side]) do cmds[#cmds + 1] = c end
            end
        end
        local pkg = { t = "pkg", turn = turn, cmds = cmds, drops = self.pendingDrops }
        self.pendingDrops = nil
        self.assembled = turn
        self.inputs[turn] = nil
        self.pkgs[turn] = pkg
        for side, peer in pairs(self.peers) do
            if not self.dropped[side] then peer:send(pkg) end
        end
    end
end

function Session:dropSide(side, reason)
    if self.dropped[side] or side == self.localSide then return end
    self.dropped[side] = true
    self.pendingDrops = self.pendingDrops or {}
    self.pendingDrops[#self.pendingDrops + 1] = side
    log.info("lockstep: side %d dropped (%s)", side, tostring(reason))
    self:assemble()
end

-- What a client may send: commands for a turn a little ahead of the last one the host packaged (DELAY turns in
-- normal play; the window is generous for a slow host), at most MAX_COMMANDS of them. Anything else is dropped, so
-- a broken or hostile peer cannot grow the host's tables without bound.
local MAX_AHEAD, MAX_COMMANDS = 64, 256
---@param turn any
---@param assembled integer
---@return boolean
local function validTurn(turn, assembled)
    return type(turn) == "number" and turn == math.floor(turn) and turn > assembled and turn <= assembled + MAX_AHEAD
end

-- Receives network traffic.
function Session:pump()
    for _, e in ipairs(self.host:service()) do
        local peer = e.peer
        if e.type == "receive" then
            local m = e.data
            if self.role == "host" then
                local side = peer.side
                if side and m.t == "chat" and not self.dropped[side] then
                    self:relayChat(side, m.text, m.sides)
                elseif side and m.t == "in" and not self.dropped[side] and validTurn(m.turn, self.assembled) then
                    self.lastHeard[side] = love.timer.getTime()
                    local cmds = {}
                    for _, c in ipairs(type(m.cmds) == "table" and m.cmds or {}) do
                        if #cmds >= MAX_COMMANDS then break end
                        if type(c) == "table" then
                            c.side = side                -- players can only command their own side
                            cmds[#cmds + 1] = c
                        end
                    end
                    self.inputs[m.turn] = self.inputs[m.turn] or {}
                    self.inputs[m.turn][side] = cmds
                    if m.hash and type(m.hashTurn) == "number" and m.hashTurn <= self.assembled + MAX_AHEAD
                        and m.hashTurn > self.assembled - 4 * M.HASH_EVERY then
                        self.peerHashes[m.hashTurn] = self.peerHashes[m.hashTurn] or {}
                        self.peerHashes[m.hashTurn][side] = m.hash
                    end
                end
            else
                if m.t == "chat" then self.chatInbox[#self.chatInbox + 1] = { side = m.side, text = tostring(m.text or ""):sub(1, CHAT_LENGTH) }
                elseif m.t == "pkg" then self.pkgs[m.turn] = m
                elseif m.t == "desync" then self.desync = m.info
                elseif m.t == "netstats" and type(m.stats) == "table" then self.netStats = m.stats end
            end
        elseif e.type == "disconnect" then
            if self.role == "host" and peer.side then self:dropSide(peer.side, e.reason)
            elseif self.role == "client" and peer == self.server then
                self.lost = true
            end
        end
    end
    if self.role == "host" then
        -- a player that stays silent for too long is dropped
        local now = love.timer.getTime()
        for _, side in ipairs(self.sides) do
            if side ~= self.localSide and not self.dropped[side] then
                self.lastHeard[side] = self.lastHeard[side] or now
                if now - self.lastHeard[side] > 20 then self:dropSide(side, "silent") end
            end
        end
        self:assemble()
        self:checkHashes()
        if not self.statsAt or now - self.statsAt >= M.STATS_EVERY then
            self.statsAt = now
            self:sendStats()
        end
    end
end

-- Compares the checksums the players reported with the host's.
function Session:checkHashes()
    for turn, bySide in pairs(self.peerHashes) do
        local mine = self.hashes[turn]
        if mine then
            for side, h in pairs(bySide) do
                if h ~= mine and not self.desync then
                    self.desync = ("side %d out of sync at turn %d"):format(side, turn)
                    for _, p in pairs(self.peers) do p:send({ t = "desync", info = self.desync }) end
                end
            end
            self.peerHashes[turn] = nil
            if turn < self.tick / M.TURN_TICKS - 400 then self.hashes[turn] = nil end
        end
    end
end

-- Sends our commands for turn `turn`.
function Session:flush(turn, hashTurn, hash)
    local cmds = self.outbox
    self.outbox = {}
    if self.role == "host" then
        self.inputs[turn] = self.inputs[turn] or {}
        self.inputs[turn][self.localSide] = cmds
        for _, c in ipairs(cmds) do c.side = self.localSide end
        if hash then self.hashes[hashTurn] = hash end
    else
        self.server:send({ t = "in", turn = turn, cmds = cmds, hash = hash, hashTurn = hashTurn })
    end
end

-- Runs the simulation. applyFn(cmd) applies a command, dropFn(side) hands a dropped player to the
-- computer, tickFn(tick) advances the world by one tick, hashFn() returns a state checksum.
---@param dt number
---@param applyFn fun(cmd: Command)
---@param tickFn fun(tick: integer)
---@param hashFn fun(): integer
---@param dropFn fun(side: integer)?
function Session:update(dt, applyFn, tickFn, hashFn, dropFn)
    self:pump()
    self.acc = math.min(self.acc + dt, 0.5)
    local ran = false
    while self.acc >= M.TICK do
        local turn = math.floor(self.tick / M.TURN_TICKS)
        -- keep the pipeline of inputs full even while waiting
        while self.sentTurn < turn + M.DELAY do
            self.sentTurn = self.sentTurn + 1
            local hash, hashTurn
            if self.sentTurn % M.HASH_EVERY == 0 then
                hash, hashTurn = hashFn(), turn
            end
            self:flush(self.sentTurn, hashTurn, hash)
        end
        if self.tick % M.TURN_TICKS == 0 then
            local pkg = self.pkgs[turn]
            if not pkg then
                self.stalled = true
                break
            end
            self.pkgs[turn] = nil
            self.stalled = false
            for _, side in ipairs(pkg.drops or {}) do
                self.dropped[side] = true
                if dropFn then dropFn(side) end
            end
            for _, cmd in ipairs(pkg.cmds) do applyFn(cmd) end
        end
        tickFn(self.tick)
        self.tick = self.tick + 1
        self.acc = self.acc - M.TICK
        ran = true
    end
    if ran then self.stallTime = 0 elseif self.stalled then self.stallTime = self.stallTime + dt end
    self:pump()
end

function Session:close()
    for _, p in pairs(self.peers) do p:disconnect() end
    if self.server then self.server:disconnect() end
end

return M
