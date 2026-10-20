-- Scenario editor, placed armies and buildings: the dialog of a selected object (owner, name, ID tag, level), the behaviour
-- dialog and the character / statistics dialogs (screens/editor.lua calls into this module; the editor screen `S` is the
-- first argument everywhere).
--
-- Follows the original editor's handlers of the selected army 0x004c7b40 and building 0x004c7ef0, the select click of
-- the map click routine FUN_004c4670 and the army creation FUN_004c8ad0, and the panels PNL_EDITOR_ARMY_SELECTED,
-- PNL_EDITOR_BUILDING_SELECTED, PNL_EDITMODE_ARMY_BEHAVIOR and PNL_EDITOR_CHARACTER of War4Int.xci:
--  * Selecting an army or building (the Select tool, a click that does not drag) opens its dialog and blocks the map until
--    Done: the owner button cycles the sides 0..6 (a critter / a searchable building - lair, shop, shrine - always ends up
--    neutral, and a side the scenario does not use is flagged "(not in use)"), the first edit is the character name (a
--    name makes the object a character), the second the ID tag (the name the events and scripts refer to
--    it by) and, for an army, the level, shown as level + 1 (the SCN counts from 0); Done stores the experience the
--    level needs (army XP table at 0x005fbc50, read by FUN_0040da20) with it.
--  * openwbc3's own additions, because the original's panels have no button for them: the dialog carries Behaviour,
--    Character and Stats buttons. The 1.04 data has the strings of these dialogs (TXT_EDITOR_BEHAVIOR1,
--    TXT_EDITOR_ARMY_BEHAVIORS = Wimp / Defensive / Normal / Aggressive / Mad, TXT_EDITOR_CHARACTER = Create / Name /
--    Level / Experience, TXT_EDITOR_ARMY_STATS) and the panels (the stats panels ship without their
--    background pictures, bitmaps 81 and 86 are missing), but nothing opens them: the behaviour type and script code the
--    scenario stores are never read by the game (not traced in the 1.04 binary yet). The stats dialog is laid
--    out by hand (the fields are the type's general statistics, armour and damage; the "use default data" flag goes off on
--    Apply, as the original's building statistics writer does - not traced in the 1.04 binary yet); the script code is
--    typed (where the original's script list would come from is not known).
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local lib = require("src.game.editorlib")
local rules = require("src.game.rules")
local strings = require("src.game.strings")
local F = require("src.screens.editorfields")

local O = {}
O.PANELS = { objarmy = "PNL_EDITOR_ARMY_SELECTED", objbuilding = "PNL_EDITOR_BUILDING_SELECTED",
             objbehav = "PNL_EDITMODE_ARMY_BEHAVIOR", objchar = "PNL_EDITOR_CHARACTER",
             objstats = "PNL_EDITOR_BUILDING_CHARACTER" }
-- the 700 pixel wide behaviour dialog slides in at x = 50 like the editor's other wide dialogs, the others sit in the middle panel's place
O.X = { objbehav = 50 }
O.ID = "ob_"

local function X(id, sub) return UI.text(id, sub) or "" end
local function G(n) return strings.get("Game.txt", ("%04d"):format(n)) or "" end

-- The damage types by number (0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic, 5 crushing, 6 slashing); the
-- names are the parenthesised words of the item strings Game.txt 0440..0446.
local DMG_GAME = { [0] = 442, 444, 445, 443, 446, 441, 440 }
local function damageName(t)
    local n = DMG_GAME[t]
    return n and G(n):match("%((.-)%)") or ("#" .. tostring(t))
end

local BEHAVIOURS = 5
local MAX_NAME = 19

---@param S EditorScreen
---@return table
local function state(S)
    if not S.obj then S.obj = { f = F.new(O.ID), list = { scroll = 0 }, scripts = { scroll = 0 } } end
    return S.obj
end

function O.isDialog(name) return name ~= nil and O.PANELS[name] ~= nil end
function O.mapDialog() return false end          -- the map is blocked while an object dialog is open (as in the original)

-- The object whose dialog is open.
---@param S EditorScreen
function O.current(S) local st = S.obj return st and st.rec, st and st.layer end

local function hideAll(p, ...) for _, n in ipairs({ ... }) do p:hide(n) end end

function O.setupPanel(p, name)
    if name == "objbehav" then
        hideAll(p, "SBAR_VEDIT120", "SBAR_VEDIT120B", "LB_EDITOR_BEHAVIOR_SCRIPT", "LB_EDITOR_BEHAVIOR_TYPE")
    elseif name == "objchar" then
        hideAll(p, "STR_MEDIUM120")
    elseif name == "objstats" then
        hideAll(p, "STR_MEDIUM120", "BUTT_EDITOR_STATS_APPLY", "BUTT_EDITOR_STATS_CANCELSMALL")
    end
    if name == "objarmy" or name == "objbuilding" then
        for _, it in ipairs(p.items) do
            if it.name == "STR_MEDIUM120" then p.align[it] = "right" end
        end
        p.align[p:find("STR_SMALL200")] = "left"
    end
end

-- Opening -----------------------------------------------------------------------------------------------------------

-- Opens the dialog of the object `rec` of `layer` ("armies" | "buildings").
---@param S EditorScreen
function O.open(S, layer, rec)
    local st = state(S)
    st.layer, st.rec = layer, rec
    local f = st.f
    f:clear()
    f:set("name", { maxLen = MAX_NAME, text = rec.name })
    f:set("tag", { maxLen = MAX_NAME, text = rec.tag })
    if layer == "armies" then f:set("level", { kind = "num", min = 0, max = 999, text = lib.levelNumber(rec) }) end
    f.focus = "name"
    S.dialog = layer == "armies" and "objarmy" or "objbuilding"
end

local function closeObject(S)
    local st = state(S)
    local rec = st.rec
    if rec then
        local f = st.f
        if st.layer == "armies" then
            lib.applyArmy(rec, f:text("name"), f:text("tag"), f:text("level"))
        else
            lib.applyBuilding(rec, f:text("name"), f:text("tag"))
        end
    end
    S.dialog = nil
    S.selected = nil
    S:touch()
end

-- Drawing -------------------------------------------------------------------------------------------------------

local function sideUnused(S, rec)
    local sd = S.scn.sides[rec.side]
    return rec.side ~= 6 and sd and not sd.used
end

local function drawObject(S, p)
    local st = state(S)
    local rec, layer = st.rec, st.layer
    local army = layer == "armies"
    p:setString("BUTT_EDITOR_OBJECT_OWNER", X(84, rec.side))
    p:setString("STR_SMALL200", sideUnused(S, rec) and (" (" .. X(80, 3) .. ")") or "")
    -- the original's labels, right-justified to the edit boxes: the name, "ID" and the level
    for _, it in ipairs(p.items) do
        if it.name == "STR_MEDIUM120" then
            local y = it.e.y
            p.itemStrings[it] = y == 55 and X(3, 2) or y == 80 and "ID" or (y == 105 and army) and G(933) or ""
        end
    end
    p:setDisabled("BUTT_EDITOR_DONE", false)
    p:draw()
    local f = st.f
    f:draw(S, "name", p.x + 128, p.y + 55, 160, 19)
    f:draw(S, "tag", p.x + 128, p.y + 80, 160, 19)
    if army then f:draw(S, "level", p.x + 128, p.y + 105, 40, 19) end
    -- openwbc3's extra buttons (see the header)
    local bx = p.x + 290
    if army then
        S.widgets.bmpButton(S, "ob_behav", X(72, 0), bx, p.y + 50, 66, false)
        S.widgets.bmpButton(S, "ob_char", X(72, 5), bx, p.y + 72, 66, false)
    end
    S.widgets.bmpButton(S, "ob_stats", X(74, 6), bx, p.y + (army and 94 or 55), 66, false)
end

local function drawBehaviour(S, p)
    local st = state(S)
    p:draw()
    local items = {}
    for i = 0, BEHAVIOURS - 1 do items[#items + 1] = { label = X(66, i), key = i } end
    st.list.sel = st.behaviour
    S.widgets.listBox(S, "ob_btype", items, st.list, p.x + 13, p.y + 12, 150, 120)
    -- the scripts already used by other armies of the scenario (openwbc3's own: where the original's script list
    -- would come from is not known), "none" first
    local scripts = { { label = G(294), key = "" } }
    local seen = { [""] = true }
    for _, a in ipairs(S.scn.armies) do
        if a.script and a.script ~= "" and not seen[a.script] then
            seen[a.script] = true
            scripts[#scripts + 1] = { label = a.script, key = a.script }
        end
    end
    st.scripts.sel = st.f:text("script")
    S.widgets.listBox(S, "ob_bscript", scripts, st.scripts, p.x + 193, p.y + 12, 150, 120)
    fonts.print(5, "Script", p.x + 380, p.y + 14, "left", 140)
    st.f:draw(S, "script", p.x + 380, p.y + 34, 200, 19)
end

local function drawCharacter(S, p)
    local st = state(S)
    p:setDisabled("BUTT_EDITOR_CREATE", false)
    p:draw()
    local rec = st.rec
    fonts.print(5, X(73, 1), p.x + 12, p.y + 22, "left", 62)
    st.f:draw(S, "name", p.x + 125, p.y + 20, 160, 19)
    fonts.print(5, X(73, 2), p.x + 20, p.y + 60, "right", 118)
    st.f:draw(S, "level", p.x + 142, p.y + 59, 34, 19)
    fonts.print(5, X(73, 3), p.x + 184, p.y + 60, "right", 74)
    st.f:draw(S, "xp", p.x + 262, p.y + 59, 54, 19)
    if lib.characterCount(S.scn) > 8 and not rec.character then
        fonts.print(2, "Nine characters are the most a map can hold.", p.x + 20, p.y + 84, "left", 330)
    end
end

-- The stats dialog: 3 columns of labelled edits on the middle panel's frame.
local STAT_COLS = {
    { title = { 67, 5 }, x = 8, rows = { { "combat", { 67, 0 } }, { "speed", { 67, 1 } }, { "resistance", { 67, 2 } },
                                         { "hits", { 67, 3 } }, { "view", { 67, 4 } } } },
    { title = { 68, 5 }, x = 132, rows = { { "armor", { 68, 5 } }, { "strong", "Strong vs" }, { "weak", "Weak vs" },
                                           { "curHits", "Current hits" } } },
    { title = { 70, 2 }, x = 252, rows = { { "damage", { 70, 0 } }, { "damageType", "Type" }, { "range", { 70, 1 } } } },
}

local function drawStats(S, p)
    local st = state(S)
    p:draw()
    for _, col in ipairs(STAT_COLS) do
        fonts.print(5, X(col.title[1], col.title[2]), p.x + col.x, p.y + 6, "left", 118)
        for r, row in ipairs(col.rows) do
            local y = p.y + 24 + (r - 1) * 21
            local lab = type(row[2]) == "table" and X(row[2][1], row[2][2]) or row[2]
            if #lab > 12 then lab = lab:match("^%S+") or lab end
            fonts.print(2, lab, p.x + col.x, y + 3, "left", 80)
            if row[1] == "damageType" or row[1] == "strong" or row[1] == "weak" then
                local v = st.f:number(row[1], 0)
                S.widgets.bmpButton(S, "ob_cycle", damageName(v), p.x + col.x + 56, y, 58, false, row[1])
            else
                st.f:draw(S, row[1], p.x + col.x + 80, y, 34, 19)
            end
        end
    end
    S.widgets.bmpButton(S, "ob_apply", X(72, 3), p.x + 252, p.y + 94, 100, false)
    S.widgets.bmpButton(S, "ob_cancel", X(65, 2), p.x + 252, p.y + 116, 100, false)
end

---@param S EditorScreen
function O.draw(S, p)
    local d = S.dialog
    if d == "objarmy" or d == "objbuilding" then drawObject(S, p)
    elseif d == "objbehav" then drawBehaviour(S, p)
    elseif d == "objchar" then drawCharacter(S, p)
    elseif d == "objstats" then drawStats(S, p) end
end

-- Map overlay: a ring round the object being edited.
---@param S EditorScreen
function O.drawMap(S, g)
    local rec = O.current(S)
    if rec and O.isDialog(S.dialog) then
        g.setColor(0.2, 1, 0.2, 0.9)
        g.ellipse("line", rec.x, rec.y, 20, 10)
        g.setColor(1, 1, 1)
    end
end

-- Buttons ----------------------------------------------------------------------------------------------------------

local function openStats(S)
    local st = state(S)
    local rec = st.rec
    local f = st.f
    f:clear()
    for _, col in ipairs(STAT_COLS) do
        for _, row in ipairs(col.rows) do
            local k = row[1]
            f:set(k, { kind = "num", min = 0, max = (k == "hits" or k == "curHits") and 32767 or 9999,
                       text = rec[k] or 0 })
        end
    end
    f.focus = "combat"
    st.back = S.dialog
    S.dialog = "objstats"
end

local function openBehaviour(S)
    local st = state(S)
    local rec = st.rec
    st.f:clear()
    st.f:set("script", { maxLen = 29, text = rec.script })
    st.f.focus = "script"
    st.behaviour = math.max(0, math.min(BEHAVIOURS - 1, rec.behaviour or 2))
    st.list = { scroll = 0 }
    st.scripts = { scroll = 0 }
    st.back = S.dialog
    S.dialog = "objbehav"
end

local function openCharacter(S)
    local st = state(S)
    local rec = st.rec
    st.f:clear()
    st.f:set("name", { maxLen = MAX_NAME, text = rec.name })
    st.f:set("level", { kind = "num", min = 1, max = 999, text = lib.levelNumber(rec) })
    st.f:set("xp", { kind = "num", min = 0, max = 99999, text = rec.xp or 0 })
    st.f.focus = "name"
    st.back = S.dialog
    S.dialog = "objchar"
end

-- Back to the object dialog with its edits restored from the record.
local function backToObject(S)
    local st = state(S)
    S.dialog = nil
    O.open(S, st.layer, st.rec)
end

---@param S EditorScreen
function O.button(S, panel, name)
    local st = state(S)
    local rec = st.rec
    if panel == "objarmy" or panel == "objbuilding" then
        if name == "BUTT_EDITOR_OBJECT_OWNER" then
            lib.setOwner(st.layer, rec, lib.nextOwner(st.layer, rec))
            S:touch()
        elseif name == "BUTT_EDITOR_DONE" then
            closeObject(S)
        end
    elseif panel == "objbehav" then
        if name == "BUTT_EDITOR_OKAY" then
            rec.behaviour = st.behaviour
            rec.script = st.f:text("script")
            S:touch()
            backToObject(S)
        elseif name == "BUTT_EDITOR_CANCEL" then
            backToObject(S)
        end
    elseif panel == "objchar" then
        if name == "BUTT_EDITOR_CREATE" then
            -- Create: the name makes the army a character; a hero keeps its level and takes the experience typed
            local f = st.f
            if f:text("name") == "" then S:notify(X(73, 1) .. "?") return end
            if lib.characterCount(S.scn) > 8 and not rec.character then return end
            rec.name, rec.character = f:text("name"), true
            local lvl = f:number("level", 1)
            local hero = rec.hero or (rules.armyInfo(rec.code) or {}).hero
            rec.level = hero and lvl or math.max(0, lvl - 1)
            rec.xp = f:number("xp", 0)
            S:touch()
            backToObject(S)
        elseif name == "BUTT_EDITOR_CANCEL" then
            backToObject(S)
        end
    end
end

-- Clicks on the custom widgets: ids "ob_<what>". Returns true when handled.
---@param S EditorScreen
function O.click(S, id, extra, button)
    local st = state(S)
    local rec = st.rec
    if st.f:click(id) then return true end
    if id == "ob_behav" then openBehaviour(S)
    elseif id == "ob_char" then
        if lib.characterCount(S.scn) > 8 and not rec.character then S:notify("Nine characters are the most a map can hold.")
        else openCharacter(S) end
    elseif id == "ob_stats" then openStats(S)
    elseif id == "ob_btype" then
        local it = extra and extra >= 1 and extra - 1
        if it then st.behaviour = it end
    elseif id == "ob_bscript" then
        local scripts = { "" }
        local seen = { [""] = true }
        for _, a in ipairs(S.scn.armies) do
            if a.script and a.script ~= "" and not seen[a.script] then seen[a.script] = true scripts[#scripts + 1] = a.script end
        end
        if scripts[extra] then st.f:setText("script", scripts[extra]) end
    elseif id == "ob_cycle" then
        local dir = button == 2 and -1 or 1
        local f = st.f
        local v = f:number(extra, 0)
        f:setText(extra, (v + dir) % 7)
    elseif id == "ob_apply" then
        local f = st.f
        for _, col in ipairs(STAT_COLS) do
            for _, row in ipairs(col.rows) do rec[row[1]] = f:number(row[1], rec[row[1]] or 0) end
        end
        rec.useDefault = false
        S:touch()
        backToObject(S)
    elseif id == "ob_cancel" then backToObject(S)
    else return false end
    return true
end

-- Keyboard ------------------------------------------------------------------------------------------------------------

---@param S EditorScreen
function O.textinput(S, t)
    if not O.isDialog(S.dialog) then return false end
    return state(S).f:textinput(t)
end

---@param S EditorScreen
function O.keypressed(S, key)
    if not O.isDialog(S.dialog) then return false end
    local st = state(S)
    if st.f:keypressed(key) then return true end
    if key == "escape" then O.back(S) return true end
    return false
end

-- Escape: the object dialog applies what was typed (the original has no way to cancel), a sub dialog goes back.
---@param S EditorScreen
function O.back(S)
    local d = S.dialog
    if d == "objarmy" or d == "objbuilding" then closeObject(S)
    else backToObject(S) end
end

-- Developer aid: --show editor:object[_building|_behaviour|_character|_stats|_used] ----------------------------

---@param S EditorScreen
function O.dev(S, sub)
    local lib2 = require("src.game.editorlib")
    S.mode = "armies"
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    local rec
    if sub == "building" then
        S.mode = "buildings"
        rec = scn.buildings[1]
        for _, b in ipairs(scn.buildings) do if b.side == 0 then rec = b break end end
        O.open(S, "buildings", rec)
    else
        for _, a in ipairs(scn.armies) do
            if a.side == 0 and not a.hero and a.code ~= "ACGO" then rec = a break end
        end
        rec = rec or scn.armies[1]
        if sub == "used" then rec.side = 5 end
        S.selected = { layer = "armies", o = rec, i = 1 }
        O.open(S, "armies", rec)
        if sub == "behaviour" then openBehaviour(S) elseif sub == "character" then openCharacter(S)
        elseif sub == "stats" then openStats(S) end
    end
    S.selected = { layer = S.mode, o = rec, i = 1 }
    S.camX, S.camY = rec.x - S.vw / 2, rec.y - S.vh / 2
    S:clampCamera()
    return lib2
end

return O
