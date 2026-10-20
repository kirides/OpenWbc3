-- In-battle interface built from the original bitmaps: the control panel
-- (Panel_800.bmp) with minimap, hero area, info area and 3x3 command
-- buttons, the resource/army-limit counters at the top and the production /
-- construction dialog.
--
-- Everything is laid out in the original 800x600 coordinates and scaled by
-- `s` = window height / 600; the panel is centred and the sides are filled
-- with Panel_Extension.bmp.
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")
local anims = require("src.gfx.anims")
local fonts = require("src.ui.fonts")
local gamedata = require("src.game.gamedata")
local rules = require("src.game.rules")
local unitMod = require("src.game.unit")
local economy = require("src.game.economy")
local spells = require("src.game.spells")
local powerups = require("src.game.powerups")
local attitudes = require("src.game.attitude")
local abilities = require("src.game.buildingabilities")
local armyabilities = require("src.game.armyabilities")
local formation = require("src.game.formation")
local status = require("src.game.status")
local heroMod = require("src.game.hero")
local heroBonus = require("src.game.herobonus")
local classes = require("src.game.classes")
local UI = require("src.ui.interface")
local spellbar = require("src.ui.spellbar")
local sound = require("src.audio.sound")
local strings = require("src.game.strings")
local widgets = require("src.ui.widgets")
local walls = require("src.game.walls")

local M = {}

local CPI = { STOP = 1, MOVE = 2, ATTACK = 3, PATROL = 4, GUARD = 5, CONVERT = 6, PRODUCTION = 7, SPELL = 8, PREVIOUS = 16,
              REPAIR = 17, FORMATIONS = 18, RALLY = 19, ATTITUDE = 21, BUILD = 31, WALL = 33, FORMATION_BLOCK = 34 }
M.CPI = CPI
-- command -> control panel icon, reported to the scenario's button events (the tutorial waits for them)
local ACTION_ICON = { stop = CPI.STOP, move = CPI.MOVE, attack = CPI.ATTACK, convert = CPI.CONVERT,
                      production = CPI.PRODUCTION, build = CPI.BUILD, walls = CPI.WALL, rally = CPI.RALLY,
                      repair = CPI.REPAIR, spells = CPI.SPELL }

local bitmaps = {}

---@param name string Name/Path of a bitmap file in the VFS. Case-Sensitive.
---@return love.Image|nil
local function bitmap(name)
    local b = bitmaps[name]
    if b == nil then
        local data = vfs.find(name)
        b = false
        if data then
            local ok, img = pcall(bmp.image, data, { key = true })
            if ok and img then b = img end
        end
        bitmaps[name] = b
    end
    return b or nil
end
M.bitmap = bitmap

local quads = {}

---@return love.Quad
local function quad(img, x, y, w, h)
    local key = tostring(img) .. x .. ":" .. y .. ":" .. w .. ":" .. h
    local q = quads[key]
    if not q then
        q = love.graphics.newQuad(x, y, w, h, img:getDimensions())
        quads[key] = q
    end
    return q
end
local function blit(name, sx, sy, w, h, dx, dy)
    local img = bitmap(name)
    if img then love.graphics.draw(img, quad(img, sx, sy, w, h), dx, dy) end
end

-- sprite digits (ERNX) and counter backgrounds (ERIX rows)
local function drawNumber(n, x, y)
    local set = anims.get("ERNX")
    if not set then return end
    local s = tostring(math.max(0, math.floor(n)))
    for i = 1, #s do
        local c = s:sub(i, i)
        local f = c == "/" and 10 or (c == ":" and 11 or tonumber(c))
        if f then set:drawCell(0, 0, f, x + (i - 1) * 7, y) end
    end
end

local function drawNumberCentred(n, cx, y)
    local w = #tostring(math.max(0, math.floor(n))) * 7
    drawNumber(n, math.floor(cx - w / 2), y)
end

local function drawCounter(row, x, y, w)
    local set = anims.get("ERIX")
    if not set then return end
    local rec = set:image(0, nil)
    if not rec then return end
    love.graphics.draw(rec.image, quad(rec.image, 0, row * 20, w or 60, 20), x, y)
end

---@class HUDCommand        a button of the 3x3 command grid (HUD:commands)
---@field icon integer         CPI icon (row of Panel_Icons.bmp + 1)
---@field action string        what HUD:runCommand does ("stop", "formation:3", "ability:<id>" ...)
---@field tip string?
---@field disabled boolean?

---@class HUDPanelButton      a round button of the control panel (PBUTTONS)
---@field id "hero"|"skills"|"pause"|"menu"
---@field x integer
---@field y integer
---@field row integer          row of Panel_Menu.bmp
---@field tip string

---@class HUDOverlay          a tutorial text box with a pointer line over the production / construction dialog
---@field x number
---@field y number
---@field corner integer       1: the line starts at the right edge
---@field tx number            where the line points
---@field ty number
---@field lines string[]
---@field w number
---@field h number

-- The open dialog over the battle, one class per kind.
---@alias HUDDialog
---| HUDProductionDialog
---| HUDBuildDialog
---| HUDRepairDialog
---| HUDTradeDialog
---| HUDDiplomacyDialog
---| HUDAttitudeDialog

---@class HUDProductionDialog
---@field kind "production"
---@field building Building
---@field overlay HUDOverlay?  a tutorial overlay

---@class HUDBuildDialog      construction
---@field kind "build"
---@field builder Unit
---@field row integer          0 buildings, 1 walls
---@field overlay HUDOverlay?

---@class HUDRepairDialog
---@field kind "repair"
---@field building Building

---@class HUDTradeDialog      the market
---@field kind "trade"
---@field building Building

---@class HUDDiplomacyDialog  gifts to another side
---@field kind "diplomacy"
---@field amount integer?      the chosen amount (index of economy.GIFT_AMOUNTS - 1)
---@field res integer?         the chosen resource (key of economy.GIFT_RESOURCES)
---@field side integer?        the receiving side
---@field sent boolean?

---@class HUDAttitudeDialog   the attitude list popup
---@field kind "attitude"
---@field list string[]        the attitude ids on offer
---@field x number             position in the layout
---@field y number

---@class HUDTutorial         the open tutorial dialog
---@field name string
---@field lines string[]
---@field flag integer?        scenario flag set when it is closed
---@field picture love.Image?
---@field cancelDown boolean?  the close button is held

-- The battle's control panel; one per battle screen. Window positions are pixels, layout positions the panel's
-- 800x600 coordinates (HUD:toLayout).
---@class HUD
---@field screen BattleScreen
---@field mode string?         a pending map click: "move", "attack", "patrol", "guard", "rally", "spell", "place",
---                            "convert", or the command panels "buildmenu" / "formations"
---@field dialog HUDDialog?
---@field tutorial HUDTutorial?
---@field base number          window scale of the map (without the UI scale option)
---@field s number             interface scale (layout -> window)
---@field ox number            window position of the layout's origin
---@field oy number
---@field W number             window size
---@field H number
---@field mapBottom number     window y where the panel body starts
---@field previewX number      layout x of the hovered-unit preview
---@field previewVisible boolean
---@field hoverEntity (Unit|Building)?  under the mouse on the map (feeds the preview)
---@field hoverButton integer? command button under the mouse (0..8)
---@field pressedButton integer?
---@field hoverPanel HUDPanelButton?
---@field pressedPanel HUDPanelButton?
---@field hoverSpell integer?  spell bar: the spell under the mouse
---@field overPortrait boolean?
---@field miniDrag boolean?    the minimap is being dragged
---@field infoPage integer?    right-click page of the info area (stats / overview / skills)
---@field guardAttitude string?  mode "guard": the designating attitude chosen in the attitude dialog
---@field spellId integer?     mode "spell": the spell waiting for its target
---@field placeCode string?    mode "place": the building to place
---@field placeBuilder Unit?   mode "place": who builds it
---@field spellPage integer?   page of the spell bar (spellbar.lua)
---@field dialogHover integer? production / build dialog: the item under the mouse
---@field dialogTip {code: string, info: table?, legal: boolean}?
---@field cancelHover boolean?
local HUD = {}
HUD.__index = HUD

---@param screen BattleScreen
---@return HUD
function M.new(screen)
    local self = setmetatable({ screen = screen, mode = nil, hoverButton = nil, dialog = nil }, HUD)
    return self --[[@as HUD]]
end

-- Layout -------------------------------------------------------------------------

-- Updates the scale and the panel's place for the current window size; returns the interface scale.
---@return number s
function HUD:layout()
    local W, H = love.graphics.getDimensions()
    local s = H / 600
    if 800 * s > W then s = W / 800 end
    self.base = s -- the map scales with the window only, not with the UI scale option
    s = s * require("src.ui.interface").userScale()
    self.s = s
    self.ox = math.floor((W - 800 * s) / 2)
    self.oy = H - 600 * s
    self.W, self.H = W, H
    -- map view ends where the panel body starts (layout y = 450)
    self.mapBottom = math.floor(self.oy + 450 * s)
    -- the hovered-unit preview sits in the first extension tile right of the panel
    -- (Panel_Extension.bmp is 128 wide); it needs the whole area to be on screen
    self.previewX = 813
    self.previewVisible = self.ox + 914 * s <= self.W
    return s
end

-- window -> layout coordinates (panel space)
---@param x number
---@param y number
---@return number lx
---@return number ly
function HUD:toLayout(x, y)
    return (x - self.ox) / self.s, (y - self.oy) / self.s
end

---@return boolean
function HUD:overPanel(x, y)
    local lx, ly = self:toLayout(x, y)
    if ly >= 450 then return true end
    -- horns: opaque pixels of Panel_800 above the body
    return false
end

-- Selection helpers ----------------------------------------------------------------

---@return (Unit|Building)[]
function HUD:selection() return self.screen.selection end

