-- The lobby of a joined network game: the host's side selection screen (PNL_SS, skirmish.lua). Everything on it comes
-- from the host's "lobby" messages (map, options, the seats with their race / resources / team / computer level, the
-- players with their ready boxes). The player can read the options dialogs and chat; he takes one of the Open seats
-- with a click (and gives it up with a click on his own), changes the resources and team of his own seat and ticks his
-- ready box (side panel handler FUN_004eb4d0: a joined player's PNL_SS has the host's controls greyed).
-- Chat lines go to the host, which formats "<name> - <text>" and sends them to everybody.
--
-- The message boxes of the original's map change (texts 284: "Changing maps / Please wait...", "You do not have this
-- scenario / Do you wish to download it from the host?", "Different version of scenario found", "Player joining",
-- 286.7 "Game already started") are the generic message box (ui/msgbox.lua, the binary's FUN_0042d7b0); see mphost.lua
-- for the messages. A map the player lacks is received in pieces and stored with the editor's maps (game/mapxfer.lua).
local screens = require("src.core.screens")
local skirmish = require("src.screens.skirmish")
local profile = require("src.game.profile")
local lockstep = require("src.game.lockstep")
local scnMod = require("src.formats.scn")
local msgbox = require("src.ui.msgbox")
local mapxfer = require("src.game.mapxfer")
local UI = require("src.ui.interface")

-- The connection to the host (screens/multiplayer.lua).
---@class JoinConnection
---@field host table                 the UDP client (game/net.lua)
---@field peer table                 the host (an internet join sets it on connect)
---@field slot integer?              this player's lobby slot
---@field inbox table[]?             network events kept for later
---@field since number
---@field players table
---@field info table
---@field lobby LobbyClient?       the lobby client (internet joins; it relays when the game is relayed)
---@field password string?          the password sent with the join message
---@field gameId integer?           the internet game being joined
---@field relayOk boolean?          the host accepts a relay
---@field relayAsked boolean?       the relay was asked for

-- A message box of the lobby, tagged with what it is about (S:closeBox).
---@class LobbyBox: MsgBox
---@field kind string?

-- The joined player's lobby inherits the skirmish setup (the metatable falls back to skirmish.lua) and overrides some of
-- its methods; the class says so (without it the language server takes S for the skirmish table itself and reports
-- every override as a duplicate field).
---@class MpJoinScreen: SkirmishScreen
---@field ctx { hero: table, client: JoinConnection, parent: MultiplayerScreen, devAuto: boolean? }
---@field client JoinConnection
---@field players table<integer, LobbyPlayer>
---@field sideKey string?            the seats the side panels were built for
---@field joinPending boolean        until the first lobby message has been checked for the map
---@field joining boolean?           the map is being fetched while joining
---@field receiving { info: table, collect: fun(m: table): string? }?   a map coming in pieces
---@field mapKey string?             the host's map the list shows
---@field devLack string?            developer aid: a map file taken as missing
---@field devGot boolean?
---@field devAsked string?
---@field devReady boolean?
---@field making boolean?            the temporary hero of a Tournament game is being made
---@field tournRec HeroProfile?      the temporary hero's record
---@field inBattle boolean?
---@field box LobbyBox?
local S = setmetatable({}, { __index = skirmish })
S.helpId = 11          -- screen help (src/screens/screenhelp.lua)
S.__index = S
S.multiplayer = true

-- ctx = { hero, client = { host, peer, slot, inbox }, parent = the join screen (gets the notice when we leave) }
function S:enter(ctx)
    self.players = {}
    skirmish.enter(self)
    self.title = "Multiplayer - Joined"
    self.ctx, self.client = ctx, ctx.client
    self.hero = ctx.hero
    self.players = {}
    self.sideKey = nil
    self.chat = {}
    self.joinPending = true          -- until the first lobby message has been checked for the map
end

function S:canEdit() return false end
function S:canEditAdvanced() return false end
function S:mySlot() return self.client and self.client.slot end
function S:start() end            -- only the host starts
function S:startBlocked() return true end

-- Cancel / Esc: leave the game (not while ready, the button is greyed then).
function S:button(name, it)
    if name == "BUTT_CANCEL_STARTUP" then
        if not self:cancelBlocked() then self:leaveGame() end
    else
        skirmish.button(self, name, it)
    end
end

function S:keypressed(key)
    if not self.box and (key == "up" or key == "down" or key == "pageup" or key == "pagedown") then return end     -- the list is the host's
    skirmish.keypressed(self, key)
end

---@param notice string? shown on the join screen
function S:leaveGame(notice)
    if notice then self.ctx.parent.notice = notice end
    screens.pop()
end

function S:leave()
    skirmish.leave(self)
    local c = self.client
    if c and c.peer then
        c.peer:disconnect()
        c.host:service()
    end
end

function S:resume()
    -- the game is over: the original closes the network session and returns to the main menu, not to the lobby (the
    -- retinue screen's exit handler FUN_00440e80 closes the comms and runs the startup screen's set-up FUN_0041d2c0)
    if self.inBattle then screens.popToBottom() return end
    skirmish.resume(self)
end

-- A chat line goes to the host, which sends "<name> - <text>" back to everybody (including us).
function S:submitChat(line)
    self.client.peer:send({ t = "lobbychat", text = line })
end

-- Seat actions: asked of the host, which answers with the next lobby message.
function S:takeSeat(i) self.client.peer:send({ t = "seat", side = i }) end
function S:leaveSeat() self.client.peer:send({ t = "unseat" }) end

function S:readyClicked(i)
    local me = self:humanAt(i)
    if me and self:isMine(i) then self.client.peer:send({ t = "ready", on = not me.ready }) end
end

function S:setSide(i, field, value)
    self.client.peer:send({ t = "side", side = i, field = field, value = value })
end

-- Message boxes ---------------------------------------------------------------------------------------------------------

---@param kind string what the box is about (closeBox)
---@param cfg MsgBoxConfig
function S:showBox(kind, cfg)
    local inner = cfg.onResult
    cfg.onResult = function(yes)
        self.box = nil
        if inner then inner(yes) end
    end
    self.box = msgbox.new(cfg) --[[@as LobbyBox]]
    self.box.kind = kind
end

---@param kind string
function S:closeBox(kind)
    if self.box and self.box.kind == kind then self.box = nil end
end

local function t(id, sub, fallback) return UI.text(id, sub) or fallback or "" end

function S:changingBox()
    self:showBox("changing", { title = t(284, 0, "Changing maps"), line1 = t(284, 1, "Please wait...") })
end

-- Maps ------------------------------------------------------------------------------------------------------------------

-- The local copy of the host's map: the entry of the map list, or nil and why ("missing" / "differs": a map of that file
-- name with another size or checksum exists).
---@param info table the host's map details
---@return SkirmishMap? map, "ok"|"missing"|"differs" status
function S:findMap(info)
    if info.random then return self.maps[1], "ok" end
    local differs
    for _, m in ipairs(self.maps) do
        if not m.random and (m.file or ""):lower() == (info.file or ""):lower()
           and not (self.devLack == (m.file or ""):lower() and not self.devGot) then      -- devLack: developer aid
            if not m.sum then
                local data = self:mapData(m)
                m.sum, m.size = data and mapxfer.checksum(data) or 0, data and #data or 0
            end
            if m.sum == info.sum and m.size == info.size then return m, "ok" end
            differs = true
        end
    end
    return nil, differs and "differs" or "missing"
