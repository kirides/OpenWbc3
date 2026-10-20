-- Skirmish setup on the original's side selection screen (PNL_SS with one PNL_SIDESEL_SIDEn per side, laid out as
-- the set-up opener FUN_004e47e0 and the side panel opener FUN_004f19f0 open them): the map list with its size /
-- player count filters, the minimap, six option drop-downs (victory, keep level, hidden map, fog, handicapping, quests),
-- the army setup points bar, game speed, More options / Rules..., the hover help lines and the side panels (player /
-- computer level, race, resources, team shield). The multiplayer host lobby (mphost.lua) and the join screen build on it.
--
-- Network games (mphost.lua / mpjoin.lua) use the original's seat model (seat states at 0x00a498dc):
-- a seat is Open (waiting for a player), taken by a player, a computer or closed; every seat of a new map starts Open,
-- a joined player picks an Open seat himself, and the "ready" check box of every human seat gates the host's start
-- (the start check FUN_004eacd0 in the 1.04 binary). A seat's data: sd.open, sd.player (the lobby slot sitting there),
-- self.players[slot] = { name, race, ready }.
--
-- Own choices (not verified against the original): the list row height and highlight, the resolution button changes the
-- window size (the original's battle resolution), the host sits on the first seat after a map change instead of
-- picking one (the original leaves every player, the host too, without a seat), no "line of sight" fog choice
-- (openwbc3 has no such fog), the campaign scenarios are not in the list (the original's list is the Scenario folder).
-- A right click on a computer side opens the AI hero panel (aihero.lua, PNL_VIEWHERO: race, class, level and AI script
-- of the computer's hero).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local config = require("src.core.config")
local fs = require("src.core.fs")
local scnMod = require("src.formats.scn")
local classes = require("src.game.classes")
local content = require("src.content")
local profile = require("src.game.profile")
local aihero = require("src.game.aihero")
local aiparams = require("src.game.aiparams")
local music = require("src.audio.music")
local log = require("src.core.log")
local Advanced = require("src.game.advanced")
local gameopts = require("src.core.gameopts")
local dropdown = require("src.ui.dropdown")
local listbox = require("src.ui.listbox")
local bars = require("src.ui.scrollbars")
local text = require("src.core.text")

-- A map of the list: a scenario file of the game or of the editor, or the random map.
---@class SkirmishMap
---@field dir string               "Scenario", "scenarios" (the editor's) or "random"
---@field file string
---@field label string
---@field user boolean?            saved by the editor (user directory)
---@field random boolean?          the random map (the list's first entry)
---@field scn Scenario|false|nil   the parsed scenario, cached (false: unreadable)
---@field sum integer?             network games: checksum and size of the file (mapxfer.lua)
---@field size integer?

-- One seat (side panel) of the setup.
---@class SkirmishSeat
---@field used boolean
---@field closed boolean
---@field open boolean?            network games: waiting for a player
---@field player integer?          network games: the lobby slot sitting there
---@field race integer?            nil: Random
---@field res integer              resources 0..4
---@field team integer
---@field level integer            computer level
---@field scnLevel integer         the scenario's computer level
---@field raceLocked boolean?
---@field teamLocked boolean?
---@field resLocked boolean?
---@field aiLocked boolean?
---@field mustBeOn boolean?
---@field mustBeHuman boolean?
---@field aiFile string?           the computer's custom AI script
---@field aiHero table?            the computer hero's race / class / level (game/aihero.lua)

-- A player of a network lobby (`players[slot]`; the host is slot 0).
---@class LobbyPlayer
---@field name string
---@field race integer?
---@field ready boolean
---@field hero table?              the save of his profile hero
---@field peer table?              host only: his connection (game/net.lua)
---@field booted number?           host only: when he was removed

-- The options of the setup (what the lobby message carries to the joined players).
---@class SkirmishOptions
---@field fog integer              visibility mode 1..4 (FOG)
---@field night boolean
---@field quests boolean
---@field points integer           army setup points
---@field tech integer             keep level 0..5
---@field mods table<string, boolean>
---@field victory integer
---@field handicap boolean
---@field locks table              what the scenario locks: tech, fog, hidden, quests, points, handicap, mods
---@field advanced table           the "More options" values (game/advanced.lua)
---@field speed integer            game speed 0..4
---@field oldTech integer?         what setVictory replaced, restored by the next pick
---@field oldPoints integer?
---@field oldMods table?

-- The panel of one seat.
---@class SidePanel: Panel
---@field side integer

---@class SkirmishScreen: Screen
---@field multiplayer boolean?     a network lobby (mphost.lua / mpjoin.lua)
---@field title string?            network lobbies: the screen's title
---@field sizeFilter integer       0..3 the map widths, 4 any
---@field playerFilter integer     0..4 two to six players, 5 any
---@field opt SkirmishOptions
---@field previews table<SkirmishMap, love.Image|false>
---@field sides table<integer, SkirmishSeat>   by side 0..5 (only the scenario's used sides)
---@field rm RandomPanel           PNL_SS_RANDOMMAP
---@field maps SkirmishMap[]
---@field shown SkirmishMap[]      the list after the filters
---@field map SkirmishMap?
---@field sel integer              index into `shown`
---@field list ListBox
---@field panel Panel              PNL_SS
---@field opts PanelItem[]         the six option buttons
---@field res PanelItem
---@field speedButton PanelItem
---@field okay PanelItem
---@field cancel PanelItem
---@field sendMap PanelItem
---@field help PanelItem[]         the three hover help lines
---@field pointsBar PanelItem
---@field pointsText PanelItem
---@field mapInfo PanelItem
---@field chatLines PanelItem[]
---@field chatFrame PanelItem
---@field chatEdit PanelItem
---@field chatInput string?        network games: the chat line being typed
---@field chat string[]?           the last chat lines
---@field hero HeroProfile?        the profile record that plays (profile.current())
---@field players table<integer, LobbyPlayer>?   network games: the lobby's players by slot
---@field sidePanels SidePanel[]?
---@field humanSide integer?
---@field mustHumanSide integer?
---@field teamBackup table<integer, integer>?    the teams before a mode forced them
---@field setupSaved table?        the setup "I am the greatest" replaced
---@field box MsgBox?              a message box over the screen
---@field pointsHover boolean?
---@field pointsDrag boolean?
---@field readyHover integer?
---@field readyPressed integer?
---@field shieldQuads table<integer, love.Quad>?
---@field readyQuads table<integer, love.Quad>?
---@field startBlocked? fun(self: SkirmishScreen): boolean    network games: whether Start is greyed
---@field sendMapActive? fun(self: SkirmishScreen): boolean   network games: whether Send Map is active
---@field sendMapClicked? fun(self: SkirmishScreen)
local S = {}

S.helpId = 10          -- screen help (src/screens/screenhelp.lua)

local FOG = { "Fog of war", "Explored map", "No fog", "Hidden map" }
-- The fog / hidden map modes of the visibility cycler as { fogged, hidden } (the original has a button each).
local FOG_PARTS = { { true, true }, { true, false }, { false, false }, { false, true } }
local Victory = require("src.game.victory")
local MAX_POINTS = 50      -- the original's upper limit for army setup points
-- FUN_004f19f0: PNL_SIDESEL_SIDE0 at (22, 201), the next ones 31 px lower
local SIDE_X, SIDE_Y, SIDE_STEP = 22, 201, 31
-- the victory conditions that force the teams (victory choice 0x004dfec0): raze fest, slug fest,
-- fortress, king of the castle, rich get richer put everybody in team 0, against the horde side 0 in team 1, the rest team 2
local FORCES_TEAMS = { [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true }

-- AI level names: TXT_AI_LEVELS (XCI text 214, the strings carry the "AI: " prefix the side button shows)
local function levelName(l)
    return UI.text(214, l) or ({ "Passive", "Squire", "Knight", "Lord", "Prince", "Warlord", "Emperor", "Rampant" })[l + 1]
end
-- The AI levels a computer side offers (the seat drop-down callback 0x004eb110): a side that
-- is Passive in the scenario can be set to Passive .. Emperor, every other one to Squire .. Emperor; Rampant is not on
-- offer (the screen clamps the scenario's own level to Knight when it is above Warlord, see selectMap).
local function levelRange(sd) return sd.scnLevel == 0 and 0 or 1, 6 end
-- The custom AI scripts on offer: entry 1 is "None" (the original's listbox adds one),
-- then the scripts for the side's race plus the generic ones.
local function aiFiles(sd)
    return (type(sd.race) == "number" and aiparams.forRace(sd.race)) or aiparams.list()
end
local function raceName(r)
    if type(r) ~= "number" then return UI.text(83, 0) or "Random" end
    return (r < 8 and UI.text(15, r) or UI.text(104, r - 8)) or classes.RACE_NAMES[r] or "?"
end
-- The race a side starts with on the setup screen: the scenario's own (FUN_004e7760 copies the race of every SIDH record to
-- the side panel's race when a map is loaded; a locked race is fixed to it), Random for a value outside 0..15 and for the random
-- map (whose stub scenario has no races of its own: the panel code sets every side to Random).
local function scenarioRace(sd, m)
    local r = sd.race
    if m and m.random or type(r) ~= "number" or not content.race:bySlot(r) then return nil end
    return r
end
local function resName(r) return UI.text(102, r) or tostring(r) end

-- Names of the scenarios: <language>/scenario.cfg has "[SCEN_<file>]<tab><name>" lines (the scenario list
-- FUN_004072b0); a map without an entry shows its file name without the extension.
local function scenarioNames()
    local out = {}
    local data = fs.read(config.gamedir .. "/" .. (config.language or "English") .. "/scenario.cfg")
    for line in ((data or "") .. "\n"):gmatch("(.-)\r?\n") do
        local file, name = line:match("^%[SCEN_(.-)%]%s*(.-)%s*$")
        if file and name ~= "" then out[file:lower()] = text.fromCP1252(name) end
    end
    return out
end

---@return integer[]
function S:victories()
    local out = {}
    for v = 0, 12 do
        if not (v == 12 and not self.multiplayer) and not (v == 3 and self.opt.mods.noHeroes) then out[#out + 1] = v end
    end
    return out
end

---@param v integer
---@return string
function S:victoryNameOf(v)
    return (v < 8 and UI.text(172, v) or UI.text(173, v - 8)) or Victory.NAMES[v]
end

function S:victoryName()
    return self:victoryNameOf(self.opt.victory)
end

-- Keep level text of the drop-down (TXT_SS_BUILDING 0 = no building, 5 = "Keep level %d").
function S:techName()
    local t = self.opt.tech
    if t == 0 then return UI.text(174, 0) or "0" end
    return (UI.text(174, 5) or "%d"):format(t)
end

-- Tech levels on offer (the mode can raise the lower end).
function S:techLow()
    return (self.opt.victory == 1 or self.opt.victory == 4 or self.opt.victory == 6) and 1 or 0
end

-- Whether the tech level cannot be changed (the mode sets it, or the scenario locks it).
function S:techLocked()
    local v = self.opt.victory
    return v == 11 or v == 7 or v == 8 or self.opt.locks.tech == true
end

-- The visibility modes on offer: a scenario that locks fog of war or the hidden map keeps that part of the current mode
-- (the original has a button for each, FUN_004e3130).
---@return integer[]
function S:fogChoices()
    local o = self.opt
    local cur, out = FOG_PARTS[o.fog] or FOG_PARTS[1], {}
    for m = 1, #FOG do
        local p = FOG_PARTS[m]
        if (not o.locks.fog or p[1] == cur[1]) and (not o.locks.hidden or p[2] == cur[2]) then out[#out + 1] = m end
    end
    return out
end

function S:enter()
    self.sizeFilter, self.playerFilter = 4, 5          -- the size / player filters start at "any"
    -- fog, night, quests and points are overwritten from the map header by selectMap
    self.opt = { fog = 1, night = false, quests = true, points = 0, tech = 5, mods = {}, victory = 0, handicap = false,
                 locks = { mods = {} },       -- what the scenario locks: tech, fog, hidden, quests, points, handicap, mods
                 -- the advanced options (dialog "More options") and the game speed 0..4 the battle starts at; the setup
                 -- takes the speed of the options screen (set-up opener FUN_004e47e0; not traced in the 1.04 binary yet)
                 advanced = Advanced.enforce(gameopts.advanced(), self.multiplayer),
                 speed = math.max(0, math.min(4, tonumber(gameopts.get("gamespeed")) or 2)) }
    self.previews = {}
    self.sides = {}
    self:loadMaps()
    self:build()
    self.rm = require("src.ui.randompanel").new(self)          -- PNL_SS_RANDOMMAP, shown over the minimap for "Random Map"
    local last = config.get("skirmish", "map", "")
    for _, m in ipairs(self.maps) do if m.file == last then self.map = m end end
    self.map = self.map or self.maps[1]
    self:rebuild()
    self:selectMap()
    self.hero = profile.current()
end

function S:resume() music.play("intro") end

-- developer aid (--show skirmish:night starts the battle at night with an explored map)
function S:dev(sub)
    local function pick(file)
        for i, m in ipairs(self.shown) do if m.file == file then self:selectIndex(i) end end
    end
    if sub == "night" then
        self.opt.night, self.opt.fog = true, 2
        self:start()
    elseif sub == "greatest" then -- "I am the greatest" forcing the setup (not stored in openwbc3.ini)
        self.opt.advanced = Advanced.enforce({ greatest = true })
        self:storeSetup()
        self:applyGreatest()
    elseif sub == "advanced" then self:openAdvanced()
    elseif sub == "rules" then self:openRules()
    elseif sub == "locks" then pick("Eldritch Tower.SCN")     -- locks the team and resources of every side
    elseif sub == "tournament" then -- starts a Tournament mode battle (level 15 heroes, the level-up dialog opens at once)
        self.opt.advanced = Advanced.enforce({ tournament = true, points = 15 })
        self.opt.points = 0
        self:start()
    elseif sub == "flags" then pick("Dwarven Tunnels.SCN")    -- locked sides (side 0 must be human, sides on)
    elseif sub == "filter" then                                -- the 4 player maps of the large size
        self.sizeFilter, self.playerFilter = 2, 2
        self:rebuild()
        self:selectIndex(1)
    elseif sub == "seat" then self:seat(1)                     -- the player sits on the second side
    elseif sub == "ai" then self:chooseAI(1)
    elseif sub == "aihero" then   -- the AI hero panel with a chosen race / class / level, then the battle
        self.sides[1].aiHero = { race = 5, class = 13, level = 20 }
        self:start()
    end
end

-- Raw scenario file: the game's own, or one saved by the editor (user directory).
---@param m SkirmishMap
---@return string? data
---@return any ...
function S:mapData(m)
    if m.user then return require("src.game.editorlib").readUser(m.file) end
    return fs.read(config.gamedir .. "/" .. m.dir .. "/" .. m.file)
end

-- The parsed scenario of a map (cached), nil when it cannot be read.
---@param m SkirmishMap
---@return Scenario?
function S:scenario(m)
    if m.random and not m.scn then m.scn = require("src.game.randommap").stub() end
    if not m.scn then
        local data = self:mapData(m)
        m.scn = data and scnMod.parse(data) or false
    end
    return m.scn or nil
end

-- The minimap of a map as an image (cached), nil when it has none.
---@param m SkirmishMap
---@return love.Image?
function S:preview(m)
    local p = self.previews[m]
    if p ~= nil then return p or nil end
    local s = self:scenario(m)
    if not s or not s.minimap then self.previews[m] = false return nil end
    local img = love.image.newImageData(128, 128)
    local mm = s.minimap --[[@as string]]
    for y = 0, 127 do
        for x = 0, 127 do
            local o = (y * 128 + x) * 3 + 1
            local b, g, r = mm:byte(o, o + 2)
            img:setPixel(x, y, r / 255, g / 255, b / 255, 1)
        end
    end
    p = love.graphics.newImage(img)
    self.previews[m] = p
    return p
end

-- The human player of side i: { name, race } (in a network game the lobby player sitting there).
---@param i integer
---@return LobbyPlayer|{ name: string, race: integer? }|nil
function S:humanAt(i)
    if self.multiplayer then
        local sd = self.sides[i]
        return sd and sd.player ~= nil and self.players and self.players[sd.player] or nil
    end
    if i == self.humanSide and self.hero then return { name = self.hero.name, race = self.sides[i] and self.sides[i].race } end
end

-- Network games: the lobby slot of this machine's player (the host is 0), the seat it sits on, and whether side i is it.
---@return integer?
function S:mySlot() return 0 end

---@return integer?
function S:mySeat()
    if not self.multiplayer then return nil end
    for i = 0, 5 do
        local sd = self.sides[i]
        if sd and sd.player ~= nil and sd.player == self:mySlot() then return i end
    end
end

---@param i integer
---@return boolean
function S:isMine(i) return self.multiplayer == true and self:mySeat() == i end

-- Fresh player settings for the selected map.
function S:selectMap()
    local m = self.shown[self.sel] or self.map
    self.map = m
    self.sides = {}
    self.teamBackup = nil
    local s = m and self:scenario(m)
    if not s or not s.sides then return end
    -- the original takes the options from the map's header whenever a map is picked
    local ho = s.header and s.header.options
    if ho then
        local o = self.opt
        local fogged, hidden = ho.fog ~= 0, ho.hiddenMap
        o.fog = hidden and (fogged and 1 or 4) or (fogged and 2 or 3)
        o.night = ho.environment == 1
        o.quests = ho.quests
        o.tech = math.max(0, math.min(5, ho.techLevel or 5))
        o.mods = {}
        for k, v in pairs(ho.mods or {}) do o.mods[k] = v end
        o.points = math.max(0, math.min(MAX_POINTS, ho.armySetupPoints or 0))
        -- the scenario's locks (greyed buttons of FUN_004e3130); handicapping is forced off in a single player game
        -- (the map-finished handler FUN_004e7760; not traced in the 1.04 binary yet) and only the host of a network
        -- game can switch it
        o.locks = { tech = ho.techLocked, fog = ho.fogLocked, hidden = ho.hiddenLocked, quests = ho.questsLocked,
                    points = ho.pointsLocked, handicap = ho.handicapLocked, mods = {} }
        for k, v in pairs(ho.modLocks or {}) do o.locks.mods[k] = v end
        o.handicap = ho.handicapping == true and self.multiplayer == true
        o.victory = Victory.NAMES[ho.victory or 0] and ho.victory or 0
        if o.victory == 12 and not self.multiplayer then o.victory = 0 end
        o.oldTech, o.oldPoints, o.oldMods = nil, nil, nil
        local v = o.victory
        o.victory = 0
        self:setVictory(v)
    end
    for i = 0, 5 do
        local sd = s.sides[i]
        if sd and sd.used then
            -- the computer's level starts at the scenario's (a level above Warlord is taken as Knight, the map-finished
            -- handler FUN_004e7760; not traced in the 1.04 binary yet)
            local level = sd.aiLevel or 2
            if level < 0 or level > 5 then level = 2 end
            self.sides[i] = { used = true, closed = false, race = scenarioRace(sd, m), res = sd.resources or 2,
                              team = sd.team or 0, level = level, scnLevel = level,
                              -- the scenario can lock a side: its race, team, resources or computer level are fixed, it
                              -- cannot be closed, or it must be played by a human (the original greys the matching
                              -- button in the side selection screen, FUN_004ef650)
                              raceLocked = sd.raceLocked or nil, teamLocked = sd.teamLocked or nil,
                              resLocked = sd.resourcesLocked or nil, aiLocked = sd.aiLocked or nil,
                              mustBeOn = sd.mustBeOn or nil, mustBeHuman = sd.mustBeHuman or nil }
            if self.sides[i].res < 0 or self.sides[i].res > 4 then self.sides[i].res = 2 end
            -- a new map in a network game starts with every seat Open (the binary's map change handler FUN_004e0590
            -- zeroes the seat states at 0x00a498dc); a side the scenario says must be on cannot be Open, it stays a
            -- computer
            if self.multiplayer and not sd.mustBeOn then self.sides[i].open = true end
        end
    end
    -- the player sits on the side the scenario says must be human, otherwise on the first one
    self.mustHumanSide, self.humanSide = nil, nil
    for i = 0, 5 do
        if self.sides[i] and self.sides[i].mustBeHuman and not self.mustHumanSide then self.mustHumanSide = i end
    end
    for i = 0, 5 do
        if self.sides[i] then self.humanSide = self.humanSide or i end
    end
    self.humanSide = self.mustHumanSide or self.humanSide
    -- (the player's race is the seat's, like everybody's: he can change it unless the scenario locks it, and his hero keeps
    -- its own race, see the header comment of World:heroRaceOf)
    if self.multiplayer then self:seatAfterMapChange() end
    self:forceTeams(self.opt.victory)
    self:buildSides()
    self.setupSaved = nil
    if self.opt.advanced.greatest then self:storeSetup() self:applyGreatest() end
end

-- Network games: what happens to the players when the map (and with it every seat) changed (mphost.lua).
function S:seatAfterMapChange() end

-- "I am the greatest" forces the setup (scenario details FUN_004de4f0, game data FUN_004de740, map-finished handler
-- FUN_004e7760; the side panels' handler 0x004f2c90 locks them; not traced in the 1.04 binary yet): hidden map with
-- fog, no quests, 5 army setup points, tech level 5, standard victory, every game mod off but No Walls; the player is
-- side 0 alone in team 0 on very low resources, every other side is an Emperor computer in team 1 on very high
-- resources with a random race. What it replaces is kept so that switching the option off restores the setup (the
-- original keeps a copy of the scenario's setup).
function S:storeSetup()
    local o, saved = self.opt, { sides = {} }
    saved.opt = { fog = o.fog, night = o.night, quests = o.quests, points = o.points, tech = o.tech, victory = o.victory,
                  oldTech = o.oldTech, oldPoints = o.oldPoints, oldMods = o.oldMods, mods = {} }
    for k, v in pairs(o.mods) do saved.opt.mods[k] = v end
    for i, sd in pairs(self.sides) do
        local c = {}
        for k, v in pairs(sd) do c[k] = v end
        saved.sides[i] = c
    end
    self.setupSaved = saved
end

function S:applyGreatest()
    local o, G = self.opt, Advanced.GREATEST
    o.fog, o.quests, o.points, o.tech, o.victory = 1, G.quests, G.points, G.tech, G.victory
    o.oldTech, o.oldPoints, o.oldMods = nil, nil, nil
    o.mods = {}
    for k, v in pairs(G.mods) do o.mods[k] = v end
    -- the random map's settings are forced too (advanced options message handler FUN_004ea050; not traced in the 1.04
    -- binary yet)
    self.rm:force(true)
    for i, sd in pairs(self.sides) do
        sd.closed = false
        if sd.player == nil then sd.open = nil end
        if i == 0 then
            sd.res, sd.team, sd.race = Advanced.GREATEST_HUMAN.res, Advanced.GREATEST_HUMAN.team, nil
        else
            sd.res, sd.team, sd.level = Advanced.GREATEST_AI.res, Advanced.GREATEST_AI.team, Advanced.GREATEST_AI.level
            sd.race, sd.aiFile = nil, nil
        end
    end
end

function S:restoreSetup()
    local saved = self.setupSaved
    if not saved then return end
    for k, v in pairs(saved.opt) do self.opt[k] = v end
    self.rm:force(false)
    for i, c in pairs(saved.sides) do
        if self.sides[i] then self.sides[i] = c end
    end
    self.setupSaved = nil
end

-- Whether "I am the greatest" has locked the setup.
---@return boolean?
function S:locked() return self.opt.advanced.greatest end

-- The "More options" dialog (the host / single player edits, everybody else only looks).
function S:openAdvanced()
    screens.push(require("src.screens.advancedoptions"), {
        value = self.opt.advanced, speed = self.opt.speed, editable = self:canEditAdvanced(), single = not self.multiplayer,
        noHeroes = self.opt.mods.noHeroes,
        onDone = function(value, speed) self:setAdvanced(value, speed) end,
    })
end

---@return boolean
function S:canEditAdvanced() return true end

-- The "Rules..." dialog (PNL_SS_GAMEMODS): the seven game mods. Greyed boxes: what the scenario locks, Battle of Titans
-- (No Lords, No Heroes: the setup screen's own rule), No Heroes with the Assassin victory condition or Tournament mode.
function S:openRules()
    local o = self.opt
    local locked = {}
    for k, v in pairs(o.locks.mods) do locked[k] = v end
    if o.victory == 10 then locked.noLords, locked.noHeroes = true, true end
    if o.victory == 3 or o.advanced.tournament then locked.noHeroes = true end
    screens.push(require("src.screens.gamemods"), {
        mods = o.mods, locked = locked, editable = self:canEditAdvanced() and not self:locked(),
        onDone = function(mods) self:setMods(mods) end,
    })
end

---@param mods table<string, boolean>
function S:setMods(mods)
    for k, v in pairs(mods) do self.opt.mods[k] = v end
end

---@param value table the advanced options (game/advanced.lua)
---@param speed integer
function S:setAdvanced(value, speed)
    local was = self.opt.advanced.greatest
    self.opt.advanced, self.opt.speed = value, speed
    gameopts.setAdvanced(value)
    if value.greatest and not was then self:storeSetup() end
    if value.greatest then self:applyGreatest() elseif was then self:restoreSetup() end
end

-- The modes that force the teams back them up and restore them when another mode is picked
-- (the victory choice 0x004dfec0 keeps a backup of the teams and a flag that it is taken).
---@param v integer the victory condition
function S:forceTeams(v)
    local sides = self.sides or {}
    if FORCES_TEAMS[v] then
        if not self.teamBackup then
            self.teamBackup = {}
            for i, sd in pairs(sides) do self.teamBackup[i] = sd.team end
        end
        local first = true
        for i = 0, 5 do
            local sd = sides[i]
            if sd then
                sd.team = v == 9 and (first and 1 or 2) or 0
                first = false
            end
        end
    elseif self.teamBackup then
        for i, t in pairs(self.teamBackup) do if sides[i] then sides[i].team = t end end
        self.teamBackup = nil
    end
end

-- Picks a victory condition and applies what the original forces with it: Pitched Battle plays at tech level 0 with
-- 50 setup points, King of the Castle and Rich Get Richer at level 5, the raze / fortress modes need a keep level of at
-- least 1, Battle of Titans allows Titans and heroes. What was changed is restored when another mode is picked.
---@param v integer
function S:setVictory(v)
    local o = self.opt
    if v == o.victory then return end
    if o.victory == 10 and o.oldMods then
        o.mods.noLords, o.mods.noHeroes = o.oldMods.noLords, o.oldMods.noHeroes
        o.oldMods = nil
    end
    if o.oldPoints then o.points, o.oldPoints = o.oldPoints, nil end
    if o.oldTech then o.tech, o.oldTech = o.oldTech, nil end
    if v == 11 then
        o.oldPoints, o.oldTech = o.points, o.tech
        o.points, o.tech = MAX_POINTS, 0
    elseif v == 7 or v == 8 then
        o.oldTech, o.tech = o.tech, 5
    elseif (v == 1 or v == 4 or v == 6) and o.tech == 0 then
        o.oldTech, o.tech = 0, 1
    elseif v == 10 then
        o.oldMods = { noLords = o.mods.noLords, noHeroes = o.mods.noHeroes }
        o.mods.noLords, o.mods.noHeroes = false, false
    end
    self:forceTeams(v)
    o.victory = v
end

-- Layout and drawing -------------------------------------------------------------------------------------------

-- The six option buttons of PNL_SS in the original's order (top to bottom).
local VC, BUILDING, HIDDEN, FOW, HANDICAP, QUESTS = 1, 2, 3, 4, 5, 6

-- The maps on offer (the original's scenario list: the Scenario folder, sorted by name, plus the editor's maps).
function S:loadMaps()
    local names = scenarioNames()
    self.maps = {}
    for _, name in ipairs(fs.fileList(config.gamedir .. "/Scenario", "%.scn$")) do
        local label = names[name:lower()] or name:gsub("%.[sS][cC][nN]$", "")
        self.maps[#self.maps + 1] = { dir = "Scenario", file = name, label = label }
    end
    for _, f in ipairs(require("src.game.editorlib").userScenarios()) do
        self.maps[#self.maps + 1] = { dir = "scenarios", file = f, user = true, label = f:gsub("%.[sS][cC][nN]$", "") }
    end
    table.sort(self.maps, function(a, b) return a.label:lower() < b.label:lower() end)
    -- the list's first entry is the random map (the scenario list FUN_004072b0 puts it first), whatever the filters say
    table.insert(self.maps, 1, { dir = "random", file = "", random = true,
                                 label = require("src.game.strings").get("Game.txt", "0287") or "Random Map" })
    if #self.maps == 1 then log.error("no scenarios found") end
end

-- The list after the size / player count filters (the scenario list FUN_004072b0 / FUN_00407b10: widths 64 / 128 / 192
-- / 256, number of players).
function S:rebuild()
    self.shown = {}
    for _, m in ipairs(self.maps) do
        local s = self:scenario(m)
        local ok = s ~= nil
        if s and not m.random and self.sizeFilter < 4 and s.width ~= 64 * (self.sizeFilter + 1) then ok = false end
        if s and ok and not m.random and self.playerFilter < 5 and (s.header.numPlayers or 0) ~= self.playerFilter + 2 then
            ok = false
        end
        if ok then self.shown[#self.shown + 1] = m end
    end
    local names = {}
    for i, m in ipairs(self.shown) do names[i] = m.label end
    local sel = 1
    for i, m in ipairs(self.shown) do if m == self.map then sel = i end end
    self.sel = sel
    self.list:setItems(names, sel)
end

function S:build()
    local p = UI.panel("PNL_SS", { onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    for _, n in ipairs({ "BUTT_SS_FULLSCREEN", "BUTT_SS_MAPSIZE", "BUTT_SS_MAPPLAYERS", "IM_SS_MAPSIZE", "IM_SS_MAPPLAYERS",
                         "IM_STRATMAP_SIDESEL", "STR_SMALL120", "STR_MEDIUM332", "LB_SS_MAPS", "SBAR_V156B", "SBAR_H170" }) do
        p:hide(n)
    end
    local lb, bar = p:find("LB_SS_MAPS"), p:find("SBAR_V156B")
    ---@cast lb -nil
    ---@cast bar -nil
    self.list = listbox.new(lb.e.x, lb.e.y, lb.ob.w, lb.ob.h, bar.e.x, bar.e.y, bar.ob.h, lb.ob.fonts[1], lb.ob.fonts[2])
    self.opts = p:all("BUTT_SS_BUTTON")
    for _, it in ipairs(self.opts) do p.align[it] = "left" end
    -- (the items below are all on PNL_SS)
    self.res, self.speedButton = p:find("BUTT_SS_RES") --[[@as PanelItem]], p:find("BUTT_SS_GAMESPEED") --[[@as PanelItem]]
    p.align[self.res], p.align[self.speedButton] = "left", "left"
    self.okay, self.cancel = p:find("BUTT_OKAY_STARTUP") --[[@as PanelItem]], p:find("BUTT_CANCEL_STARTUP") --[[@as PanelItem]]
    p.itemStrings[self.okay], p.itemStrings[self.cancel] = "", ""
    self.sendMap = p:find("BUTT_SS_SENDMAP") --[[@as PanelItem]]
    self.help = p:all("STR_MEDIUM500")
    for _, it in ipairs(self.help) do p.align[it] = "center" end
    self.pointsBar, self.pointsText = p:find("SBAR_H170") --[[@as PanelItem]], p:find("STR_MEDIUM30") --[[@as PanelItem]]
    p.align[self.pointsText] = "center"
    self.mapInfo = p:find("STR_SMALL_450") --[[@as PanelItem]]
    self.chatLines = p:all("STR_SMALL500")
    self.chatFrame = p:find("IM_SS_MP_CHAT") --[[@as PanelItem]]
    self.chatEdit = p:find("EDIT_SIDESEL_CHAT") --[[@as PanelItem]]
    self.chatInput = self.multiplayer and "" or nil
    if not self.multiplayer then
        p:hideItem(self.chatFrame, true)
        p:hideItem(self.sendMap, true)
        p:hideItem(self.mapInfo, true)
        for _, it in ipairs(self.chatLines) do p:hideItem(it, true) end
    end
end

-- One PNL_SIDESEL_SIDEn per used side, stacked from (22, 201).
function S:buildSides()
    self.sidePanels = {}
    local row = 0
    for i = 0, 5 do
        if self.sides[i] then
            local sp = UI.panel("PNL_SIDESEL_SIDE" .. row, { x = SIDE_X, y = SIDE_Y + row * SIDE_STEP,
                onButton = function(name, it) self:sideButton(i, name, it) end }) --[[@as SidePanel]]
            sp:hide("IM_ICON_SHLDCLRS")
            sp:hideItem(sp:find("BUTT_SIDESEL_READY") --[[@as PanelItem]], true)
            for _, n in ipairs({ "BUTT_SIDESEL_PLAYER", "BUTT_SIDESEL_RACE", "BUTT_SIDESEL_RESOURCES" }) do
                sp.align[sp:find(n)] = "left"
            end
            sp.side = i
            self.sidePanels[#self.sidePanels + 1] = sp
            row = row + 1
        end
    end
end

-- Whether the setup can be changed by this player: single player and the host of a network game.
---@return boolean
function S:canEdit() return true end

-- Seat text and states of one side panel.
---@param sp SidePanel
function S:syncSide(sp)
    if self.multiplayer then return self:syncSideNet(sp) end
    local i = sp.side
    local sd = self.sides[i]
    local human = self:humanAt(i)
    local locked = self:locked()
    local player, race = sp:find("BUTT_SIDESEL_PLAYER"), sp:find("BUTT_SIDESEL_RACE")
    local res, shield = sp:find("BUTT_SIDESEL_RESOURCES"), sp:find("BUTT_SIDESEL_SHIELD")
    -- (every PNL_SIDESEL_SIDEn has the four buttons)
    ---@cast player -nil
    ---@cast race -nil
    ---@cast res -nil
    ---@cast shield -nil
    local forced = FORCES_TEAMS[self.opt.victory]
    if human then
        sp.itemStrings[player] = human.name
        sp.itemStrings[race] = raceName(sd.race)
    elseif sd.closed then
        sp.itemStrings[player] = UI.text(103, 1) or "Closed"
        sp.itemStrings[race] = ""
    else
        sp.itemStrings[player] = levelName(sd.level)
        sp.itemStrings[race] = raceName(sd.race)
    end
    sp.itemStrings[res] = sd.closed and "" or resName(sd.res)
    -- greyed: what the scenario or "I am the greatest" fixes, a closed seat's fields
    local editable = self:canEdit()
    local fixedSeat = (human ~= nil and (self.multiplayer or sd.mustBeHuman or self.humanSide == i))
        or (human == nil and sd.mustBeOn and sd.aiLocked)
    sp:setItemDisabled(player, (not editable) or locked or fixedSeat or false)
    sp:setItemDisabled(race, sd.closed or sd.raceLocked or locked or not editable or false)
    sp:setItemDisabled(res, sd.closed or sd.resLocked or locked or not editable or false)
    sp:setItemDisabled(shield, sd.closed or sd.teamLocked or locked or forced or not editable or false)
end

-- Seat text and states of one side panel in a network game (the panel refresh FUN_004ef650): an Open
-- seat shows "Open", the scenario's race and the resources greyed; the player sitting on a seat can change the
-- resources and the team of his own seat until he is ready (then everything of the seat is greyed); the host edits
-- the computer seats; a player without a seat may take an Open one.
---@param sp SidePanel
function S:syncSideNet(sp)
    local i = sp.side
    local sd = self.sides[i]
    local human = self:humanAt(i)
    local mine = self:isMine(i)
    local host, locked = self:canEdit(), self:locked()
    local player, race = sp:find("BUTT_SIDESEL_PLAYER"), sp:find("BUTT_SIDESEL_RACE")
    local res, shield = sp:find("BUTT_SIDESEL_RESOURCES"), sp:find("BUTT_SIDESEL_SHIELD")
    ---@cast player -nil
    ---@cast race -nil
    ---@cast res -nil
    ---@cast shield -nil
    local st = sp.itemStrings
    if human then
        -- the seat's own race (FUN_004ef650 shows the panel's race: the scenario's until the player picks another)
        st[player], st[race] = human.name, raceName(sd.race)
    elseif sd.closed then
        st[player], st[race] = UI.text(103, 1) or "Closed", ""
    elseif sd.open then
        st[player], st[race] = UI.text(103, 0) or "Open", raceName(sd.race)
    else
        st[player], st[race] = levelName(sd.level), raceName(sd.race)
    end
    st[res] = sd.closed and "" or resName(sd.res)
    local forced = FORCES_TEAMS[self.opt.victory]
    local mayEdit                                       -- may this machine change the seat's resources and team
    if human then mayEdit = mine and not human.ready
    else mayEdit = host and not sd.open and not sd.closed end
    local playerOff, raceOff
    if human then
        -- the host may remove another player from his seat (the player button of a human panel, answer callback
        -- 0x004ed610)
        if mine then playerOff = human.ready or locked else playerOff = not host or locked end
        raceOff = not mine or human.ready or sd.raceLocked or locked
    elseif host then playerOff = locked or (sd.mustBeOn and sd.aiLocked) or false
    else playerOff = locked or not sd.open or self:mySeat() ~= nil end
    sp:setItemDisabled(player, playerOff or false)
    if raceOff == nil then raceOff = sd.closed or sd.open or sd.raceLocked or locked or not host end
    sp:setItemDisabled(race, raceOff or false)
    sp:setItemDisabled(res, not mayEdit or sd.resLocked or locked or false)
    sp:setItemDisabled(shield, not mayEdit or sd.teamLocked or locked or forced or false)
end

-- The ready check box of a network seat: { checked, enabled } (FUN_004ef650: a computer seat is greyed and
-- checked, an Open / Closed one greyed and unchecked, a player's own box is active, everybody else's greyed).
---@param i integer
---@return boolean checked, boolean enabled
function S:readyBox(i)
    local sd = self.sides[i]
    local human = self:humanAt(i)
    if human then return human.ready == true, self:isMine(i) end
    if sd.closed or sd.open then return false, false end
    return true, false
end

-- The hover help of the three lines under the lists (what the original's hover handler FUN_004ead70 sets).
---@return string[]
function S:helpTexts()
    local o = self.opt
    local over = self.panel.hover
    local t = UI.text
    local lines = { "", "", "" }
    local function set(a, b, c) lines[1], lines[2], lines[3] = a or "", b or "", c or "" end
    local function fogPart(part) return (FOG_PARTS[o.fog] or FOG_PARTS[1])[part] end
    if over then
        local n = over.name
        local k
        for idx, it in ipairs(self.opts) do if it == over then k = idx end end
        if k == VC then
            local v = o.victory
            local l2, l3 = "", ""
            if v < 8 then l2 = t(196, v) or ""
            else
                l2 = t(197, v - 8) or ""
                if v == 11 then l3 = t(197, 4) or ""
                elseif v == 12 then l2, l3 = t(197, 6) or "", t(197, 7) or ""
                elseif v == 9 then l3 = t(197, 5) or ""
                elseif v == 10 then l3 = t(196, 0) or "" end
            end
            set(t(179, 0), l2, l3)
        elseif k == BUILDING then
            if o.tech == 0 then set(t(174, 0), t(174, 1))
            else
                local keep = (t(174, 2) or "") .. " " .. o.tech
                set(keep, t(174, 3), (t(174, 4) or "") .. " " .. keep)
            end
        elseif k == HIDDEN then
            if fogPart(2) then set(t(175, 2), t(175, 3), t(175, 4)) else set(t(175, 0), t(175, 1)) end
        elseif k == FOW then
            if fogPart(1) then set(t(176, 2), t(176, 3), t(176, 4)) else set(t(176, 0), t(176, 1)) end
        elseif k == HANDICAP then
            if self.multiplayer then
                if o.handicap then set(t(177, 0), t(177, 1), t(177, 2)) else set(t(177, 3), t(177, 4), t(177, 5)) end
            end
        elseif k == QUESTS then
            if o.quests then set(t(178, 0), t(178, 1), t(178, 2)) else set(t(178, 3), t(178, 4), t(178, 5)) end
        elseif n == "BUTT_SS_RES" then set(t(171, 6), t(171, 7))
        elseif n == "BUTT_SS_SENDMAP" then set(t(210, 0))
        elseif n == "BUTT_SS_ADVANCED_OPTIONS" then set(t(237, 0))
        elseif n == "BUTT_SS_GAMEMODS" then set(t(237, 1))
        end
    end
    if self.pointsHover then set(t(179, 3), t(179, 4), t(179, 5)) end
    for _, sp in ipairs(self.sidePanels or {}) do
        local h = sp.hover
        if h then
            local sd = self.sides[sp.side]
            local n = h.name
            if self:humanAt(sp.side) then
                if self.multiplayer and not self:isMine(sp.side) then
                    -- another player's seat: the host is told that a click removes the player (FUN_004ead70)
                    if self:canEdit() and n == "BUTT_SIDESEL_PLAYER" then set(t(207, 6)) end
                elseif n == "BUTT_SIDESEL_RACE" then set(t(207, 0))
                elseif n == "BUTT_SIDESEL_RESOURCES" then set(t(207, 1))
                elseif n == "BUTT_SIDESEL_SHIELD" then set(t(207, 4))
                elseif n == "BUTT_SIDESEL_PLAYER" then set(t(207, 7)) end
            elseif sd.open then
                -- FUN_004ead70: a player without a seat is told how to take it, the host
                -- how to put a computer there
                if n == "BUTT_SIDESEL_PLAYER" then
                    if self:canEdit() then set(t(209, 4)) elseif not self:mySeat() then set(t(209, 2)) end
                end
            elseif sd.closed then
                if n == "BUTT_SIDESEL_PLAYER" then set(t(209, 0)) end
            else
                if n == "BUTT_SIDESEL_PLAYER" then set(t(209, 5))
                elseif n == "BUTT_SIDESEL_RACE" then set(t(208, 0))
                elseif n == "BUTT_SIDESEL_RESOURCES" then set(t(208, 1))
                elseif n == "BUTT_SIDESEL_SHIELD" then set(t(208, 3)) end
            end
        end
    end
    if self.readyHover and self:isMine(self.readyHover) then set(t(207, 2)) end
    return lines
end

function S:syncPanel()
    local o, p = self.opt, self.panel
    local locked, edit = self:locked(), self:canEdit()
    local fogged, hidden = unpack(FOG_PARTS[o.fog] or FOG_PARTS[1])
    local st = p.itemStrings
    st[self.opts[VC]] = self:victoryName()
    st[self.opts[BUILDING]] = self:techName()
    st[self.opts[HIDDEN]] = UI.text(175, hidden and 2 or 0) or ""
    st[self.opts[FOW]] = UI.text(176, fogged and 2 or 0) or ""
    st[self.opts[HANDICAP]] = UI.text(177, o.handicap and 0 or 3) or ""
    st[self.opts[QUESTS]] = UI.text(178, o.quests and 0 or 3) or ""
    local fogFixed = #self:fogChoices() < 2
    p:setItemDisabled(self.opts[VC], locked or not edit)
    p:setItemDisabled(self.opts[BUILDING], self:techLocked() or locked or not edit)
    p:setItemDisabled(self.opts[HIDDEN], o.locks.hidden or locked or not edit or fogFixed or false)
    p:setItemDisabled(self.opts[FOW], o.locks.fog or locked or not edit or fogFixed or false)
    p:setItemDisabled(self.opts[HANDICAP], not self.multiplayer or o.locks.handicap or locked or not edit or false)
    p:setItemDisabled(self.opts[QUESTS], self.multiplayer or o.locks.quests or locked or not edit or false)
    local w, h = love.graphics.getDimensions()
    st[self.res] = w .. " x " .. h
    st[self.speedButton] = UI.text(212, o.speed) or tostring(o.speed)
    p:setItemDisabled(self.speedButton, not edit)
    st[self.pointsText] = tostring(o.points)
    local blocked = not self.hero or not self.map or not self:scenario(self.map) or (self.startBlocked and self:startBlocked())
    p:setItemDisabled(self.okay, blocked or not edit or false)
    p:setItemDisabled(self.sendMap, not (self.multiplayer and self.sendMapActive and self:sendMapActive()))
    -- being ready greys Cancel (BUTT_CANCEL_STARTUP; the ready box is case 0x7d of FUN_004eb4d0)
    p:setItemDisabled(self.cancel, self:cancelBlocked())
    local lines = self:helpTexts()
    for k, it in ipairs(self.help) do st[it] = lines[k] or "" end
    if self.multiplayer then
        local s = self.map and self:scenario(self.map)
        st[self.mapInfo] = s and ("%s  (%d x %d)"):format(self.map.label, s.width, s.height) or ""
        local chat = self.chat or {}
        for k, it in ipairs(self.chatLines) do st[it] = chat[#chat - #self.chatLines + k] or "" end
    end
    for _, sp in ipairs(self.sidePanels or {}) do self:syncSide(sp) end
end

---@return boolean
function S:cancelBlocked()
    local me = self.multiplayer and self:humanAt(self:mySeat() or -1)
    return me and me.ready or false
end

function S:pointsActive()
    local o = self.opt
    return self:canEdit() and not (o.victory == 11 or o.victory == 7 or o.locks.points or self:locked())
end

function S:pointsRect()
    local it = self.pointsBar
    return it.e.x, it.e.y, it.ob.w, it.ob.h
end

-- The filter buttons' icon sheets (SSMapSizeButton.bmp / SSMapPlayersButton.bmp: 32x32 frames, rows normal / hover /
-- greyed; the last column of each stands for "any").
local FILTER_SIZE = { x = 460, y = 3, w = 32, h = 32, bitmap = 477 }
local FILTER_PLAYERS = { x = 460, y = 134, w = 32, h = 32, bitmap = 478 }

local function inside(r, vx, vy) return vx >= r.x and vx < r.x + r.w and vy >= r.y and vy < r.y + r.h end

function S:drawFilter(f, value, mx, my)
    local img = UI.bitmap(f.bitmap)
    if not img then return end
    local row = (not self:canEdit()) and 2 or inside(f, mx, my) and 1 or 0
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, love.graphics.newQuad(value * 32, row * 32, 32, 32, img:getDimensions()), f.x, f.y)
end

function S:drawPreview()
    love.graphics.setColor(1, 1, 1)
    local p = self.map and self:preview(self.map)
    if p then love.graphics.draw(p, 29, 19) end
end

function S:drawShields()
    local img = UI.bitmap(35)
    if not img then return end
    local g = love.graphics
    local s = self.map and self:scenario(self.map)
    self.shieldQuads = self.shieldQuads or {}
    for _, sp in ipairs(self.sidePanels or {}) do
        local sd = self.sides[sp.side]
        if not sd.closed then
            local colour = s and s.sides[sp.side] and s.sides[sp.side].color or sp.side
            local key = colour * 4 + sd.team
            local q = self.shieldQuads[key]
            if not q then
                q = g.newQuad(colour * 25, sd.team * 20, 25, 20, img:getDimensions())
                self.shieldQuads[key] = q
            end
            g.setColor(1, 1, 1)
            g.draw(img, q, sp.x + 149, sp.y)
        end
    end
end

function S:drawPoints()
    local x, y, w = self:pointsRect()
    bars.hDraw(UI.bitmap(229), x, y, w, self.opt.points / MAX_POINTS, self:pointsActive(), true)
end

function S:draw()
    UI.begin()
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    self:syncPanel()
    self.panel:draw()
    self.list:draw(self:canEdit())
    self:drawFilter(FILTER_SIZE, self.sizeFilter, mx, my)
    self:drawFilter(FILTER_PLAYERS, self.playerFilter, mx, my)
    self:drawPreview()
    if self.map and self.map.random then self.rm:draw() end
    self:drawPoints()
    -- PNL_SS_COVERREADY (opened at 500, 160 in single player by FUN_004e4000): hides the "ready" column
    -- that only network games have
    if not self.multiplayer then
        local cover = UI.bitmap(631)
        if cover then love.graphics.setColor(1, 1, 1) love.graphics.draw(cover, 500, 160) end
    end
    for _, sp in ipairs(self.sidePanels or {}) do sp:draw() end
    if self.multiplayer then self:drawReadyBoxes(mx, my) end
    self:drawShields()
    if self.multiplayer then self:drawChatInput() end
    dropdown.draw()
    if self.box then self.box:draw() end
    UI.finish()
end

-- The ready check boxes (BUTT_SIDESEL_READY, 21 x 20 at (511, 3) of each side panel, bitmap 546: eight rows, unchecked
-- then checked, each normal / hover / pressed / greyed).
local READY_X, READY_Y, READY_W, READY_H = 511, 3, 21, 20

---@param sp SidePanel
---@return number x, number y, number w, number h
function S:readyRect(sp) return sp.x + READY_X, sp.y + READY_Y, READY_W, READY_H end

function S:drawReadyBoxes(mx, my)
    local img = UI.bitmap(546)
    if not img then return end
    local g = love.graphics
    g.setColor(1, 1, 1)
    for _, sp in ipairs(self.sidePanels or {}) do
        local checked, enabled = self:readyBox(sp.side)
        local x, y, w, h = self:readyRect(sp)
        local st = 3
        if enabled then
            st = 0
            if self.readyPressed == sp.side then st = 2 elseif inside({ x = x, y = y, w = w, h = h }, mx, my) then st = 1 end
        end
        local row = (checked and 4 or 0) + st
        self.readyQuads = self.readyQuads or {}
        local q = self.readyQuads[row]
        if not q then
            q = g.newQuad(0, row * h, w, h, img:getDimensions())
            self.readyQuads[row] = q
        end
        g.draw(img, q, x, y)
    end
end

-- The ready box under the mouse (side number) when it can be clicked.
---@return integer?
function S:readyAt(vx, vy)
    for _, sp in ipairs(self.sidePanels or {}) do
        local _, enabled = self:readyBox(sp.side)
        local x, y, w, h = self:readyRect(sp)
        if enabled and inside({ x = x, y = y, w = w, h = h }, vx, vy) then return sp.side end
    end
end

function S:drawChatInput()
    local e = self.chatEdit
    if not e or not self.chatInput then return end
    love.graphics.setColor(1, 1, 1)
    local s = self.chatInput .. ((love.timer.getTime() % 1 < 0.5) and "|" or "")
    fonts.print(2, s, e.e.x, e.e.y, "left", e.ob.w)
end

-- Actions ------------------------------------------------------------------------------------------------------

function S:save()
    local o = self.opt
    if self.map then config.set("skirmish", "map", self.map.file) end
    if self:canEdit() then require("src.ui.randompanel").store(self.rm.values) end
    config.save()
end

---@param i integer index into `shown`
function S:selectIndex(i)
    if not self.shown[i] then return end
    self.sel = i
    self.list.sel = i
    self.list:ensureVisible()
    self:selectMap()
end

---@param items string[]
---@param it PanelItem the button the drop-down opens under
---@param panel Panel
---@param onPick fun(index: integer)
function S:openMenu(items, it, panel, onPick)
    dropdown.open(items, panel.x + it.e.x, panel.y + it.e.y + it.ob.h, onPick)
end

---@param name string
---@param it PanelItem? the button (nil: Esc as Cancel)
function S:button(name, it)
    local o = self.opt
    if name == "BUTT_CANCEL_STARTUP" then
        if self:cancelBlocked() then return end
        self:save()
        screens.pop()
    elseif name == "BUTT_OKAY_STARTUP" then
        self:start()
    elseif name == "BUTT_SS_SENDMAP" then
        if self.sendMapClicked then self:sendMapClicked() end
    elseif name == "BUTT_SS_ADVANCED_OPTIONS" then
        self:openAdvanced()
    elseif name == "BUTT_SS_GAMEMODS" then
        self:openRules()
    elseif name == "BUTT_SS_GAMESPEED" then
        local items = {}
        for i = 0, 4 do items[#items + 1] = UI.text(212, i) or tostring(i) end
        self:openMenu(items, it --[[@as PanelItem]], self.panel, function(index) o.speed = index - 1 end)
    elseif name == "BUTT_SS_RES" then
        local options = require("src.screens.options")
        local modes, items = options.resolutions(), {}
        for i, m in ipairs(modes) do items[i] = m[1] .. " x " .. m[2] end
        self:openMenu(items, it --[[@as PanelItem]], self.panel, function(index)
            local m = modes[index]
            config.set("graphics", "fullscreen", false)
            config.set("graphics", "width", m[1])
            config.set("graphics", "height", m[2])
            options.applyWindow()
        end)
    elseif name == "BUTT_SS_BUTTON" then
        for k, b in ipairs(self.opts) do
            if b == it then self:optionMenu(k, it) end
        end
    end
end

function S:optionMenu(k, it)
    local o = self.opt
    if k == VC then
        local list, items = self:victories(), {}
        for i, v in ipairs(list) do items[i] = self:victoryNameOf(v) end
        self:openMenu(items, it, self.panel, function(index) self:setVictory(list[index]) end)
    elseif k == BUILDING then
        local low, items = self:techLow(), {}
        for t = low, 5 do items[#items + 1] = t == 0 and (UI.text(174, 0) or "0") or (UI.text(174, 5) or "%d"):format(t) end
        self:openMenu(items, it, self.panel, function(index) o.tech = low + index - 1 end)
    elseif k == HIDDEN or k == FOW then
        -- the two parts of the visibility mode: hidden / exposed map, fog / no fog
        local fogged, hidden = unpack(FOG_PARTS[o.fog] or FOG_PARTS[1])
        local items = k == HIDDEN and { UI.text(175, 0), UI.text(175, 2) } or { UI.text(176, 0), UI.text(176, 2) }
        self:openMenu(items, it, self.panel, function(index)
            if k == HIDDEN then hidden = index == 2 else fogged = index == 2 end
            for m, part in ipairs(FOG_PARTS) do
                if part[1] == fogged and part[2] == hidden then o.fog = m end
            end
        end)
    elseif k == HANDICAP then
        self:openMenu({ UI.text(177, 0), UI.text(177, 3) }, it, self.panel, function(index) o.handicap = index == 1 end)
    elseif k == QUESTS then
        self:openMenu({ UI.text(178, 0), UI.text(178, 3) }, it, self.panel, function(index) o.quests = index == 1 end)
    end
end

-- A click in a side panel (FUN_004eb4d0).
function S:sideButton(i, name, it)
    local sd = self.sides[i]
    local sp
    for _, p in ipairs(self.sidePanels) do if p.side == i then sp = p end end
    if name == "BUTT_SIDESEL_SHIELD" then
        self:setSide(i, "team", (sd.team + 1) % 4)
    elseif name == "BUTT_SIDESEL_RESOURCES" then
        local items = {}
        for r = 0, 4 do items[#items + 1] = resName(r) end
        self:openMenu(items, it, sp, function(index) self:setSide(i, "res", index - 1) end)
    elseif name == "BUTT_SIDESEL_RACE" then
        local items, slots = {}, classes.raceSlots()
        for _, r in ipairs(slots) do items[#items + 1] = raceName(r) end
        items[#items + 1] = raceName(nil)
        self:openMenu(items, it, sp, function(index)
            local r = slots[index]
            if self.multiplayer and self:humanAt(i) then return self:setSide(i, "race", r or -1) end   -- the player's own seat
            sd.race = r
            sd.aiFile = nil         -- the race callback clears the side's AI script (0x004eb030)
        end)
    elseif name == "BUTT_SIDESEL_PLAYER" then
        self:seatMenu(i, it, sp)
    end
end

-- The resources / team of a seat changed by this machine's player (the joined player's screen sends it to the host).
---@param i integer
---@param field "res"|"team"|"race"
---@param value integer
function S:setSide(i, field, value)
    local v = value ---@type integer?
    if field == "race" then v = value >= 0 and value or nil end          -- -1 is Random
    self.sides[i][field] = v
end

-- The seat's drop-down: your name (a seat to play on), the computer levels, closed (callback 0x004eb110).
-- In a network game it also offers Open, and a player without the host's rights takes / leaves a seat with a click.
function S:seatMenu(i, it, sp)
    local sd = self.sides[i]
    if self.multiplayer then return self:netSeatMenu(i, it, sp) end
    local items, acts = {}, {}
    local function add(label, fn) items[#items + 1] = label acts[#acts + 1] = fn end
    if not self.multiplayer and self.humanSide ~= i and not self.mustHumanSide and self.hero then
        add(self.hero.name, function() self:seat(i) end)
    end
    if sd.aiLocked then
        add(levelName(sd.scnLevel), function() sd.closed, sd.level = false, sd.scnLevel end)
    else
        local lo, hi = levelRange(sd)
        for l = lo, hi do add(levelName(l), function() sd.closed, sd.level = false, l end) end
    end
    if not sd.mustBeOn then add(UI.text(103, 1) or "Closed", function() sd.closed = true end) end
    self:openMenu(items, it, sp, function(index) acts[index]() end)
end

-- The player sits on side i; the seat left becomes a computer again.
function S:seat(i)
    local old = self.sides[self.humanSide]
    if old then old.closed = false end
    self.humanSide = i
    local sd = self.sides[i]
    sd.closed = false
end

-- Network seats. The host's drop-down (callback 0x004eb110): your name when you have no seat or this is it,
-- the computer levels, Open and Closed (the last two not for a side the scenario says must be on). A joined player has
-- no drop-down: a click on an Open seat asks the host for it (message 3036), a click on his own seat gives
-- it up again (the button cycles to Open, FUN_004eb4d0).
function S:netSeatMenu(i, it, sp)
    local sd = self.sides[i]
    local mine = self:isMine(i)
    if not self:canEdit() then
        if mine then self:leaveSeat() elseif sd.open and not self:mySeat() then self:takeSeat(i) end
        return
    end
    if self:humanAt(i) and not mine then return self:bootClicked(i) end
    local items, acts = {}, {}
    local function add(label, fn) items[#items + 1] = label acts[#acts + 1] = fn end
    if mine or not self:mySeat() then add(self.hero.name, function() if not mine then self:takeSeat(i) end end) end
    if sd.aiLocked then
        add(levelName(sd.scnLevel), function() self:setSeatKind(i, "ai", sd.scnLevel) end)
    else
        local lo, hi = levelRange(sd)
        for l = lo, hi do add(levelName(l), function() self:setSeatKind(i, "ai", l) end) end
    end
    if not sd.mustBeOn then
        add(UI.text(103, 0) or "Open", function() self:setSeatKind(i, "open") end)
        add(UI.text(103, 1) or "Closed", function() self:setSeatKind(i, "closed") end)
    end
    self:openMenu(items, it, sp, function(index) acts[index]() end)
end

-- The seat actions of a network lobby (mphost.lua does them, mpjoin.lua asks the host).
---@param i integer
function S:takeSeat(i) end
function S:leaveSeat() end
---@param i integer
---@param kind "ai"|"open"|"closed"
---@param level integer?
function S:setSeatKind(i, kind, level) end
---@param i integer
function S:bootClicked(i) end
---@param i integer
function S:readyClicked(i) end

-- Right click on a computer side: the AI hero panel (race, class, level, AI script of its hero).
function S:chooseAI(i)
    local sd = self.sides[i]
    if not sd or sd.closed or self:humanAt(i) or self:locked() or not self:canEdit() then return end
    local hero = self.hero and self.hero.hero
    screens.push(require("src.screens.aihero"), {
        hero = sd.aiHero or {}, file = sd.aiFile, files = aiFiles(sd),
        sideRace = type(sd.race) == "number" and sd.race or nil, heroLevel = hero and hero.level or 1,
        onDone = function(h, file) sd.aiHero, sd.aiFile = aihero.clean(h), file end })
end

-- Input ----------------------------------------------------------------------------------------------------------

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then self.box:mousemoved(vx, vy) return end
    self.readyHover = self.multiplayer and self:readyAt(vx, vy) or nil
    self.list:drag(vx, vy)
    if self.pointsDrag then self:setPoints(vx) end
    self.panel:mousemoved(vx, vy)
    if self.map and self.map.random then self.rm:mousemoved(vx, vy) end
    for _, sp in ipairs(self.sidePanels or {}) do sp:mousemoved(vx, vy) end
    local bx, by, bw, bh = self:pointsRect()
    self.pointsHover = vx >= bx and vx < bx + bw and vy >= by and vy < by + bh
end

function S:setPoints(vx)
    local x, _, w = self:pointsRect()
    self.opt.points = math.floor(bars.hPos(x, w, vx) * MAX_POINTS + 0.5)
end

local function click() require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav") end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then self.box:mousepressed(vx, vy, button) return end
    if dropdown.pressed(vx, vy) then return end
    if button == 1 and self.multiplayer then
        local r = self:readyAt(vx, vy)
        if r then self.readyPressed = r return end
    end
    if button == 2 then
        for _, sp in ipairs(self.sidePanels or {}) do
            if vx >= sp.x and vx < sp.x + 540 and vy >= sp.y and vy < sp.y + 23 then self:chooseAI(sp.side) return end
        end
        return
    end
    if button ~= 1 then return end
    if self:canEdit() then
        local i = self.list:press(vx, vy)
        if i then click() self:selectIndex(i) return end
        if self.list.dragging then return end
        if inside(FILTER_SIZE, vx, vy) then
            click()
            self.sizeFilter = (self.sizeFilter + 1) % 5
            self:rebuild() self:selectIndex(self.sel)
            return
        elseif inside(FILTER_PLAYERS, vx, vy) then
            click()
            self.playerFilter = (self.playerFilter + 1) % 6
            self:rebuild() self:selectIndex(self.sel)
            return
        end
        if self:pointsActive() then
            local bx, by, bw, bh = self:pointsRect()
            if vx >= bx and vx < bx + bw and vy >= by and vy < by + bh then
                click()
                local part = bars.hHit(bx, by, bw, bh, vx, vy)
                if part == "left" then self.opt.points = math.max(0, self.opt.points - 1)
                elseif part == "right" then self.opt.points = math.min(MAX_POINTS, self.opt.points + 1)
                else self.pointsDrag = true self:setPoints(vx) end
                return
            end
        end
    end
    if self.map and self.map.random and self.rm:mousepressed(vx, vy, button) then return end
    if self.panel:mousepressed(vx, vy, button) then return end
    for _, sp in ipairs(self.sidePanels or {}) do sp:mousepressed(vx, vy, button) end
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.box then self.box:mousereleased(vx, vy, button) return end
    if self.readyPressed then
        local was = self.readyPressed --[[@as integer]]
        self.readyPressed = nil
        if self:readyAt(vx, vy) == was then click() self:readyClicked(was) end
        return
    end
    self.list:release()
    self.pointsDrag = false
    self.panel:mousereleased(vx, vy, button)
    self.rm:mousereleased(vx, vy, button)
    for _, sp in ipairs(self.sidePanels or {}) do sp:mousereleased(vx, vy, button) end
end

function S:wheelmoved(_, dy)
    if not self.box then self.list:wheel(dy) end
end

function S:textinput(t)
    if self.box then return end
    if self.multiplayer and self.chatInput then self.chatInput = self.chatInput .. t end
end

function S:keypressed(key)
    if self.box then self.box:keypressed(key) return end
    if dropdown.isOpen() then dropdown.close() return end
    if self.multiplayer and self.chatInput and (key == "backspace" or key == "return" or key == "kpenter") then
        if key == "backspace" then self.chatInput = self.chatInput:sub(1, -2)
        else
            local line = self.chatInput
            self.chatInput = ""
            if line ~= "" then self:submitChat(line) end
        end
        return
    end
    local n = #self.shown
    if key == "up" and self.sel > 1 then self:selectIndex(self.sel - 1)
    elseif key == "down" and self.sel < n then self:selectIndex(self.sel + 1)
    elseif key == "pageup" then self:selectIndex(math.max(1, self.sel - self.list:rows()))
    elseif key == "pagedown" then self:selectIndex(math.min(n, self.sel + self.list:rows()))
    elseif key == "return" or key == "kpenter" then self:start()
    elseif key == "escape" then self:button("BUTT_CANCEL_STARTUP") end
end

-- A chat line typed in the lobby (the host / join screens override this to send it).
---@param line string
function S:submitChat(line)
    self:addChat(line)
end

-- A line arrived in the chat area (FUN_004e1e80): the click sound, each of the last three lines is cut until it
-- is at most 325 px wide (the original shortens the line by its last character while it is longer).
---@param line string
function S:addChat(line)
    self.chat = self.chat or {}
    while #line > 0 and fonts.width(self.chatLines[1].ob.font or 2, line) > 325 do line = line:gsub("[%z\1-\127\194-\244][\128-\191]*$", "") end
    self.chat[#self.chat + 1] = line
    if #self.chat > 3 then table.remove(self.chat, 1) end
    require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
end

function S:update(dt) music.update() end

function S:leave() dropdown.close() end

-- Starting ----------------------------------------------------------------------------------------------------

function S:start()
    local m = self.map
    local scn = m and self:scenario(m)
    if not scn or not self.hero then return end
    ---@cast m -nil
    -- the scenario is parsed fresh so repeated starts don't inherit the changes (the file was read before)
    scn = (m.random and require("src.game.randommap").stub() or scnMod.parse(self:mapData(m) --[[@as string]])) --[[@as Scenario]]
    for i = 0, 5 do
        local sd = scn.sides[i]
        local set = self.sides[i]
        if sd and set then
            local human = self:humanAt(i)
            sd.used = (set.mustBeOn and true) or human ~= nil or not (set.closed or set.open)
            -- every seat plays the race of its panel, a human's too (FUN_004de740 copies the panel's race to the side and
            -- draws Random then; the host sends the result to everybody). A locked race is the scenario's own (the panel
            -- cannot change it); the hero keeps its race either way (World:heroRaceOf)
            sd.race = type(set.race) == "number" and set.race or math.random(0, 15)
            sd.resources = set.res
            sd.team = set.team
            sd.aiLevel = set.level
            sd.aiFile = set.aiFile
            sd.aiHero = not human and aihero.clean(set.aiHero) or nil
        end
    end
    self:save()
    local o = self.opt
    if scn.header and scn.header.options then
        scn.header.options.techLevel, scn.header.options.mods = o.tech, o.mods     -- the rules text shows them
    end
    local random = m.random and self.rm:build(scn, o) or nil      -- builds the map (what every peer repeats from the seed)
    self:launch(scn, {
        random = random,
        techLevel = o.tech, mods = o.mods, victory = Victory.NAMES[o.victory],
        resurrect = config.get("skirmish", "resurrect", false) == true,
        profile = true,
        scnPath = m.dir .. "/" .. m.file,
        startPoints = o.points, handicap = o.handicap and self.multiplayer == true, quests = o.quests, night = o.night,
        fogMode = FOG[o.fog] and o.fog or 1,
        advanced = o.advanced, gameSpeed = o.speed,
        player = (not self.multiplayer) and self.humanSide or nil,
    })
end

-- Tournament mode: the player makes a temporary hero first (screens/tournamenthero.lua, the original's creation screen
-- FUN_0054b040 with the temporary flag and the points after the start), then the game goes on with
-- `opts.tournamentRec`.
---@param opts table
---@param onDone fun(rec: table)
function S:tournamentHero(opts, onDone)
    screens.push(require("src.screens.tournamenthero"), onDone, opts.advanced.points)
end

-- Starts the battle (after the army setup when there are setup points).
---@param scn table the parsed scenario
---@param opts table the battle's options (screens/battle.lua)
function S:launch(scn, opts)
    local battle = require("src.screens.battle")
    local human = self:humanAt(self.humanSide or 0)
    if human and not opts.tournamentRec and require("src.game.advanced").tournamentGame(opts.advanced, opts.mods) then
        return self:tournamentHero(opts, function(rec)
            opts.tournamentRec = rec
            self:launch(scn, opts)
        end)
    end
    -- the player's hero keeps its own race whatever race the seat plays (not a Tournament hero: it is made for the seat)
    if human and not self.multiplayer and not opts.tournamentRec then opts.heroRace = profile.current().race end
    if not human or (opts.startPoints or 0) <= 0 then
        screens.push(battle, scn, opts)
        return
    end
    -- the army setup: regular troops and the hero's retinue are bought with the setup points (army setup opener
    -- FUN_00440b40: the points are capped at 100; the Charisma bonus and the Diplomacy skill add nothing in the 1.04
    -- binary)
    local retinue = require("src.game.retinue")
    local rec = opts.tournamentRec or profile.current()
    screens.push(require("src.screens.armysetup"), {
        mode = "select", race = scn.sides[self.humanSide or 0].race, points = math.min(retinue.MAX_POINTS, opts.startPoints),
        techLevel = require("src.game.victory").get(opts.victory, "pitched") and 0 or opts.techLevel,
        slots = retinue.slotsOf(rec), retinue = retinue.get(rec), graveyard = retinue.graveyard(rec),
        onDone = function(result)
            opts.army, opts.retinue = result.army, result.retinue
            screens.push(battle, scn, opts)
        end,
    })
end

return S
