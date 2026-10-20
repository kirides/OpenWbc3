-- Scenario editor, sides and game options: the Sides mode (which of the six sides play, their shield colour and race), the
-- side edit dialog (race, resources, team, computer level, the custom AI file, the four lock flags and "must be human /
-- must be on"), the AI file chooser, the Options mode (hidden map, fog, handicapping, quests, tech level, army setup points,
-- each with its lock flag) and the game mods dialog (screens/editor.lua calls into this module; the editor screen `S` is the
-- first argument everywhere).
--
-- Follows the original editor's handlers of the sides panel 0x004b5b40, the side edit dialog 0x004b6580 (opener
-- FUN_004b5f00), the AI file chooser 0x004b70c0, the options panel 0x004be720 and the mods dialog 0x004bef80, and the
-- panels PNL_EDITMODE_SIDES, PNL_EDITOR_SIDES_EDIT, PNL_EDITOR_SIDES_AIFILE, PNL_EDITMODE_OPTIONS and
-- PNL_EDITOR_OPTION_MODS of War4Int.xci with their strings (XCIStrings 15 / 104 / 277 / 278 races, 35 resources, 214 AI
-- levels, 106 / 107 / 186 the option texts, 238 the mods, 249 the two side checkboxes):
--  * Sides mode: six rows (check box, shield, race button); a side can be switched on only when every lower one is on and off
--    only when no higher one is on, sides 1 and 2 stay on; the shield button cycles the colour 0..5 (the same colour may be
--    taken twice); the race button opens the edit dialog.
--  * Side edit dialog: race cycles all 16 races (the button is greyed while a custom AI file is set: choosing a file locks
--    the race, choosing "None" unlocks it), resources 0..4, team 0..4, computer level
--    0..7; each of these has its lock flag (the skirmish setup greys what the scenario locks); "Must be on" / "Must be human".
--  * AI file: "None" and the scripts of CustomAI whose header race is -1 (any) or the side's race, sorted by name, as
--    the filter 0x004b7450 does; the file name goes into the SAIH record of the side.
--  * Options mode: the buttons cycle hidden map, fog (0..2: no fog / fog / line of sight; openwbc3 has no line of sight and
--    plays it as the fog), handicapping, quests and the tech level (0..5, TXT_TECHLEVELS), every one with its lock flag, the
--    army setup points bar (+ lock) and the Rules button for the seven game mods (dialog with a lock flag per mod).
--    The bar's range is not traced in the 1.04 binary yet; openwbc3 takes 0..50, the skirmish setup's own limit.
--  * Own additions: the Options panel also carries the "produce heroes" and "standard victory" toggles (the original has them
--    as debug keys 'H' / 'V'); the scenario's name and description are edited in the Save As dialog.
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local lib = require("src.game.editorlib")
local strings = require("src.game.strings")
local aiparams = require("src.game.aiparams")
local F = require("src.screens.editorfields")
local scnwrite = require("src.formats.scnwrite")

local SD = {}
SD.PANELS = { sideedit = "PNL_EDITOR_SIDES_EDIT", sideai = "PNL_EDITOR_SIDES_AIFILE", mods = "PNL_EDITOR_OPTION_MODS" }
SD.X = {}
SD.ID = "sd_"

local MAX_POINTS = 50       -- openwbc3's own range of the army setup points bar (see the header)
local RACES, RESOURCES, TEAMS, AI_LEVELS = 16, 5, 5, 8

local function X(id, sub) return UI.text(id, sub) or "" end
local function G(n) return strings.get("Game.txt", ("%04d"):format(n)) or "" end
local function hideAll(p, ...) for _, n in ipairs({ ... }) do p:hide(n) end end

local function raceName(r) return r < 8 and X(277, r) or X(278, r - 8) end

---@param S EditorScreen
---@return table
local function state(S)
    if not S.sd then S.sd = { side = 0, list = { scroll = 0 } } end
    return S.sd
