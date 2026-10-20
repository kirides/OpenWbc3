-- Scenario editor, items and treasure chests: the items mode (placing and deleting chests), the chest dialog (the items a
-- chest holds) and the item view (what one of them is, remove it). screens/editor.lua calls into this module; the editor
-- screen `S` is the first argument everywhere.
--
-- Follows the original editor's items mode (map click FUN_004c3f90; handlers 0x004b5a00 of the items panel, 0x004c8260 of
-- the chest and 0x004c8400 of the chest view; view opener FUN_004c8360, item builder FUN_004c8980, item list filler
-- FUN_004c8790, the select click of FUN_004c4670 on a chest) and the panels PNL_EDITOR_EDIT_ITEMS, PNL_EDITOR_ITEMS_CHEST
-- and PNL_EDITOR_ITEMS_CHEST_VIEW. The format of the scenario's ITMH record is in docs/formats.md:
--  * The original reaches its items mode only in the in-house testing build (the `i` key; not traced in the 1.04 binary yet);
--    the released editor can only select a chest that is already on the map (a click on it with the Select tool opens the
--    chest panel). openwbc3 offers the mode on the `I` key too, and the chest dialog by a click on a chest in it.
--  * Type buttons "Item" / "Random" / "Resource" (TXT_EDIT_MODE_ITEMS 0..2; the in-house panel enables Random and Resource
--    only), mode buttons "New" / "Edit" / "Delete" (3..5). A click with "New" puts a chest with the chosen item on the cell; on a
--    cell that already has a chest it adds the item to it, which the original allows only for a numbered item (never a random
--    one: a negative item index is an error), only while the chest has fewer than four items and is no resource chest.
--    Resource chests are a gold / metal / stone / crystal chest (the list order of the original) worth 500 of it, picked by
--    its colour (the picture direction 0..3); a random chest looks at direction 4.
--  * The chest dialog has "Item One" .. "Item Four" (greyed beyond the chest's count) and Done; an item button opens the view:
--    "Random item" or "Resource" (Game.txt 0193 / 0194), "Remove" (not for the last item) and Done.
--  * Own additions: the "Item" type lists the item catalogue (Items.xml; only the numbered items, a mod item's id does not fit
--    the scenario file) and puts a numbered item into the chest (the original's list shows 16 hard-coded artefact names but
--    the item builder FUN_004c8980 always returns a random item); the view shows a numbered item's name and powers.
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local lib = require("src.game.editorlib")
local strings = require("src.game.strings")
local items = require("src.game.items")
local anims = require("src.gfx.anims")

local IT = {}
IT.PANELS = { chest = "PNL_EDITOR_ITEMS_CHEST", chestview = "PNL_EDITOR_ITEMS_CHEST_VIEW" }
IT.X = {}
IT.ID = "it_"

local CW, CH = 32, 24
local TYPES = { { "item", 0 }, { "random", 1 }, { "resource", 2 } }          -- TXT_EDIT_MODE_ITEMS
local MODES = { { "new", 3 }, { "edit", 4 }, { "delete", 5 } }

local function X(id, sub) return UI.text(id, sub) or "" end
local function G(n) return strings.get("Game.txt", ("%04d"):format(n)) or "" end

---@param S EditorScreen
---@return table
local function state(S)
    if not S.it then S.it = { type = "random", mode = "new", list = { scroll = 0 }, sel = {} } end
    return S.it
end

function IT.isDialog(name) return name ~= nil and IT.PANELS[name] ~= nil end
function IT.mapDialog() return false end

local function hideAll(p, ...) for _, n in ipairs({ ... }) do p:hide(n) end end

function IT.setupPanel(p, name)
    if name == "items" then
        hideAll(p, "BUTT_EDITMODE_ITEM_MODE", "BUTT_EDITMODE_ITEM_TYPE", "LB_EDITITEMS", "SBAR_VEDIT120")
    elseif name == "chest" then
        -- the item buttons take the 187.x strings
    elseif name == "chestview" then
        for _, it in ipairs(p.items) do
            if it.name == "STR_SMALL200" or it.name == "STR_SMALL_450" then p.align[it] = "left" end
        end
    end
end

-- The items a scenario chest can hold: the numbered ones (a mod item's "modid:name" does not fit the file's i16).
local function chestItems()
    local out = {}
    for _, it in ipairs(items.all()) do
        if lib.chestItemId(it.id) then out[#out + 1] = it end
    end
    return out
end

-- The list of the chosen type: what a click on the map puts into a chest.
local function listItems(S)
    local st = state(S)
    local out = {}
    if st.type == "random" then
        out[1] = { label = G(249), key = 1 }                        -- "Random item"
    elseif st.type == "resource" then
        for i = 1, 4 do out[i] = { label = G(249 + i), key = i } end  -- Gold, Metal, Stone, Crystal
    else
        for i, it in ipairs(chestItems()) do out[i] = { label = it.name, key = i, id = it.id } end
    end
    return out
end

-- Drawing -------------------------------------------------------------------------------------------------------------

---@param S EditorScreen
function IT.drawMode(S, p)
    local st = state(S)
    p:draw()
    local w = S.widgets
    for i, t in ipairs(TYPES) do
        w.bmpButton(S, "it_type", X(165, t[2]), p.x + 12, p.y + 12 + (i - 1) * 28, 90, st.type == t[1], t[1])
    end
    for i, m in ipairs(MODES) do
        w.bmpButton(S, "it_mode", X(165, m[2]), p.x + 290, p.y + 12 + (i - 1) * 30, 100, st.mode == m[1], m[1])
    end
    local rows = listItems(S)
    local sel = st.sel[st.type]
    st.list.sel = sel and (st.type == "item" and sel or sel) or nil
    w.listBox(S, "it_list", rows, st.list, p.x + 105, p.y + 12, 160, 120)
    w.hint(p.x + 12, p.y + 100, "Press Esc for", "the menu")
end

local function selectedItem(S)
    local st = state(S)
    local sel = st.sel[st.type]
    if st.type == "random" then return "random", nil end
    if not sel then return nil end
    if st.type == "resource" then return "resource", sel end
    local it = chestItems()[sel]
    return it and "item", it and it.id --[[@as integer]]
end

local function itemLabel(m)
    if m.resource then
        for _, r in ipairs(lib.CHEST_RESOURCES) do
            if r.code == m.data then
                return G(194) .. ": " .. G(249 + (({ gold = 1, metal = 2, stone = 3, crystal = 4 })[r.name]))
            end
        end
        return G(194)
    end
    if m.index >= 0 then
        local it = items.get(m.index)
        return it and it.name or ("#" .. tostring(m.index))
    end
    return G(193)       -- "Random item"
end

local function drawChest(S, p)
    local st = state(S)
    local rec = st.rec
    local c = rec.chest
    local names = { "BUTT_EVENTS_EFFECTONE", "BUTT_EVENTS_EFFECTTWO", "BUTT_EVENTS_EFFECTTHREE", "BUTT_EVENTS_EFFECTFOUR" }
    for i, n in ipairs(names) do
        p:setString(n, X(187, i - 1))
        p:setDisabled(n, i > c.count)
    end
    p:draw()
    S.widgets.hint(p.x + 12, p.y + 12, c.resource and G(194) or ("%d / 4"):format(c.count))
end

local function drawView(S, p)
    local st = state(S)
    local rec = st.rec
    local m = rec.chest.items[st.view]
    local lines = {}
    if m.resource or m.index < 0 then
        lines[1] = ""
    else
        local it = items.get(m.index)
        if it then
            lines[1] = it.name
            for _, l in ipairs(items.powerLines(it)) do lines[#lines + 1] = l end
        end
    end
    p:setString("STR_SMALL_450", itemLabel(m))
    for i, y in ipairs({ 50, 70, 90 }) do
        local l = lines[i + 1]
        local it = p:at("STR_SMALL200", 12, y)
        if it then p.itemStrings[it] = l or "" end
    end
    p:setDisabled("BUTT_EDITOR_REMOVE_ITEM", rec.chest.count <= 1)
    p:draw()
end

---@param S EditorScreen
function IT.draw(S, p)
    if S.dialog == "chest" then drawChest(S, p) elseif S.dialog == "chestview" then drawView(S, p) end
end

-- The chests are always drawn (the original shows them in every mode); the open one is ringed.
---@param S EditorScreen
function IT.drawMap(S, g)
    local st = S.it
    if st and st.rec and (S.mode == "items" or IT.isDialog(S.dialog)) then
        g.setColor(0.2, 1, 0.2, 0.9)
        g.ellipse("line", st.rec.x, st.rec.y, 20, 10)
        g.setColor(1, 1, 1)
    end
end

-- Map ----------------------------------------------------------------------------------------------------------------

---@param S EditorScreen
function IT.mapPress(S, x, y, button)
    local st = state(S)
    local wx, wy = S:mouseCell(x, y)
    local gx, gy = lib.snap(wx, wy)
    if gx < 0 or gy < 0 or gx >= S.scn.width or gy >= S.scn.height then return end
    local at, idx = lib.chestAt(S.scn, gx, gy)
    if button == 2 and not at and st.mode == "edit" and st.rec then
        -- the original's way to move the selected chest: a right click on an empty cell (the move action of FUN_004c4670)
        if lib.moveChest(S.scn, st.rec, gx, gy) then S:touch() end
    elseif button == 2 or st.mode == "delete" then
        if at then
            table.remove(S.scn.items, idx)
            st.rec = nil
            S:touch()
        end
    elseif st.mode == "edit" then
        if at then
            -- a click opens the chest dialog (on release); dragging moves the chest like the armies and buildings
            st.rec = at
            st.drag = { moved = false, dx = at.x - wx, dy = at.y - wy }
        end
    elseif button == 1 then
        local kind, which = selectedItem(S)
        if not kind then S:notify("Pick an entry from the list first") return end
        local rec, why = lib.placeChest(S.scn, gx, gy, kind, which)
        if rec then
            st.rec = rec
            S:touch()
        elseif why then
            S:notify(why == "full" and "A chest holds four items" or why == "resource" and "A resource chest holds nothing else"
                or why == "moditem" and "A mod item cannot be saved in a scenario chest"
                or "Only a numbered item goes into a chest that is there")
        end
    end
end

-- Dragging a chest in the Edit mode (the original moves the selected chest to the cell of a right click; the drag is
-- openwbc3's addition, like the dragging of armies and buildings).
---@param S EditorScreen
function IT.mouseMoved(S, wx, wy)
    local st = S.it
    if not st then return end
    local d = st.drag
    if not d or not st.rec then return end
    local gx, gy = lib.snap(wx + d.dx, wy + d.dy)
    if gx < 0 or gy < 0 or gx >= S.scn.width or gy >= S.scn.height then return end
    local cx, cy = math.floor(st.rec.x / CW), math.floor(st.rec.y / CH)
    if (gx ~= cx or gy ~= cy) and lib.moveChest(S.scn, st.rec, gx, gy) then
        d.moved = true
        S:touch()
    end
end

---@param S EditorScreen
function IT.mouseReleased(S)
    local st = S.it
    if not st then return end
    local d = st.drag
    if not d then return end
    st.drag = nil
    if not d.moved and st.rec and not S.dialog then S.dialog = "chest" end
end

-- Buttons and clicks -----------------------------------------------------------------------------------------------------

---@param S EditorScreen
function IT.button(S, panel, name)
    local st = state(S)
    if panel == "chest" then
        local k = ({ BUTT_EVENTS_EFFECTONE = 1, BUTT_EVENTS_EFFECTTWO = 2, BUTT_EVENTS_EFFECTTHREE = 3,
                     BUTT_EVENTS_EFFECTFOUR = 4 })[name]
        if k and k <= st.rec.chest.count then
            st.view = k
            S.dialog = "chestview"
        elseif name == "BUTT_EVENTS_DONE" then
            S.dialog = nil
        end
    elseif panel == "chestview" then
        if name == "BUTT_EDITOR_REMOVE_ITEM" then
            if lib.removeChestItem(st.rec, st.view) then S:touch() S.dialog = "chest" end
        elseif name == "BUTT_EDITOR_DONE" then
            S.dialog = "chest"
        end
    end
end

---@param S EditorScreen
function IT.click(S, id, extra, button)
    local st = state(S)
    if id == "it_type" then
        st.type = extra
        st.list = { scroll = 0 }
    elseif id == "it_mode" then
        st.mode = extra
    elseif id == "it_list" then
        st.sel[st.type] = extra
    else
        return false
    end
    return true
end

-- `I` enters the items mode (the original's in-house key); Escape closes the chest dialogs.
---@param S EditorScreen
function IT.keypressed(S, key)
    if IT.isDialog(S.dialog) then
        if key == "escape" then S.dialog = S.dialog == "chestview" and "chest" or nil return true end
        return false
    end
    if key == "i" and S.scn and not S.dialog and not love.keyboard.isDown("lctrl", "rctrl") then
        S.mode = "items"
        state(S)
        return true
    end
    return false
end

-- Developer aid: --show editor:items[_chest|_view] ---------------------------------------------------------------------------

---@param S EditorScreen
function IT.dev(S, sub)
    local scn = S.scn --[[@as table]]       -- the modes and dialogs open with a scenario only
    S.mode = "items"
    local st = state(S)
    -- a few chests next to the first start location of the demo map (or its centre)
    local gx, gy = 40, 30
    for i = 0, 5 do
        local sd = scn.sides[i]
        if sd.used and sd.startX >= 0 then gx, gy = sd.startX + 2, sd.startY + 2 break end
    end
    lib.placeChest(scn, gx, gy, "random")
    local list = chestItems()
    lib.placeChest(scn, gx + 3, gy, "item", list[1] and list[1].id --[[@as integer]] or 0)
    lib.placeChest(scn, gx + 3, gy, "item", list[2] and list[2].id --[[@as integer]] or 0)
    lib.placeChest(scn, gx + 6, gy, "resource", 1)
    lib.placeChest(scn, gx + 8, gy, "resource", 4)
    S.camX, S.camY = (gx + 4) * CW - S.vw / 2, gy * CH - S.vh / 2
    S:clampCamera()
    st.rec = lib.chestAt(scn, gx + 3, gy)
    if sub == "chest" or sub == "view" then S.dialog = "chest" end
    if sub == "view" then st.view = 2 S.dialog = "chestview" end
    if sub == "resource" then
        st.type = "resource"
        st.sel.resource = 2
    end
end

return IT
