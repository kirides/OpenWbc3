-- Scenario editor, events: the events mode panel, the event pool dialog, the modify dialog and the condition and
-- effect dialogs (screens/editor.lua calls into this module; the editor screen `S` is the first argument everywhere).
--
-- Follows the original editor's events mode (handlers of the pool 0x004b7e90, modify 0x004b8ae0, condition 0x004b90f0
-- and effect 0x004bdf80 dialogs) and the panels PNL_EDITMODE_EVENTS, PNL_EDITMODE_EVENTS_POOL, PNL_EVENTS_MODIFY,
-- PNL_EVENTS_CONDITION, PNL_EVENTS_EFFECT:
--  * the events panel lists the scenario's events (not slot 0, the standard victory), a timer event has its seconds
--    edited there, an event with a map position takes it from a click on the map; "Events" opens the pool;
--  * the pool dialog copies a template of EVENTS/*.EVT into the scenario (">" or a double click) or takes an event out
--    again ("<"); the pool's effects fix what an event does: the modify dialog can only change the fields of the
--    effects it already has, plus the condition, which cycles through its kinds;
--  * the condition dialog edits owner, kind (cycling 0-9, 23-29, 31-35 as the original does), square radius, the
--    event flag it needs, a number and a type (unit, building, side ...); the effect dialog the owner ("who"), number,
--    text, type and a map position (click the map).
-- What the dialogs show for each kind of condition and effect is the table of what the original's dialogs fill in
-- (FUN_004b9a30, FUN_004bacd0); the labels are its XCIStrings / Game.txt strings. Own additions, not in the
-- original: Ctrl+Up / Ctrl+Down reorders events; a counter increment's loop count only sets `shots` (the original also
-- copies it into the run-time loop counter, which would make the event repeat forever); numbers may be 0 where the
-- original ignores 0; the radius is limited to 10 (the editor has ten square sprites, EEE0..EEE9).
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local lib = require("src.game.editorlib")
local evt = require("src.formats.evt")
local strings = require("src.game.strings")

local E = {}
E.PANELS = { evpool = "PNL_EDITMODE_EVENTS_POOL", evmodify = "PNL_EVENTS_MODIFY", evcond = "PNL_EVENTS_CONDITION",
             eveffect = "PNL_EVENTS_EFFECT" }

-- the 700 pixel wide dialogs slide in at x = 50 (openers FUN_004b7aa0, FUN_004b8ec0, FUN_004bacd0), the others sit in
-- the middle panel's place
E.X = { evpool = 50, evcond = 50, eveffect = 50 }

local CW, CH = 32, 24
local ANY = evt.ANY

-- Strings ---------------------------------------------------------------------------------

local function X(id, sub) return UI.text(id, sub) or "" end
local function G(n) return strings.get("Game.txt", ("%04d"):format(n)) or "" end

-- A label given as { xciId, sub }, a Game.txt number or a plain string.
local function label(l)
    if type(l) == "table" then return X(l[1], l[2]) end
    if type(l) == "number" then return G(l) end
    return l or ""
end

local function dirty(S) S.dirty = true end

-- Type lists ----------------------------------------------------------------------------------
-- Every list is { { label, value }... }; the value is what the field takes (a packed type code, an index ...).

-- The control panel icons of condition 32 ("button press"): the list shows, for every icon 0 .. 97 (98 icons), the
-- title the button help routine FUN_00414ef0 gives it, which is a Game.txt line; an icon that routine has no case for
-- (blank 0, disguise 11, next 15, earthquake 56) shows "-*-", as does an empty line (list filler FUN_004babf0). The
-- table is icon -> Game.txt number; the chosen row's index is the condition's target.
local ICON_TITLE = {
    [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 141, [6] = 5, [7] = 10, [8] = 11, [9] = 149, [10] = 234,
    [12] = 224, [13] = 146, [14] = 100, [16] = 14, [17] = 7, [18] = 6, [19] = 13, [20] = 63, [21] = 71,
    [22] = 96, [23] = 213, [24] = 156, [25] = 222, [26] = 123, [27] = 70, [28] = 357, [29] = 116, [30] = 139,
    [31] = 8, [32] = 9, [33] = 12, [34] = 359, [35] = 360, [36] = 361, [37] = 362, [38] = 363, [39] = 364,
    [40] = 365, [41] = 366, [42] = 20, [43] = 19, [44] = 106, [45] = 107, [46] = 105, [47] = 108, [48] = 109,
    [49] = 159, [50] = 142, [51] = 152, [52] = 218, [53] = 220, [54] = 134, [55] = 407, [57] = 161, [58] = 163,
    [59] = 165, [60] = 167, [61] = 169, [62] = 171, [63] = 173, [64] = 175, [65] = 228, [66] = 230, [67] = 232,
    [68] = 417, [69] = 409, [70] = 412, [71] = 420, [72] = 415, [73] = 423, [74] = 426, [75] = 429, [76] = 526,
    [77] = 675, [78] = 677, [79] = 720, [80] = 726, [81] = 867, [82] = 872, [83] = 874, [84] = 876, [85] = 879,
    [86] = 906, [87] = 904, [88] = 884, [89] = 890, [90] = 902, [91] = 881, [92] = 888, [93] = 886, [94] = 892,
    [95] = 894, [96] = 1106, [97] = 1104,
}
local ICONS = 98

local lists = {}

local function xcis(id, n)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = { label = X(id, i), value = i } end
    return out
end

local function codes(src, any)
    local out = {}
    for _, a in ipairs(src) do out[#out + 1] = { label = a.name, value = evt.pack(a.code) } end
    if any then out[#out + 1] = { label = G(any), value = ANY } end
    return out
end

local function build(kind)
    local rules = require("src.game.rules")
    if kind == "army" or kind == "armyany" then return codes(rules.armyList(), kind == "armyany" and 197)
    elseif kind == "building" or kind == "buildingany" then return codes(rules.buildingList(), kind == "buildingany" and 198)
    elseif kind == "feature" then
        local out = {}
        for _, f in ipairs(lib.featureList()) do out[#out + 1] = { label = f.name, value = evt.pack(f.code) } end
        return out
    elseif kind == "side" then return xcis(109, 6)
    elseif kind == "race" then
        local out = xcis(277, 8)
        out[#out + 1] = { label = X(278, 0), value = 8 }
        return out
    elseif kind == "resource" then return xcis(121, 4)
    elseif kind == "damage" then return xcis(120, 5)
    elseif kind == "onoff" then return xcis(122, 2)
    elseif kind == "explosion" then return xcis(123, 6)
    elseif kind == "daynight" then return xcis(124, 2)
    elseif kind == "notify" then return { { label = G(208), value = 0 }, { label = G(209), value = 1 } }
    elseif kind == "slide" then return { { label = X(204, 3), value = 0 }, { label = X(204, 4), value = 1 } }
    elseif kind == "sound" then return { { label = G(207), value = 0 }, { label = G(206), value = 1 } }
    elseif kind == "ailevel" then
        local out = {}
        for i = 0, 7 do out[#out + 1] = { label = (X(214, i):gsub("^AI:%s*", "")), value = i } end
        return out
    elseif kind == "amount" then
        local out = {}
        for i = 0, 254 do out[#out + 1] = { label = tostring(i), value = i } end
        return out
    elseif kind == "flags" then
        local out = {}
        for i = 0, 15 do out[#out + 1] = { label = G(201):format(i), value = i } end
        out[#out + 1] = { label = G(200), value = -1 }
        return out
    elseif kind == "buttonicon" then
        local out = {}
        for i = 0, ICONS - 1 do
            local t = ICON_TITLE[i] and G(ICON_TITLE[i])
            out[#out + 1] = { label = (t and t ~= "") and t or "-*-", value = i }
        end
        return out
    elseif kind == "item" then
        local items = require("src.game.items")
        local out = {}
        for _, it in ipairs(items.all()) do out[#out + 1] = { label = it.name, value = it.id } end
        return out
    end
    return {}
end

local function list(kind)
    if not lists[kind] then lists[kind] = build(kind) end
    return lists[kind]
end

-- The characters of the scenario (armies marked as characters, with a name), for "move a character to a square".
local function characters(scn)
    local out, seen = {}, {}
    for _, a in ipairs(scn.armies) do
        if a.character and a.name ~= "" and not seen[a.name:lower()] then
            seen[a.name:lower()] = true
            out[#out + 1] = { label = a.name, value = a.name }
        end
    end
    return out
end

-- What each kind of condition shows (FUN_004b9a30): the title, the label and field of the number edit,
-- the type list (with its caption and the field it sets), and whether it has a map position and radius.
-- `target` fields hold the type; `number` is the count; kinds without a list say "No data required".
local COND = {
    [0] = { title = { 112, 0 }, num = { label = 202, obj = "event", field = "shots" } },
    [1] = { title = { 112, 1 }, num = { label = { 111, 0 } }, list = "armyany", cap = { 125, 3 }, pos = true },
    [2] = { title = { 112, 2 }, list = "race", cap = { 110, 2 }, pos = true },
    [3] = { title = { 112, 3 }, num = { label = { 111, 1 } }, list = "buildingany", cap = { 110, 3 } },
    [4] = { title = { 112, 4 }, num = { label = { 111, 0 } }, list = "armyany", cap = { 125, 3 } },
    [5] = { title = { 112, 5 }, num = { label = { 111, 0 } }, list = "armyany", cap = { 125, 3 } },
    [6] = { title = { 112, 6 }, num = { label = { 111, 0 } }, list = "side", cap = { 110, 4 } },
    [7] = { title = { 112, 7 }, list = "item", cap = { 110, 5 } },
    [8] = { title = { 113, 0 }, num = { label = { 111, 1 } }, list = "buildingany", cap = { 110, 3 } },
    [9] = { title = { 113, 1 }, num = { label = { 111, 1 } }, list = "side", cap = { 110, 4 } },
    [23] = { title = { 113, 2 }, note = 204 },
    [24] = { title = { 113, 3 }, num = { label = { 111, 0 } }, list = "armyany", cap = { 125, 3 } },
    [25] = { title = { 113, 4 }, num = { label = { 111, 1 } }, list = "buildingany", cap = { 110, 3 } },
    [26] = { title = { 113, 5 }, num = { label = { 111, 1 } }, list = "buildingany", cap = { 110, 3 } },
    [27] = { title = { 113, 6 }, num = { label = { 111, 1 } } },
    [28] = { title = { 113, 7 }, num = { label = { 111, 5 } } },
    [29] = { title = { 211, 0 }, num = { label = { 111, 6 } }, list = "resource", cap = { 211, 0 } },
    [31] = { title = { 211, 1 }, list = "char", cap = { 111, 3 }, pos = true },
    [32] = { title = { 211, 2 }, list = "buttonicon", nolabel = true },
    [33] = { title = { 211, 3 }, list = "side", cap = { 110, 4 } },
    [34] = { title = { 211, 4 }, num = { label = { 211, 4 } }, list = "side", cap = { 110, 4 } },
    [35] = { title = { 211, 5 }, list = "side", cap = { 110, 4 } },
}
-- Conditions the original's cycle button visits, in order (0-9, 23-29, 31-35).
local CYCLE = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 23, 24, 25, 26, 27, 28, 29, 31, 32, 33, 34, 35 }
local NEXT = {}
for i, c in ipairs(CYCLE) do NEXT[c] = CYCLE[i % #CYCLE + 1] end
-- the type a freshly chosen condition starts with: "any" for unit / building lists, else the first entry
local function defaultTarget(spec)
    if spec.list == "armyany" or spec.list == "buildingany" then return ANY end
    return 0
end

-- What each kind of effect shows (FUN_004bacd0): description, the number edit, the second edit (a file name,
-- a character name, or a number such as a radius), the type list and whether the effect has a map position.
-- Fields: ef.number, ef.location (radius / side / minutes), ef.type, ef.text. Sides are shown from 1.
local EFFECT = {
    [0] = { desc = { 116, 0 }, num = { label = { 119, 0 } }, txt = { label = { 206, 1 }, field = "location", kind = "num" },
            list = "damage", cap = { 125, 0 }, pos = true },
    [1] = { desc = { 116, 1 }, num = { label = { 119, 2 } }, list = "resource", cap = { 125, 1 } },
    [2] = { desc = { 116, 2 }, num = { label = { 119, 6 } }, list = "onoff", cap = { 125, 2 } },
    [3] = { desc = { 116, 3 } },
    [4] = { desc = { 116, 4 } },
    [5] = { desc = { 116, 5 }, num = { label = { 119, 1 } }, list = "army", cap = { 125, 3 }, pos = true },
    [6] = { desc = { 116, 6 }, list = "explosion", cap = { 125, 4 }, pos = true },
    [7] = { desc = { 116, 7 }, txt = { label = "Sound file", kind = "text" }, list = "sound", cap = { 125, 4 } },
    [8] = { desc = { 117, 0 }, num = { label = { 119, 5 } } },
    [9] = { desc = { 117, 1 }, txt = { label = { 114, 4 }, kind = "text" } },
    [10] = { desc = { 117, 2 }, txt = { label = "Video file", kind = "text" } },
    [11] = { desc = { 117, 3 }, num = { label = { 119, 3 } } },
    [12] = { desc = { 117, 4 }, list = "feature", cap = { 125, 5 }, pos = true },
    [13] = { desc = { 117, 5 }, list = "feature", cap = { 125, 5 }, pos = true },
    [14] = { desc = { 117, 6 }, num = { label = { 119, 2 } } },
    [15] = { desc = { 117, 7 }, num = { label = { 119, 7 } }, list = "onoff", cap = { 125, 7 } },
    [16] = { desc = { 118, 0 } },
    [17] = { desc = { 118, 1 }, num = { label = { 119, 4 } }, list = "daynight", cap = { 125, 6 } },
    [18] = { desc = { 118, 2 }, txt = { label = { 111, 3 }, kind = "text" } },
    [19] = { desc = { 118, 3 }, txt = { label = { 111, 3 }, kind = "text" } },
    [20] = { desc = { 118, 4 }, txt = { label = { 111, 3 }, kind = "text" }, list = "army", cap = { 125, 3 }, pos = true },
    [21] = { desc = { 118, 5 }, txt = { label = { 111, 4 }, kind = "text" }, list = "notify" },
    [22] = { desc = { 118, 6 }, num = { label = { 119, 6 } }, txt = { label = { 111, 4 }, kind = "text" }, list = "notify" },
    [23] = { desc = { 118, 7 }, list = "slide", cap = { 204, 3 }, pos = true },
    [24] = { desc = { 205, 0 }, num = { label = { 206, 0 } }, txt = { label = { 111, 3 }, kind = "text" } },
    [25] = { desc = { 205, 1 }, num = { label = { 206, 1 } }, pos = true },
    [26] = { desc = { 205, 2 }, txt = { label = "Scene file (.nis)", kind = "text" } },
    [27] = { desc = { 205, 3 }, num = { label = 210, field = "location" }, list = "flags", cap = { 204, 2 },
             listField = "number" },
    [28] = { desc = { 205, 4 }, txt = { label = { 111, 3 }, kind = "text" } },
    [29] = { desc = { 205, 5 }, txt = { label = { 111, 4 }, kind = "text" }, list = "notify" },
    [30] = { desc = { 205, 6 }, num = { label = { 27, 2 }, field = "location", offset = 1, min = 1, max = 6 },
             list = "ailevel", listField = "number" },
    [31] = { desc = { 205, 7 }, num = { label = { 27, 2 }, field = "location", offset = 1, min = 1, max = 6 } },
    [32] = { desc = { 276, 0 }, num = { label = { 27, 2 }, field = "location", offset = 1, min = 1, max = 6 } },
    [33] = { desc = { 276, 1 }, num = { label = { 27, 2 }, field = "location", offset = 1, min = 1, max = 6 },
             list = "amount", listField = "number" },
    [34] = { desc = { 276, 2 }, num = { label = { 27, 2 }, field = "location", offset = 1, min = 1, max = 6 },
             list = "amount", listField = "number", txt = { label = 202, field = "shots", kind = "num" } },
}
local EFFECT_NONE = { desc = "(no effect)" }

local function effectSpec(ef) return EFFECT[ef.effect] or EFFECT_NONE end

local function condSpec(c) return COND[c.condition] or { title = "Condition " .. tostring(c.condition) } end

-- State ------------------------------------------------------------------------------------------

---@param S EditorScreen
---@return table
local function state(S)
    if not S.evs then
        S.evs = { pool = { scroll = 0, sel = nil }, scn = { scroll = 0 }, type = { scroll = 0 }, buf = {}, fields = {} }
    end
    return S.evs
end

function E.isDialog(name) return name ~= nil and E.PANELS[name] ~= nil end

-- Dialogs that leave the map usable (scrolling, clicking a position).
function E.mapDialog(name) return E.isDialog(name) end

---@param S EditorScreen
---@return table? event, integer? index
function E.selected(S)
    local sel = S.st.events.sel
    return sel and lib.userEvents(S.scn)[sel] or nil, sel
end

-- Cell -> window of the map: scrolls so that the cell is in view.
local function centre(S, x, y)
    S:layout()
    S.camX, S.camY = x * CW + CW / 2 - S.vw / 2, y * CH + CH / 2 - S.vh / 2
    S:clampCamera()
end

-- Panels --------------------------------------------------------------------------------------------

local function hideAll(p, ...) for _, n in ipairs({ ... }) do p:hide(n) end end

-- Called when the editor builds the panel `name` ("events" or one of E.PANELS).
function E.setupPanel(p, name)
    if name == "events" then
        hideAll(p, "PAD_371x145", "SBAR_VEDIT120B", "LB_EDITITEMS_SCENARIO")
        for _, n in ipairs({ "STR_SMALL120", "STR_SMALL80" }) do
            local it = p:find(n)
            if it then p.align[it] = "center" end
        end
    elseif name == "evpool" then
        hideAll(p, "PAD_700x145", "SBAR_VEDIT120", "SBAR_VEDIT120B", "LB_EDITITEMS_POOL", "LB_EDITITEMS_SCENARIO")
    elseif name == "evmodify" then
        hideAll(p, "PAD_371x145")
    else
        hideAll(p, "PAD_700x145", "SBAR_VEDIT120", "LB_EVENTS_TYPE")
        for _, it in ipairs(p.items) do
            if it.name == "STR_SMALL120" or it.name == "STR_SMALL80" then p.align[it] = "center" end
        end
    end
end

-- Fields (the edit boxes) ------------------------------------------------------------------------------------
-- A field is { get = fn, set = fn(number|string), kind = "num"|"text", min, max, maxLen }; `buf` holds what is typed.

local function numField(obj, key, spec)
    local off = spec.offset or 0
    return { kind = "num", min = spec.min, max = spec.max or 32767,
             get = function() return (obj[key] or 0) + off end,
             set = function(v) obj[key] = v - off end }
end

-- Rebuilds the fields of the open dialog and fills the edit buffers from the model.
---@param S EditorScreen
function E.refresh(S)
    local st = state(S)
    st.fields = {}
    local e = st.event
    if S.dialog == "evcond" and e then
        local c = e.cond
        local spec = condSpec(c)
        st.fields.radius = numField(c, "radius", { min = 1, max = 10 })
        if spec.num then
            local n = spec.num
            local obj = n.obj == "event" and e or c
            st.fields.num = numField(obj, n.field or "number", { min = 0 })
        end
    elseif S.dialog == "eveffect" and e then
        local ef = st.effect
        local spec = effectSpec(ef)
        if spec.num then
            st.fields.num = numField(ef, spec.num.field or "number", spec.num)
            st.fields.num.min = spec.num.min or 0
        end
        if spec.txt then
            local t = spec.txt
            if t.kind == "text" then
                st.fields.text = { kind = "text", maxLen = 259, get = function() return ef.text or "" end,
                                   set = function(v) ef.text = v end }
            elseif t.field == "shots" then
                st.fields.text = { kind = "num", min = 0, max = 32767, get = function() return e.shots end,
                                   set = function(v) e.shots, e.loopCount = v, 0 end }
            else
                st.fields.text = numField(ef, t.field, { min = 0 })
            end
        end
    elseif S.dialog == nil and S.mode == "events" then
        local sel = E.selected(S)
        if sel and not sel.onMap then
            st.fields.time = { kind = "num", min = 0, max = 32767, get = function() return sel.seconds end,
                               set = function(v) sel.seconds = v end }
        end
        st.timeFor = sel
    end
    st.buf = {}
    for k, f in pairs(st.fields) do st.buf[k] = tostring(f.get()) end
    if not st.fields[st.focus or ""] then st.focus = nil end
end

local function commit(S, key)
    local st = state(S)
    local f = st.fields[key]
    if not f then return end
    if f.kind == "text" then f.set(st.buf[key] or "") return end
    local v = tonumber(st.buf[key])
    if not v then return end
    v = math.floor(v)
    if f.min and v < f.min then v = f.min end
    if f.max and v > f.max then v = f.max end
    f.set(v)
end

-- Opens a dialog on the event being modified (openers FUN_004b8990 / FUN_004b8ec0 / FUN_004bacd0).
local function open(S, dialog, e, slot)
    local st = state(S)
    st.event = e or st.event
    S.dialog = dialog
    if dialog == "eveffect" then
        st.slot = slot
        st.effect = nil
        for _, ef in ipairs(st.event.effects) do if ef.slot == slot then st.effect = ef end end
        -- an effect with a map position starts at (4, 4) when it has none (the original's default)
        local ef = st.effect
        if ef and effectSpec(ef).pos and (ef.x < 0 or ef.y < 0) then ef.x, ef.y = 4, 4 end
        if ef and effectSpec(ef).pos then centre(S, ef.x, ef.y) end
    end
    st.focus = nil
    st.type = { scroll = 0 }
    st.typeKey = nil
    E.refresh(S)
end

-- Widgets --------------------------------------------------------------------------------------------

local function edit(S, key, x, y, w, h)
    local st = state(S)
    local f = st.fields[key]
    if f then
        S.widgets.textBox(S, "ev_" .. key, st.buf[key] or "", x, y, w, h, st.focus == key)
    else
        -- an edit the kind does not use is greyed out
        local g = love.graphics
        g.setColor(0, 0, 0, 0.5)
        g.rectangle("fill", x, y, w, h)
        g.setColor(0.3, 0.3, 0.3)
        g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
        g.setColor(1, 1, 1)
    end
end

-- The type list at the panel's (350, 12): `items` { label, value }, `get` the current value, shows `note` when empty.
local function typeList(S, p, items, current, note)
    local st = state(S)
    local rows = {}
    local sel
    for i, it in ipairs(items) do
        rows[i] = { label = it.label, key = i }
        if it.value == current and sel == nil then sel = i end
    end
    if #rows == 0 then rows[1] = { label = note or G(203), key = 0, header = true } end
    st.type.sel = sel
    local key = tostring(S.dialog) .. ":" .. tostring(st.slot) .. ":" .. tostring(items)
    if st.typeKey ~= key then
        st.typeKey = key
        st.type.scroll = sel and math.max(0, sel - 4) or 0
    end
    S.widgets.listBox(S, "ev_type", rows, st.type, p.x + 350, p.y + 12, 200, 120)
    return items
end

local function setStr(p, name, x, y, s)
    if not p:setTextAt(name, x, y, s) then p:setString(name, s) end
end

local OWNER_LABEL = function(t, d)
    if t == 0 then return X(114, 1)
    elseif t == 1 then return X(114, 2)
    elseif t == 2 then return X(114, 3)
    elseif t == 3 then return X(109, d)
    else return X(115, d) end
end

-- Events panel (mode) ---------------------------------------------------------------------------------------

---@param S EditorScreen
function E.drawMode(S, p)
    local st = state(S)
    local events = lib.userEvents(S.scn)
    local e, sel = E.selected(S)
    if st.timeFor ~= e or (st.fields.time ~= nil) ~= (e ~= nil and not e.onMap) then E.refresh(S) end
    p:setDisabled("BUTT_EDIT_EVENTS_MODIFY", not e)
    if e then
        if e.onMap then
            p:setString("STR_SMALL120", G(196))
            p:setString("STR_SMALL80", ("%d, %d"):format(e.x, e.y))
        else
            p:setString("STR_SMALL120", G(195))
            p:setString("STR_SMALL80", "")
        end
    else
        p:setString("STR_SMALL120", "")
        p:setString("STR_SMALL80", "")
    end
    p:draw()
    local items = {}
    for i, ev in ipairs(events) do items[#items + 1] = { label = evt.name(ev.code), key = i } end
    S.widgets.listBox(S, "ev_list", items, S.st.events, p.x + 20, p.y + 12, 200, 120)
    if e and not e.onMap then edit(S, "time", p.x + 273, p.y + 35, 50, 20) end
end

-- Dialogs -----------------------------------------------------------------------------------------------------

local function drawPool(S, p)
    local st = state(S)
    p:draw()
    local pool = evt.pool()
    local items = {}
    for i, entry in ipairs(pool) do items[i] = { label = entry.name, key = i } end
    S.widgets.listBox(S, "ev_pool", items, st.pool, p.x + 13, p.y + 12, 200, 120)
    local rows = {}
    for i, ev in ipairs(lib.userEvents(S.scn)) do rows[i] = { label = evt.name(ev.code), key = i } end
    S.widgets.listBox(S, "ev_scn", rows, S.st.events, p.x + 278, p.y + 12, 200, 120)
    S.widgets.hint(p.x + 520, p.y + 14, "Ctrl+Up / Ctrl+Down", "moves the selected", "event in the list.")
end

local function drawModify(S, p)
    local st = state(S)
    local e = st.event
    for k = 1, evt.EFFECTS do
        local used
        for _, ef in ipairs(e.effects) do if ef.slot == k and ef.effect >= 0 then used = true end end
        p:setDisabled(({ "BUTT_EVENTS_EFFECTONE", "BUTT_EVENTS_EFFECTTWO", "BUTT_EVENTS_EFFECTTHREE",
                         "BUTT_EVENTS_EFFECTFOUR" })[k], not used)
    end
    p:draw()
    fonts.print(2, evt.name(e.code), p.x + 8, p.y + 128, "left", 138)
end

local function drawCond(S, p)
    local st = state(S)
    local e = st.event
    local c = e.cond
    local spec = condSpec(c)
    p:setString("BUTT_EVENTS_CONDITION_CYCLE", label(spec.title))
    p:setString("BUTT_EVENTS_OWNER", X(109, c.owner))
    setStr(p, "STR_MEDIUM120", 12, 42, X(110, 0))
    setStr(p, "STR_MEDIUM120", 12, 98, X(110, 1))
    setStr(p, "STR_MEDIUM200", 12, 70, spec.num and label(spec.num.label) or (spec.nolabel and "" or G(203)))
    p:setString("STR_MEDIUM70", X(204, 2))
    local flag = st.flag or 0
    p:setString("BUTT_EVENTS_FLAG_NUMBER", tostring(flag))
    p:setString("BUTT_EVENTS_FLAG_ONOFF", X(204, (c.flags or 0) % (2 ^ (flag + 1)) >= 2 ^ flag and 0 or 1))
    p:setString("STR_SMALL120", spec.cap and label(spec.cap) or "")
    p:draw()
    edit(S, "radius", p.x + 85, p.y + 98, 30, 19)
    edit(S, "num", p.x + 250, p.y + 70, 50, 19)
    local items, current
    if spec.list == "char" then
        items = characters(S.scn)
        local ef4
        for _, ef in ipairs(e.effects) do if ef.slot == 4 then ef4 = ef end end
        current = ef4 and ef4.text
    elseif spec.list then
        items = list(spec.list)
        current = c.target
    end
    if items then
        typeList(S, p, items, current)
    elseif spec.note then
        S.widgets.listBox(S, "ev_type", { { label = G(spec.note), key = 0, header = true } }, st.type, p.x + 350,
            p.y + 12, 200, 120)
    else
        S.widgets.listBox(S, "ev_type", { { label = G(203), key = 0, header = true } }, st.type, p.x + 350, p.y + 12,
            200, 120)
    end
    fonts.print(2, "Click the map to set the position", p.x + 12, p.y + 124, "left", 320)
end

local function drawEffect(S, p)
    local st = state(S)
    local ef = st.effect
    local spec = ef and effectSpec(ef) or EFFECT_NONE
    p:setString("STR_SMALL500", label(spec.desc))
    if ef then p:setString("BUTT_EVENTS_OWNER", OWNER_LABEL(ef.ownerType, ef.ownerData)) end
    setStr(p, "STR_MEDIUM120", 12, 42, X(114, 0))
    setStr(p, "STR_MEDIUM200", 12, 70, spec.num and label(spec.num.label) or G(203))
    setStr(p, "STR_MEDIUM200", 12, 98, spec.txt and label(spec.txt.label) or "")
    p:setTextAt("STR_SMALL120", 580, 12, spec.cap and label(spec.cap) or "")
    p:setTextAt("STR_SMALL120", 570, 50, spec.pos and G(205) or "")
    p:setString("STR_SMALL80", spec.pos and ef and ("%d, %d"):format(ef.x, ef.y) or "")
    p:draw()
    edit(S, "num", p.x + 195, p.y + 70, 50, 19)
    if spec.txt then
        edit(S, "text", p.x + 12, p.y + 113, spec.txt.kind == "text" and 300 or 50, 19)
    end
    if spec.pos then S.widgets.hint(p.x + 580, p.y + 32, "Click the map") end
    if spec.list and ef then
        local items = list(spec.list)
        typeList(S, p, items, ef[spec.listField or "type"])
    else
        S.widgets.listBox(S, "ev_type", { { label = G(203), key = 0, header = true } }, st.type, p.x + 350, p.y + 12,
            200, 120)
    end
end

-- Draws the dialog `S.dialog`.
---@param S EditorScreen
function E.draw(S, p)
    local name = S.dialog
    if name == "evpool" then drawPool(S, p)
    elseif name == "evmodify" then drawModify(S, p)
    elseif name == "evcond" then drawCond(S, p)
    elseif name == "eveffect" then drawEffect(S, p) end
end

-- Map overlay: the squares of the events with a position, the effect's position -------------------------------------

---@param S EditorScreen
function E.drawMap(S, g)
    if S.mode ~= "events" and not E.isDialog(S.dialog) then return end
    local st = state(S)
    local events = lib.userEvents(S.scn)
    local cur = st.event
    if not S.dialog then cur = E.selected(S) end
    for _, e in ipairs(events) do
        if e.onMap and e.cond.condition ~= 0 and e.x >= 0 and e.y >= 0 then
            local r = math.max(1, math.min(10, e.cond.radius or 1))
            -- the original's square sprite EEE<radius - 1>, a picture of r x r cells that is a faint shadow; the
            -- selected event also gets an outline (openwbc3's own aid) and so does every event when the install has no
            -- such sprite
            local sprite = S:editorSprite("EEE" .. (r - 1), e.x, e.y)
            if not sprite or e == cur then
                local half = r > 1 and math.floor(r / 2) or 0
                local sel = e == cur
                g.setColor(1, 0.9, 0.2, sel and 0.25 or 0.1)
                g.rectangle("fill", (e.x - half) * CW, (e.y - half) * CH, (2 * half + 1) * CW, (2 * half + 1) * CH)
                g.setColor(1, 0.9, 0.2, sel and 1 or 0.6)
                g.rectangle("line", (e.x - half) * CW + 0.5, (e.y - half) * CH + 0.5, (2 * half + 1) * CW - 1,
                    (2 * half + 1) * CH - 1)
            end
        end
    end
    if S.dialog == "eveffect" and st.effect and effectSpec(st.effect).pos then
        local ef = st.effect
        if not S:editorSprite("EEBX", ef.x, ef.y) then       -- the original's red X
            local cx, cy = ef.x * CW + CW / 2, ef.y * CH + CH / 2
            g.setColor(1, 0.2, 0.2)
            g.setLineWidth(3)
            g.line(cx - 12, cy - 12, cx + 12, cy + 12)
            g.line(cx - 12, cy + 12, cx + 12, cy - 12)
            g.setLineWidth(1)
        end
    end
    g.setColor(1, 1, 1)
end

-- A click on the map (window position x, y): sets the effect's position in the effect dialog, else the position of the
-- event (map click routines FUN_004c3c70 / FUN_004c39d0).
---@param S EditorScreen
function E.mapPress(S, x, y, button)
    if button ~= 1 or S.dialog == "evpool" then return end
    local st = state(S)
    local wx, wy = S:mouseCell(x, y)
    local gx, gy = lib.snap(wx, wy)
    if gx < 0 or gy < 0 or gx >= S.scn.width or gy >= S.scn.height then return end
    if S.dialog == "eveffect" then
        local ef = st.effect
        if ef and effectSpec(ef).pos then
            ef.x, ef.y = gx, gy
            dirty(S)
        end
        return
    end
    local e = S.dialog and st.event or E.selected(S)
    if e and e.onMap then
        e.x, e.y = gx, gy
        dirty(S)
    end
end

-- Buttons ----------------------------------------------------------------------------------------------------------

local function ownerCycle(ef, condOwner)
    local t, d = ef.ownerType, ef.ownerData
    if t == 0 then ef.ownerData, ef.ownerType = 0, 3
    elseif t == 1 then ef.ownerData, ef.ownerType = condOwner, 2
    elseif t == 2 then ef.ownerData, ef.ownerType = 0, 0
    elseif t == 3 then
        ef.ownerData = d + 1
        if ef.ownerData == 6 then ef.ownerData, ef.ownerType = 0, 4 end
    elseif t == 4 then
        ef.ownerData = d + 1
        if ef.ownerData == 6 then ef.ownerData, ef.ownerType = condOwner, 1 end
    end
end

---@param S EditorScreen
function E.button(S, panel, name)
    local st = state(S)
    if panel == "events" then
        if name == "BUTT_EDITOR_EVENTS_ADD" then
            lib.ensureEvents(S.scn)
            S.dialog = "evpool"
            st.pool.sel = st.pool.sel or (#evt.pool() > 0 and 1 or nil)
        elseif name == "BUTT_EDIT_EVENTS_MODIFY" then
            local e = E.selected(S)
            if e then open(S, "evmodify", e) end
        end
    elseif panel == "evpool" then
        if name == "BUTT_EDITOR_RIGHT" then
            E.addSelected(S)
        elseif name == "BUTT_EDITOR_LEFT" then
            E.removeSelected(S)
        elseif name == "BUTT_EDITOR_DONE" then
            S.dialog = nil
            if #lib.userEvents(S.scn) > 0 then S.st.events.sel = S.st.events.sel or 1 end
            E.refresh(S)
        end
    elseif panel == "evmodify" then
        if name == "BUTT_EVENTS_CONDITION" then open(S, "evcond")
        elseif name == "BUTT_EVENTS_EFFECTONE" then open(S, "eveffect", nil, 1)
        elseif name == "BUTT_EVENTS_EFFECTTWO" then open(S, "eveffect", nil, 2)
        elseif name == "BUTT_EVENTS_EFFECTTHREE" then open(S, "eveffect", nil, 3)
        elseif name == "BUTT_EVENTS_EFFECTFOUR" then open(S, "eveffect", nil, 4)
        elseif name == "BUTT_EVENTS_DONE" then
            S.dialog = nil
            E.refresh(S)
        end
    elseif panel == "evcond" then
        local e = st.event
        local c = e.cond
        if name == "BUTT_EVENTS_OWNER" then
            c.owner = (c.owner + 1) % 7
        elseif name == "BUTT_EVENTS_CONDITION_CYCLE" then
            c.condition = NEXT[c.condition] or 0
            e.onMap = c.condition ~= 0
            local spec = condSpec(c)
            c.target = spec.list and defaultTarget(spec) or 0
            E.refresh(S)
            st.type = { scroll = 0 }
            dirty(S)
        elseif name == "BUTT_EVENTS_FLAG_NUMBER" then
            st.flag = ((st.flag or 0) + 1) % 16
        elseif name == "BUTT_EVENTS_FLAG_ONOFF" then
            local bit = require("bit")
            c.flags = bit.bxor(c.flags or 0, bit.lshift(1, st.flag or 0))
            dirty(S)
        elseif name == "BUTT_EVENTS_DONE" then
            S.dialog = "evmodify"
            E.refresh(S)
        end
        dirty(S)
    elseif panel == "eveffect" then
        if name == "BUTT_EVENTS_OWNER" and st.effect then
            ownerCycle(st.effect, st.event.cond.owner)
            dirty(S)
        elseif name == "BUTT_EVENTS_DONE" then
            S.dialog = "evmodify"
            E.refresh(S)
        end
    end
end

---@param S EditorScreen
function E.addSelected(S)
    local st = state(S)
    local entry = evt.pool()[st.pool.sel or 0]
    if not entry then return end
    local e = lib.addEvent(S.scn, entry)
    if not e then S:notify("The scenario has no room for more events") return end
    S.st.events.sel = #lib.userEvents(S.scn)
    dirty(S)
end

---@param S EditorScreen
function E.removeSelected(S)
    local sel = S.st.events.sel
    if not sel or not lib.userEvents(S.scn)[sel] then return end
    lib.removeEvent(S.scn, sel)
    local n = #lib.userEvents(S.scn)
    S.st.events.sel = n > 0 and math.min(sel, n) or nil
    dirty(S)
end

-- Clicks on the custom widgets: ids "ev_<what>". Returns true when handled.
---@param S EditorScreen
function E.click(S, id, extra, button)
    local st = state(S)
    if id == "ev_list" then
        S.st.events.sel = extra
        local e = lib.userEvents(S.scn)[extra]
        if e and e.onMap and e.x >= 0 then centre(S, e.x, e.y) end
        E.refresh(S)
        if button == 1 and st.last and st.last.id == id and st.last.i == extra
            and love.timer.getTime() - st.last.t < 0.4 then
            open(S, "evmodify", e)
        end
        st.last = { id = id, i = extra, t = love.timer.getTime() }
    elseif id == "ev_pool" then
        st.pool.sel = extra
        if button == 1 and st.last and st.last.id == id and st.last.i == extra
            and love.timer.getTime() - st.last.t < 0.4 then
            E.addSelected(S)
        end
        st.last = { id = id, i = extra, t = love.timer.getTime() }
    elseif id == "ev_scn" then
        S.st.events.sel = extra
        if button == 1 and st.last and st.last.id == id and st.last.i == extra
            and love.timer.getTime() - st.last.t < 0.4 then
            E.removeSelected(S)
        end
        st.last = { id = id, i = extra, t = love.timer.getTime() }
    elseif id == "ev_type" then
        E.pickType(S, extra)
    elseif id:match("^ev_%a+$") and st.fields[id:sub(4)] then
        st.focus = id:sub(4)
    else
        return false
    end
    return true
end

-- The list entry `i` of the type list was picked: sets the field it is about.
---@param S EditorScreen
function E.pickType(S, i)
    local st = state(S)
    local e = st.event
    if S.dialog == "evcond" then
        local spec = condSpec(e.cond)
        if spec.list == "char" then
            local ch = characters(S.scn)[i]
            if not ch then return end
            -- the name goes into the fourth effect's text, as the original's Done does (FUN_004b99d0)
            local ef4
            for _, ef in ipairs(e.effects) do if ef.slot == 4 then ef4 = ef end end
            if not ef4 then
                ef4 = { slot = 4, ownerType = 0, ownerData = 0, effect = -1, number = 0, location = 0, type = 0, text = "",
                        x = 0, y = 0 }
                e.effects[#e.effects + 1] = ef4
                table.sort(e.effects, function(a, b) return a.slot < b.slot end)
            end
            ef4.text = ch.value
        elseif spec.list then
            local it = list(spec.list)[i]
            if it then e.cond.target = it.value end
        end
    elseif S.dialog == "eveffect" and st.effect then
        local spec = effectSpec(st.effect)
        local it = spec.list and list(spec.list)[i]
        if it then st.effect[spec.listField or "type"] = it.value end
    end
    dirty(S)
end

-- Keyboard ---------------------------------------------------------------------------------------------------------

local function relevant(S)
    return E.isDialog(S.dialog) or (S.dialog == nil and S.mode == "events")
end

---@param S EditorScreen
function E.textinput(S, t)
    if not relevant(S) then return false end
    local st = state(S)
    local f = st.fields[st.focus or ""]
    if not f then return false end
    if f.kind == "num" then
        if not t:match("^[%d%-]$") then return true end
    else
        if not t:match("^[%w%s%p]$") or #(st.buf[st.focus] or "") >= (f.maxLen or 259) then return true end
    end
    st.buf[st.focus] = (st.buf[st.focus] or "") .. t
    commit(S, st.focus)
    dirty(S)
    return true
end

---@param S EditorScreen
function E.keypressed(S, key)
    if not relevant(S) then return false end
    local st = state(S)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if key == "backspace" and st.focus then
        st.buf[st.focus] = require("src.ui.kit").backspace(st.buf[st.focus] or "")
        commit(S, st.focus)
        dirty(S)
        return true
    elseif (key == "return" or key == "kpenter" or key == "tab") and st.focus then
        -- leaving the field shows what the model took (clamped)
        local k = st.focus
        E.refresh(S)
        st.focus = nil
        if key == "tab" then
            local order = { "num", "text", "radius" }
            for i, name in ipairs(order) do
                if name == k then
                    for j = 1, #order do
                        local nxt = order[(i + j - 1) % #order + 1]
                        if st.fields[nxt] then st.focus = nxt break end
                    end
                end
            end
        end
        return true
    elseif ctrl and (key == "up" or key == "down") and (S.dialog == "evpool" or S.dialog == nil) then
        local sel = S.st.events.sel
        if sel then S.st.events.sel = lib.moveEvent(S.scn, sel, key == "up" and -1 or 1) dirty(S) end
        return true
    elseif key == "escape" and E.isDialog(S.dialog) then
        E.back(S)
        return true
    end
    return false
end

-- One dialog level back (Escape).
---@param S EditorScreen
function E.back(S)
    local d = S.dialog
    if d == "evcond" or d == "eveffect" then
        S.dialog = "evmodify"
        E.refresh(S)
    else
        S.dialog = nil
        E.refresh(S)
    end
end

-- Developer aid: --show editor:events (mode), events_pool, events_modify, events_cond, events_effect[N] ---------------

---@param S EditorScreen
function E.dev(S, sub)
    S.mode = "events"
    lib.ensureEvents(S.scn)
    local pool = {}
    for _, p in ipairs(evt.pool()) do pool[p.code] = p end
    if #lib.userEvents(S.scn) == 0 then
        for _, code in ipairs({ "EACM", "EDMU", "ECLK", "EVIC" }) do
            local e = pool[code] and lib.addEvent(S.scn, pool[code])
            if e and code == "EDMU" then e.x, e.y, e.cond.radius = 40, 30, 4 end
            if e and code == "EACM" then e.x, e.y = 20, 20 end
            if e and code == "EVIC" then e.cond.condition, e.onMap, e.seconds = 0, false, 600 end
        end
    end
    S.st.events.sel = 2
    local e = E.selected(S)
    if e and e.onMap then centre(S, e.x, e.y) end
    if sub == "pool" then
        S.dialog = "evpool"
    elseif sub == "modify" then
        open(S, "evmodify", e)
    elseif sub == "cond" then
        open(S, "evmodify", e)
        open(S, "evcond")
    elseif sub == "cond32" then
        open(S, "evmodify", e)
        ---@cast e -nil
        e.cond.condition, e.cond.target = 32, 7
        open(S, "evcond")
    elseif sub and sub:match("^effect") then
        open(S, "evmodify", e)
        open(S, "eveffect", nil, tonumber(sub:match("%d+")) or 1)
    else
        E.refresh(S)
    end
end

return E