end

function SD.isDialog(name) return name ~= nil and SD.PANELS[name] ~= nil end
function SD.mapDialog() return false end

function SD.setupPanel(p, name)
    if name == "sides" then
        hideAll(p, "IM_ICON_SHLDCLRS", "BUTT_EDITOR_SIDE_SELECT")
    elseif name == "options" then
        hideAll(p, "BUTT_EDITOR_LOCK_TECHLEVEL", "BUTT_EDITOR_LOCK_AP", "BUTT_EDITOR_LOCK_QUESTS", "BUTT_EDITOR_LOCK_FOW",
            "BUTT_EDITOR_LOCK_HC", "BUTT_EDITOR_LOCK_HIDDEN", "SBAR_ARMYSETUPPOINTS")
        for _, n in ipairs({ "STR_SMALL24", "STR_MEDIUM200" }) do
            local it = p:find(n)
            if it then p.align[it] = "center" end
        end
    elseif name == "sideedit" then
        hideAll(p, "BUTT_EDITOR_LOCK_RACE", "BUTT_EDITOR_LOCK_AI", "BUTT_EDITOR_LOCK_TEAM", "BUTT_EDITOR_LOCK_RES",
            "BUTT_EDITOR_SIDE_MUSTBEON", "BUTT_EDITOR_SIDE_MUSTBHUMAN", "IM_ICON_TEAMS")
        local it = p:find("BUTT_EDITOR_AIFILE")
        if it then p.align[it] = "left" end
    elseif name == "sideai" then
        hideAll(p, "PAD_371x145", "SBAR_VEDIT120", "LB_EDITOR_LOAD_SCENARIO")
    elseif name == "mods" then
        hideAll(p, "BUTT_EDITOR_MODS_CHECK", "BUTT_EDITOR_LOCK_TOUGHTOWERS", "BUTT_EDITOR_LOCK_NOTOWERS",
            "BUTT_EDITOR_LOCK_NOLORDS", "BUTT_EDITOR_LOCK_NOFLIERS", "BUTT_EDITOR_LOCK_NOWALLS",
            "BUTT_EDITOR_LOCK_NODRAGONS", "BUTT_EDITOR_LOCK_NOHEROES")
    end
end

-- Sides mode ------------------------------------------------------------------------------------------------------------

-- The item of `p:all(name)` (top to bottom, left to right) that belongs to side i: the left column holds sides 1-3, the
-- right column 4-6 (the order of the original's XCI objects is not known; this is openwbc3's own reading).
local function slot(i) return (i % 3) * 2 + (i >= 3 and 2 or 1) end

local function sideIndexOf(p, name, it)
    for k, other in ipairs(p:all(name)) do
        if other == it then
            local row, col = math.floor((k - 1) / 2), (k - 1) % 2
            return col * 3 + row
        end
    end
end

-- Switches side i on or off by its check box (check box case of the sides handler 0x004b5b40; the rule is lib.canSwitchSide).
local function setUsed(S, i, on)
    if not lib.canSwitchSide(S.scn, i, on) then return false end
    S.scn.sides[i].used = on
    S:touch()
    return true
end

local function drawGem(p, it, colour)
    local g = love.graphics
    local img = UI.bitmap(35)
    if not img then return end
    SD.gems = SD.gems or {}
    local q = SD.gems[colour]
    if not q then
        q = g.newQuad(colour * 25, 0, 25, 20, img:getDimensions())
        SD.gems[colour] = q
    end
    g.setColor(1, 1, 1)
    g.draw(img, q, p.x + it.e.x, p.y + it.e.y)
end

