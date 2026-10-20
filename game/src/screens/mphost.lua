-- The lobby of a hosted network game: the skirmish setup with human players. Players join over
-- UDP (IPv4 / IPv6); the host picks the map and options and starts the game.
--
-- The lobby follows the original's side selection protocol (set-up screen FUN_004e47e0, side panels FUN_004eb4d0, message
-- dispatcher FUN_0049eb60; the handlers were checked in the 1.04 binary, see docs/implemented.md "Network lobby: seats,
-- ready, maps"), carried by openwbc3's own UDP messages (src/game/net.lua VERSION 2):
--   * seats: every seat of a new map is Open; a player asks for one ("seat") and the host grants it if it is still open
--     (FUN_004f3210), gives it up again ("unseat") and changes the resources / team of his own seat
--     ("side"); the host sets computer levels, Open and Closed;
--   * ready: every human seat has a ready box ("ready"); the host's Start button only works when the start check
--     FUN_004eacd0 holds; every change the host makes unreadies everybody (FUN_004eaaf0) and tells
--     the players who were ready in the chat ("* Host changed the options *");
--   * a player picks the race of his own seat ("side" with field "race"), the host can remove a player ("booted"), and after
--     the game everybody is on the main menu (see docs/implemented.md "Boot, own race, after the game");
--   * maps: a new map is announced ("mapinform"), the players answer whether they have it ("hasmap"); if all do the host
--     changes the map at once ("mapchange" / "mapok" / "mapfinished"), else the Send Map button gets active; players
--     lacking the map are asked whether to download it and get it in pieces ("mapreq" / "mapdata"); a player joining
--     during a change waits ("hold"), the others are told that somebody is joining ("joinlock").
local screens = require("src.core.screens")
local skirmish = require("src.screens.skirmish")
local net = require("src.game.net")
local lobby = require("src.game.lobby")
local classes = require("src.game.classes")
local content = require("src.content")
local lockstep = require("src.game.lockstep")
local serialize = require("src.core.serialize")
local config = require("src.core.config")
local profile = require("src.game.profile")
local log = require("src.core.log")
local strings = require("src.game.strings")
local msgbox = require("src.ui.msgbox")
local mapxfer = require("src.game.mapxfer")
local UI = require("src.ui.interface")

-- The map synchronisation of the lobby (MAPCHANGE_INFORM .. mapfinished).
---@class MapSync
---@field seq integer
---@field stage "check"|"change"|"done"
---@field has table<integer, boolean>        slot -> whether he has the map (the answers of the check)
---@field never boolean                       somebody lacks the map: Send Map is active
---@field info table                          the map's details (S:mapDetails)
---@field informed table<integer, boolean>    the slots that were asked
---@field ready table<integer, boolean>?      change: the slots that answered
---@field requested table<integer, boolean>?  change: the slots that asked for the map's pieces
---@field waitFor table<integer, boolean>?    change: the slots that were told

-- A seated player of the lobby (S:seated).
---@class SeatedPlayer
---@field side integer
---@field slot integer
---@field p LobbyPlayer

-- The host's lobby inherits the skirmish setup (the metatable falls back to skirmish.lua) and overrides some of its
-- methods; the class says so (without it the language server takes S for the skirmish table itself and reports every
-- override as a duplicate field).
---@class MpHostScreen: SkirmishScreen
---@field players table<integer, LobbyPlayer>
---@field held { peer: table, m: table }[]    players that wait until the host is no longer busy
---@field joining table<integer, number>      slot -> when he joined (until he has the map)
---@field error string?                       the network port could not be opened
---@field udp table?                          the UDP host (game/net.lua)
---@field announcer table                     the LAN announcement (net.announcer)
---@field lobby LobbyClient?                  the internet lobby client while the game is published (lobby.lua)
---@field hostOpts {publish: boolean?, unlisted: boolean?, password: string?, lobby: string?} what the host chose
---@field lastPublish string?                 the published info last sent (to send again only on a change)
---@field announcedCode boolean?              the join code was posted in the chat
---@field pending table
---@field lastState string?                   the last lobby state sent (serialised)
---@field lastBroadcast number
---@field sync MapSync?
---@field mapSeq integer?
---@field syncedMap SkirmishMap?              the map the seats were set up for
---@field snap table?                         the last snapshot of the setup (S:checkChanges)
---@field tourney { scn: table, opts: table, waiting: table<integer, integer>, heroes: table<integer, table> }?
---@field tourneyHeroes table<integer, table>?   Tournament mode: the temporary heroes by side
---@field setup { scn: table, opts: table, armies: table<integer, table>, waiting: table<integer, integer>, hostSide: integer? }?
---@field autoStart boolean?                  --show mphost:auto
---@field devArmy boolean?
local S = setmetatable({}, { __index = skirmish })
S.helpId = 11          -- screen help (src/screens/screenhelp.lua)
S.__index = S
S.multiplayer = true           -- the victory selector offers Capture the Flag only here

local function gs(id, fallback) return strings.get("Game.txt", ("%04d"):format(id)) or fallback end