---@return Unit[]
function HUD:selectedOwnUnits()
    local out = {}
    for _, e in ipairs(self:selection()) do
        if e.kind == "unit" and e.side == self.screen.world.player then out[#out + 1] = e end
    end
    return out
end

-- Who can build: the original shows the BUILD button when the army's build power (FUN_00523e10) is above 0, the
-- BUILDING power of the type record (heroes count as 10) plus the Zombie Feast's bonus (button setup FUN_004d3200).
---@param u Unit
---@return boolean
function HUD:isBuilder(u)
    return powerups.buildSkill(u) > 0
end

-- The selected-units bar: an 8x4 grid of 29x29 cells. Big units are placed first (the original's group page of
-- FUN_004d7710 and the slot lookup FUN_00531830):
-- a unit's footprint comes from its type's unitValue (<=1 one cell, 2 one column x two rows,
-- >=4 two by two), and the ring around it is the matching region of SelectionRings.bmp.
---@return table<integer, Unit> cells   cell index (0..31, row-major 8 wide) -> unit
---@return {u: Unit, i: integer, w: integer, h: integer}[] place
function HUD:unitBar()
    local units = self:selectedOwnUnits()
    local cells, place = {}, {}
    local function cat(u)
        local uv = (u.type and u.type.unitValue) or 1
        if uv >= 4 then return 4 elseif uv == 2 then return 2 else return 1 end
    end
    local n = 0
    for _, want in ipairs({ 4, 2, 1 }) do
        for _, u in ipairs(units) do
            if cat(u) == want then
                while n < 32 and cells[n] do n = n + 1 end
                if n >= 32 then return cells, place end
                local w, h = 1, 1
                if want == 4 then w, h = 2, 2 elseif want == 2 then h = 2 end
                local i = n
                cells[i] = u
                if w == 2 then cells[i + 1] = u end
                if h == 2 then cells[i + 8] = u; if w == 2 then cells[i + 9] = u end end
                n = n + (want == 4 and 2 or 1)
                place[#place + 1] = { u = u, i = i, w = w, h = h }
            end
        end
    end
    return cells, place
end

-- Source rectangle of the ring for a unit in SelectionRings.bmp: the box type (gold for heroes)
-- and the health level pick the cell; the size follows the unitValue footprint.
local function unitRing(u)
    local hl = math.max(0, math.min(7, math.floor((15 - math.floor(15 * u.hp / math.max(1, u.maxHp))) / 2)))
    local bt = (u.hero or (u.level or 0) >= 4) and 1 or 0       -- the gold box: heroes and veterans (level 4 and up)
    local uv = (u.type and u.type.unitValue) or 1
    if uv >= 4 then
        return 168 + bt * 112 + math.floor(hl / 4) * 56, 491 + (hl % 4) * 56, 56, 56
    elseif uv == 2 then
        return 56 + bt * 56 + math.floor(hl / 4) * 28, 491 + (hl % 4) * 56, 28, 56
    else
        return bt * 28, 491 + hl * 28, 28, 28
    end
end

-- The 3x3 command grid for the current selection: list of {icon, action}.
---@return table<integer, HUDCommand>  slot 1..9 (gaps are empty buttons)
function HUD:commands()
    local sel = self:selection()
    local world = self.screen.world
    local cmds = {}
    if self.mode == "buildmenu" then
        cmds[1] = { icon = CPI.PREVIOUS, action = "previous" }
        return cmds
    end
    local first = sel[1]
    if not first then return cmds end
    if first.kind == "unit" and first.side == world.player then
        local units = self:selectedOwnUnits()
        local group = #units > 1
        if self.mode == "formations" and group then
            -- formation panel: the eight formations and Previous
            for i, kind in ipairs(formation.KINDS) do
                cmds[i] = { icon = CPI.FORMATION_BLOCK + i - 1, action = "formation:" .. i, tip = formation.NAMES[kind] }
            end
            cmds[9] = { icon = CPI.PREVIOUS, action = "previous" }
            return cmds
        end
        cmds[1] = { icon = CPI.STOP, action = "stop" }
        cmds[2] = { icon = CPI.MOVE, action = "move" }
        cmds[3] = { icon = CPI.ATTACK, action = "attack" }
        -- a group has the formation button instead of Patrol (group page; Patrol stays on its hotkey)
        if group then
            cmds[4] = { icon = CPI.FORMATIONS, action = "formations" }
        else
            cmds[4] = { icon = CPI.PATROL, action = "patrol" }
        end
        cmds[5] = { icon = CPI.GUARD, action = "guard" }
        cmds[6] = { icon = CPI.ATTITUDE, action = "attitude" }
        -- the last three slots are for special abilities, filled in this order (the original's special
        -- button routine FUN_004d3200): convert, spell book, build, then the army abilities (armyabilities.lua)
        local slot = 7
        local homogeneous = true
        local converter = false
        for _, u in ipairs(units) do
            if u.code ~= first.code then homogeneous = false end
            if u.hero or (rules.armyInfo(u.code) or {}).general then converter = true end
        end
        if converter then
            cmds[slot] = { icon = CPI.CONVERT, action = "convert" }
            slot = slot + 1
        end
        if #sel == 1 then
            if first.hero and first.h then
                cmds[slot] = { icon = CPI.SPELL, action = "spells" }
                slot = slot + 1
            end
            if self:isBuilder(first) then
                -- tech level 0 ("No Building") greys the button out (FUN_004d3200 via FUN_0040c740); a button
                -- only gets one of the three special slots (while fewer than 3 are used), so Build Wall can be
                -- crowded out
                if slot <= 9 then
                    cmds[slot] = { icon = CPI.BUILD, action = "build", disabled = world.techLevel == 0 }
                    slot = slot + 1
                end
                -- Build Wall: not for heroes, Treants and Ancient Treants; also greyed with No Walls and No Towers
                if slot <= 9 and walls.canBuild(first) then
                    local mods = world.mods
                    cmds[slot] = { icon = CPI.WALL, action = "walls",
                                   disabled = world.techLevel == 0 or (mods.noWalls and mods.noTowers) or nil }
                    slot = slot + 1
                end
            end
        end
        for _, e in ipairs(armyabilities.buttons(world, world.player, units, slot - 7)) do
            local action = "army:" .. e.id
            if e.id == "rotateLeft" then action = "rotate:1" elseif e.id == "rotateRight" then action = "rotate:-1" end
            cmds[slot] = { icon = e.icon, action = action, tip = e.tip, disabled = e.disabled }
            slot = slot + 1
        end
    elseif first.kind == "building" and first.side == world.player and first.complete then
        cmds[1] = { icon = CPI.STOP, action = "cancel" }
        if world.eco:garrisoned(first) > 0 then
            cmds[4] = { icon = CPI.PREVIOUS, action = "unload" }
        end
        local list = world.eco:productionList(first)
        if #list > 0 then
            cmds[2] = { icon = CPI.PRODUCTION, action = "production" }
            cmds[3] = { icon = CPI.RALLY, action = "rally" }
            for _, code in ipairs(list) do
                if code:sub(1, 1) == "A" then cmds[6] = { icon = CPI.ATTITUDE, action = "attitude" } break end
            end
        end
        -- a keep's Convert button (the fifth button, FUN_004d2300): greyed out while it produces or converts
        if economy.isKeep(first.code) then
            cmds[5] = { icon = CPI.CONVERT, action = "convert",
                        disabled = (first.current or first.waiting or #first.queue > 0 or first.convert) and true or nil }
        end
        if first.hp < first.maxHp and world.sides[first.side].race ~= economy.ORC then
            cmds[7] = { icon = CPI.REPAIR, action = "repair" }
        end
        -- slot 1 / 2 of an ability: the first / second extra button (the eighth / ninth button, FUN_004d2300)
        for _, e in ipairs(abilities.of(world, first)) do
            local slot = 7 + (e.def.slot or 1)
            if not cmds[slot] then
                cmds[slot] = { icon = e.def.icon, action = "ability:" .. e.def.id, tip = e.def.name, disabled = not e.usable }
            end
        end
    end
    return cmds
end

-- A hot key presses the button of the current panel (FUN_004d2290): nothing when the panel has none or it is greyed
-- out (the Build and Build Wall shortcuts test the tech level and No Walls + No Towers themselves, FUN_00427fb0).
---@param action string
function HUD:pressButton(action)
    for _, cmd in ipairs(self:commands()) do
        if cmd.action == action then
            if not cmd.disabled then self:runCommand(action) end
            return
        end
    end
end

---@param action string
function HUD:runCommand(action)
    local screen = self.screen
    local world = screen.world
    local sel = self:selection()
    local first = sel[1]
    if action == "stop" then
        local ids = {}
        for _, u in ipairs(self:selectedOwnUnits()) do ids[#ids + 1] = u.id end
        if #ids > 0 then
            screen:issue({ t = "stop", ids = ids })
            screen:speakOrder(self:selectedOwnUnits())      -- Stop button 0x004ce360: the best voice of the group
        end
    elseif action == "move" or action == "attack" or action == "rally" or action == "patrol" or action == "guard" then
        if #self:selectedOwnUnits() > 0 or action == "rally" then self.mode = action end
        self.guardAttitude = nil
    elseif action == "convert" and first and first.kind == "building" then
        if first.side == world.player and first.complete and economy.isKeep(first.code) and not first.convert
            and not (first.current or first.waiting or #first.queue > 0) then
            screen:issue({ t = "keepconvert", bid = first.id })
        end
    elseif action == "convert" then
        -- the convert button (binary): Alt inserts (mode 2), Shift appends a deferred convert (mode 1),
        -- otherwise immediate. A queued convert has no building bound and converts whatever is in range where the unit
        -- stands when the order runs, so it works even with nothing nearby right now.
        local shift = love.keyboard.isDown("lshift", "rshift")
        local alt = love.keyboard.isDown("lalt", "ralt")
        local ids = {}
        for _, u in ipairs(self:selectedOwnUnits()) do
            if u.hero or (rules.armyInfo(u.code) or {}).general then ids[#ids + 1] = u.id end
        end
        if #ids == 0 then return end
        if not shift and not alt then
            -- immediate: needs something to convert nearby now, else the "No conversions" message
            local any = false
            for _, u in ipairs(self:selectedOwnUnits()) do
                if (u.hero or (rules.armyInfo(u.code) or {}).general) and world.eco:canConvert(u)
                    and #world.eco:conversionTargets(u) > 0 then any = true break end
            end
            if not any then
                screen:notify("Nothing to convert nearby")
                return
            end
        end
        screen:issue({ t = "convert", ids = ids, queue = shift or nil, interrupt = alt or nil })
    elseif action == "production" and first then
        self.tutorial = nil
        self.dialog = { kind = "production", building = first --[[@as Building]] }   -- only buildings have the button
    elseif action == "repair" and first and first.kind == "building" and first.side == world.player
        and first.hp < first.maxHp and world.sides[first.side].race ~= economy.ORC then
        self.tutorial = nil
        self.dialog = { kind = "repair", building = first }
    elseif action == "attitude" then
        self:openAttitude()
    elseif action == "spells" then
        screen:openSpells()
    elseif action:sub(1, 8) == "ability:" and first and first.kind == "building" then
        local def = abilities.byId[action:sub(9)]
        if def and def.dialog == "trade" then
            if abilities.usable(world, first.side, def) then self.dialog = { kind = "trade", building = first } end
        elseif def then
            screen:issue({ t = "ability", bid = first.id, ability = def.id })
        end
    elseif (action == "build" or action == "walls") and first and first.kind == "unit" then
        -- both open the construction dialog, with row 0 (major buildings) or row 1 (the tower, walls and rampart) of
        -- the race's [CONSTRUCTION]
        self.tutorial = nil
        self.dialog = { kind = "build", builder = first, row = action == "walls" and 1 or 0 }
    elseif action == "cancel" and first and first.kind == "building" then
        screen:issue({ t = "cancel", bid = first.id })
    elseif action == "unload" and first and first.kind == "building" then
        screen:issue({ t = "unload", bid = first.id })
    elseif action == "formations" then
        if #self:selectedOwnUnits() > 1 then self.mode = "formations" end
    elseif action:sub(1, 10) == "formation:" then
        screen:formUp(tonumber(action:sub(11)))
    elseif action:sub(1, 7) == "rotate:" then
        screen:formUp(nil, tonumber(action:sub(8)))
    elseif action:sub(1, 5) == "army:" and armyabilities.ABILITIES[action:sub(6)]
        and armyabilities.ABILITIES[action:sub(6)].mana > 0 and armyabilities.ABILITIES[action:sub(6)].key then
        -- a troop's spell button: the 1.04 actions 0x004cf9d0 .. 0x004cfc20 push the ability's case and call FUN_00426350,
        -- the handler of the KeyMap.txt keys, so the press picks its caster like the key (abilitykeys.lua: the selection,
        -- else the screen; Invisibility's loop). Feast and Scavenge have their own actions (0x004cfc30 / 0x004cfc60: the
        -- first selected army), below.
        screen:abilityCase(armyabilities.ABILITIES[action:sub(6)].key)
    elseif action:sub(1, 5) == "army:" then
        local ids = {}
        for _, u in ipairs(self:selectedOwnUnits()) do ids[#ids + 1] = u.id end
        screen:issue({ t = "army", ids = ids, ability = action:sub(6) })
        if action == "army:mergeWisps" then screen:speakOrder(self:selectedOwnUnits()) end   -- merge wisps 0x004cea80
    elseif action == "previous" then
        self.mode = nil
    end
    if ACTION_ICON[action] and world.events then world.events:button(ACTION_ICON[action]) end
end

-- Tutorial dialog and overlay ------------------------------------------------------------
-- The tutorial dialog (anim EMDQ, 430x417) takes the place of any open dialog, sits at 350,24 of the 800x600
-- layout and leaves the rest of the screen usable (the original only swallows clicks inside it). Layout numbers
-- (picture 78,75; text rows; close button 79,345) are from the original tutorial dialog (constructor FUN_00573910,
-- drawing FUN_005741b0); font 19 is FO_MEDIUM_DLG.
local TUT_X, TUT_Y, TUT_W, TUT_H = 350, 24, 430, 417
local TUT_CANCEL_X, TUT_CANCEL_Y = 79, 345
local TUT_PIC_X, TUT_PIC_Y = 78, 75
local TUT_ROWS = 13
local TUT_WRAP_ROW = 9                    -- from this row on, the text runs under the picture (x 70, 290 wide)

---@param name string     picture <name>.bmp
---@param text string
---@param bing boolean?    play the bing sound
---@param flag integer?    scenario flag to set when it is closed
function HUD:openTutorial(name, text, bing, flag)
    self.dialog = nil
    self:closeTutorial()
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local _, font = fonts.get(19)
    local lines, i = {}, 1
    while i <= #words and #lines < TUT_ROWS do
        local row = #lines
        local width = row < TUT_WRAP_ROW and 142 or 290
        local line = words[i]
        i = i + 1
        while i <= #words and font and font:getWidth(line .. " " .. words[i]) <= width do
            line = line .. " " .. words[i]
            i = i + 1
        end
        lines[#lines + 1] = line
    end
    self.tutorial = { name = name, lines = lines, flag = flag, picture = bitmap(name .. ".bmp") }
    if bing then sound.play("Assets/SoundFX.xcr", "Bing.WAV") end
end

function HUD:closeTutorial()
    local t = self.tutorial
    self.tutorial = nil
    if t and t.flag then self.screen.world.events:setFlag(t.flag) end
end

-- A text box with a pointer line over the open production / construction dialog: "At(x,y) Corner(c) To(x,y) "text"".
---@param raw string
---@param bing boolean?
function HUD:openOverlay(raw, bing)
    local d = self.dialog
    if not d then return end
    local x, y, corner, tx, ty, text = raw:match('At%((%-?%d+),(%-?%d+)%)%s*Corner%((%d+)%)%s*To%((%-?%d+),(%-?%d+)%)%s*"([^"]*)')
    if not x then return end
    local lines = widgets.wrap(5, text, 150)
    -- the pattern only matches numbers
    d.overlay = { x = tonumber(x) --[[@as number]], y = tonumber(y) --[[@as number]],
                  corner = tonumber(corner) --[[@as integer]], tx = tonumber(tx) --[[@as number]],
                  ty = tonumber(ty) --[[@as number]], lines = lines, w = 160, h = 8 + 20 * #lines }
    if bing then sound.play("Assets/SoundFX.xcr", "Bing.WAV") end
end

---@param o HUDOverlay
function HUD:drawOverlay(o)
    local g = love.graphics
    local x0 = o.corner == 1 and o.x + o.w - 1 or o.x
    g.setColor(0, 0, 0)
    g.rectangle("fill", o.x, o.y, o.w, o.h)
    g.setColor(0, 1, 0)
    g.rectangle("line", o.x + 0.5, o.y + 0.5, o.w - 1, o.h - 1)
    g.line(x0, o.y, o.tx, o.ty)
    g.setColor(1, 1, 1)
    for i, l in ipairs(o.lines) do fonts.print(5, l, o.x + 5, o.y + 5 + (i - 1) * 20) end
end

function HUD:tutorialOrigin()
    self:layout()
    return self.ox + TUT_X * self.s, self.oy + TUT_Y * self.s
end

function HUD:overTutorial(x, y)
    local ox, oy = self:tutorialOrigin()
    local lx, ly = (x - ox) / self.s, (y - oy) / self.s
    return lx >= 0 and ly >= 0 and lx < TUT_W and ly < TUT_H, lx, ly
end

local function overCancel(lx, ly)
    return lx >= TUT_CANCEL_X and ly >= TUT_CANCEL_Y and lx < TUT_CANCEL_X + 30 and ly < TUT_CANCEL_Y + 30
end

function HUD:drawTutorial()
    local t = self.tutorial
    ---@cast t -nil              drawn while open
    local g = love.graphics
    local ox, oy = self:tutorialOrigin()
    local mx, my = love.mouse.getPosition()
    local _, lx, ly = self:overTutorial(mx, my)
    g.push()
    g.translate(ox, oy)
    g.scale(self.s)
    local bg = anims.get("EMDQ")
    if bg then
        bg:drawCell(0, 0, 0, 0, 0)
    else
        g.setColor(0.1, 0.08, 0.05, 0.95)
        g.rectangle("fill", 0, 0, TUT_W, TUT_H)
        g.setColor(1, 1, 1)
    end
    if t.picture then g.draw(t.picture, TUT_PIC_X, TUT_PIC_Y) end
    for i, l in ipairs(t.lines) do
        local row = i - 1
        local x = row < TUT_WRAP_ROW and 217 or 70
        fonts.print(19, l, x, 72 + row * 20)
    end
    local cancel = anims.get("EMDC")
    if cancel then
        local state = 0
        if overCancel(lx, ly) then state = t.cancelDown and 2 or 1 end
        cancel:drawCell(0, state, 0, TUT_CANCEL_X, TUT_CANCEL_Y)
    end
    g.pop()
end

-- Returns true when the click landed on the tutorial dialog.
function HUD:tutorialPressed(x, y)
    local over, lx, ly = self:overTutorial(x, y)
    if not over then return false end
    self.tutorial.cancelDown = overCancel(lx, ly)
    return true
end

function HUD:tutorialReleased(x, y)
    local t = self.tutorial
    ---@cast t -nil              the caller checks it is open
    local down = t.cancelDown
    t.cancelDown = false
    local over, lx, ly = self:overTutorial(x, y)
    if down and over and overCancel(lx, ly) then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self:closeTutorial()
    end
    return over
end

-- Drawing ---------------------------------------------------------------------------

function HUD:draw()
    local g = love.graphics
    local s = self:layout()
    local world = self.screen.world
    g.push()
    g.translate(self.ox, self.oy)
    g.scale(s)
    -- side fill for wide windows
    local ext = bitmap("Panel_Extension.bmp")
    if ext and self.ox > 0 then
        local w = ext:getWidth()
        local x = -w
        while x * s + self.ox > -w * s do
            g.draw(ext, x, 411)
            x = x - w
        end
        x = 800
        while (x * s + self.ox) < self.W do
            g.draw(ext, x, 411)
            x = x + w
        end
    end
    local panel = bitmap("Panel_800.bmp")
    if panel then g.draw(panel, 0, 411) end

    self:drawMinimap()
    self:drawHeroArea()
    self:drawInfoArea()
    self:drawCommands()
    self:drawPreview()
    g.pop()
    self:drawTopCounters()
    spellbar.draw(self)
    self:drawCommandTip()
    if self.dialog then self:drawDialog() end
    if self.tutorial then self:drawTutorial() end
end

function HUD:drawMinimap()
    local g = love.graphics
    local screen = self.screen
    local world = screen.world
    local x, y = 20, 456
    if screen.minimap then
        g.draw(screen.minimap, x, y)
    else
        g.setColor(0.1, 0.2, 0.1)
        g.rectangle("fill", x, y, 128, 128)
    end
    local fog = screen.fog
    if fog.enabled and fog.image then
        g.setColor(1, 1, 1)
        g.draw(fog.image, x, y, 0, 128 / world.w, 128 / world.h)
    end
    local sx, sy = 128 / world.w, 128 / world.h
    for _, b in ipairs(world.buildings) do
        if b.hp > 0 and screen:shown(b) then
            local c = M.SIDE_RGB[screen:teamColor(b.side)] or M.SIDE_RGB[6]
            local size = (b.shape and b.shape.h >= 4) and 4 or ((b.shape and b.shape.h >= 2) and 2 or 1)
            if b.mine then
                local rc = M.RES_RGB[b.mine.resource]
                g.setColor(rc[1] / 255, rc[2] / 255, rc[3] / 255)
                g.rectangle("fill", x + b.gx * sx - 2, y + b.gy * sy - 2, 4, 4)
                g.setColor(c[1] / 255, c[2] / 255, c[3] / 255)
                g.polygon("fill", x + b.gx * sx - 2, y + b.gy * sy - 2, x + b.gx * sx + 2, y + b.gy * sy - 2,
                    x + b.gx * sx - 2, y + b.gy * sy + 2)
            else
                g.setColor(c[1] / 255, c[2] / 255, c[3] / 255)
                g.rectangle("fill", x + b.gx * sx - size / 2, y + b.gy * sy - size / 2, size, size)
            end
        end
    end
    for _, u in ipairs(world.units) do
        if u:alive() and screen:shown(u) then
            local c = M.SIDE_RGB[screen:teamColor(u.side)] or M.SIDE_RGB[6]
            if u.hero then c = M.SIDE_RGB_LIGHT[screen:teamColor(u.side)] or c end
            g.setColor(c[1] / 255, c[2] / 255, c[3] / 255)
            g.rectangle("fill", x + u.gx * sx - 1, y + u.gy * sy - 1, 2, 2)
        end
    end
    self:drawInfoBox(x, y)
    -- view rectangle
    local vw, vh = screen:viewSize()
    g.setColor(0, 1, 0)
    g.setLineWidth(1)
    g.rectangle("line", x + screen.camX / 32 * sx + 0.5, y + screen.camY / 24 * sy + 0.5,
        vw / 32 * sx, vh / 24 * sy)
    g.setColor(1, 1, 1)
    local over = bitmap("Panel_OverStrat.bmp")
    if over then g.draw(over, x + 91, y) end
end

-- The red box that shrinks onto a place on the minimap when something is announced (started by FUN_004dcf70, drawn by
-- the panel update `FUN_004dc850`: 17 frames of esibi.bmp, 64 x 64 each, one per event timer tick
-- (the main screen's timer runs at 18 a second), the last one staying until the 100th tick, then it is
-- cleared). The box is centred on the place (the map is scaled to the 128 x 128 minimap: 64 -> x2, 192 -> x2/3, 256 ->
-- x1/2, other sizes proportionally) and clipped to the minimap. Only one runs at a time; the screen starts it.
local INFOBOX_RATE, INFOBOX_TICKS, INFOBOX_FRAMES = 18, 100, 17

function HUD:drawInfoBox(x, y)
    local screen = self.screen
    local box = screen.infoBox
    if not box then return end
    local n = math.floor((love.timer.getTime() - box.t0) * INFOBOX_RATE)
    if n >= INFOBOX_TICKS then
        screen.infoBox = nil
        return
    end
    local world = screen.world
    local bx = math.floor(box.gx * 128 / world.w) - 32
    local by = math.floor(box.gy * 128 / world.h) - 32
    self:clip(x, y, 128, 128)
    blit("esibi.bmp", math.min(n, INFOBOX_FRAMES - 1) * 64, 0, 64, 64, x + bx, y + by)
    love.graphics.setScissor()
end

-- The local side's hero while alive.
---@return Unit?
function HUD:hero()
    local world = self.screen.world
    return world.eco:heroAlive(world.player)
end

function HUD:drawBar(row, x, y, h, cur, max)
    local img = bitmap("Panel_Bars.bmp")
    if not img or max <= 0 then return end
    local w = math.floor(math.max(0, math.min(1, cur / max)) * 98)
    local g = love.graphics
    g.draw(img, quad(img, 0, row + h, 98, h), x, y)
    if w > 0 then g.draw(img, quad(img, 0, row, w, h), x, y) end
end

-- Round buttons of the control panel (icons of Panel_Menu.bmp: columns are
-- normal / hover / pressed / disabled, rows are the four symbols).
local PBUTTONS = {
    { id = "hero", x = 150, y = 507, row = 2, tip = "Hero: stats and items (I)" },
    { id = "skills", x = 150, y = 547, row = 3, tip = "Hero: skills" },
    { id = "pause", x = 620, y = 507, row = 1, tip = "Pause (P)" },
    { id = "menu", x = 620, y = 545, row = 0, tip = "Menu (Esc)" },
}

---@return HUDPanelButton?
function HUD:panelButtonAt(lx, ly)
    for _, b in ipairs(PBUTTONS) do
        if lx >= b.x and ly >= b.y and lx < b.x + 30 and ly < b.y + 30 then return b end
    end
end

---@param b HUDPanelButton
function HUD:runPanelButton(b)
    local screen = self.screen
    if b.id == "hero" then screen:openHero(1)
    elseif b.id == "skills" then screen:openHero(3)
    elseif b.id == "pause" then screen.paused = not screen.paused
    elseif b.id == "menu" then screen:openMenu() end
end

function HUD:drawHeroArea()
    local g = love.graphics
    local hero = self:hero()
    local team = self.screen:teamColor(self.screen.world.player)
    for _, b in ipairs(PBUTTONS) do
        local col = 0
        if self.hoverPanel == b then col = self.pressedPanel == b and 2 or 1 end
        if (b.id == "hero" or b.id == "skills") and not hero then col = 3 end
        blit("Panel_Menu.bmp", col * 30, b.row * 30, 30, 30, b.x, b.y)
    end
    if hero then
        g.setScissor()
        local px, py = 185, 456
        g.setColor(0, 0, 0)
        g.rectangle("fill", px, py, 98, 98)
        g.setColor(1, 1, 1)
        if hero.set then hero.set:drawInterface(3, px + 4, py + 4, team) end
        self:drawBar(0, 185, 555, 11, hero.hp, hero.maxHp)
        local h = hero.h
        if h then
            local base = require("src.game.hero").xpFor(h.level)
            local nxt = require("src.game.hero").xpFor(h.level + 1)
            self:drawBar(44, 185, 579, 4, h.level >= 50 and 1 or h.xp - base, h.level >= 50 and 1 or nxt - base)
            drawNumber(h.level, 190, 460)
            if h.latch then          -- a level-up whose points are not spent yet (binary FUN_004d7710 reads the latch)
                local pulse = 0.35 + 0.35 * math.sin(love.timer.getTime() * 4)
                g.setBlendMode("add")
                g.setColor(1, 1, 1, pulse)
                blit("Panel_HeroLevelUp.bmp", 0, 0, 98, 98, px, py)
                g.setBlendMode("alpha")
                g.setColor(1, 1, 1)
            end
        else
            self:drawBar(44, 185, 579, 4, 0, 1)
        end
        self:drawBar(22, 185, 567, 11, hero.h and hero.h.mana or 0, hero.h and hero.h.mod.mana or 1)
    else
        blit("Panel_HeroDead.bmp", 0, 0, 98, 98, 185, 456)
    end
    local over = bitmap("Panel_OverHero.bmp")
    if over then g.draw(over, 183, 456) end
end

-- The psych effect of the selected army the first test that matches wins, in the order chaos, awe, fear,
-- terror, poison, disease (the psych auras of game/psych.lua put chaos and terror on armies).
local PSYCH_X, PSYCH_Y = 314, 462
local PSYCH_ICONS = {
    { "chaos", 232 }, { "awe", 248 }, { "fear", 200 }, { "terror", 216 },
    { "poison", 280 }, { "disease", 264 },
}

-- Geometry of the info area (set by the panel setup FUN_004d6e00, at 800x600: panel top 456, info area (304, -4)
-- 342 wide, army / building statistics (460, 35), the big picture (403, 69)).
local PANEL_Y = 456
-- (the temple test FUN_0052fc50: the tag `temple`)
local AREA_X, AREA_Y, AREA_W = 304, PANEL_Y - 4, 342
local STATS_X, STATS_Y = 460, PANEL_Y + 35
local PIC_X, PIC_Y = 403, PANEL_Y + 69

local function gs(n, default) return strings.get("Game.txt", ("%04d"):format(n)) or default end

-- The strings Game.txt 0262 / 0263 label the armour and resistance rows of a single army in
-- every language: FUN_004d7710 (and the German executables, checked by disassembly) always load these two ids, whatever
-- the table holds. The German Game.txt has "Reichweite:" / "Sicht:" there, so the original German game really prints
-- those words next to armour and resistance; the table text is shown unchanged.

-- As FUN_004ddeb0: "N" when the real value equals the base one, else "base +diff" / "base -diff".
local function formatStat(base, real)
    base, real = math.floor(base), math.floor(real)
    if real == base then return ("%d"):format(base) end
    return ("%d %s%d"):format(base, real > base and "+" or "", real - base)
end

local function printRight(font, s, xr, y) fonts.print(font, s, xr - 300, y, "right", 300) end

-- Clip rectangle in panel coordinates (FUN_00469db0); `g.setScissor()` removes it.
function HUD:clip(x, y, w, h)
    love.graphics.setScissor(self.ox + x * self.s, self.oy + y * self.s, w * self.s, h * self.s)
end

-- The attitude icon of SkillIcons.bmp (80 + 16 * icon, 40; the getter FUN_00585c80 returns the number each built-in
-- attitude's setup stores (FUN_00505cc0 .. FUN_00506950, called from FUN_00506c40): cowardly 0 flag, stand ground 1
-- tower, defensive 2 statue, standard 7 key, aggressive 3 swords, rampant 4 chaos, scout 9 spyglass, guardian 5 cross,
-- magic guardian 6 staff; the icon of a custom attitude is the icon field of its .uai file).
function HUD:drawAttitudeIcon(attitude, x, y)
    local icon = attitudes.icon(attitude)
    if icon then blit("SkillIcons.bmp", 80 + icon * 16, 40, 16, 16, x, y) end
end

-- DamageIcons.bmp: seven 24x20 icons in the damage type order (0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic,
-- 5 crushing, 6 slashing); hot-and-pointy shows the fire icon.
function HUD:drawDamageIcon(dtype, hot, x, y)
    if hot then dtype = 3 end
    if dtype < 0 or dtype > 6 then dtype = 6 end
    blit("DamageIcons.bmp", dtype * 24, 0, 24, 20, x, y)
end

-- The production bar of ProductionBar.bmp: 36x36 frame, the part not yet done covered in black, "n%" on top.
function HUD:drawPercentBar(x, y, pct)
    local g = love.graphics
    blit("ProductionBar.bmp", 0, 0, 36, 36, x, y)
    local cover = 32 - math.floor(pct * 32 / 100)
    if cover > 0 then
        g.setColor(0, 0, 0)
        g.rectangle("fill", x + 2, y + 2, 32, cover)
        g.setColor(1, 1, 1)
    end
    fonts.print(2, ("%d%%"):format(pct), x + 2, y + 14, "center", 32)
end

-- Conversion progress of a building in percent: its own (a converting keep) or the best of the units and keeps
-- converting it (0 = none).
function HUD:buildingConversion(b)
    local world = self.screen.world
    local best = world.eco:keepConversionPercent(b)
    -- a keep converting this building
    for _, k in ipairs(world.buildings) do
        if k.convert and k.side ~= b.side then
            for _, target in ipairs(world.eco:conversionList(k.side, k.gx, k.gy, k.convert.range)) do
                if target == b then
                    best = math.max(best, world.eco:keepConversionPercent(k))
                end
            end
        end
    end
    for _, u in ipairs(world.units) do
        if u.converting and u.state == "convert" and u:alive() then
            for _, target in ipairs(world.eco:conversionTargets(u)) do
                if target == b then
                    local c = u.converting
                    ---@cast c -nil
                    local p = math.floor(100 * (world.time - c.t0) / math.max(1, c.t1 - c.t0))
                    best = math.max(best, math.max(0, math.min(100, p)))
                end
            end
        end
    end
    return best
end

-- Nothing selected (the original's default mode): the side's morale, the army limit, command effect, attack speed and
-- the hero's merchant skill (Game.txt 1097..1100, then the merchant line of herobonus.lua).
function HUD:drawMorale()
    local world = self.screen.world
    local side = world.sides[world.player]
    local hero = self:hero()
    local morale = hero and hero.h and hero.h:getMorale() or powerups.moraleBonus(side)
    local cx = AREA_X + math.floor(AREA_W / 2) - 15
    local y = AREA_Y + 10
    local function centred(font, s, yy) fonts.print(font, s, cx - 200, yy, "center", 400) end
    centred(17, gs(1097, "Morale: +%d"):format(morale), y)
    y = y + 32
    centred(2, gs(1098, "Army limit: +%d"):format(math.floor(morale / 2)), y)
    y = y + 18
    centred(2, gs(1099, "Command effect: +%d sec"):format(morale), y)
    y = y + 18
    centred(2, gs(1100, "Attack speed: %.2f sec"):format(math.max(0.5, 1.5 - morale * 0.01 + 0.0001)), y)
    y = y + 30
    local merchant = hero and hero.h and hero.h.mod.discount or 0
    centred(2, heroBonus.merchantLine(merchant), y)
end


-- A single army (the info area's single-army page): picture, name, the statistics as "base +bonus", the damage type
-- icon, converting progress, mana, experience and medals, attitude and the psych effect.
function HUD:drawSingleArmy(u, team)
    local g = love.graphics
    local world = self.screen.world
    local t = u.type or {}
    local base, real = u:baseStats(), u:stats(true)
    local conv = 0
    if u.state == "convert" and u.converting then
        local c = u.converting
        conv = math.max(0, math.min(100, math.floor(100 * (world.time - c.t0) / math.max(1, c.t1 - c.t0))))
    end
    if u.set then u.set:drawInterface(0, PIC_X, PIC_Y, team) end
    self:clip(AREA_X + 145, AREA_Y + 18, 168, 20)
    fonts.print(5, u.name or u.code, AREA_X + 145, AREA_Y + 18)
    g.setScissor()
    -- labels (Game.txt 0258 .. 0263) right-aligned at x 517, values at x 528
    local lx, vx, y = AREA_X + 213, AREA_X + 224, AREA_Y + 44
    local labels = { gs(258, "Combat:"), gs(259, "Hits:"), gs(260, "Speed:"), gs(261, "Damage:"), gs(262, "Armor:"),
                     gs(263, "Resistance:") }
    for k = 1, conv > 0 and 2 or 6 do printRight(2, labels[k], lx, y + 14 * (k - 1)) end
    fonts.print(2, formatStat(base.combat, real.combat), vx, y)
    fonts.print(2, ("%d / %d"):format(math.max(0, math.floor(u.hp)), u.maxHp), vx, y + 14)
    if conv == 0 then
        fonts.print(2, formatStat(base.speed, real.speed), vx, y + 28)
        if (t.attackType or 1) == 0 then
            fonts.print(2, "-", vx, y + 42)
        else
            local text = formatStat(base.damage, real.damage)
            if real.range > 0 then text = text .. " / " .. formatStat(base.range, real.range) end
            local len = fonts.width(2, text)
            self:drawDamageIcon(real.damageType, real.hot, vx + math.min(len + 4, 90 - 24), y + 42 - 5)
            fonts.print(2, text, vx, y + 42)
        end
        fonts.print(2, formatStat(base.armor, real.armor), vx, y + 56)
        local baseRes, realRes = u:resistances()
        fonts.print(2, formatStat(baseRes, realRes), vx, y + 70)
    else
        fonts.print(2, gs(264, "Converting"), lx - 32, y + 45)
        self:drawPercentBar(lx - 32 + 80, y + 45 - 10, conv)
    end
    if not u.hero then
        -- experience (Game.txt 0265) with the medal strips of SkillIcons.bmp; critters and titans show neither
        if not unitMod.isCritter(u.code) and not unitMod.isTitanUnit(u.code) then
            local lvl = math.min(u.level or 0, unitMod.MAX_ARMY_LEVEL)
            local gold, silver = math.floor(lvl / 5), lvl % 5
            local s = gs(265, "%ld xp"):gsub("%%ld", "%%d"):format(u.xp or 0)
            fonts.print(2, s, AREA_X + 25 - math.floor(fonts.width(2, s) / 2), AREA_Y + (gold > 0 and 80 or 92))
            if gold > 0 then blit("SkillIcons.bmp", 45 + gold * 29, 142, 29, 16, AREA_X + 10, AREA_Y + 95) end
            blit("SkillIcons.bmp", 45 + silver * 29, 158, 29, 16, AREA_X + 10, AREA_Y + 111)
        end
        -- the troop's own mana (the bell icon, current / maximum mana centred below)
        if u.maxMana and u.maxMana > 0 then
            blit("SkillIcons.bmp", 170, 125, 16, 16, AREA_X + 20, STATS_Y + 4)
            local s = ("%d/%d"):format(math.floor(u.mana or 0), u.maxMana)
            fonts.print(2, s, AREA_X + 28 - math.floor(fonts.width(2, s) / 2), STATS_Y + 24)
        end
        -- the Troll's sheep and the Catapult's cows: the ammunition counter under its icon, drawn
        -- opaque, text centred 8 pixels right of the icon's left edge (the panel drawing FUN_004d7710)
        if u.code == "AOMX" or u.code == "ASCA" then
            blit("SkillIcons.bmp", u.code == "AOMX" and 186 or 218, 125, 16, 16, AREA_X + 15, STATS_Y + 4)
            local s = tostring(u.ammo or 0)
            fonts.print(2, s, AREA_X + 23 - math.floor(fonts.width(2, s) / 2), STATS_Y + 24)
        end
    end
    if conv == 0 and u.side == world.player then
        self:drawAttitudeIcon(attitudes.of(u), AREA_X + 267, AREA_Y + 108)
    end
    -- the psych effect icon: one only, the first that applies in this order
    for _, p in ipairs(PSYCH_ICONS) do
        if status.has(u, p[1]) then
            blit("SkillIcons.bmp", p[2], 0, 16, 16, PSYCH_X, PSYCH_Y)
            break
        end
    end
end

-- A garrisoned army as a small boxed picture (FUN_004ddd30): the SelectionRings frame of its size and health.
function HUD:drawTinyArmy(u, x, y, team)
    local sx, sy, sw, sh = unitRing(u)
    blit("SelectionRings.bmp", sx, sy, sw, sh, x, y)
    if u.set then u.set:drawInterface(5, x + 3, y + 3, team) end
end

-- Slot (top left corner) of the n-th garrisoned army of a tower page (CARRYX / CARRYY).
local function garrisonSlot(n)
    return AREA_X + 2 + 110 + ((n - 1) % 2) * 29, AREA_Y + 50 + math.floor((n - 1) / 2) * 29
end

-- The five tower rows: Combat, Hits, Speed, Damage (+ type icon) and Range, labels right-aligned at x + 68.
function HUD:drawTowerRows(b, x, y, base, real)
    local labels = { gs(258, "Combat:"), gs(259, "Hits:"), gs(260, "Speed:"), gs(261, "Damage:"), gs(755, "Range:") }
    for k = 1, 5 do printRight(2, labels[k], x + 68, y + 18 * (k - 1)) end
    fonts.print(2, formatStat(base.combat, real.combat), x + 76, y)
    fonts.print(2, b.code == "BMFL" and "-" or ("%d / %d"):format(math.max(0, math.floor(b.hp)), b.maxHp), x + 76, y + 18)
    fonts.print(2, formatStat(base.speed, real.speed), x + 76, y + 36)
    local text = formatStat(base.damage, real.damage)
    fonts.print(2, text, x + 76, y + 54)
    self:drawDamageIcon(real.damageType, false, x + 76 + fonts.width(2, text) + 4, y + 54 - 2)
    fonts.print(2, formatStat(base.range, real.range), x + 76, y + 72)
end

-- The name and the hits line shared by most building pages: the name clipped to 168x20 at the stats point, the hits
-- below it ("-" for the flag).
function HUD:drawBuildingHeader(b, x, y)
    self:clip(x, y, 168, 20)
    fonts.print(5, b.name or b.code, x, y)
    love.graphics.setScissor()
    local s = b.code == "BMFL" and "-" or ("%d / %d"):format(math.max(0, math.floor(b.hp)), b.maxHp)
    fonts.print(2, s, x + 36, y + 26)
end

-- A building (the info area's building page): own garrisonable buildings show the tower page with the garrisoned
-- armies, an own tower without garrison its statistics, mines, temples, shops and quest sites their own lines, a
-- producing own building its queue.
function HUD:drawBuildingInfo(b, team)
    local world = self.screen.world
    local eco = world.eco
    local own = b.side == world.player
    local info = rules.building(b.code) or {}
    local garrison = own and b.complete and (info.garrison or 0) > 0
    local tower = ((b.type and b.type.damage) or 0) > 0
    if garrison then
        local ox, oy = AREA_X + 2, AREA_Y
        blit("Garrison.bmp", 0, 0, 309, 129, ox + 1, oy + 1)
        if b.set then b.set:drawInterface(3, ox + 7, oy + 25, team) end
        for n, u in ipairs(b.garrison or {}) do
            if n > 4 then break end
            local sx, sy = garrisonSlot(n)
            self:drawTinyArmy(u, sx, sy, team)
        end
        fonts.print(5, gs(126, "Tower"), STATS_X, STATS_Y - 10)
        local base, real = eco:buildingStats(b)
        self:drawTowerRows(b, STATS_X + 16, STATS_Y + 10, base, real)
        return
    end
    if own and b.complete and (b.current or b.waiting) then
        self:drawQueue(b)
        return
    end
    local pic = function() if b.set then b.set:drawInterface(0, PIC_X, PIC_Y, team) end end
    local pct = self:buildingConversion(b)
    local repairing = b.repair ~= nil
    if tower and own and b.complete and not repairing then
        pic()
        self:clip(STATS_X, STATS_Y - 10, 168, 20)
        fonts.print(5, b.name or b.code, STATS_X, STATS_Y - 10)
        love.graphics.setScissor()
        local base, real = eco:buildingStats(b)
        self:drawTowerRows(b, STATS_X + 16, STATS_Y + 10, base, real)
        return
    end
    local x, y = STATS_X, STATS_Y
    pic()
    self:drawBuildingHeader(b, x, y)
    y, x = y + 22, x + 16
    if b.mine then
        local m = b.mine
        local text
        if m.reserve > 0 then
            local label = ({ gold = 250, metal = 251, stone = 252, crystal = 253 })[m.resource] or 250
            text = ("%s: %d"):format(gs(label, m.resource), m.reserve) .. (b.pillaged and " (*)" or "")
        else
            text = gs(272, "Run dry!")
        end
        fonts.print(2, text, x + 8, y + 24)
        if b.pillaged then
            local secs = math.max(0, math.ceil((b.pillaged - world.time) / 1000))
            fonts.print(2, gs(273, "Recovery: %d sec"):format(secs), x + 24, y + 42)
        end
        -- the workers: icon and count
        blit("SkillIcons.bmp", 202, 125, 16, 16, AREA_X + 15, STATS_Y + 12)
        local s = tostring(m.workers)
        fonts.print(2, s, AREA_X + 23 - math.floor(fonts.width(2, s) / 2), STATS_Y + 32)
    elseif require("src.game.gamedata").hasTag(b.code, "temple") then
        fonts.print(2, b.pillaged and gs(274, "Rebuilding") or gs(275, "Operational"), x + 8, y + 24)
        if b.pillaged then
            local secs = math.max(0, math.ceil((b.pillaged - world.time) / 1000))
            fonts.print(2, gs(276, "%d sec"):format(secs), x + 24, y + 42)
        end
    elseif b.shop then
        fonts.print(2, gs(1123, "Items available!"), x + 10, y + 30)
    elseif b.quest then
        local q = b.quest
        if q.state == "held" then
            blit("SkillIcons.bmp", 296, 19, 29, 21, x + 20, y + 25)
        elseif q.state == "recovery" then
            blit("SkillIcons.bmp", 278, 19, 18, 21, x + 20, y + 25)
            fonts.print(2, ("%d"):format(math.max(0, math.floor((q.expiry - world.time) / 1000))), x + 42, y + 28)
        else
            blit("SkillIcons.bmp", 260, 19, 18, 21, x + 20, y + 25)
        end
    elseif pct > 0 then
        fonts.print(2, gs(264, "Converting"), x, y + 45)
        self:drawPercentBar(x + 80, y + 35, pct)
    elseif (not b.complete and b.site) or repairing then
        -- under construction / being repaired: the hammer icon and the progress bar
        local p
        if repairing then
            p = b.repair.total > 0 and math.floor(100 * (b.repair.done or 0) / b.repair.total) or 0
        else
            p = math.floor(100 * (world.time - b.site.t0) / math.max(1, b.site.t1 - b.site.t0))
        end
        blit("SkillIcons.bmp", 323, 74, 17, 17, STATS_X + 20, STATS_Y + 18 + 36)
        self:drawPercentBar(STATS_X + 20 + 30, STATS_Y + 18 + 36 - 10, math.max(0, math.min(100, p)))
    end
end

function HUD:drawInfoArea()
    local g = love.graphics
    local screen = self.screen
    local world = screen.world
    local sel = self:selection()
    blit("Panel_Menu.bmp", 0, 30, 30, 30, 620, 507)
    blit("Panel_Menu.bmp", 0, 0, 30, 30, 620, 545)
    local first = sel[1]
    if not first then
        self:drawMorale()
        return
    end
    local team = screen:teamColor(first.side or 6)
    if #sel == 1 and first.kind == "unit" then
        local u = first
        -- the info area pages: page 0 is the unit's stats; a hero adds an overview
        -- (race / class / level / regeneration) and a skills page; every unit ends with the
        -- resistances / combat-bonuses page. Right-clicking the info area cycles them.
        local hero = u.hero and u.h
        local pageCount = hero and 4 or 2
        local page = self.infoPage or 0
        if page >= pageCount then page = 0 end
        if hero and page == 1 then
            g.setScissor()
            self:drawHeroOverview(u)
        elseif hero and page == 2 then
            g.setScissor()
            self:drawHeroSkills(u)
        elseif page == pageCount - 1 then
            g.setScissor()
            self:drawUnitResist(u)
        else
            self:drawSingleArmy(u, team)
        end
    elseif #sel > 1 then
        local _, place = self:unitBar()
        for _, p in ipairs(place) do
            local bx = 310 + 29 * (p.i % 8)
            local by = PANEL_Y + 12 + 29 * math.floor(p.i / 8)
            self:drawTinyArmy(p.u, bx, by, team)
        end
        -- the group's attitude, when all share one
        local att
        for _, e in ipairs(sel) do
            if e.side == world.player then
                local a = e.kind == "unit" and attitudes.of(e) or e.attitude or attitudes.DEFAULT
                if att == nil then att = a elseif att ~= a then att = false break end
            end
        end
        if att then self:drawAttitudeIcon(att, STATS_X + 120, STATS_Y + 32) end
    elseif first.kind == "building" then
        self:drawBuildingInfo(first, team)
    end
end

-- Hero info-area pages (the original's info area cycles through these on right-click). Positions, fonts and row
-- spacing are those of the two page modes of `FUN_004d7710` (the panel drawing, switch cases 6 and 7 of the page
-- mode), both starting at the info area + (14, 5):
-- Overview (hero details): the hero's name in FO_MEDIUM; 20 below, +8 across, "Race: <name>" (XCI text 6/3 + " " +
-- text 15 / 104 of the race number), 18 further "Class:" (text 6/4, class names are texts 8..11), 18 further "Level:"
-- (6/5); then, 24 below and +4 more across, FO_SMALL: Game.txt 0661 with the seconds one life point takes (the
-- army's regeneration interval / 1000) and, for an undead hero, 16 below and +8 across Game.txt 0663 ("only at
-- night"); 20 below the last line Game.txt 0662 for the mana.
-- Skills (the hero skills page): the heading (XCI text 18/2) in FO_MEDIUM, 24 below, +8 across the skills of slots 1..10
-- with a level > 0 as "<Game.txt 759 + id> +<level>" (`FUN_00556c90`, format " +%d") in FO_MEDIUM, two columns 140
-- apart, 18 per row.
local INFO_X, INFO_Y = AREA_X + 14, AREA_Y + 5            -- header of an info-area page
local CLASS_GROUP_TEXT = { 8, 9, 10, 11 }                  -- XCI text resources of the class names (8 per resource)

local function raceName(race)
    return (race < 8 and UI.text(15, race) or UI.text(104, race - 8)) or classes.RACE_NAMES[race] or "?"
end

local function className(name)
    for i, c in ipairs(classes.list()) do
        if c[1] == name then
            local n = i - 1
            return UI.text(CLASS_GROUP_TEXT[math.floor(n / 8) + 1], n % 8) or name
        end
    end
    return name or ""
end

function HUD:drawHeroOverview(u)
    local h = u.h
    local x, y = INFO_X, INFO_Y
    fonts.print(5, u.name or u.code, x, y)
    x, y = x + 8, y + 20
    fonts.print(5, (UI.text(6, 3) or "Race:") .. " " .. raceName(h.race or 0), x, y)
    fonts.print(5, (UI.text(6, 4) or "Class:") .. " " .. className(h.class), x, y + 18)
    fonts.print(5, (UI.text(6, 5) or "Level:") .. " " .. tostring(h.level), x, y + 36)
    x, y = x + 4, y + 36 + 24
    local per = function(rate) return rate > 0 and 1 / rate or 0 end
    fonts.print(2, (strings.get("Game.txt", "0661") or "Life Regeneration: 1 point per %0.2f seconds")
        :format(per(h:lifeRegen())), x, y)
    if h:isUndead() then
        y = y + 16
        fonts.print(2, gs(663, "(only at night)"), x + 8, y)
    end
    y = y + 20
    local manaRate = h.mod.manaRegen * (h.mod.manaRegenPct or 100) / 100
    fonts.print(2, (strings.get("Game.txt", "0662") or "Mana Regeneration: 1 point per %0.2f seconds")
        :format(per(manaRate)), x, y)
end

function HUD:drawHeroSkills(u)
    local h = u.h
    local x, y = INFO_X, INFO_Y
    fonts.print(5, UI.text(18, 2) or "Skills", x, y)
    x, y = x + 8, y + 24
    local n = 0
    for _, e in ipairs(h.skillList) do
        local lvl = h.skill[e[1]] or 0
        if lvl > 0 then
            fonts.print(5, heroMod.skillName(e[1]) .. " +" .. lvl, x + (n % 2) * 140, y)
            if n % 2 == 1 then y = y + 18 end
            n = n + 1
        end
    end
end

-- The last info-area page (army details): the complete armour as signed values on the ArmyDetails.bmp frame -
-- row 1 piercing, slashing, crushing, row 2 fire, electricity, ice, magic (`Unit:completeArmour`) - then the damage
-- type the unit is strong / weak against (Game.txt 0910 + type, 0921 + type; 0932 when neither).
local RESIST_CELLS = { { 0, 0, 0 }, { 6, 1, 0 }, { 5, 2, 0 }, { 3, 0, 1 }, { 2, 1, 1 }, { 1, 2, 1 }, { 4, 3, 1 } }

---@param u Unit
function HUD:drawUnitResist(u)
    local armour = u:completeArmour()
    local st = u:stats(true)
    local ox, oy = AREA_X + 10, AREA_Y
    blit("ArmyDetails.bmp", 0, 0, 309, 129, ox + 4, oy + 1)
    for _, c in ipairs(RESIST_CELLS) do
        fonts.print(2, ("%+d"):format(math.floor(armour[c[1]] or 0)), ox + 42 + 65 * c[2], oy + 22 + 28 * c[3])
    end
    local strong, weak = st.strong or -1, st.weak or -1
    local y = oy + 22 + 3 * 23
    if strong < 0 and weak < 0 then
        fonts.print(2, gs(932, ""), ox, y)
    elseif strong < 0 then
        fonts.print(2, gs(921 + weak, ""), ox, y)
    elseif weak < 0 then
        fonts.print(2, gs(910 + strong, ""), ox, y)
    else
        fonts.print(2, gs(910 + strong, ""), ox, y)
        fonts.print(2, gs(921 + weak, ""), ox, y + 23)
    end
end

-- The production queue of the selected own building (drawn by FUN_004d7710: the strip
-- ProductionSlots.bmp at 308,502, six 32x50 slots at 315+41k,523; the first slot is the current
-- production, or an animated frame of SelectionRings.bmp at 392+32c,619 (c cycles 0..7, one step
-- every 4 ticks) while the queue is frozen because the head cannot be afforded ("Freeze the
-- queue", the waiting state); armies and upgrades use the interface sheet, power-ups are blitted from
-- Powerups<Race>_Small.bmp at 32*listIndex (list index from FUN_00439050); "+ n" at 562,540; the progress bar
-- BM_PRODUCTIONBAR at 319,464). Only drawn while something is producing (a production item is set).
function HUD:drawQueue(b)
    if not (b.current or b.waiting) then return end
    local g = love.graphics
    local world = self.screen.world
    local team = self.screen:teamColor(b.side)
    blit("ProductionSlots.bmp", 0, 0, 302, 78, 308, 502)
    local function icon(code, k)
        local x = 315 + 41 * (k - 1)
        if powerups.isPowerup(code) then
            local race = world.sides[b.side].race
            local idx = powerups.pictureIndex(rules.RACE_LETTER[race], code)
            if idx then blit("Powerups" .. powerups.PICTURE[race] .. "_Small.bmp", idx * 32, 0, 32, 50, x, 523) end
        else
            local set = anims.get(code)
            if set then set:drawInterface(1, x, 523, team) end
        end
    end
    if b.current then
        icon(b.current.code, 1)
    else
        blit("SelectionRings.bmp", 392 + 32 * (math.floor(world.time / 133) % 8), 619, 32, 50, 315, 523)
    end
    for k = 1, math.min(5, #b.queue) do icon(b.queue[k], k + 1) end
    local total = 1 + #b.queue
    if total > 6 then fonts.print(5, "+ " .. (total - 6), 562, 540) end
    -- the continuous army production button (FUN_004d7710: a 12x12 outline at 390,478
    -- filled 8x8 when on, the label of Game.txt 0523 at +14,+1)
    g.setColor(200 / 255, 200 / 255, 200 / 255)
    g.rectangle("line", 390, 478, 12, 12)
    if b.continuous then
        g.setColor(180 / 255, 180 / 255, 180 / 255)
        g.rectangle("fill", 392, 480, 8, 8)
    end
    g.setColor(1, 1, 1)
    fonts.print(2, strings.get("Game.txt", "0523") or "Continuous army production", 404, 479)
    if b.current then
        local p = math.max(0, math.min(1, (world.time - b.current.t0) / (b.current.t1 - b.current.t0)))
        blit("ProductionBar.bmp", 0, 0, 36, 36, 319, 464)
        g.setColor(0, 0, 0, 0.75)
        g.rectangle("fill", 321, 466, 32, 32 * (1 - p))
        g.setColor(1, 1, 1)
        fonts.print(2, ("%d%%"):format(math.floor(p * 100)), 319, 473, "center", 36)
    end
end

function HUD:drawCommands()
    local cmds = self:commands()
    local g = love.graphics
    local hover = self.hoverButton
    local col = hover and (hover + 1) or 0
    blit("Panel_Buttons.bmp", col * 134, self.pressedButton and 134 or 0, 134, 134, 649, 453)
    local icons = bitmap("Panel_Icons.bmp")
    for i = 0, 8 do
        local c, r = i % 3, math.floor(i / 3)
        local cmd = cmds[i + 1]
        if not cmd then
            blit("Panel_Buttons.bmp", 8 + 43 * c, 142 + 43 * r, 38, 38, 649 + 2 + 43 * c, 453 + 2 + 43 * r)
        elseif icons then
            local sy = (self.pressedButton == i) and 32 or 0
            if cmd.disabled then g.setColor(0.4, 0.4, 0.4) end
            g.draw(icons, quad(icons, (cmd.icon - 1) * 32, sy, 32, 32), 657 + 43 * c, 461 + 43 * r)
            g.setColor(1, 1, 1)
        end
    end
end

-- The hovered-unit preview: the original's auto data display area (101x132 at the right edge of the wide panel,
-- set up by FUN_004d6e00 only for widths 1024, 1280 and 1600; filled by the battle screen whenever the cursor rests
-- on an army or building, not traced in the 1.04 binary yet). It blits the interface picture (frame 3, 4 when
-- fog-hidden) at area+5,+15, a 46x8 border rectangle in the side colour at area+27,+109 around one of the
-- 16 health frames of SelectionRings.bmp (97, 7 * level, 44x7; level = 15 - 15 * hits / max), and the troop's
-- medals below it. openwbc3 puts the area in the extension bitmap right of the command buttons.
local PREVIEW_RGB = { [0] = { 200, 0, 0 }, { 0, 0, 200 }, { 0, 200, 0 }, { 150, 0, 200 }, { 50, 50, 50 },
                      { 200, 150, 0 }, { 125, 125, 125 } }

function HUD:drawPreview()
    local e = self.hoverEntity
    if not e or not self.previewVisible then return end
    if e.kind == "unit" and not e:alive() then self.hoverEntity = nil return end
    if e.kind == "building" and e.hp <= 0 then self.hoverEntity = nil return end
    local g = love.graphics
    local x = self.previewX
    if e.set then e.set:drawInterface(3, x + 5, 469, self.screen:teamColor(e.side)) end
    local barY = PANEL_Y - 2 + 90 + 15 + 5
    local rgb = PREVIEW_RGB[self.screen:teamColor(e.side)] or PREVIEW_RGB[6]
    g.setColor(rgb[1] / 255, rgb[2] / 255, rgb[3] / 255)
    g.rectangle("line", x + 27.5, barY - 0.5, 45, 7)
    g.setColor(1, 1, 1)
    local health = 15 - math.floor(15 * math.max(0, e.hp) / math.max(1, e.maxHp))
    if health < 0 then health = 0 end
    if health <= 15 then blit("SelectionRings.bmp", 97, health * 7, 44, 7, x + 28, barY) end
    -- medals of a plain troop: gold (level / 5) then silver (level % 5 + 1)
    if e.kind == "unit" and not e.hero and not unitMod.isCritter(e.code) then
        local lvl = e.level or 0
        local mx = x + 5
        for _ = 1, math.floor(lvl / 5) do
            blit("SkillIcons.bmp", 319, 108, 12, 12, mx, barY + 8)
            mx = mx + 12
        end
        for _ = 1, lvl % 5 + 1 do
            blit("SkillIcons.bmp", 306, 96, 12, 12, mx, barY + 8)
            mx = mx + 12
        end
    end
end

-- Top counters: army limit (left) and resources (right), in window space at scale s.
function HUD:drawTopCounters()
    local g = love.graphics
    local world = self.screen.world
    local s = self.s
    local side = world.sides[world.player]
    g.push()
    g.scale(s)
    local cur, max = world.eco:armyLimit(world.player)
    drawCounter(8, 5, 5)
    drawNumberCentred(cur, 5 + 25, 10)
    local set = anims.get("ERNX")
    if set then set:drawCell(0, 0, 10, 5 + 36, 10) end
    drawNumberCentred(max, 5 + 50, 10)
    local right = self.W / s
    local res = { { "gold", 0 }, { "metal", 2 }, { "stone", 1 }, { "crystal", 3 } }
    for k, r in ipairs(res) do
        local x = right - 225 + (k - 1) * 55
        drawCounter(r[2], x, 5, 50)
        drawNumberCentred(side[r[1]], x + 34, 10)
    end
    g.pop()
end

-- Running totals of the victory modes (razes, kills, keep level, lowest resource, flags): one counter per side at the
-- right edge below the resources, ERIX row 10 + side colour with the ERNX digits (the running total routine
-- FUN_004980a0: x = 730 widened to the screen, y = 90, rows 21 px apart, digits 8 px apart from x + 24, y + 5).
function HUD:drawRunningTotal(totals)
    local set = anims.get("ERNX")
    local bg = anims.get("ERIX")
    if not (set and bg) then return end
    local g = love.graphics
    local world = self.screen.world
    g.push()
    g.scale(self.s)
    local x = self.W / self.s - 70
    local y = 90
    for i = 0, 5 do
        local n = totals[i]
        if n then
            local colour = world.sides[i].color or i
            drawCounter(10 + colour, x, y, 60)
            local text = tostring(math.min(n, 9999))
            for k = 1, #text do
                set:drawCell(0, 0, tonumber(text:sub(k, k)) --[[@as integer]], x + 24 + (k - 1) * 8, y + 5)
            end
            y = y + 21
        end
    end
    g.pop()
end

-- Production / construction dialog ------------------------------------------------

function HUD:dialogItems()
    local d = self.dialog
    ---@cast d HUDProductionDialog|HUDBuildDialog
    local world = self.screen.world
    local items = {}
    if d.kind == "production" then
        for _, code in ipairs(world.eco:productionList(d.building)) do items[#items + 1] = code end
    else
        items = world.eco:constructionList(d.builder.side, d.row or 0)
    end
    local out = {}
    for i = 1, math.min(9, #items) do out[i] = items[i] end
    return out
end

function HUD:dialogRect()
    local s = self.s
    local W, H = love.graphics.getDimensions()
    local x = math.floor((W - 610 * s) / 2)
    local y = math.floor(self.oy + 6 * s)
    return x, y, s
end

function HUD:itemSlot(i)
    return 95 + (i - 1) % 4 * 107, 58 + math.floor((i - 1) / 4) * 107
end

function HUD:itemLegal(code)
    local d = self.dialog
    ---@cast d HUDProductionDialog|HUDBuildDialog
    local world = self.screen.world
    local side = d.kind == "production" and d.building.side or d.builder.side
    local ok = world.eco:requirementsMet(side, code)
    local info = world.eco:itemInfo(code, side)
    if ok and powerups.isPowerup(code) then ok = powerups.offered(world.sides[side], code) end
    return ok and info ~= nil, info
end

-- Repair dialog: anim EMDR (450x431) at 175,12 of the 800x600 layout, EMDF the slow / fast pictures (120x120, frame 1
-- = unavailable), EMDC the cancel button at 116,369; texts at the offsets of the original's drawing 0x0056c390 (a 25 px
-- shift of the picture column is already included below). Strings 0322-0324 of Game.txt.
local REPAIR_X, REPAIR_Y = 175, 12
local REPAIR_PIC_X, REPAIR_PIC_Y = 71, { 72, 207 }

function HUD:repairRect()
    local s = self.s
    return self.ox + REPAIR_X * s, self.oy + REPAIR_Y * s, s
end

-- Which of the two repair options can be started right now.
function HUD:repairAllowed()
    local b = self.dialog.building
    local world = self.screen.world
    local slow, fast = world.eco:repairCost(b)
    local side = world.sides[b.side]
    local function ok(cost)
        if b.repair or b.hp >= b.maxHp then return false end
        for _, r in ipairs(economy.RESOURCES) do
            if cost[r] > side[r] then return false end
        end
        return true
    end
    return ok(slow), ok(fast), slow, fast
end

function HUD:startRepair(speed)
    local slowOk, fastOk = self:repairAllowed()
    if (speed == 0 and slowOk) or (speed == 1 and fastOk) then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self.screen:issue({ t = "repair", bid = self.dialog.building.id, speed = speed })
        self.dialog = nil
    end
end

function HUD:drawRepairDialog()
    local g = love.graphics
    local x, y, s = self:repairRect()
    local b = self.dialog.building
    local slowOk, fastOk, slow, fast = self:repairAllowed()
    local busy = b.repair or b.hp >= b.maxHp
    g.push()
    g.translate(x, y)
    g.scale(s)
    local bg = anims.get("EMDR")
    if bg then bg:drawCell(0, 0, 0, 0, 0) end
    local mx, my = love.mouse.getPosition()
    local lx, ly = (mx - x) / s, (my - y) / s
    local overCancel = lx >= 116 and ly >= 369 and lx < 146 and ly < 399
    local cancel = anims.get("EMDC")
    if cancel then cancel:drawCell(0, overCancel and (love.mouse.isDown(1) and 2 or 1) or 0, 0, 116, 369) end
    fonts.print(1, strings.get("Game.txt", "0322") or "Repairs", 0, 14, "center", 436)
    local pics = anims.get("EMDF")
    local rows = { { ok = slowOk, cost = slow, name = "0323", time = economy.REPAIR_SECONDS[0] },
                   { ok = fastOk, cost = fast, name = "0324", time = economy.REPAIR_SECONDS[1] } }
    local dy = { 0, 135 }
    for i, row in ipairs(rows) do
        if pics then pics:drawCell(0, i - 1, row.ok and 0 or 1, REPAIR_PIC_X, REPAIR_PIC_Y[i]) end
        local oy = dy[i]
        fonts.print(2, strings.get("Game.txt", row.name) or "", 214, 74 + oy)
        local function v(n) return busy and "-" or tostring(n) end
        fonts.print(2, v(row.cost.gold), 229, 101 + oy)
        fonts.print(2, v(row.cost.stone), 300, 101 + oy)
        fonts.print(2, v(row.cost.metal), 229, 126 + oy)
        fonts.print(2, v(row.cost.crystal), 300, 126 + oy)
        fonts.print(2, v(row.time), 256, 159 + oy)
    end
    local left = b.repair and math.max(0, math.floor((b.repair.t1 - self.screen.world.time) / 1000)) or nil
    fonts.print(2, ("%d/%d"):format(math.floor(b.hp), b.maxHp), 217, 343)
    fonts.print(2, left and tostring(left) or "-", 331, 343)
    g.pop()
end

function HUD:repairClick(x, y)
    local dx, dy, s = self:repairRect()
    local lx, ly = (x - dx) / s, (y - dy) / s
    if lx < 0 or ly < 0 or lx > 450 or ly > 431 then
        self.dialog = nil
        return true
    end
    if lx >= 116 and ly >= 369 and lx < 146 and ly < 399 then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self.dialog = nil
        return true
    end
    if lx >= 71 and lx <= 345 then
        if ly >= 72 and ly <= 192 then self:startRepair(0)
        elseif ly >= 207 and ly <= 327 then self:startRepair(1) end
    end
    return true
end

-- Diplomacy dialog (Alt+D): send resources to another side. Anim EMDA (450x431) at 320,12; the amount, resource and
-- side buttons are painted into the background, the chosen ones get a brown frame; shields are frames of ESHD.
-- Coordinates are those of the original alliance dialog (constructor FUN_00558810, button hit test FUN_00558e20).
local DIPLO_X, DIPLO_Y = 320, 12
local DIPLO_AMOUNT = { x = 75, y = 129, w = 48, h = 27, dy = 27 }
local DIPLO_RES = { x = 146, y = 121, w = 53, h = 46, dy = 46 }
local DIPLO_SIDE = { x = 227, y = 107, w = 140, h = 35, dy = 35 }
local DIPLO_SEND = { x = 92, y = 336, w = 255, h = 34 }

function HUD:openDiplomacy()
    if self.screen.result or self.screen.world.opts.tutorial or self.dialog then return end
    self.dialog = { kind = "diplomacy" }
end

function HUD:diploRect()
    local s = self.s
    return self.ox + DIPLO_X * s, self.oy + DIPLO_Y * s, s
end

-- Sides that can receive resources.
function HUD:diploSide(i)
    local world = self.screen.world
    local sd = world.sides[i]
    return i <= 5 and sd.used and not sd.defeated and i ~= world.player
end

-- Button under dialog-local (x, y): "amount" | "res" | "side" | "send", index
function HUD:diploButton(x, y)
    local function inside(b, i) return x > b.x and x < b.x + b.w and y > b.y + b.dy * i and y < b.y + b.dy * i + b.h end
    for i = 0, 5 do if inside(DIPLO_AMOUNT, i) then return "amount", i end end
    for i = 0, 3 do if inside(DIPLO_RES, i) then return "res", i end end
    for i = 0, 5 do
        if self:diploSide(i) and inside(DIPLO_SIDE, i) then return "side", i end
    end
    if x > DIPLO_SEND.x and x < DIPLO_SEND.x + DIPLO_SEND.w and y > DIPLO_SEND.y and y < DIPLO_SEND.y + DIPLO_SEND.h then
        return "send", 0
    end
end

function HUD:drawDiplomacyDialog()
    local g = love.graphics
    local x, y, s = self:diploRect()
    local d = self.dialog
    ---@cast d HUDDiplomacyDialog
    local world = self.screen.world
    g.push()
    g.translate(x, y)
    g.scale(s)
    local bg = anims.get("EMDA")
    if bg then bg:drawCell(0, 0, 0, 0, 0) end
    local mx, my = love.mouse.getPosition()
    local lx, ly = (mx - x) / s, (my - y) / s
    local cancel = anims.get("EMDC")
    local over = lx >= 205 and ly >= 369 and lx < 235 and ly < 399
    if cancel then cancel:drawCell(0, over and (love.mouse.isDown(1) and 2 or 1) or 0, 0, 205, 369) end
    fonts.print(1, strings.get("Game.txt", "0295") or "Diplomacy", 0, 12, "center", 438)
    for k, key in ipairs({ "0296", "0297", "0298" }) do
        fonts.print(2, strings.get("Game.txt", key) or "", ({ 87, 236, 322 })[k], 80)
    end
    local shields = anims.get("ESHD")
    for i = 0, 5 do
        local sd = world.sides[i]
        if sd.used and not sd.defeated then
            local top = DIPLO_SIDE.y + DIPLO_SIDE.dy * i
            g.setScissor()
            if shields then shields:drawCell(0, 0, sd.color or 0, 235, 114 + 35 * i) end
            fonts.print(2, world:sideName(i), DIPLO_SIDE.x + 38, top + 11)
            fonts.print(2, sd.team == 0 and "-" or tostring(sd.team), DIPLO_SIDE.x + 122, top + 11)
        end
    end
    local function frame(rx, ry, w, h)
        g.setColor(150 / 255, 90 / 255, 50 / 255)
        g.setLineWidth(2)
        g.rectangle("line", rx, ry, w, h)
        g.setLineWidth(1)
        g.setColor(1, 1, 1)
    end
    local text = ""
    if d.amount then
        frame(DIPLO_AMOUNT.x, DIPLO_AMOUNT.y - 1 + d.amount * DIPLO_AMOUNT.dy, DIPLO_AMOUNT.w, DIPLO_AMOUNT.h)
        text = tostring(economy.GIFT_AMOUNTS[d.amount + 1])
    end
    if d.res then
        frame(DIPLO_RES.x, DIPLO_RES.y - 1 + d.res * DIPLO_RES.dy, DIPLO_RES.w, DIPLO_RES.h)
        text = text .. " " .. (strings.get("Game.txt", ("%04d"):format(250 + d.res)) or "") .. " -> "
    end
    if d.side then
        frame(DIPLO_SIDE.x + 5, DIPLO_SIDE.y + 4 + d.side * DIPLO_SIDE.dy, 31, 26)
        text = text .. world:sideName(d.side)
    end
    if d.sent then text = strings.get("Game.txt", "0299") or "Resources Sent" end
    if text ~= "" then fonts.print(2, text, DIPLO_SEND.x, DIPLO_SEND.y + 1, "center", DIPLO_SEND.w) end
    g.pop()
end

function HUD:diplomacyClick(x, y)
    local dx, dy, s = self:diploRect()
    local lx, ly = (x - dx) / s, (y - dy) / s
    if lx < 0 or ly < 0 or lx > 450 or ly > 431 then
        self.dialog = nil
        return true
    end
    if lx >= 205 and ly >= 369 and lx < 235 and ly < 399 then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self.dialog = nil
        return true
    end
    local d = self.dialog
    ---@cast d HUDDiplomacyDialog
    local kind, i = self:diploButton(lx, ly)
    if kind == "amount" then d.amount, d.sent = i, nil
    elseif kind == "res" then d.res, d.sent = i, nil
    elseif kind == "side" then d.side, d.sent = i, nil
    elseif kind == "send" and d.amount and d.res and d.side then
        local world = self.screen.world
        local res = economy.GIFT_RESOURCES[d.res]
        local amount = economy.GIFT_AMOUNTS[d.amount + 1]
        if world.sides[world.player][res] >= amount then
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self.screen:issue({ t = "gift", to = d.side, res = res, amount = amount })
            self.dialog = nil
        else
            sound.play("Assets/SoundFX.xcr", "Error.wav")
        end
    end
    return true
end

-- Trade dialog (market): anim EMDX (450x431) at 175,12. Source column x 143-213, destination x 244-325, amount column
-- x 48-119 (hit areas, 46 / 27 px rows from y 120 / 130); the chosen ones get a frame; result line at y 72, the
-- "Trade" button at 108,333 (224x24), the rate at 330,374. The last choice is remembered like in the original.
local tradeLast = { src = -1, dst = -1, amt = 2 }

function HUD:tradeRate()
    return abilities.tradeRate(self.screen.world, self.screen.world.player)
end

-- (source, destination, amount) from a position inside the dialog, as button kind + index
local function tradeButton(x, y)
    if x > 143 and x < 213 then
        for i = 0, 3 do if y >= 120 + 46 * i and y < 166 + 46 * i then return "src", i end end
    elseif x > 244 and x < 325 then
        for i = 0, 3 do if y >= 120 + 46 * i and y < 166 + 46 * i then return "dst", i end end
    elseif x > 48 and x < 119 then
        for i = 0, 5 do if y >= 130 + 27 * i and y < 157 + 27 * i then return "amt", i end end
    end
end

function HUD:tradeAmount()
    local side = self.screen.world.sides[self.screen.world.player]
    local amount = economy.GIFT_AMOUNTS[tradeLast.amt + 1]
    local src, dst = economy.GIFT_RESOURCES[tradeLast.src], economy.GIFT_RESOURCES[tradeLast.dst]
    if not src or not dst then return 0 end
    amount = math.min(amount, side[src])
    local rate = self:tradeRate()
    local room = self.screen.world.eco:cap(self.screen.world.player) - side[dst]
    if math.floor(amount * rate / 100) > room then amount = math.floor(100 * math.max(0, room) / rate) end
    return amount
end

function HUD:drawTradeDialog()
    local g = love.graphics
    local x, y, s = self:repairRect()
    g.push()
    g.translate(x, y)
    g.scale(s)
    local bg = anims.get("EMDX")
    if bg then bg:drawCell(0, 0, 0, 0, 0) end
    local mx, my = love.mouse.getPosition()
    local lx, ly = (mx - x) / s, (my - y) / s
    local cancel = anims.get("EMDC")
    local over = lx >= 204 and ly >= 369 and lx < 234 and ly < 399
    if cancel then cancel:drawCell(0, over and (love.mouse.isDown(1) and 2 or 1) or 0, 0, 204, 369) end
    local title = strings.get("Game.txt", "0116") or "Trade"
    fonts.print(1, title, 0, 14, "center", 432)
    local function frame(rx, ry, w, h)
        g.setColor(220 / 255, 180 / 255, 100 / 255)
        g.setLineWidth(2)
        g.rectangle("line", rx, ry, w, h)
        g.setLineWidth(1)
        g.setColor(1, 1, 1)
    end
    local legal = tradeLast.src >= 0 and tradeLast.dst >= 0 and tradeLast.src ~= tradeLast.dst
    if tradeLast.amt >= 0 then frame(81, 129 + tradeLast.amt * 27, 58, 28) end
    if tradeLast.src >= 0 then frame(170, 120 + tradeLast.src * 46, 62, 46) end
    if tradeLast.dst >= 0 then frame(278, 120 + tradeLast.dst * 46, 62, 46) end
    if legal then
        local amount = self:tradeAmount()
        local got = math.floor(amount * self:tradeRate() / 100)
        local a = (strings.get("Game.txt", ("%04d"):format(119 + tradeLast.src)) or "%d"):format(amount)
        local b = (strings.get("Game.txt", ("%04d"):format(119 + tradeLast.dst)) or "%d"):format(got)
        fonts.print(2, a .. " -> " .. b, 0, 70, "center", 432)
    end
    if not legal then g.setColor(0.5, 0.5, 0.5) end
    fonts.print(2, title, 108, 337, "center", 224)
    g.setColor(1, 1, 1)
    fonts.print(2, ("%d %%"):format(self:tradeRate()), 316, 372)
    g.pop()
end

function HUD:tradeClick(x, y)
    local dx, dy, s = self:repairRect()
    local lx, ly = (x - dx) / s, (y - dy) / s
    if lx < 0 or ly < 0 or lx > 450 or ly > 431 then
        self.dialog = nil
        return true
    end
    if lx >= 204 and ly >= 369 and lx < 234 and ly < 399 then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self.dialog = nil
        return true
    end
    local kind, i = tradeButton(lx, ly)
    if kind then
        tradeLast[kind] = i
        return true
    end
    if lx >= 108 and lx < 332 and ly >= 333 and ly < 357 and tradeLast.src >= 0 and tradeLast.dst >= 0
        and tradeLast.src ~= tradeLast.dst then
        self.screen:issue({ t = "trade", from = tradeLast.src, to = tradeLast.dst, amount = economy.GIFT_AMOUNTS[tradeLast.amt + 1] })
        sound.play("Assets/SoundFX.xcr", "Bing.WAV")
    end
    return true
end

-- Attitude dialog: a list popup at the cursor (Ctrl+right click, or the attitude button).
local ATT_W, ATT_ROW = 190, 18

function HUD:openAttitude(x, y)
    local own = false
    for _, e in ipairs(self:selection()) do
        if e.side == self.screen.world.player then own = true end
    end
    if not own then return end
    if not x then x, y = love.mouse.getPosition() end
    local lx, ly = self:toLayout(x, y)
    local list = {}
    local anyUnit = #self:selectedOwnUnits() > 0
    for _, a in ipairs(attitudes.list()) do
        -- Guardian / Magic Guardian designate a unit to guard: units only
        if anyUnit or not attitudes.def[a].designated then list[#list + 1] = a end
    end
    table.sort(list, function(a, b) return attitudes.name(a):lower() < attitudes.name(b):lower() end)
    self.dialog = { kind = "attitude", list = list, x = math.max(4, math.min(lx - ATT_W / 2, 800 - ATT_W - 4)),
                    y = math.max(4, math.min(ly - 10, 590 - #list * ATT_ROW - 30)) }
end

function HUD:attitudeHit(lx, ly)
    local d = self.dialog
    ---@cast d HUDAttitudeDialog
    if lx < d.x or lx > d.x + ATT_W or ly < d.y + 22 then return nil end
    local i = math.floor((ly - d.y - 22) / ATT_ROW) + 1
    if not d.list[i] then return nil end
    return d.list[i], i
end

function HUD:drawAttitudeDialog()
    local g = love.graphics
    local d = self.dialog
    ---@cast d HUDAttitudeDialog
    local first
    for _, e in ipairs(self:selection()) do if e.side == self.screen.world.player then first = e break end end
    local current = first and (first.kind == "unit" and attitudes.of(first) or first.attitude) or attitudes.DEFAULT
    local mx, my = love.mouse.getPosition()
    local lx, ly = self:toLayout(mx, my)
    g.push()
    g.translate(self.ox, self.oy)
    g.scale(self.s)
    local h = 22 + #d.list * ATT_ROW + 22
    g.setColor(0.12, 0.02, 0.02, 0.95)
    g.rectangle("fill", d.x, d.y, ATT_W, h)
    g.setColor(220 / 255, 180 / 255, 120 / 255)
    g.rectangle("line", d.x + 0.5, d.y + 0.5, ATT_W - 1, h - 1)
    g.setColor(1, 1, 1)
    fonts.print(2, strings.get("Game.txt", "0071") or "Attitude", d.x, d.y + 3, "center", ATT_W)
    local _, hover = self:attitudeHit(lx, ly)
    for i, a in ipairs(d.list) do
        local y = d.y + 22 + (i - 1) * ATT_ROW
        if i == hover then g.setColor(0.5, 0.2, 0.1, 0.7) g.rectangle("fill", d.x + 2, y, ATT_W - 4, ATT_ROW) g.setColor(1, 1, 1) end
        if a == current then g.setColor(1, 0.9, 0.5) end
        fonts.print(2, attitudes.name(a), d.x + 10, y + 1)
        g.setColor(1, 1, 1)
    end
    if hover then
        local fy = d.y + 22 + #d.list * ATT_ROW + 3
        local lines = widgets.wrap(2, attitudes.description(d.list[hover]), ATT_W - 12)
        fonts.print(2, lines[1] or "", d.x + 6, fy)
    end
    g.pop()
end

function HUD:attitudeClick(x, y)
    local lx, ly = self:toLayout(x, y)
    local a = self:attitudeHit(lx, ly)
    local d = self.dialog
    if a then
        local ids, bids = {}, {}
        for _, e in ipairs(self:selection()) do
            if e.side == self.screen.world.player then
                if e.kind == "unit" then ids[#ids + 1] = e.id else bids[#bids + 1] = e.id end
            end
        end
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        if attitudes.def[a].designated then
            -- the click on a friendly unit designates it (handed on by FUN_00507010); it sends the guard order
            self.mode, self.guardAttitude = "guard", a
            self.screen:notify(attitudes.description(a), 3)
        else
            self.screen:issue({ t = "attitude", ids = ids, bids = bids, attitude = a })
        end
    end
    self.dialog = nil
    return true
end

-- Whether the mouse is over one of the open dialog's controls: the question every dialog class of the
-- original answers in its cursor method (trade 0x00572dd0, production FUN_00568e30, repair 0x0056c0c0; those of the
-- alliance and attitude dialogs are not traced in the 1.04 binary yet), which shows POINTER over an active control
-- and POINTERUP elsewhere inside the dialog.
---@return boolean
function HUD:dialogOver(mx, my)
    local d = self.dialog
    if not d then return false end
    if d.kind == "attitude" then
        local lx, ly = self:toLayout(mx, my)
        return (self:attitudeHit(lx, ly)) ~= nil
    end
    local x, y, s
    if d.kind == "repair" or d.kind == "trade" then x, y, s = self:repairRect()
    elseif d.kind == "diplomacy" then x, y, s = self:diploRect()
    else x, y, s = self:dialogRect() end
    local lx, ly = (mx - x) / s, (my - y) / s
    if d.kind == "diplomacy" then
        if lx >= 205 and ly >= 369 and lx < 235 and ly < 399 then return true end
        return (self:diploButton(lx, ly)) ~= nil
    end
    if d.kind == "trade" then
        if lx >= 204 and ly >= 369 and lx < 234 and ly < 399 then return true end
        if tradeButton(lx, ly) then return true end
        return lx >= 108 and lx < 332 and ly >= 333 and ly < 357
            and tradeLast.src >= 0 and tradeLast.dst >= 0 and tradeLast.src ~= tradeLast.dst
    end
    if d.kind == "repair" then
        if lx >= 116 and ly >= 369 and lx < 146 and ly < 399 then return true end
        local slowOk, fastOk = self:repairAllowed()
        if lx >= 71 and lx <= 345 then
            if ly >= 72 and ly <= 192 then return slowOk end
            if ly >= 207 and ly <= 327 then return fastOk end
        end
        return false
    end
    -- production / construction: the cancel cross and the item pictures that can be queued
    if lx >= 285 and ly >= 386 and lx < 315 and ly < 416 then return true end
    for i, code in ipairs(self:dialogItems()) do
        if self:itemLegal(code) then
            local ix, iy = self:itemSlot(i)
            if lx >= ix and ly >= iy and lx < ix + 90 and ly < iy + 90 then return true end
        end
    end
    return false
end

function HUD:drawDialog()
    if self.dialog.kind == "attitude" then return self:drawAttitudeDialog() end
    if self.dialog.kind == "trade" then return self:drawTradeDialog() end
    if self.dialog.kind == "repair" then return self:drawRepairDialog() end
    if self.dialog.kind == "diplomacy" then return self:drawDiplomacyDialog() end
    local g = love.graphics
    local x, y, s = self:dialogRect()
    local world = self.screen.world
    g.push()
    g.translate(x, y)
    g.scale(s)
    local bg = anims.get("EMDP")
    if bg then
        bg:drawCell(0, 0, 0, 0, 0)
        bg:drawCell(5, 0, 0, 0, 0)
    else
        g.setColor(0.1, 0.08, 0.05, 0.95)
        g.rectangle("fill", 0, 0, 610, 450)
        g.setColor(1, 1, 1)
    end
    local d = self.dialog
    ---@cast d HUDProductionDialog|HUDBuildDialog
    local title = d.kind == "production" and (d.building.name or d.building.code) or "Construct"
    fonts.print(1, title, 0, 14, "center", 610)
    local team = self.screen:teamColor(world.player)
    local items = self:dialogItems()
    local mx, my = love.mouse.getPosition()
    local lx, ly = (mx - x) / s, (my - y) / s
    self.dialogHover = nil
    for i, code in ipairs(items) do
        local ix, iy = self:itemSlot(i)
        local legal, info = self:itemLegal(code)
        if powerups.isPowerup(code) then
            -- power-up pictures: 90x90 cells of Powerups<Race>.bmp in the race's list order, greyed row below
            local race = world.sides[d.building.side].race
            local idx = powerups.pictureIndex(rules.RACE_LETTER[race], code)
            if idx then blit("Powerups" .. powerups.PICTURE[race] .. ".bmp", idx * 90, legal and 0 or 90, 90, 90, ix, iy) end
        else
            local set = anims.get(code)
            if set then set:drawInterface(legal and 3 or 4, ix, iy, team) end
        end
        if lx >= ix and ly >= iy and lx < ix + 90 and ly < iy + 90 then
            self.dialogHover = i
            g.setColor(1, 0.9, 0.5)
            g.rectangle("line", ix - 1, iy - 1, 92, 92)
            g.setColor(1, 1, 1)
            self.dialogTip = { code = code, info = info, legal = legal }
        end
        if info then
            -- costs stacked upwards from the bottom of the item
            local rows = { { "gold", 4 }, { "metal", 6 }, { "stone", 5 }, { "crystal", 7 } }
            local cy = iy + 69
            for _, r in ipairs(rows) do
                local v = info.cost[r[1]] or 0
                if v > 0 then
                    drawCounter(r[2], ix, cy, 40)
                    drawNumber(v, ix + 16, cy + 5)
                    cy = cy - 21
                end
            end
        end
        if d.kind == "production" then
            local n = 0
            for _, q in ipairs(d.building.queue) do if q == code then n = n + 1 end end
            if d.building.current and d.building.current.code == code then n = n + 1 end
            if n > 0 then fonts.print(5, "x" .. n, ix + 60, iy + 4) end
        end
    end
    if not self.dialogHover then self.dialogTip = nil end
    local cancel = anims.get("EMDC")
    if cancel then cancel:drawCell(0, self.cancelHover and 1 or 0, 0, 285, 386) end
    self.cancelHover = lx >= 285 and ly >= 386 and lx < 315 and ly < 416
    if d.overlay then self:drawOverlay(d.overlay) end
    g.pop()
    local tip = self.dialogTip
    if tip then
        local h = strings.help(tip.code)
        local lines = {}
        if powerups.isPowerup(tip.code) then
            h.lines = { powerups.name(tip.code), powerups.description(tip.code) }
            h.requires = powerups.requirementText(tip.code)
        end
        lines[1] = h.lines[1] or (tip.info and tip.info.name) or tip.code
        if h.lines[2] then lines[#lines + 1] = h.lines[2] end
        if h.lines[3] then lines[#lines + 1] = h.lines[3] end
        if not tip.legal and h.requires then lines[#lines + 1] = h.requires end
        self:tooltip(lines, mx, my)
    end
end

-- Tooltip in window coordinates: dark red gradient box with a gold border.
function HUD:tooltip(lines, mx, my)
    -- options "Popup Help": None shows no popups, Some only the title line (the popup texts FUN_00414940 /
    -- FUN_00414ef0: help level DAT_00608338 <= 1 drops the details)
    local level = require("src.core.gameopts").helpLevel()
    if level <= 0 then return end
    if level == 1 and #lines > 1 then lines = { lines[1] } end
    local g = love.graphics
    local s = self.s
    local d, f = fonts.get(2)
    if not f then return end
    local w = 0
    for _, l in ipairs(lines) do w = math.max(w, f:getWidth(l)) end
    w = w + 12
    local h = #lines * 15 + 8
    g.push()
    g.scale(s)
    local x = math.max(2, math.min(mx / s - w / 2, self.W / s - w - 2))
    local y = my / s + 26
    if y + h > self.H / s - 2 then y = my / s - h - 12 end
    g.setColor(0.12, 0.02, 0.02, 0.92)
    g.rectangle("fill", x, y, w, h)
    g.setColor(220 / 255, 180 / 255, 120 / 255)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    g.setColor(1, 1, 1)
    for i, l in ipairs(lines) do fonts.print(2, l, x + 6, y + 4 + (i - 1) * 15) end
    g.pop()
end

local COMMAND_TIPS = { stop = "Stop (S)", move = "Move (M)", attack = "Attack (A)", convert = "Convert (C)",
                       build = "Build (B)", walls = "Build walls (W)", production = "Production", rally = "Set rally point", cancel = "Cancel production",
                       previous = "Back", unload = "Leave the building", repair = "Repair (E)", patrol = "Patrol (P)",
                       guard = "Guard (G)", attitude = "Attitude", spells = "Spells" }

function HUD:drawCommandTip()
    if self.hoverSpell and not self.dialog then
        local mx, my = love.mouse.getPosition()
        self:tooltip(spellbar.tooltipLines(self, self.hoverSpell), mx, my - 120 * self.s)
        return
    end
    if self.hoverPanel and not self.dialog then
        local mx, my = love.mouse.getPosition()
        self:tooltip({ self.hoverPanel.tip }, mx, my - 50 * self.s)
        return
    end
    if self.dialog or not self.hoverButton then return end
    local cmd = self:commands()[self.hoverButton + 1]
    if not cmd then return end
    local mx, my = love.mouse.getPosition()
    self:tooltip({ cmd.tip or COMMAND_TIPS[cmd.action] or cmd.action }, mx, my - 70 * self.s)
end

function HUD:dialogClick(x, y, button)
    if self.dialog.kind == "attitude" then return self:attitudeClick(x, y) end
    if self.dialog.kind == "trade" then return self:tradeClick(x, y) end
    if self.dialog.kind == "repair" then return self:repairClick(x, y) end
    if self.dialog.kind == "diplomacy" then return self:diplomacyClick(x, y) end
    local dx, dy, s = self:dialogRect()
    local lx, ly = (x - dx) / s, (y - dy) / s
    if lx < 0 or ly < 0 or lx > 610 or ly > 450 then
        self.dialog = nil
        return true
    end
    if lx >= 285 and ly >= 386 and lx < 315 and ly < 416 then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self.dialog = nil
        return true
    end
    local d = self.dialog
    ---@cast d HUDProductionDialog|HUDBuildDialog
    local world = self.screen.world
    for i, code in ipairs(self:dialogItems()) do
        local ix, iy = self:itemSlot(i)
        if lx >= ix and ly >= iy and lx < ix + 90 and ly < iy + 90 then
            local legal = self:itemLegal(code)
            if not legal then
                sound.play("Assets/SoundFX.xcr", "Error.wav")
                return true
            end
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            if d.kind == "production" then
                local n = (button == 2 or love.keyboard.isDown("lshift", "rshift")) and 5 or 1
                self.screen:issue({ t = "enqueue", bid = d.building.id, code = code, n = n })
            else
                self.dialog = nil
                self.mode = "place"
                self.placeCode = code
                self.placeBuilder = d.builder
            end
            return true
        end
    end
    return true
end

-- Input --------------------------------------------------------------------------------

-- The command button (0..8) at a layout position.
---@return integer?
function HUD:buttonAt(lx, ly)
    if lx < 649 or ly < 453 or lx >= 649 + 134 or ly >= 453 + 134 then return nil end
    return math.floor((lx - 649) / 45) + math.floor((ly - 453) / 45) * 3
end

-- Starts casting spell `id` (asks for a target when the spell needs one).
---@param id integer?
function HUD:castSpell(id)
    local hero = self:hero()
    local screen = self.screen
    if not hero or not hero.h or not id then return end
    local ok, why = spells.canCast(hero, id)
    if not ok then
        screen:notify(why == "mana" and "Not enough mana" or "Cannot cast now", 2)
        if why == "mana" then require("src.audio.voices").say(hero, "Mana") end    -- the hero's Mana speech
        if why == "recovering" and screen.fx then screen.fx:recovering(hero) end   -- the recovering text over the hero
        sound.play("Assets/SoundFX.xcr", "Error.wav")
        return
    end
    local kind = spells.targetKind(id)
    if kind == "none" then
        screen:issue({ t = "cast", id = hero.id, spell = id })
    elseif kind == "choice" or kind == "weather" then
        -- the four-picture dialog of the four-choice spells (FUN_005717e0 -> FUN_0055bc90); its pick is the cast
        require("src.core.screens").push(require("src.screens.spellchoice"), screen, hero, id)
    else
        self.mode, self.spellId = "spell", id
        screen:notify(({ ground = "Choose a place for %s", enemy = "Choose an enemy for %s", ally = "Choose a unit for %s" })[kind]
            :format(spells.name(id)), 3)
    end
end

-- F1..F8: the spell assigned in the spell book (the 8 shortcut slots of FUN_004258a0 / FUN_004258f0); nothing when none
-- is assigned.
---@param n integer
function HUD:castSlot(n)
    local hero = self:hero()
    if not hero or not hero.h then return end
    local id = hero.h.shortcuts[n]
    if id and id >= 0 and hero.h.spells[id] then self:castSpell(id) end
end

function HUD:mousemoved(x, y)
    self:layout()
    local _, spellId = spellbar.at(self, x, y)
    self.hoverSpell = spellId
    local lx, ly = self:toLayout(x, y)
    self.hoverPanel = ly >= 450 and self:panelButtonAt(lx, ly) or nil
    self.overPortrait = ly >= 450 and lx >= 185 and lx < 283 and ly >= 456 and ly < 554
    local b = self:buttonAt(lx, ly)
    if b and self:commands()[b + 1] then self.hoverButton = b else self.hoverButton = nil end
    -- the hovered unit / building feeds the preview (the original's battle screen sets the auto
    -- data display from the cursor position; hidden ones stay unset, its point query FUN_00548360
    -- uses the visible filter)
    if ly < 450 then
        local wx, wy = self.screen:toWorld(x, y)
        local e = self.screen.world:pick(wx, wy)
        self.hoverEntity = (e and self.screen:shown(e)) and e or nil
    else
        self.hoverEntity = nil
    end
end

-- Returns true when the click was consumed by the interface.
---@param x number
---@param y number
---@param button integer
---@return boolean consumed
function HUD:mousepressed(x, y, button)
    self:layout()
    if self.tutorial and self:tutorialPressed(x, y) then return true end
    if self.dialog then return self:dialogClick(x, y, button) end
    local slot, sid = spellbar.at(self, x, y)
    if slot then
        if button == 1 then self:castSpell(sid) end
        return true
    end
    local lx, ly = self:toLayout(x, y)
    if ly < 450 then return false end
    local pb = button == 1 and self:panelButtonAt(lx, ly)
    if pb then
        self.pressedPanel = pb
        return true
    end
    if lx >= 185 and lx < 283 and ly >= 456 and ly < 554 and self:hero() then
        local hero = self:hero()
        ---@cast hero -nil           tested above
        if button == 1 and hero.h and hero.h.latch then
            -- a level-up waits: the click opens the spending screens (binary FUN_004d54c0: with the latch set the portrait
            -- click opens the attribute screen, else the skill screen, else clears the latch)
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self.screen:openHero(1, true)
        elseif button == 1 then
            -- left click selects the hero (and centres the view on a second click)
            if #self.screen.selection == 1 and self.screen.selection[1] == hero then
                self.screen:centreOn(hero.x, hero.y)
            else
                self.screen:select({ hero })
            end
        elseif button == 2 then
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self.screen:openHero(1, hero.h and hero.h.latch)
        end
        return true
    end
    -- right-click on the info area pages through a hero's info (stats / overview / skills)
    if button == 2 and #self:selection() == 1 then
        local u = self:selection()[1]
        if u.kind == "unit" and lx >= 304 and lx < 646 and ly >= 456 and ly < 584 then
            local count = (u.hero and u.h) and 4 or 2
            self.infoPage = ((self.infoPage or 0) + 1) % count
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            return true
        end
    end
    local b = self:buttonAt(lx, ly)
    if b and button == 1 then
        local cmd = self:commands()[b + 1]
        if cmd and cmd.disabled then
            sound.play("Assets/SoundFX.xcr", "Error.wav")
        elseif cmd then
            self.pressedButton = b
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self:runCommand(cmd.action)
        end
        return true
    end
    -- a click on a unit in the selected-units bar selects that single unit (left) or drops it from the group (right)
    if #self:selection() > 1 then
        local cells = self:unitBar()
        local col, row = math.floor((lx - 310) / 29), math.floor((ly - 468) / 29)
        local u = (col >= 0 and col < 8 and row >= 0 and row < 4) and cells[col + row * 8] or nil
        if u then
            if button == 1 then
                self.screen:select({ u })
            elseif button == 2 then
                local rest = {}
                for _, e in ipairs(self:selection()) do
                    if e ~= u then rest[#rest + 1] = e end
                end
                self.screen:select(rest, true)
            end
            return true
        end
    end
    -- a click on a production queue slot removes that item (the panel's mouse press FUN_004d54c0 passes
    -- the slot to the queue removal FUN_0052d8a0; slot 0 cancels the running one and
    -- does nothing while the queue is waiting)
    local first = self:selection()[1]
    -- a click on a garrisoned army of the tower page lets that army out (info-area parts 0x2a..0x2d of
    -- FUN_004d54c0, released by FUN_0052dc40)
    if first and first.kind == "building" and button == 1 and first.side == self.screen.world.player and first.garrison then
        for n, g in ipairs(first.garrison) do
            local sx, sy = garrisonSlot(n)
            if n <= 4 and lx >= sx and lx < sx + 29 and ly >= sy and ly < sy + 29 then
                self.screen:issue({ t = "unload", bid = first.id, uid = g.id })
                return true
            end
        end
    end
    -- the continuous army production button (FUN_004d54c0, part 0x36: a 128x14 area at 390,478 toggles it)
    if first and first.kind == "building" and button == 1 and (first.current or first.waiting) and lx >= 390 and lx < 390 + 128 and ly >= 478 and ly < 478 + 14 then
        self.screen:issue({ t = "continuous", bid = first.id })
        return true
    end
    if first and first.kind == "building" and button == 1 and ly >= 523 and ly < 573 and lx >= 315 and lx < 315 + 41 * 6 then
        local k = math.floor((lx - 315) / 41) + 1
        if k == 1 then
            if first.current then
                self.screen:issue({ t = "cancel", bid = first.id })
            elseif not first.waiting and first.queue[1] then
                self.screen:issue({ t = "dequeue", bid = first.id, index = 1 })
            end
        else
            local idx = k - ((first.current or first.waiting) and 1 or 0)
            if first.queue[idx] then self.screen:issue({ t = "dequeue", bid = first.id, index = idx }) end
        end
        return true
    end
    -- minimap
    if lx >= 20 and ly >= 456 and lx < 148 and ly < 584 then
        local world = self.screen.world
        local wx = (lx - 20) / 128 * world.terrain.pixelW
        local wy = (ly - 456) / 128 * world.terrain.pixelH
        if button == 1 then
            self.miniDrag = true
            self.screen:centreOn(wx, wy)
        elseif button == 2 then
            self.screen:command(wx, wy)
        end
        return true
    end
    return true
end

---@return boolean consumed
function HUD:mousereleased(x, y, button)
    self.pressedButton = nil
    if self.tutorial and self.tutorial.cancelDown then return self:tutorialReleased(x, y) end
    local pb = self.pressedPanel
    if pb then
        self.pressedPanel = nil
        self:layout()
        local lx, ly = self:toLayout(x, y)
        if self:panelButtonAt(lx, ly) == pb and (self:hero() or (pb.id ~= "hero" and pb.id ~= "skills")) then
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self:runPanelButton(pb)
        end
        return true
    end
    if self.miniDrag and button == 1 then
        self.miniDrag = false
        return true
    end
    return false
end

function HUD:update()
    if self.miniDrag then
        self:layout()
        local x, y = love.mouse.getPosition()
        local lx, ly = self:toLayout(x, y)
        local world = self.screen.world
        lx = math.max(20, math.min(147, lx))
        ly = math.max(456, math.min(583, ly))
        self.screen:centreOn((lx - 20) / 128 * world.terrain.pixelW, (ly - 456) / 128 * world.terrain.pixelH)
    end
    -- close dialogs whose subject vanished
    local d = self.dialog
    if d and d.kind ~= "diplomacy" and d.kind ~= "attitude" then
        local subject = d.building or d.builder
        if not subject or (subject.kind == "unit" and not (subject --[[@as Unit]]):alive())
            or (subject.kind == "building" and subject.hp <= 0)
            or subject.side ~= self.screen.world.player then
            self.dialog = nil
        end
    end
end

M.SIDE_RGB = { [0] = { 255, 0, 0 }, { 0, 0, 255 }, { 0, 255, 0 }, { 160, 0, 250 }, { 0, 0, 0 }, { 208, 140, 52 },
               { 100, 70, 70 }, { 230, 230, 40 } }
M.SIDE_RGB_LIGHT = { [0] = { 255, 132, 141 }, { 94, 105, 252 }, { 79, 165, 79 }, { 188, 118, 227 }, { 77, 73, 54 },
                     { 255, 171, 71 }, { 120, 100, 100 }, { 255, 255, 120 } }
M.RES_RGB = require("src.content").resource:idView("colour")      -- the `colour` of the resource records

return M