local function drawSides(S, p)
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    local races, shields, gems = p:all("BUTT_EDITOR_SIDES_RACE"), p:all("BUTT_EDITOR_SIDE_SHIELD"), p:all("IM_ICON_SHLDCLRS")
    local boxes = p:all("BUTT_EDITOR_SIDE_SELECT")
    for i = 0, 5 do
        local sd = scn.sides[i]
        local k = slot(i)
        p.itemStrings[races[k]] = sd.used and raceName(sd.race) or ""
        p:setItemDisabled(races[k], not sd.used)
        p:setItemDisabled(shields[k], not sd.used)
    end
    p:draw()
    for i = 0, 5 do
        local sd = scn.sides[i]
        local k = slot(i)
        drawGem(p, gems[k], sd.used and (sd.color % 6) or 6)
        local b = boxes[k]
        F.checkBox(S, "sd_used", p.x + b.e.x, p.y + b.e.y, sd.used, nil, i, i < 2)
        if not sd.used then
            -- "Not in use" is wider than the race button: a smaller font
            fonts.print(2, X(80, 3), p.x + races[k].e.x, p.y + races[k].e.y + 5, "center", races[k].ob.w, 0.6)
        end
    end
end

-- Side edit dialog ------------------------------------------------------------------------------------------------------

local function aiLabel(S, side)
    local ai = S.scn.ai and S.scn.ai[side]
    if ai and ai.file ~= "" then
        local params = aiparams.load(ai.file)
        local name
        for _, f in ipairs(aiparams.list()) do if f.file == ai.file then name = f.name end end
        return G(536):format(name or (params and params.desc) or ai.file)
    end
    return G(534)
end

local function drawSideEdit(S, p)
    local st = state(S)
    local sd = S.scn.sides[st.side]
    local ai = S.scn.ai and S.scn.ai[st.side]
    local hasFile = ai and ai.file ~= ""
    p:setString("BUTT_EDITOR_SIDES_RACE_CYCLE", raceName(sd.race))
    p:setString("BUTT_EDITOR_SIDES_RES_CYCLE", X(35, sd.resources))
    p:setString("BUTT_EDITOR_SIDES_TECH_CYCLE", X(214, sd.aiLevel))
    p:setString("BUTT_EDITOR_AIFILE", aiLabel(S, st.side))
    p:setDisabled("BUTT_EDITOR_SIDES_RACE_CYCLE", hasFile)
    p:draw()
    -- team icon (bitmap 36: five 20 pixel pictures) on the small team button
    local tb = p:find("BUTT_EDITOR_SIDES_TEAM_CYCLE")
    local img = UI.bitmap(36)
    if img and tb then
        SD.teamQuads = SD.teamQuads or {}
        local q = SD.teamQuads[sd.team]
        if not q then
            q = love.graphics.newQuad(sd.team * 20, 0, 20, 20, img:getDimensions())
            SD.teamQuads[sd.team] = q
        end
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(img, q, p.x + tb.e.x, p.y + tb.e.y)
    end
    -- the lock flags next to race, resources, team and AI level (a custom AI file locks the race)
    F.lock(S, "sd_lock", p.x + 100, p.y + 19, sd.raceLocked or hasFile, "race", hasFile)
    F.lock(S, "sd_lock", p.x + 100, p.y + 46, sd.resourcesLocked, "resources")
    F.lock(S, "sd_lock", p.x + 100, p.y + 70, sd.teamLocked, "team")
    F.lock(S, "sd_lock", p.x + 80, p.y + 95, sd.aiLocked, "ai")
    F.checkBox(S, "sd_flag", p.x + 223, p.y + 22, sd.mustBeOn, X(249, 1), "mustBeOn", false, 140)
    F.checkBox(S, "sd_flag", p.x + 223, p.y + 48, sd.mustBeHuman, X(249, 0), "mustBeHuman", false, 150)
end

local function drawAiFile(S, p)
    local st = state(S)
    p:draw()
    local items = {}
    for i, e in ipairs(st.aiItems) do items[i] = { label = e.label, key = i } end
    st.list.sel = st.aiSel
    S.widgets.listBox(S, "sd_ailist", items, st.list, p.x + 12, p.y + 12, 150, 120)