---@param hero table? the hero record that plays
---@param opts {publish: boolean?, unlisted: boolean?, password: string?, lobby: string?}? hosting options
function S:enter(hero, opts)
    self.hostOpts = opts or {}
    self.hero = hero or profile.current()
    self.players = { [0] = { name = self.hero.name, race = self.hero.race, hero = self.hero.hero, ready = false } }
    self.held, self.joining = {}, {}
    skirmish.enter(self)
    self.title = "Multiplayer - Host"
    self.hero = hero or profile.current()
    self.opt.quests = false              -- shrines and shops only exist in single player games
    local port = net.PORT
    local host
    for p = port, port + 9 do
        host = net.host(p)
        if host then break end
    end
    if not host then
        self.error = "Cannot open the network port"
        return
    end
    self.udp = host
    self.announcer = net.announcer(host)
    self.pending = {}
    self.lastState = nil
    self.lastBroadcast = 0
    -- the chat area starts with the host's address (Game.txt 0238, as the set-up opener FUN_004e47e0 does)
    local a = net.localAddresses()
    local ip = a.v4 or a.v6
    if ip then self:addChat((strings.get("Game.txt", "0238") or "Game started... IP Address is %s"):format(ip)) end
    if self.hostOpts.publish then
        local client, err = lobby.client(host, self.hostOpts.lobby or config.get("net", "lobby", ""))
        if client then self.lobby = client else self:addChat("Internet: " .. tostring(err)) end
    end
    self:beginMapSync()
end

-- Publishes the game on the lobby server (again when something players see in the list changed).
---@param started boolean? the battle has begun (listed, not joinable)
function S:publish(started)
    if not self.lobby then return end
    local info = { name = self.hero.name .. "'s game", map = self.map and self.map.label or "?", players = self:count(),
                   maxPlayers = math.min(6, self:usedSides()), version = net.VERSION, started = started,
                   content = require("src.content.mods").describe(require("src.content")).hash,
                   password = (self.hostOpts.password or "") ~= "", unlisted = self.hostOpts.unlisted }
    local key = serialize.encode(info)
    if key == self.lastPublish then return end
    self.lastPublish = key
    self.lobby:publish(info)
end

-- Players ---------------------------------------------------------------------------------------------------------