end

-- The map the host announced is not here (or another version): "Do you wish to download it from the host?" (the buttons
-- are No on the left and Yes on the right, as in the original's call); No leaves the game.
function S:askForMap(info, status, request)
    self:showBox("ask", {
        title = t(284, 7, "Scenario error"), line1 = t(284, status == "missing" and 2 or 4), line2 = t(284, 3),
        buttons = { t(285, 3, "No"), t(285, 2, "Yes") },
        onResult = function(yes)
            if not yes then self:leaveGame() return end
            self:changingBox()
            self.receiving = { info = info, collect = mapxfer.collector() }
            request()
        end,
    })
end

-- The pieces of the map arrived: store it and put it in the list.
---@param data string
function S:receivedMap(data)
    local info = self.receiving.info
    self.receiving = nil
    self.devGot = true
    if mapxfer.checksum(data) ~= info.sum or #data ~= info.size then
        self:leaveGame("The map could not be received")
        return
    end
    local file, err = mapxfer.store(info.file, data)
    if not file then self:leaveGame("Cannot store the map: " .. tostring(err)) return end
    self:loadMaps()
    self:rebuild()
    self.mapKey = nil
end

function S:onMessage(m)
    local peer = self.client.peer
    if m.t == "mapinform" then
        local _, status = self:findMap(m.map or {})
        peer:send({ t = "hasmap", seq = m.seq, has = status == "ok" })
    elseif m.t == "mapchange" then
        local _, status = self:findMap(m.map or {})
        if status == "ok" then
            self:changingBox()
            peer:send({ t = "mapok", seq = m.seq })
        else
            self:askForMap(m.map, status, function() peer:send({ t = "mapreq", seq = m.seq }) end)
        end
    elseif m.t == "mapdata" then
        local data = self.receiving and self.receiving.collect(m)
        if data then self:receivedMap(data) end
    elseif m.t == "mapfinished" then
        self:closeBox("changing")
        if m.join and not self.receiving then
            peer:send({ t = "joindone" })
            self.joinPending = false
        end
    elseif m.t == "joinlock" then
        if m.on then
            if not self.box then
                self:showBox("joining", { title = t(284, 5, "Player joining"), line1 = t(284, 1, "Please wait...") })
            end
        else
            self:closeBox("joining")
        end
    elseif m.t == "booted" then
        self:booted()
    elseif m.t == "notseated" then
        self:showBox("notseated", { title = t(286, 7, "Game already started"), line1 = t(287, 0), line2 = t(287, 1),
                                    buttons = { t(285, 0, "Okay") }, onResult = function() self:leaveGame() end })
    end
end

-- The host removed this player from his seat (message 0xbc3 handler FUN_004f0b00): he leaves the game at once (the
-- leave function FUN_004f0bc0: "has left" chat, closes the session) and lands on the main menu, where the message box
-- "Farewell / The host considers you unfit for battle / You have been removed from the game" (texts 286.0-2, button
-- 285.0) tells him.
function S:booted()
    screens.popToBottom()
    local menu = screens.top() --[[@as MainMenuScreen?]]
    if menu and menu.message then
        menu:message{ title = t(286, 0, "Farewell"), line1 = t(286, 1), line2 = t(286, 2), buttons = { t(285, 0, "Okay") } }
    end
end

-- Joining: the first lobby message names the map; without it (or with another version) the player is asked at once
-- (map setup handler FUN_004e1f30), then he tells the host that he is in.
function S:checkJoinMap(info)
    self.joinPending = false
    local _, status = self:findMap(info)
    if status == "ok" then
        self.client.peer:send({ t = "joindone" })
    else
        self:askForMap(info, status, function() self.client.peer:send({ t = "joinmap", seq = 0 }) end)
        self.joining = true
    end
end

-- The host's setup: map, options and seats.
function S:applyLobby(m)
    self.players = m.players or {}
    self.client.slot = m.slot or self.client.slot
    local info = m.map or {}
    if self.joinPending then self:checkJoinMap(info) end
    local key = tostring(info.file) .. ":" .. tostring(info.sum) .. ":" .. tostring(info.random)
    if self.mapKey ~= key then
        self.mapKey = key
        local entry = self:findMap(info)
        local found
        for i, e in ipairs(self.shown) do
            if e == entry then found = i end
        end
        if found then
            self.map, self.sel = self.shown[found], found
            self.list.sel = found
            self.list:ensureVisible()
        else            -- a map this installation lacks: only its name can be shown
            self.map, self.sel = { dir = info.dir, file = info.file, label = info.label or "?" }, 0
            self.list.sel = 0
        end
    end
    local o = m.opt or {}
    o.mods, o.locks = o.mods or {}, o.locks or {}
    o.locks.mods = o.locks.mods or {}
    self.opt = o
    if m.rm then self.rm.values = m.rm end              -- the random map's settings
    self.sides = m.sides or {}
    local seats = {}
    for i = 0, 5 do if self.sides[i] then seats[#seats + 1] = i end end
    local key2 = table.concat(seats, ",")
    if key2 ~= self.sideKey then
        self.sideKey = key2
        self:buildSides()
    end
end

function S:update(dt)
    skirmish.update(self, dt)
    local c = self.client
    local inbox = c.inbox
    c.inbox = nil
    for _, e in ipairs(inbox or {}) do
        if self:handle(e) then return end
    end
    for _, e in ipairs(c.host:service()) do
        if self:handle(e) then return end
    end
    if self.ctx.devAuto and self.sides then self:devSeat() end
end

-- While the temporary hero of a Tournament game is made on top of this screen, the host's messages are kept for later
-- and the session stays alive (the screens above do not run the network).
function S:underUpdate()
    local c = self.client
    if not self.making or not c then return end
    for _, e in ipairs(c.host:service()) do
        c.inbox = c.inbox or {}
        c.inbox[#c.inbox + 1] = e
    end
end

-- developer aid (--show multiplayer:join): take the first Open seat and get ready
function S:devSeat()
    local mine = self:mySeat()
    if not mine then
        self.devReady = nil
        for i = 0, 5 do
            if self.sides[i] and self.sides[i].open and self.devAsked ~= self.mapKey and not self.box then
                self.devAsked = self.mapKey
                self:takeSeat(i)
                return
            end
        end
    else
        local me = self:humanAt(mine)
        if me and not me.ready and not self.devReady and not self.box then
            self.devReady = true
            self.client.peer:send({ t = "ready", on = true })
        end
    end
end

-- One network event; true when the screen is done with.
---@param e table
---@return boolean?
function S:handle(e)
    local c = self.client
    if e.type == "receive" then
        local m = e.data
        if m.t == "lobby" then
            self:applyLobby(m)
        elseif m.t == "lobbychat" then
            self:addChat(tostring(m.text or ""))
        elseif m.t == "tournament" then
            -- the host started a Tournament mode game: make the temporary hero here, send it, then the army setup follows
            self.tournRec = nil
            local function done(rec)
                self.tournRec = rec
                self.making = nil
                c.peer:send({ t = "tournhero", hero = rec.hero })
            end
            self.making = true
            if self.ctx.devAuto then             -- --show multiplayer:join: no screen
                local save = require("src.game.classes").newHero("Warrior", self.hero.race)
                save.level, save.tournament, save.xp = m.points, true, require("src.game.hero").xpFor(m.points)
                save.points = { attr = 0, skill = 0 }
                done({ id = "tournament", temporary = true, name = "Dev", race = self.hero.race, class = "Warrior", portrait = 0,
                       password = "", mode = 0, battles = 0, hero = save })
            else
                screens.push(require("src.screens.tournamenthero"), done, m.points)
            end
        elseif m.t == "setup" then
            -- the host started: choose the army for the battle, then wait for the start message
            local retinue = require("src.game.retinue")
            local rec = (self.tournRec or profile.current()) --[[@as HeroProfile]]   -- (the lobby has a hero)
            if self.ctx.devAuto then             -- --show multiplayer:join: no screen, a general comes along
                c.peer:send({ t = "army", retinue = { { slot = 1, code = retinue.generalFor(m.race or self.hero.race, 0), level = 2,
                                                        xp = 10, name = "Dev" } }, army = {} })
            else
                screens.push(require("src.screens.armysetup"), {
                    mode = "select", race = m.race or self.hero.race, points = m.points, techLevel = m.techLevel,
                    slots = retinue.slotsOf(rec), retinue = retinue.get(rec), graveyard = retinue.graveyard(rec),
                    onDone = function(result)
                        c.peer:send({ t = "army", retinue = result.retinue, army = result.army })
                    end,
                })
            end
        elseif m.t == "start" then
            self:startGame(m)
            return true
        else
            self:onMessage(m)
        end
    elseif e.type == "disconnect" then
        self:leaveGame(e.reason == "timeout" and "No answer from the host" or "Disconnected from the host")
        return true
    end
end

-- The host started: build the same battle as everybody else and run it in lockstep.
function S:startGame(m)
    local c = self.client
    -- a random map is built again from the host's settings and seed (randommap.build)
    local scn
    if m.random then
        require("src.ui.randompanel").showGenerating()
        scn = require("src.game.randommap").build(m.random)
    else
        local entry = m.map and self:findMap(m.map)
        local data = entry and self:mapData(entry)
        scn = data and scnMod.parse(data)
    end
    if not scn then
        self:leaveGame("This game needs the map " .. tostring(m.scnPath))
        return
    end
    for i, set in pairs(m.sides) do
        local sd = scn.sides[i]
        if sd then
            sd.used, sd.race, sd.resources, sd.team, sd.aiLevel = set.used, set.race, set.resources, set.team, set.aiLevel
            sd.aiFile = set.aiFile
            sd.aiHero = set.aiHero
        end
    end
    local humans, sideList = {}, {}
    for side in pairs(m.heroes) do humans[side] = true sideList[#sideList + 1] = side end
    table.sort(sideList)
    local session = lockstep.client(c.host, { sides = sideList, localSide = m.you, seed = m.seed, server = c.peer, names = m.names,
                                              hostSide = m.hostSide })
    local opts = m.opts
    opts.net, opts.seed, opts.humans, opts.heroes, opts.player = session, m.seed, humans, m.heroes, m.you
    opts.armies = m.armies or {}
    opts.profile, opts.scnPath, opts.random = true, m.scnPath, m.random
    opts.tournamentRec, self.tournRec = self.tournRec, nil
    profile.setCurrent(self.hero.id)
    self.inBattle = true
    screens.push(require("src.screens.battle"), scn, opts)
end

return S