end

-- Options mode ----------------------------------------------------------------------------------------------------------

local function setStr(p, name, s) p:setString(name, s) end

local function drawOptions(S, p)
    local h = S.scn.header
    local o = h.options
    local pos = {
        hidden = { 20, 12 }, fog = { 20, 32 }, handicap = { 20, 52 }, quests = { 20, 72 }, tech = { 20, 92 },
        points = { 255, 112 },
    }
    setStr(p, "BUTT_EDITMODE_OPTIONS_HIDDEN", o.hiddenMap and X(106, 0) or X(106, 1))
    setStr(p, "BUTT_EDITMODE_OPTIONS_FOW", X(107, (o.fog or 1) + 5))
    setStr(p, "BUTT_EDITMODE_OPTIONS_HC", o.handicapping and X(106, 4) or X(106, 5))
    setStr(p, "BUTT_EDITMODE_OPTIONS_QUEST", o.quests and X(106, 6) or X(106, 7))
    setStr(p, "BUTT_EDITMODE_OPTIONS_TL", X(186, math.max(0, math.min(5, o.techLevel or 5))))
    setStr(p, "STR_MEDIUM200", G(247))
    setStr(p, "STR_SMALL24", tostring(o.armySetupPoints or 0))
    p:draw()
    F.lock(S, "sd_olock", p.x + pos.hidden[1], p.y + pos.hidden[2], o.hiddenLocked, "hiddenLocked")
    F.lock(S, "sd_olock", p.x + pos.fog[1], p.y + pos.fog[2], o.fogLocked, "fogLocked")
    F.lock(S, "sd_olock", p.x + pos.handicap[1], p.y + pos.handicap[2], o.handicapLocked, "handicapLocked")
    F.lock(S, "sd_olock", p.x + pos.quests[1], p.y + pos.quests[2], o.questsLocked, "questsLocked")
    F.lock(S, "sd_olock", p.x + pos.tech[1], p.y + pos.tech[2], o.techLocked, "techLocked")
    F.lock(S, "sd_olock", p.x + pos.points[1], p.y + pos.points[2], o.pointsLocked, "pointsLocked")
    F.hbar(S, "sd_points", p.x + 178, p.y + 90, (o.armySetupPoints or 0) / MAX_POINTS)
    -- openwbc3's own toggles (the original has debug keys for them)
    S.widgets.bmpButton(S, "sd_heroes", "Heroes: " .. (h.produceHeroes and "yes" or "no"), p.x + 12, p.y + 118, 110, false)
    S.widgets.bmpButton(S, "sd_stdvic", "Std victory: " .. (h.standardVictory and "yes" or "no"), p.x + 128, p.y + 118, 120,
        false)
end

-- Game mods dialog ------------------------------------------------------------------------------------------------------

-- The check boxes sit left (x 20: dragons, fliers, lords, tough towers) and right (x 200: no towers, walls, heroes), the
-- lock flag at x 140 / 320 next to each (PNL_EDITOR_OPTION_MODS positions).
local MOD_POS = { { 20, 15 }, { 20, 45 }, { 20, 75 }, { 20, 105 }, { 200, 15 }, { 200, 45 }, { 200, 75 } }

local function drawMods(S, p)
    p:draw()
    local o = S.scn.header.options
    o.mods, o.modLocks = o.mods or {}, o.modLocks or {}
    for i, name in ipairs(scnwrite.MODS) do
        local x, y = p.x + MOD_POS[i][1], p.y + MOD_POS[i][2]
        F.checkBox(S, "sd_mod", x, y, o.mods[name], X(238, i), name, false, 118)
        F.lock(S, "sd_modlock", x + 120, y, o.modLocks[name], name)
    end
end

---@param S EditorScreen
function SD.drawMode(S, p)
    if S.mode == "sides" then drawSides(S, p) elseif S.mode == "options" then drawOptions(S, p) end