-- The lobby slots in use, ascending (the host is 0; a leaving player leaves a hole that the next one fills).
function S:slots()
    local out = {}
    for slot in pairs(self.players) do out[#out + 1] = slot end
    table.sort(out)
    return out
end

function S:count()
    local n = 0
    for _ in pairs(self.players) do n = n + 1 end
    return n
end

function S:usedSides()
    local n = 0
    for _ in pairs(self.sides) do n = n + 1 end
    return n
end

-- The side the player of `slot` sits on.
---@param slot integer
---@return integer?
function S:seatOf(slot)
    for i = 0, 5 do
        local sd = self.sides[i]
        if sd and sd.player == slot then return i end
    end
end

-- The players that sit on a seat, by side: { { side, slot, p } ... }.
---@return SeatedPlayer[]
function S:seated()
    local out = {}
    for i = 0, 5 do
        local sd = self.sides[i]
        local p = sd and sd.player ~= nil and self.players[sd.player]
        if p then out[#out + 1] = { side = i, slot = sd.player, p = p } end
    end
    return out
end

---@param slot integer
function S:releaseSeat(slot)
    local i = self:seatOf(slot)
    if not i then return end
    local sd = self.sides[i]
    sd.player = nil
    sd.open = not sd.mustBeOn
    if self.players[slot] then self.players[slot].ready = false end
end

-- readyToStart (the binary's FUN_004eacd0): no map still missing at a player, the host has a seat, every human seat is
-- ready, at least two seats are played (humans and computers) and they are not all in the same non-zero team.
---@return boolean
function S:readyToStart()
    if self.sync and self.sync.never then return false end
    if not self:mySeat() then return false end
    local n = 0
    for i = 0, 5 do
        local sd = self.sides[i]
        if sd then
            local human = self:humanAt(i)
            if human then
                if not human.ready then return false end
                n = n + 1
            elseif not sd.open and not sd.closed then
                n = n + 1
            end
        end
    end
    if n < 2 then return false end
    local previous = -1
    for i = 0, 5 do
        local sd = self.sides[i]
        if sd and (self:humanAt(i) or (not sd.open and not sd.closed)) then
            if sd.team == 0 then return true end
            if previous ~= -1 and sd.team ~= previous then return true end
            previous = sd.team
        end
    end
    return false
end

---@return boolean
function S:startBlocked() return not self:readyToStart() end

function S:playerList()
    local out = {}
    for slot, p in pairs(self.players) do out[slot] = { name = p.name, race = p.race, ready = p.ready or false } end
    return out
end

-- Seat actions of the host's own player ---------------------------------------------------------------------------

function S:takeSeat(i)
    local sd = self.sides[i]
    if not sd or self:humanAt(i) then return end
    self:releaseSeat(0)
    sd.open, sd.closed, sd.player = false, false, 0
    self.players[0].ready = false
end

function S:leaveSeat() self:releaseSeat(0) end

function S:setSeatKind(i, kind, level)
    local sd = self.sides[i]
    if not sd then return end
    if sd.player ~= nil then self:releaseSeat(sd.player) end
    sd.open, sd.closed = kind == "open", kind == "closed"
    if kind == "ai" then sd.level = level end
end

-- A click on the host's ready box: the original refuses it with a message box while the others are not ready
-- (GS_SORRYREADY 1140-1142) or nobody else is in the game (GS_SORRYSOLO 1143-1145).
function S:readyClicked(i)
    if not self:isMine(i) then return end
    local me = self.players[0]
    if me.ready then me.ready = false return end
    me.ready = true
    if self:readyToStart() then return end
    me.ready = false
    local base = self:count() <= 1 and 1143 or 1140
    self.box = msgbox.new{ title = gs(base), line1 = gs(base + 1), line2 = gs(base + 2), buttons = { gs(300, "OK") },
                           onResult = function() self.box = nil end }
end

-- The host's player starts on the first seat after a map change (the original leaves him without one).
function S:seatAfterMapChange()
    if self.map == self.syncedMap then return end
    self.syncedMap = self.map
    self.snap = nil
    for _, p in pairs(self.players) do p.ready = false end
    for i = 0, 5 do if self.sides[i] then self.sides[i].player = nil end end
    local hs = self.humanSide
    local sd = hs and self.sides[hs]
    if sd then sd.player, sd.open, sd.closed = 0, false, false end
    self:beginMapSync()
end

-- Picking the map that is already selected (the size / player filters do it) keeps the seats.
function S:selectMap()
    local old, was = self.sides, self.syncedMap
    local m = self.shown[self.sel] or self.map
    skirmish.selectMap(self)
    if m == was and old and next(old) then
        self.sides = old
        self:buildSides()
    end
end

-- Map synchronisation ---------------------------------------------------------------------------------------------

-- What the players need to know to find the map: the file, its size and checksum (the original sends the map name and
-- the CRC of the header, see mapxfer.lua).
---@return table
function S:mapDetails()
    local m = self.map
    if not m then return { label = "?" } end
    if m.random then return { random = true, label = m.label } end
    if not m.sum then
        local data = self:mapData(m)
        m.sum, m.size = data and mapxfer.checksum(data) or 0, data and #data or 0
    end
    return { dir = m.dir, file = m.file, label = m.label, sum = m.sum, size = m.size }
end

-- The slots of the joined players that are connected.
---@return integer[]
function S:clients()
    local out = {}
    for _, slot in ipairs(self:slots()) do
        if slot ~= 0 and self.players[slot].peer then out[#out + 1] = slot end
    end
    return out
end

---@param slot integer
---@param msg table
function S:sendTo(slot, msg)
    local p = self.players[slot]
    if p and p.peer then p.peer:send(msg) end
end

-- A new map was picked: ask everybody whether he has it (MAPCHANGE_INFORM).
function S:beginMapSync()
    if not self.udp then return end
    self.mapSeq = (self.mapSeq or 0) + 1
    local sync = { seq = self.mapSeq, stage = "check", has = {}, never = false, info = self:mapDetails(), informed = {} }
    self.sync = sync
    if self.map and self.map.random then return self:sendMapChange() end
    for _, slot in ipairs(self:clients()) do
        sync.informed[slot] = true
        self:sendTo(slot, { t = "mapinform", seq = sync.seq, map = sync.info })
    end
    self:advanceSync()
end

-- All answers of the check are in (the "has map" handler FUN_004e89b0, message 0xbcf): everybody has the map, so it changes
-- now; if somebody lacks it the Send Map button gets active and the game cannot start until it is sent.
function S:advanceSync()
    local s = self.sync
    if not s then return end
    if s.stage == "check" then
        for slot in pairs(s.informed) do
            if self.players[slot] and s.has[slot] == nil then return end
        end
        for slot in pairs(s.informed) do
            if self.players[slot] and s.has[slot] == false then s.never = true return end
        end
        self:sendMapChange()
    elseif s.stage == "change" then
        for slot in pairs(s.waitFor) do
            if self.players[slot] and not s.ready[slot] then return end
        end
        self:finishMapChange()
    end
end

function S:sendMapChange()
    local s = self.sync
    -- (called while a synchronisation runs)
    ---@cast s -nil
    local waitFor = {}
    s.stage, s.never, s.ready, s.requested, s.waitFor = "change", false, {}, {}, waitFor
    for _, slot in ipairs(self:clients()) do
        waitFor[slot] = true
        self:sendTo(slot, { t = "mapchange", seq = s.seq, map = s.info })
    end
    self:advanceSync()
end

-- All players have the map or asked for it (FUN_004e7530): the pieces go to the requesters, then everybody is told.
function S:finishMapChange()
    local s = self.sync
    -- (advanceSync's "change" stage)
    ---@cast s -nil
    local pieces
    for slot in pairs(s.requested) do
        pieces = pieces or mapxfer.pieces(self:mapData(self.map) or "", s.seq)
        for _, piece in ipairs(pieces) do self:sendTo(slot, piece) end
    end
    for _, slot in ipairs(self:clients()) do self:sendTo(slot, { t = "mapfinished", seq = s.seq }) end
    s.stage = "done"
end

---@return boolean
function S:sendMapActive() return self.sync ~= nil and self.sync.stage == "check" and self.sync.never end

function S:sendMapClicked()
    if self:sendMapActive() then self:sendMapChange() end
end

-- A map change or a joining player keeps new players waiting (PLEASE_HOLD).
---@return boolean
function S:busy()
    local s = self.sync
    if s and (s.stage == "change" or (s.stage == "check" and not s.never)) then return true end
    return next(self.joining) ~= nil
end

-- Chat and lobby state ----------------------------------------------------------------------------------------------

-- What the joined players see on their read-only copy of the setup screen (screens/mpjoin.lua): the map, the options
-- and the seats.
---@param slot integer
---@return table
function S:lobbyMessage(slot)
    local m = self.map
    local o, sides = self.opt, {}
    for i, sd in pairs(self.sides) do
        sides[i] = { closed = sd.closed, open = sd.open, player = sd.player, race = sd.race, res = sd.res, team = sd.team,
                     level = sd.level, raceLocked = sd.raceLocked, teamLocked = sd.teamLocked, resLocked = sd.resLocked,
                     aiLocked = sd.aiLocked, mustBeOn = sd.mustBeOn, mustBeHuman = sd.mustBeHuman,
                     scnLevel = sd.scnLevel }
    end
    return { t = "lobby", slot = slot, players = self:playerList(), rm = m and m.random and self.rm.values or nil,
             map = self:mapDetails(), hostSide = self:mySeat(),
             opt = { fog = o.fog, night = o.night, quests = o.quests, points = o.points, tech = o.tech, mods = o.mods,
                     victory = o.victory, handicap = o.handicap, locks = o.locks, advanced = o.advanced, speed = o.speed },
             sides = sides }
end

-- A chat line for everybody, the host's screen included (the original sends it to all players, itself among them).
---@param text string
function S:postChat(text)
    self:addChat(text)
    for _, slot in ipairs(self:clients()) do self:sendTo(slot, { t = "lobbychat", text = text }) end
end

function S:submitChat(line)
    if self.udp then self:postChat((self.hero.name .. " - " .. line):sub(1, 99)) end
end

function S:broadcastLobby()
    for _, slot in ipairs(self:clients()) do self:sendTo(slot, self:lobbyMessage(slot)) end
end

-- FUN_004eaaf0: everybody stops being ready; a text goes to the players (only to the ready ones for most
-- reasons) but not to the host, who made the change.
---@param reasons { text: string, onlyReady: boolean }[]
function S:disableReady(reasons)
    for _, r in ipairs(reasons) do
        for _, slot in ipairs(self:clients()) do
            if not r.onlyReady or self.players[slot].ready then self:sendTo(slot, { t = "lobbychat", text = r.text }) end
        end
    end
    for _, p in pairs(self.players) do p.ready = false end
end

-- What the host changed since the last look, as the original's reasons (Game.txt): random map 747, options 748,
-- more options 749, rules 750, 745 the host's own seat, 746 a computer seat.
function S:snapshot()
    local o = self.opt
    local sides = {}
    for i, sd in pairs(self.sides) do
        local human = self:humanAt(i)
        local kind = (human or sd.open) and "o" or sd.closed and "c" or "a"
        local e = { kind = kind }
        if kind == "a" then
            e.ai = serialize.encode({ sd.race, sd.res, sd.team, sd.level, sd.aiFile, sd.aiHero })
        elseif human and sd.player == 0 then
            e.mine = serialize.encode({ sd.res, sd.team, sd.race })
        end
        sides[i] = e
    end
    return { map = self.map, rm = serialize.encode(self.map and self.map.random and self.rm.values or {}),
             opt = serialize.encode({ o.fog, o.night, o.quests, o.points, o.tech, o.victory, o.handicap, o.speed }),
             adv = serialize.encode(o.advanced), mods = serialize.encode(o.mods), sides = sides }
end

function S:checkChanges()
    local was, now = self.snap, self:snapshot()
    self.snap = now
    if not was or was.map ~= now.map then return end
    local reasons = {}
    local function add(id, onlyReady) reasons[#reasons + 1] = { text = gs(id, ""), onlyReady = onlyReady } end
    if now.rm ~= was.rm then add(747, true) end
    if now.opt ~= was.opt then add(748, true) end
    if now.adv ~= was.adv then add(749, false) end
    if now.mods ~= was.mods then add(750, false) end
    for i = 0, 5 do
        local a, b = was.sides[i], now.sides[i]
        if a and b and (a.kind ~= b.kind or a.ai ~= b.ai or a.mine ~= b.mine) then
            add((a.mine or b.mine) and 745 or 746, true)
        end
    end
    if #reasons > 0 then self:disableReady(reasons) end
end

-- Network traffic ---------------------------------------------------------------------------------------------------

-- Takes a joining player into the lobby (the original sends him the panels and locks the others' screens meanwhile).
---@param peer table
---@param m table the join message
function S:accept(peer, m)
    local slot = 0
    while self.players[slot] do slot = slot + 1 end
    self.players[slot] = { name = tostring(m.name or "Player"):sub(1, 40), race = m.race or 0, hero = m.hero, peer = peer,
                           ready = false }
    peer.slot = slot
    peer:send({ t = "joined", slot = slot })
    peer:send(self:lobbyMessage(slot))
    self.joining[slot] = love.timer.getTime()
    for _, other in ipairs(self:clients()) do
        if other ~= slot then self:sendTo(other, { t = "joinlock", on = true }) end
    end
    self:postChat((gs(226, "%s has joined the game..."):format(self.players[slot].name)))
end

function S:endJoin(slot)
    if not self.joining[slot] then return end
    self.joining[slot] = nil
    if not next(self.joining) then
        for _, other in ipairs(self:clients()) do self:sendTo(other, { t = "joinlock", on = false }) end
    end
end

---@param peer table
---@param m table the join message
function S:join(peer, m)
    local fits, why
    if m.version == net.VERSION then fits, why = require("src.content.mods").compare(m.content, require("src.content")) end
    local password = self.hostOpts and self.hostOpts.password or ""
    if m.version ~= net.VERSION then
        peer:send({ t = "refused", reason = "Different game version" })
    elseif password ~= "" and m.password ~= password then
        peer:send({ t = "refused", reason = "Wrong password" })
    elseif not fits then
        peer:send({ t = "refused", reason = "Different content: " .. tostring(why) })
    elseif self:count() >= self:usedSides() or self:count() >= 6 then
        peer:send({ t = "full" })
    elseif self:busy() then
        self.held[#self.held + 1] = { peer = peer, m = m }
        peer:send({ t = "hold" })
    else
        self:accept(peer, m)
    end
end

-- One message of a player.
---@param peer table
---@param m table
function S:handle(peer, m)
    local slot = peer.slot
    local p = slot and self.players[slot]
    if m.t == "join" then
        if not slot then self:join(peer, m) end
    elseif not p then
        return
    elseif p.booted then
        return                                          -- removed from the game: he is on his way out
    elseif m.t == "lobbychat" then
        local line = tostring(m.text or "")
        if line ~= "" then self:postChat((p.name .. " - " .. line):sub(1, 99)) end
    elseif m.t == "tournhero" and self.tourney and self.tourney.waiting[slot] then
        -- Tournament mode: the finished temporary hero of a player (what the lobby knows of him is his profile hero)
        if type(m.hero) == "table" and m.hero.tournament then
            self.tourney.heroes[self.tourney.waiting[slot]] = m.hero
            self.tourney.waiting[slot] = nil
        end
    elseif m.t == "army" and self.setup and self.setup.waiting[slot] then
        self.setup.armies[self.setup.waiting[slot]] = { retinue = m.retinue, army = m.army }
        self.setup.waiting[slot] = nil
    elseif m.t == "seat" then
        -- SIDEPANELCHANGEREQUEST: the first request for an Open seat gets it
        local sd = self.sides[m.side]
        if sd and sd.open and not self:seatOf(slot) and not self:locked() then
            sd.open, sd.player = false, slot
            p.ready = false
            self:broadcastLobby()
        else
            peer:send({ t = "seatdenied" })
        end
    elseif m.t == "unseat" then
        self:releaseSeat(slot)
    elseif m.t == "ready" then
        p.ready = m.on == true and self:seatOf(slot) ~= nil
    elseif m.t == "side" then
        -- the player of a seat changes its resources and team, as long as he is not ready
        local i = self:seatOf(slot)
        local sd = i and self.sides[i]
        local v = tonumber(m.value)
        if sd and i == m.side and not p.ready and not self:locked() and v == math.floor(v or -1) then
            if m.field == "res" and not sd.resLocked and v >= 0 and v <= 4 then sd.res = v
            elseif m.field == "team" and not sd.teamLocked and v >= 0 and v <= 3 then sd.team = v
            elseif m.field == "race" and not sd.raceLocked and (v == -1 or content.race:bySlot(v --[[@as integer]])) then self:setSide(i --[[@as integer]], "race", v --[[@as integer]]) end
        end
    elseif m.t == "hasmap" then
        if self.sync and m.seq == self.sync.seq and self.sync.stage == "check" then
            self.sync.has[slot] = m.has == true
            self:advanceSync()
        end
    elseif m.t == "mapok" or m.t == "mapreq" then
        local s = self.sync
        if s and m.seq == s.seq and s.stage == "change" then
            s.ready[slot] = true
            if m.t == "mapreq" then s.requested[slot] = true end
            self:advanceSync()
        end
    elseif m.t == "joinmap" then
        -- a player joining without the map asks for it (JOIN_SCENARIOFILE_REQUEST)
        if self.map and not self.map.random then
            for _, piece in ipairs(mapxfer.pieces(self:mapData(self.map) or "", m.seq or 0)) do self:sendTo(slot, piece) end
            self:sendTo(slot, { t = "mapfinished", seq = m.seq or 0, join = true })
        end
    elseif m.t == "joindone" then
        self:endJoin(slot)
    end
end

-- A click on another player's seat: the box "Remove player? / Should this warrior be removed from the
-- battlefield?" (texts 287.2-4, buttons No 285.3 left / Yes 285.2 right, FUN_004eb4d0 case 0x80 of the side panel).
function S:bootClicked(i)
    local sd = self.sides[i]
    if self.box or not sd or not sd.player or sd.player == 0 then return end
    local function t(id, sub) return UI.text(id, sub) or "" end
    self.box = msgbox.new{ title = t(287, 2), line1 = t(287, 3), line2 = t(287, 4), buttons = { t(285, 3), t(285, 2) },
                           onResult = function(yes)
        self.box = nil
        local now = self.sides[i] and self.sides[i].player
        if yes and now and now ~= 0 then self:boot(now) end
    end }
end

-- Yes: the seat becomes Open (the answer callback 0x004ed610 sets the seat state at 0x00a498dc to 0 and tells everybody)
-- and the player is told that he was removed (message 3011, answered by his own leave function: he says goodbye in the
-- chat, closes the session and returns to the main menu with a message box, see mpjoin.lua S:booted). The host drops him
-- when his connection ends ("has left the game"); one that does not leave is disconnected after a few seconds.
---@param slot integer
function S:boot(slot)
    local p = self.players[slot]
    if not p or slot == 0 then return end
    self:releaseSeat(slot)
    p.booted = love.timer.getTime()
    self:sendTo(slot, { t = "booted" })
    self:broadcastLobby()
end

---@param peer table
function S:dropPlayer(peer)
    for k = #self.held, 1, -1 do
        if self.held[k].peer == peer then table.remove(self.held, k) end
    end
    local slot = peer.slot
    if not slot or not self.players[slot] then return end
    self.setup = nil                   -- somebody left while the armies were chosen: back to the lobby
    self.tourney, self.tourneyHeroes = nil, nil
    local name = self.players[slot].name
    self:releaseSeat(slot)
    self.players[slot] = nil
    self:endJoin(slot)
    peer.slot = nil
    self:advanceSync()
    self:broadcastLobby()
    self:postChat((gs(237, "%s has left the game..."):format(name)))
end

function S:service()
    for _, e in ipairs(self.udp:service()) do
        if e.type == "receive" then
            self:handle(e.peer, e.data)
        elseif e.type == "disconnect" then
            self:dropPlayer(e.peer)
        end
    end
    -- players that waited for the host are let in one by one
    while #self.held > 0 and not self:busy() do
        local h = table.remove(self.held, 1)
        self:accept(h.peer, h.m)
    end
    local now = love.timer.getTime()
    for slot, t in pairs(self.joining) do
        if now - t > 60 then self:endJoin(slot) end
    end
    for _, p in pairs(self.players) do
        if p.booted and p.peer and now - p.booted > 4 then p.booted = now + 3600 p.peer:disconnect() end
    end
    -- a connection that never says who it is does not keep a place (the UDP layer holds at most 64)
    local waiting = {}
    for _, h in ipairs(self.held) do waiting[h.peer] = true end
    for _, peer in pairs(self.udp.peers) do
        if peer.state == "connected" and not peer.slot and not waiting[peer] and peer.connectedAt
            and now - peer.connectedAt > 15 then
            peer:disconnect()
        end
    end
end

-- developer aid: --show mphost:auto starts as soon as one player has joined and taken a seat
function S:dev(sub)
    if sub == "autoonline" then
        -- as "auto", published on the lobby server of [net] lobby= (the internet path end to end, docs/lobby.md)
        self.hostOpts.publish = true
        local client, err = lobby.client(self.udp, os.getenv("OPENWBC3_LOBBY") or config.get("net", "lobby", ""))
        if client then self.lobby = client else self:addChat("Internet: " .. tostring(err)) end
        sub = "auto"
    end
    if sub == "auto" then self.autoStart, self.devArmy, self.opt.points = true, true, 5
    elseif sub == "autotournament" or sub == "tournament" then
        -- Tournament mode (level 8): "autotournament" without any screen of this machine, "tournament" with the hero
        -- creation screens (no army setup); both start when a second player has joined
        self.autoStart, self.devArmy, self.opt.points = true, sub == "autotournament", sub == "autotournament" and 5 or 0
        self.opt.advanced = require("src.game.advanced").enforce({ tournament = true, points = 8 }, true)
    end
end

function S:update(dt)
    skirmish.update(self, dt)
    if not self.udp then return end
    self:service()
    self:checkChanges()
    self:checkTournament()
    self:checkSetup()
    if self.autoStart then
        local mine = self:mySeat()
        if mine then
            self.players[0].ready = true
            if self.sides[mine].team ~= 0 then self.sides[mine].team = 0 end    -- maps with preset teams: two humans on one team cannot start
        end
        if self:count() >= 2 and self:readyToStart() then
            self.autoStart = false
            self:start()
        end
    end
    local now = love.timer.getTime()
    local used = self:usedSides()
    self.announcer:send({ content = require("src.content.mods").describe(require("src.content")).hash, name = self.hero.name .. "'s game", map = self.map and self.map.label or "?",
                          players = self:count(), max = math.min(6, used) }, now)
    self:publish(false)
    if self.lobby and self.lobby.gameId and not self.announcedCode then
        self.announcedCode = true
        self:addChat(("Published on the internet, join code %08X"):format(self.lobby.gameId))
    end
    -- keep the clients informed when the map or options change
    local state = serialize.encode(self:lobbyMessage(0))
    if state ~= self.lastState or now - self.lastBroadcast > 2 then
        self.lastState, self.lastBroadcast = state, now
        self:broadcastLobby()
    end
end

-- Starting ----------------------------------------------------------------------------------------------------------

function S:start()
    if self:startBlocked() then return end
    skirmish.start(self)
end

-- Starts the game: every human first sets up the army for the battle (the original opens the retinue screen after the host
-- started: the army setup opener FUN_00440b40 with the setup points plus the handicap); the choices go to everybody with
-- the start message. Tournament mode (start message handler FUN_004e2660): after the start every human makes his temporary
-- hero (screens/tournamenthero.lua) before the armies are chosen; the clients do it on their own machines and send the
-- finished hero back, so every peer gets the same heroes in the start message.
---@param scn table
---@param opts table
function S:launchTournament(scn, opts)
    local seated, hostSide = self:seated(), self:mySeat()
    -- (launch only comes here when the host has a seat)
    ---@cast hostSide -nil
    local t = { scn = scn, opts = opts, waiting = {}, heroes = {} }
    self.tourney = t
    for _, e in ipairs(seated) do
        if e.slot ~= 0 then
            t.waiting[e.slot] = e.side
            e.p.peer:send({ t = "tournament", points = opts.advanced.points })
        end
    end
    if self.devArmy then            -- --show mphost:auto: no screen
        local save = require("src.game.classes").newHero("Warrior", self.hero.race)
        save.level, save.tournament, save.xp = opts.advanced.points, true, require("src.game.hero").xpFor(opts.advanced.points)
        save.points = { attr = 0, skill = 0 }
        t.heroes[hostSide] = save
        opts.tournamentRec = { id = "tournament", temporary = true, name = "Dev", race = self.hero.race, class = "Warrior",
                               portrait = 0, password = "", mode = 0, battles = 0, hero = save }
        return
    end
    screens.push(require("src.screens.tournamenthero"), function(rec)
        if self.tourney ~= t then return end
        t.heroes[hostSide] = rec.hero
        opts.tournamentRec = rec
    end, opts.advanced.points)
end

-- Waits for the temporary heroes of the other players, then goes on with the army setup.
function S:checkTournament()
    local t = self.tourney
    if not t or not t.opts.tournamentRec or next(t.waiting) then return end
    self.tourney = nil
    self.tourneyHeroes = t.heroes
    self:launch(t.scn, t.opts)
end

function S:underUpdate()
    if not self.udp then return end
    if self.tourney or self.setup then
        self:service()          -- the clients keep talking while this machine is busy on a hero or army screen
        self:checkTournament()
        self:checkSetup()
    end
end

function S:launch(scn, opts)
    local retinue = require("src.game.retinue")
    local seated = self:seated()
    local hostSide = self:mySeat()
    if not self.tourneyHeroes and hostSide and require("src.game.advanced").tournamentGame(opts.advanced, opts.mods) then
        return self:launchTournament(scn, opts)
    end
    if (opts.startPoints or 0) <= 0 then return self:begin(scn, opts, {}) end
    -- (a game only starts when the host has a seat, readyToStart)
    ---@cast hostSide -nil
    -- handicapping (the setup's option, taken from the scenario): a hero below the highest hero level gets extra points
    local highest = 0
    for _, e in ipairs(seated) do highest = math.max(highest, (e.p.hero or {}).level or 1) end
    local handicap = opts.handicap
    local points = {}
    for _, e in ipairs(seated) do
        local extra = handicap and retinue.handicap(highest, (e.p.hero or {}).level or 1) or 0
        points[e.side] = math.min(retinue.MAX_POINTS, opts.startPoints + extra)
    end
    self.setup = { scn = scn, opts = opts, armies = {}, waiting = {}, hostSide = hostSide }
    local victory = require("src.game.victory").get(opts.victory, "pitched") and 0 or opts.techLevel
    local function raceOf(side) return scn.sides[side] and scn.sides[side].race or self.hero.race end
    for _, e in ipairs(seated) do
        if e.slot ~= 0 then
            self.setup.waiting[e.slot] = e.side
            e.p.peer:send({ t = "setup", points = points[e.side], techLevel = victory, race = raceOf(e.side) })
        end
    end
    local rec = opts.tournamentRec or profile.current()
    if self.devArmy then               -- --show mphost:auto: no screen, a general comes along
        self.setup.armies[hostSide] = { retinue = { { slot = 1, code = retinue.generalFor(raceOf(hostSide), 0), level = 2,
                                                      xp = 10, name = "Dev" } }, army = {} }
        return
    end
    screens.push(require("src.screens.armysetup"), {
        mode = "select", race = raceOf(hostSide), points = points[hostSide], techLevel = victory,
        slots = retinue.slotsOf(rec), retinue = retinue.get(rec), graveyard = retinue.graveyard(rec),
        onDone = function(result)
            -- a player left while this screen was open (S:dropPlayer): the setup is gone, back in the lobby
            if not self.setup then return end
            self.setup.armies[hostSide] = { retinue = result.retinue, army = result.army }
        end,
    })
end

-- Waits for the choices of the other players, then starts.
function S:checkSetup()
    local s = self.setup
    if not s or not s.armies[s.hostSide] or next(s.waiting) then return end
    self.setup = nil
    self:begin(s.scn, s.opts, s.armies)
end

-- Starts the game for everybody.
---@param scn table
---@param opts table
---@param armies table<integer, table> the army of every human side
function S:begin(scn, opts, armies)
    local seated = self:seated()
    local hostSide = self:mySeat()
    local sideSettings, heroes, names, sideList = {}, {}, {}, {}
    for i = 0, 5 do
        local sd = scn.sides[i]
        if sd then
            sideSettings[i] = { used = sd.used, race = sd.race, resources = sd.resources, team = sd.team,
                                aiLevel = sd.aiLevel, aiFile = sd.aiFile, aiHero = sd.aiHero }
        end
    end
    for _, e in ipairs(seated) do
        heroes[e.side] = self.tourneyHeroes and self.tourneyHeroes[e.side] or e.p.hero
        names[e.side] = e.p.name
        sideList[#sideList + 1] = e.side
    end
    local seed = os.time() % 1000000 + 1
    opts.quests = false
    opts.profile = true
    opts.armies = armies
    opts.seed = seed
    local peers = {}
    for _, e in ipairs(seated) do
        if e.slot ~= 0 then
            peers[e.side] = e.p.peer
            e.p.peer:send({ t = "start", scnPath = opts.scnPath, random = opts.random, sides = sideSettings, heroes = heroes,
                     names = names, seed = seed, armies = armies, you = e.side, hostSide = hostSide, map = self:mapDetails(),
                     opts = { fogMode = opts.fogMode, startPoints = opts.startPoints, quests = false, night = opts.night,
                              resurrect = opts.resurrect, victory = opts.victory, techLevel = opts.techLevel,
                              mods = opts.mods, advanced = opts.advanced, gameSpeed = opts.gameSpeed } })
        end
    end
    -- a player without a seat has no part in the game (start message handler FUN_004e2660: "Game already started")
    for _, slot in ipairs(self:clients()) do
        if not self:seatOf(slot) then self:sendTo(slot, { t = "notseated" }) end
    end
    local humans = {}
    for _, side in ipairs(sideList) do humans[side] = true end
    self:publish(true)      -- in battle: listed, not joinable; the lobby keeps relaying for the players that need it
    local session = lockstep.host(self.udp, { sides = sideList, localSide = hostSide, seed = seed, peers = peers, names = names })
    opts.net, opts.humans, opts.heroes, opts.player = session, humans, heroes, hostSide
    self.tourneyHeroes = nil
    profile.setCurrent(self.hero.id)
    screens.push(require("src.screens.battle"), scn, opts)
end

-- The game is over. The original does not return to the lobby: after the results and the retinue screens the session is
-- closed and every player, the host included, is on the main menu (the retinue screen's exit handler FUN_00440e80 closes the
-- comms and runs the startup screen's set-up FUN_0041d2c0 when the game is not a campaign one).
function S:resume()
    skirmish.resume(self)
    screens.popToBottom()
end

function S:leave()
    if self.lobby then
        self.lobby:close()
        self.lobby = nil
    end
    if self.udp then
        self.udp:service()
        self.udp:close()
        self.udp = nil
    end
end

function S:draw()
    if self.error then
        local UI = require("src.ui.interface")
        local kit = require("src.ui.kit")
        UI.begin()
        kit.backdrop(0.8)
        require("src.ui.fonts").print(5, self.error, 0, 280, "center", 800)
        UI.finish()
        return
    end
    skirmish.draw(self)
    if self.setup and self.setup.armies[self.setup.hostSide] then
        local UI = require("src.ui.interface")
        local kit = require("src.ui.kit")
        UI.begin()
        kit.panel(200, 250, 400, 80, 0.9)
        require("src.ui.fonts").print(5, "Waiting for the other players to choose their armies ...", 200, 280, "center", 400)
        UI.finish()
    end
end

return S