end

---@param S EditorScreen
function SD.draw(S, p)
    local d = S.dialog
    if d == "sideedit" then drawSideEdit(S, p)
    elseif d == "sideai" then drawAiFile(S, p)
    elseif d == "mods" then drawMods(S, p) end
end

-- Buttons and clicks ----------------------------------------------------------------------------------------------------------

local function setPoints(S, v)
    local o = S.scn.header.options
    v = math.max(0, math.min(MAX_POINTS, math.floor(v + 0.5)))
    if o.armySetupPoints ~= v then
        o.armySetupPoints = v
        S:touch()
    end
end

---@param S EditorScreen
function SD.openSide(S, i)
    local st = state(S)
    st.side = i
    S.dialog = "sideedit"
end

local function openAiFile(S)
    local st = state(S)
    local side = S.scn.sides[st.side]
    local ai = S.scn.ai and S.scn.ai[st.side]
    st.aiItems = { { label = G(294), file = "" } }
    st.aiSel = 1
    for _, f in ipairs(aiparams.forRace(side.race)) do
        st.aiItems[#st.aiItems + 1] = { label = f.name, file = f.file }
        if ai and ai.file == f.file then st.aiSel = #st.aiItems end
    end
    st.list = { scroll = 0 }
    S.dialog = "sideai"
end

---@param S EditorScreen
function SD.button(S, panel, name, it)
    local st = state(S)
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    if panel == "sides" then
        local i = sideIndexOf(S:panel("sides"), name, it)
        if not i then return end
        if name == "BUTT_EDITOR_SIDES_RACE" then
            SD.openSide(S, i)
        elseif name == "BUTT_EDITOR_SIDE_SHIELD" then
            local sd = scn.sides[i]
            sd.color = (sd.color + 1) % 6
            S:touch()
        end
    elseif panel == "sideedit" then
        local sd = scn.sides[st.side]
        local ai = scn.ai and scn.ai[st.side]
        if name == "BUTT_EDITOR_SIDES_RACE_CYCLE" then
            if not (ai and ai.file ~= "") then sd.race = (sd.race + 1) % RACES end
        elseif name == "BUTT_EDITOR_SIDES_RES_CYCLE" then
            sd.resources = (sd.resources + 1) % RESOURCES
        elseif name == "BUTT_EDITOR_SIDES_TEAM_CYCLE" then
            sd.team = (sd.team + 1) % TEAMS
        elseif name == "BUTT_EDITOR_SIDES_TECH_CYCLE" then
            sd.aiLevel = (sd.aiLevel + 1) % AI_LEVELS
        elseif name == "BUTT_EDITOR_AIFILE" then
            openAiFile(S)
            return
        elseif name == "BUTT_EDITOR_OKAY" then
            S.dialog = nil
        end
        S:touch()
    elseif panel == "sideai" then
        if name == "BUTT_EDITOR_OKAY" then
            local ai = scn.ai and scn.ai[st.side]
            local e = st.aiItems[st.aiSel or 1]
            if ai and e then
                ai.file = e.file
                -- a custom AI script is written for a race: the side's race is locked while one is set
                scn.sides[st.side].raceLocked = e.file ~= ""
                scn.sides[st.side].aiFile = e.file ~= "" and e.file or nil
                S:touch()
            end
            S.dialog = "sideedit"
        elseif name == "BUTT_EDITOR_CANCEL" then
            S.dialog = "sideedit"
        end
    elseif panel == "mods" then
        if name == "BUTT_EDITOR_DONE" then S.dialog = nil end
    elseif panel == "options" then
        local o = scn.header.options
        if name == "BUTT_EDITMODE_OPTIONS_HIDDEN" then o.hiddenMap = not o.hiddenMap
        elseif name == "BUTT_EDITMODE_OPTIONS_FOW" then o.fog = ((o.fog or 1) + 1) % 3
        elseif name == "BUTT_EDITMODE_OPTIONS_HC" then o.handicapping = not o.handicapping
        elseif name == "BUTT_EDITMODE_OPTIONS_QUEST" then o.quests = not o.quests
        elseif name == "BUTT_EDITMODE_OPTIONS_TL" then o.techLevel = ((o.techLevel or 5) + 1) % 6
        elseif name == "BUTT_EDITOR_OPTIONS_MODS" then S.dialog = "mods"
        else return end
        S:touch()
    end
end

-- Clicks on the custom widgets: ids "sd_<what>". Returns true when handled.
---@param S EditorScreen
function SD.click(S, id, extra, button)
    local st = state(S)
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    if id == "sd_used" then
        setUsed(S, extra, not scn.sides[extra].used)
    elseif id == "sd_lock" then
        local sd = scn.sides[st.side]
        local key = ({ race = "raceLocked", resources = "resourcesLocked", team = "teamLocked", ai = "aiLocked" })[extra]
        if key then sd[key] = not sd[key] S:touch() end
    elseif id == "sd_flag" then
        local sd = scn.sides[st.side]
        sd[extra] = not sd[extra]
        S:touch()
    elseif id == "sd_ailist" then
        st.aiSel = extra
    elseif id == "sd_olock" then
        local o = scn.header.options
        o[extra] = not o[extra]
        S:touch()
    elseif id == "sd_mod" then
        local o = scn.header.options
        o.mods[extra] = not o.mods[extra]
        S:touch()
    elseif id == "sd_modlock" then
        local o = scn.header.options
        o.modLocks[extra] = not o.modLocks[extra]
        S:touch()
    elseif id == "sd_points" then
        local o = scn.header.options
        local cur = o.armySetupPoints or 0
        if extra == "left" then setPoints(S, cur - 1)
        elseif extra == "right" then setPoints(S, cur + 1)
        else
            local p = S:panel("options")
            local vx = S:toV(love.mouse.getPosition())
            setPoints(S, F.hbarPos(p.x + 178, vx) * MAX_POINTS)
            S.dragFn = function(x)
                setPoints(S, F.hbarPos(p.x + 178, x) * MAX_POINTS)
            end
        end
    elseif id == "sd_heroes" then
        scn.header.produceHeroes = not scn.header.produceHeroes
        S:touch()
    elseif id == "sd_stdvic" then
        scn.header.standardVictory = not scn.header.standardVictory
        S:touch()
    else
        return false
    end
    return true
end

---@param S EditorScreen
function SD.keypressed(S, key)
    if not SD.isDialog(S.dialog) then return false end
    if key == "escape" then
        if S.dialog == "sideai" then S.dialog = "sideedit" else S.dialog = nil end
        return true
    end
    return false
end

-- Developer aid: --show editor:sides[_edit|_ai] and editor:options[_mods] ------------------------------------------------------

---@param S EditorScreen
function SD.dev(S, sub)
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    if sub == "options" or sub == "options_mods" then
        S.mode = "options"
        local o = scn.header.options
        o.hiddenLocked, o.techLocked, o.pointsLocked, o.armySetupPoints, o.techLevel = true, true, true, 20, 3
        o.mods = { noDragons = true, toughTowers = true }
        o.modLocks = { noFliers = true }
        if sub == "options_mods" then S.dialog = "mods" end
        return
    end
    S.mode = "sides"
    scn.sides[2].used = true
    scn.sides[2].race = 5
    scn.sides[3].used, scn.sides[3].race, scn.sides[3].color = true, 9, 1
    if sub == "edit" or sub == "ai" then
        scn.sides[2].resourcesLocked, scn.sides[2].mustBeHuman, scn.sides[2].team = true, true, 2
        SD.openSide(S, 2)
        if sub == "ai" then openAiFile(S) end
    end
end

return SD
