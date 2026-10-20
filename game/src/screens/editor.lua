-- Scenario editor (main menu "Editor"): the original editor bar (mode buttons, minimap) with the
-- middle panel per mode. Modes: Terrain (tile tree, big tiles, fill), Features, Armies and
-- Buildings (place / select and drag / delete, per side), Effects (listed, can be deleted), Events (pool,
-- modify, condition and effect dialogs: see editorevents.lua), Options, Sides, Start Loc's and Menu (new / load / save).
-- Scenarios are saved to the user directory (see src/game/editorlib.lua) and show up in the
-- skirmish list. Left click acts, right click deletes the object under the cursor, arrow keys /
-- screen edges / minimap scroll, Del deletes the selection, Ctrl+S saves.
-- Saving, exiting, overwriting and deleting ask through the original's message boxes (S:messageBox); Ctrl+R in the New dialog makes a
-- random map.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local config = require("src.core.config")
local fs = require("src.core.fs")
local scnMod = require("src.formats.scn")
local sprite = require("src.formats.sprite")
local terrainMod = require("src.game.terrain")
local lib = require("src.game.editorlib")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local anims = require("src.gfx.anims")
local cursor = require("src.ui.cursor")
local log = require("src.core.log")
local strings = require("src.game.strings")
local E = require("src.screens.editorevents")
local O = require("src.screens.editorobject")
local SD = require("src.screens.editorsides")
local IT = require("src.screens.editoritems")
-- the modules that own dialogs (each has PANELS, setupPanel, draw, button, click, textinput, keypressed, mapDialog ...)
---@class EditorDialogModule
---@field PANELS table<string, string>   dialog name -> XCI panel
---@field X table<string, integer>       dialog name -> panel x (default: the middle panel's)
---@field setupPanel fun(p: Panel, name: string)
---@field draw fun(S: EditorScreen, p: Panel)
---@field button fun(S: EditorScreen, panel: string, name: string, it: PanelItem?)
---@field mapDialog fun(name: string?): boolean whether the map takes clicks while the dialog is open
---@field drawMap? fun(S: EditorScreen, g: table)
---@type EditorDialogModule[]
local EXT = { E, O, SD, IT }
---@param name string?
---@return EditorDialogModule?
local function dialogOwner(name)
    for _, m in ipairs(EXT) do if m.PANELS[name] then return m end end
end

local A = sprite.ANIM
local CW, CH = terrainMod.CELL_W, terrainMod.CELL_H
local TW, TH = terrainMod.TILE_W, terrainMod.TILE_H

local BAR_Y = 448                 -- the editor bar below the map view (virtual 800x600 canvas)
local MID_X, MID_Y = 150, 452     -- middle panel
local MM_X, MM_Y = 11, BAR_Y + 11 -- minimap (128x128)
local LINE, FONT = 17, 5
local BLUE = { 0.12, 0.25, 0.65 }

local MODES = {
    { "terrain", "Terrain", 550, 13 }, { "features", "Features", 660, 13 },
    { "effects", "Effects", 550, 38 }, { "options", "Options", 660, 38 },
    { "armies", "Armies", 550, 63 }, { "sides", "Sides", 660, 63 },
    { "buildings", "Buildings", 550, 88 }, { "startlocs", "Start Loc's", 660, 88 },
    { "events", "Events", 550, 113 }, { "menu", "Menu", 660, 113 },
}
local PANELS = {
    terrain = "PNL_EDITOR_TERRAINNEW", features = "PNL_EDITMODE_FEATURE", armies = "PNL_EDITMODE_ARMY",
    buildings = "PNL_EDITMODE_BUILDING", effects = "PNL_EDITOR_EFFECTS", events = "PNL_EDITMODE_EVENTS",
    options = "PNL_EDITMODE_OPTIONS", sides = "PNL_EDITMODE_SIDES", startlocs = "PNL_EDITMODE_STARTPOS",
    menu = "PNL_EDITMODE_MENU", new = "PNL_EDITOR_NEW_SCENARIO", load = "PNL_EDITOR_LOAD_SCENARIO",
    items = "PNL_EDITOR_EDIT_ITEMS",        -- not on the mode bar: the `I` key (editoritems.lua)
}
for _, m in ipairs(EXT) do for k, v in pairs(m.PANELS) do PANELS[k] = v end end
local LAYER = { features = "features", armies = "armies", buildings = "buildings", effects = "effects" }
local TOOLS = { { "place", "Place" }, { "select", "Select" }, { "delete", "Delete" } }
local FOG = { [0] = "No fog", "Fog of war", "Explored map" }
-- AI levels 0..7 (the names are XCIStrings [0214.*] without the "AI: " prefix)
local AI = { [0] = "Passive", "Squire", "Knight", "Lord", "Prince", "Warlord", "Emperor", "Rampant" }
local SIDE_NAMES = { [0] = "Red", "Blue", "Green", "Purple", "Black", "Yellow", "Neutral" }

---@class EditorListState         scroll position and selected key of a list drawn by listBox
---@field scroll number
---@field sel any

---@class EditorScreen: Screen
---@field mode string                    "menu", "terrain", "features", "armies", "buildings", "effects", "events" ...
---@field tool string                    "place", "select" or "delete"
---@field side integer                   owner of placed armies / buildings (0..6)
---@field clock number                   seconds since the editor opened
---@field camX number
---@field camY number
---@field lists table<string, table>     geometry of the lists drawn this frame (scroll bars, wheel)
---@field hits table[]                   hit boxes of the custom widgets drawn this frame
---@field st table<string, EditorListState> list state per mode / dialog
---@field collapsed table<integer, boolean> folded groups of the tile tree
---@field panels table<string, Panel>    XCI panels per mode / dialog name
---@field bar Panel                      PNL_EDITBAR
---@field scn table?                     the scenario being edited (src/formats/scn.lua)
---@field terrain Terrain?
---@field file string?                   its file in the user folder
---@field dirty boolean?
---@field dialog string?                 open dialog ("new", "load" or one of the modules' PANELS)
---@field dialogKind string?             the "new" dialog: "new" or "saveas"
---@field newSize integer                index into editorlib.SIZES
---@field newName string
---@field newDesc string
---@field focusField string              "name" / "desc" of the New dialog
---@field brush table?                   tile catalogue entry painted in the terrain mode
---@field type table<string, string>     chosen type code per object mode
---@field notice { text: string, t: number }?
---@field s number?                      UI scale (layout)
---@field W number
---@field H number
---@field ox number
---@field oy number
---@field mapBottom number               window y of the map's bottom edge
---@field zoom number?
---@field ms number                      map scale
---@field vw number                      map view size in world pixels
---@field vh number
---@field mx number                      mouse in virtual coordinates
---@field my number
---@field minimap love.Image?
---@field mmDirty boolean?
---@field mb { panel: Panel, interlace: Panel, question: boolean?, cb: fun(yes: boolean)? }? open message box
---@field randomPending boolean?         Ctrl+R made a map, the New dialog is still open
---@field loadEntries table[]?           the Load dialog's scenarios
---@field preview { e: table, image: love.Image }? minimap of the Load dialog's scenario
---@field painting boolean?
---@field lastPaint string?
---@field dragObj { dx: number, dy: number, moved: boolean }?
---@field selected { layer: string, o: table, i: integer }?
---@field draggingMinimap boolean?
---@field dragFn fun(vx: number)?        drag of a scroll bar knob (editorsides.lua)
---@field lastLoadClick { i: integer, t: number }?
---@field bq table<integer, love.Quad>?  quads of bitmap 50's button rows
---@field cache table<string, table[]>?  type lists per object mode
---@field treeInit boolean?
---@field tileIcons table<string, love.Image|false>?
---@field evs table?                     state of editorevents.lua
---@field it table?                      state of editoritems.lua
---@field obj table?                     state of editorobject.lua
---@field sd table?                      state of editorsides.lua
---@field START_SPRITE table<integer, string> start location sprite per shield colour
---@field widgets table                  the widget helpers below, for the dialog modules
local S = {}
S.ownCursor = true      -- the editor draws its cursor at its own scale

-- Small helpers -------------------------------------------------------------------------

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function reg(self, id, x, y, w, h, extra)
    self.hits[#self.hits + 1] = { id = id, x = x, y = y, w = w, h = h, extra = extra }
    return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h
end

-- Button drawn from the interface bitmap 50 (three rows: normal, hover, pressed), stretched to w.
local function bmpButton(self, id, label, x, y, w, selected, extra, disabled)
    local g = love.graphics
    local img = UI.bitmap(50)
    local hv = reg(self, not disabled and id or nil, x, y, w, 18, extra)
    if img then
        local row = disabled and 0 or ((selected or (hv and love.mouse.isDown(1))) and 2 or (hv and 1 or 0))
        self.bq = self.bq or {}
        local q = self.bq[row]
        if not q then
            q = g.newQuad(0, row * 18, 110, 18, img:getDimensions())
            self.bq[row] = q
        end
        g.setColor(1, 1, 1, disabled and 0.5 or 1)
        g.draw(img, q, x, y, 0, w / 110, 1)
    end
    fonts.print(FONT, label, x, y + fonts.middleY(FONT, 18), "center", w, disabled and 0.5 or 1)
    g.setColor(1, 1, 1)
    return hv
end

local function textBox(self, id, text, x, y, w, h, focused)
    local g = love.graphics
    reg(self, id, x, y, w, h)
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", x, y, w, h)
    g.setColor(focused and 0.35 or BLUE[1], focused and 0.5 or BLUE[2], focused and 1 or BLUE[3])
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    local caret = focused and (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    fonts.print(FONT, text .. caret, x + 4, y + fonts.middleY(FONT, h) - 1)
end

local function hint(x, y, ...)
    for i, line in ipairs({ ... }) do fonts.print(2, line, x, y + (i - 1) * 14, "left", 120) end
end

-- Scrollable list. items: { label, key, indent, header }; st: { scroll, sel (key) }.
local function listBox(self, id, items, st, x, y, w, h)
    local g = love.graphics
    local rows = math.floor(h / LINE)
    st.scroll = clamp(st.scroll or 0, 0, math.max(0, #items - rows))
    g.setColor(0, 0, 0, 0.9)
    g.rectangle("fill", x, y, w, h)
    g.setColor(BLUE[1], BLUE[2], BLUE[3])
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    reg(self, id .. ":bg", x, y, w, h)
    self.lists[id] = { st = st, x = x, y = y, w = w, h = h, rows = rows, count = #items }
    for r = 1, rows do
        local i = st.scroll + r
        local it = items[i]
        if not it then break end
        local ry = y + (r - 1) * LINE
        local hv = not it.header and reg(self, id, x, ry, w, LINE, i) or reg(self, id, x, ry, w, LINE, i)
        if st.sel ~= nil and it.key == st.sel and not it.header then
            g.setColor(0.1, 0.2, 0.5, 0.95)
            g.rectangle("fill", x + 1, ry, w - 2, LINE)
        elseif hv then
            g.setColor(1, 1, 1, 0.07)
            g.rectangle("fill", x + 1, ry, w - 2, LINE)
        end
        g.setColor(1, 1, 1)
        fonts.print(FONT, it.label, x + 4 + (it.indent or 0) * 12, ry + fonts.middleY(FONT, LINE) - 1,
            "left", w - 8)
    end
    -- scroll bar
    local bx = x + w + 2
    g.setColor(0.05, 0.04, 0.03, 0.9)
    g.rectangle("fill", bx, y, 16, h)
    g.setColor(0.5, 0.45, 0.4)
    g.rectangle("line", bx + 0.5, y + 0.5, 15, h - 1)
    reg(self, id .. ":up", bx, y, 16, 16)
    reg(self, id .. ":down", bx, y + h - 16, 16, 16)
    reg(self, id .. ":track", bx, y + 16, 16, h - 32)
    g.setColor(0.7, 0.65, 0.5)
    g.polygon("fill", bx + 8, y + 4, bx + 3, y + 12, bx + 13, y + 12)
    g.polygon("fill", bx + 8, y + h - 4, bx + 3, y + h - 12, bx + 13, y + h - 12)
    local span = math.max(1, #items - rows)
    if #items > rows then
        local th = math.max(14, (h - 36) * rows / #items)
        local ty = y + 18 + (h - 36 - th) * st.scroll / span
        g.setColor(0.45, 0.38, 0.3)
        g.rectangle("fill", bx + 2, ty, 12, th)
    end
    g.setColor(1, 1, 1)
end

-- Entering / leaving ------------------------------------------------------------------

function S:enter()
    cursor.enable(true)
    self.mode = "menu"
    self.tool = "place"
    self.side = 6
    self.clock = 0
    self.camX, self.camY = 0, 0
    self.lists, self.hits = {}, {}
    self.st = { terrain = { scroll = 0 }, features = { scroll = 0 }, armies = { scroll = 0 },
                buildings = { scroll = 0 }, effects = { scroll = 0 }, events = { scroll = 0 },
                startlocs = { scroll = 0, sel = 0 }, load = { scroll = 0 } }
    self.collapsed = {}
    self.panels = {}
    self.bar = UI.panel("PNL_EDITBAR", { x = 0, y = BAR_Y }) --[[@as Panel]]
    self.bar:hide("BUTT_EDITMODE")
    self.bar:hide("BUTT_STRAT_MAP")
    for _, n in ipairs({ "IM_STRAT_FEATURES", "IM_STRAT_ARMIES", "IM_STRAT_BUILDINGS", "IM_STRAT_ENCOUNTERS",
                         "IM_STRAT_EVENTS", "IM_STRAT_STARTLOCS", "IM_STRAT_SQUARE" }) do self.bar:hide(n) end
    self.scn, self.terrain, self.file = nil, nil, nil
    self.dialog = nil
    self.newSize, self.newName, self.newDesc, self.focusField = 1, "", "", "name"
    self.brush = lib.baseTile()
    self.type = {}
end

function S:leave()
    cursor.enable(false)
end

---@param text string
function S:notify(text) self.notice = { text = text, t = love.timer.getTime() } end

-- Replaces the scenario being edited.
---@param scn table      parsed scenario (src/formats/scn.lua)
---@param file string?   its file in the user folder
function S:setScenario(scn, file)
    self.scn, self.file, self.dirty = scn, file, false
    lib.ensureEvents(scn)
    lib.ensureAI(scn)
    self.evs, self.st.events = nil, { scroll = 0 }
    self.terrain = terrainMod.new(scn)
    self.selected = nil
    local sx, sy
    for i = 0, 5 do
        local s = scn.sides[i]
        if s.used and s.startX >= 0 then sx, sy = s.startX * CW, s.startY * CH break end
    end
    self:layout()
    self.camX, self.camY = (sx or self.terrain.pixelW / 2) - self.vw / 2, (sy or self.terrain.pixelH / 2) - self.vh / 2
    self:clampCamera()
    self:buildMinimap()
    self.mode = "terrain"
    self.dialog = nil
end

-- Like the battle screen: the 800x600 interface is scaled to the window and sits at its bottom;
-- the map fills the window above the editor bar at the same scale.
function S:layout()
    local W, H = love.graphics.getDimensions()
    local s = H / 600
    if 800 * s > W then s = W / 800 end
    local base = s  -- the map follows the window only, not the UI scale option
    s = s * require("src.ui.interface").userScale()
    self.s, self.W, self.H = s, W, H
    self.ox, self.oy = math.floor((W - 800 * s) / 2), H - 600 * s
    self.mapBottom = math.floor(self.oy + BAR_Y * s)
    self.zoom = self.zoom or 1
    self.ms = base * self.zoom     -- map scale
    self.vw, self.vh = W / self.ms, self.mapBottom / self.ms
end

---@return number vx, number vy
function S:toV(x, y)
    if not self.s then self:layout() end
    return (x - self.ox) / self.s, (y - self.oy) / self.s
end

function S:clampCamera()
    if not self.terrain then return end
    self:layout()
    self.camX = clamp(self.camX, 0, math.max(0, self.terrain.pixelW - self.vw))
    self.camY = clamp(self.camY, 0, math.max(0, self.terrain.pixelH - self.vh))
end

function S:buildMinimap()
    if not self.scn then return end
    local mm = lib.minimap(self.scn, self.terrain)
    self.scn.minimap = mm
    local img = love.image.newImageData(128, 128)
    for y = 0, 127 do
        for x = 0, 127 do
            local o = (y * 128 + x) * 3 + 1
            local b, g, r = mm:byte(o, o + 2)
            img:setPixel(x, y, r / 255, g / 255, b / 255, 1)
        end
    end
    if self.minimap then self.minimap:release() end
    self.minimap = love.graphics.newImage(img)
    self.mmDirty = false
end

function S:touch()
    self.dirty = true
    self.mmDirty = true
end

-- Developer aid: --show editor:<what> (new, bridges, terrain, features, armies, buildings, sides, options ...).
function S:dev(sub)
    if sub == "new" then
        self:setScenario(lib.newScenario("Test", 64, "A test map"))
        return
    end
    if sub == "newdialog" then self.dialog = "new" return end
    if sub == "demo" then self:demo() return end
    if sub == "loaddialog" then self:openLoad() return end
    local data = fs.read(config.gamedir .. "/Scenario/Bridges.SCN")
    if data then
        local scn = scnMod.parse(data)
        if scn then self:setScenario(scn, nil) end
    end
    if sub == "mb" then self:saveReport(true) return end
    if sub == "mbfail" then self:saveReport(false) return end
    if sub == "mbstart" then self.mode = "menu" self.scn.sides[0].used, self.scn.sides[0].startX = true, -1 self:button("menu", "BUTT_EDIT_SAVEEXIT") return end
    if sub == "mbexit" then self.mode = "menu" self:button("menu", "BUTT_EDIT_EXIT") return end
    if sub == "mbexists" then
        self.mode = "menu"
        self:messageBox(UI.text(223, 0), UI.text(223, 1), UI.text(223, 2), true)
        return
    end
    if sub == "random" then
        self.mode = "menu"
        self.dialog, self.dialogKind, self.newName, self.newDesc, self.newSize = "new", "new", "RandomTest", "", 3
        self:randomMap()
        return
    end
    if PANELS[sub] then self.mode = sub end
    if sub == "armies" then self.type.armies = "ACCO" end
    if sub and sub:match("^events") then E.dev(self, sub:match("^events_?(.*)$")) end
    if sub and sub:match("^object") then O.dev(self, sub:match("^object_?(.*)$")) end
    if sub and sub:match("^items") then IT.dev(self, sub:match("^items_?(.*)$")) end
    if sub and (sub:match("^sides") or sub:match("^options")) then SD.dev(self, sub:match("^sides_?(.*)$") or sub) end
end

-- Builds and saves a small scenario through the editor model (screenshots, tests).
function S:demo()
    local scn = lib.newScenario("EditorDemo", 64, "Made with the editor")
    self:setScenario(scn)
    local cat = lib.tileCatalog()
    for _, e in ipairs(cat.entries) do
        if e.kind == "tile" and select(2, lib.tileInfo(e.id)) == 1 then
            ---@cast e EditorTile a tile entry carries its id and index
            lib.paintTile(scn, self.terrain, e, 1, 1)
            break
        end
    end
    local hall = (rules.buildList(0)[1] or {}).id
    for i = 0, 1 do
        local gx, gy = 12 + i * 28, 12 + i * 28
        lib.setStart(scn, i, gx, gy)
        scn.sides[i].race = i == 0 and 0 or 5
        if hall then lib.add(scn, "buildings", hall, gx + 3, gy, i) end
    end
    lib.add(scn, "armies", rules.armyList()[5].code, 14, 14, 6)
    local f = lib.featureList()
    for i = 1, 5 do lib.add(scn, "features", f[i * 7].code, 8 + i * 3, 20, 6) end
    self.mode = "menu"
    self:save()
end

-- Panels --------------------------------------------------------------------------------

---@param name string     a mode or dialog name (PANELS)
---@return Panel
function S:panel(name)
    local p = self.panels[name]
    if p then return p end
    local owner = dialogOwner(name)
    p = UI.panel(PANELS[name], { x = owner and owner.X[name] or MID_X, y = MID_Y,
                                 onButton = function(b, it) self:button(name, b, it) end }) --[[@as Panel]]
    self.panels[name] = p
    local function hideAll(...) for _, n in ipairs({ ... }) do p:hide(n) end end
    if name == "terrain" then
        -- PNL_EDITOR_TERRAINNEW (the original's terrain panel): the tile list is drawn by the editor; "Smooth map" is
        -- greyed and moved off the panel in the final game (not traced in the 1.04 binary yet), so it is not shown
        hideAll("SBAR_VEDIT120", "LB_EDITTERRAIN", "BUTT_SMOOTHMAP", "IM_TERRAIN_TILE_ICON")
        p.align[p:find("STR_SMALL80")] = "center"
    elseif name == "features" or name == "armies" or name == "buildings" then
        hideAll("BUTT_EDIT_FEATUREMODE", "LB_EDITFEATURES", "LB_EDITARMIES", "LB_EDITBUILDINGS", "SBAR_VEDIT120")
    elseif name == "effects" then
        hideAll("BUTT_EDITOR_EFFECTS_MODES", "STR_SMALL_180", "SBAR_VEDIT120", "LB_EDITITEMS")
    elseif name == "events" then
        E.setupPanel(p, name)
    elseif owner then
        owner.setupPanel(p, name)
    elseif name == "sides" or name == "options" then
        SD.setupPanel(p, name)
    elseif name == "items" then
        IT.setupPanel(p, name)
    elseif name == "startlocs" then
        hideAll("SBAR_VEDIT120", "LB_EDITOR_SIDE_POS", "STR_MEDIUM120")
    elseif name == "new" then
        p:hide("EDIT_EDITOR_SCENARIO_NAME")
        p:hide("EDIT_EDITOR_SCENARIO_DESC")
    elseif name == "load" then
        hideAll("SBAR_VEDIT120", "LB_EDITOR_LOAD_SCENARIO")
    end
    return p
end

---@return Panel
function S:currentPanel()
    return self:panel(self.dialog or self.mode)
end

-- Original panel buttons.
---@param panel string
---@param name string
---@param it PanelItem?
function S:button(panel, name, it)
    if panel == "events" then
        E.button(self, panel, name)
    elseif panel == "sides" or panel == "options" then
        SD.button(self, panel, name, it)
    elseif dialogOwner(panel) then
        dialogOwner(panel).button(self, panel, name, it)
    elseif panel == "menu" then
        if name == "BUTT_EDIT_NEW" then
            self.dialog, self.dialogKind, self.focusField = "new", "new", "name"
            self.newName, self.newDesc = "", ""
        elseif name == "BUTT_EDIT_LOAD" then
            self:openLoad()
        elseif name == "BUTT_EDIT_SAVEEXIT" then
            -- "Save" (the button's name is a leftover: it only saves, menu handler 0x004bf3c0)
            if not self.scn then return end
            self:saveChecked()
        elseif name == "BUTT_EDIT_SAVE" then
            self.dialog, self.dialogKind, self.focusField = "new", "saveas", "name"
            self.newName = self.scn and self.scn.header.name or ""
            self.newDesc = self.scn and self.scn.header.description or ""
        elseif name == "BUTT_EDIT_EXIT" then
            -- always asked, saved or not (BUTT_EDIT_EXIT: message box FUN_004bf5a0, texts 185 / 5, 3, 4, yes / no)
            self:messageBox(UI.text(185, 5), UI.text(185, 3), UI.text(185, 4), true, function(yes)
                if yes then screens.pop() end
            end)
        end
    elseif panel == "new" then
        if name == "BUTT_EDITOR_CANCEL" then
            if not self.randomPending then self.dialog = nil end     -- greyed once Ctrl+R made a map
        elseif name == "BUTT_EDITOR_SCENARIO_SIZE" then
            self.newSize = self.newSize % #lib.SIZES + 1
        elseif name == "BUTT_EDITOR_CREATE" then
            self:confirmName()
        end
    elseif panel == "load" then
        if name == "BUTT_EDITOR_CANCEL" then
            self.dialog = nil
        elseif name == "BUTT_EDITOR_LOAD_SCENARIO" then
            self:loadSelected()
        end
    elseif panel == "terrain" then
        if name == "BUTT_FILL_MAP" and self.scn and self.brush then
            lib.fillMap(self.scn, self.terrain, self.brush)
            self:touch()
            self:buildMinimap()
        end
    end
end

-- Menu actions ----------------------------------------------------------------------------

-- Message boxes (PNL_EDITPANEL_MB / _MB_QUESTION, opened by FUN_004bf5a0): the panel sits at (290, 448) over the editor
-- bar, which the interlace picture (PNL_EDITOR_INTERLACE) covers and blocks until OK / Yes / No. `cb(yes)` runs after
-- it closed (the original's pending callback, which the yes / no handler 0x004bf760 calls; for the OK box yes is always
-- true).
local MB_X = 290

---@param title string?
---@param line1 string?
---@param line2 string?
---@param question boolean? Yes / No instead of OK
---@param cb fun(yes: boolean)?
function S:messageBox(title, line1, line2, question, cb)
    local p = UI.panel(question and "PNL_EDITPANEL_MB_QUESTION" or "PNL_EDITPANEL_MB", { x = MB_X, y = BAR_Y,
        onButton = function(name) self:mbButton(name) end })
    ---@cast p -nil
    p:hide("PAD_220x145")
    -- the three STR_SMALL200 are the title and the two lines, top to bottom
    for i, it in ipairs(p:all("STR_SMALL200")) do
        p.itemStrings[it] = ({ title, line1, line2 })[i] or ""
        p.align[it] = "center"
    end
    local il = UI.panel("PNL_EDITOR_INTERLACE", { x = 0, y = BAR_Y })
    ---@cast il -nil
    il:hide("PAD_650x192")
    self.mb = { panel = p, interlace = il, question = question, cb = cb }
end

function S:mbButton(name)
    local mb = self.mb
    if not mb then return end
    local yes = name == "BUTT_EDITOR_OKAY" or name == "BUTT_EDITOR_YES"
    if not yes and name ~= "BUTT_EDITOR_NO" then return end
    self.mb = nil
    if mb.cb then mb.cb(yes) end
end

function S:drawMessageBox()
    local mb = self.mb
    if not mb then return end
    mb.interlace:draw()
    mb.panel:draw()
end

-- Whether a used side has no start location (the Save checks, TXT_EDITOR_STARTLOC_HELP)
function S:startLocationMissing()
    for i = 0, 5 do
        local sd = self.scn.sides[i]
        if sd.used and (sd.startX < 0 or sd.startY < 0) then return true end
    end
    return false
end

-- "Scenario Saved" / "Scenario NOT Saved" (TXT_EDITOR_SAVE_HELP 0 + 1 / 6)
function S:saveReport(ok)
    self:messageBox(UI.text(185, 0), ok and UI.text(185, 1) or UI.text(185, 6), UI.text(185, 2))
end

-- Save (and Save As once the name is set): a used side without a start location raises the error box first, whose OK
-- saves all the same (FUN_004c26a0), then the result box.
---@param name string?
---@param onSaved fun()?
function S:saveChecked(name, onSaved)
    local function go()
        local ok, why = self:save(name, true)
        if why == "name" then return end        -- no name yet: the Save As dialog opened instead
        if ok and onSaved then onSaved() end
        self:saveReport(ok)
    end
    if self:startLocationMissing() then
        self:messageBox(UI.text(184, 0), UI.text(184, 1), UI.text(184, 2), false, go)
    else
        go()
    end
end

-- Starts the new scenario of the dialog (after the "already exists" question, if any).
---@param name string
function S:createNew(name)
    if self.randomPending then
        -- Ctrl+R already made the map (and the editor shows it): the name and description are all that is left
        self.scn.header.name, self.scn.header.description = name, self.newDesc
        self.randomPending, self.dialog = nil, nil
        self.dirty = true
        return
    end
    self:setScenario(lib.newScenario(name, lib.SIZES[self.newSize], self.newDesc))
    self.dirty = true
end

-- Ctrl+R in the new-scenario dialog: a random map instead of the empty one; the dialog stays open (its Cancel greyed)
-- until Create.
function S:randomMap()
    if self.dialogKind ~= "new" or self.randomPending then return end
    local size = lib.SIZES[self.newSize]
    local seed = love.math.random(0, 65535)
    local ok, scn = pcall(lib.randomScenario, lib.safeName(self.newName), size, self.newDesc, seed)
    if not ok then log.error("editor: random map: %s", tostring(scn)) self:notify("The random map failed") return end
    local dialog, kind = self.dialog, self.dialogKind
    self:setScenario(scn)
    self.mode = "menu"
    self.dialog, self.dialogKind, self.focusField, self.randomPending = dialog, kind, "name", true
    self.dirty = true
end

function S:confirmName()
    local name = lib.safeName(self.newName)
    if name == "" then self:notify("Give the scenario a name") return end
    local function exists(cb)
        -- "This scenario already exists / Overwrite?" (TXT_EDITOR_SCEN_EXISTS): No leaves the dialog open
        if lib.userScenarioExists(name) then
            self:messageBox(UI.text(223, 0), UI.text(223, 1), UI.text(223, 2), true, function(yes) if yes then cb() end end)
        else
            cb()
        end
    end
    if self.dialogKind == "new" then
        exists(function() self:createNew(name) end)
    else
        exists(function()
            self.scn.header.name = name
            self.scn.header.description = self.newDesc
            self.dialog = nil
            self:saveChecked(name)
        end)
    end
end

---@param name string?
---@param quiet boolean?
---@return boolean ok, string? why "name" when the Save As dialog opened instead
function S:save(name, quiet)
    if not self.scn then self:notify("Nothing to save") return false end
    if (name or self.scn.header.name) == "" then
        self.dialog, self.dialogKind, self.focusField, self.newName = "new", "saveas", "name", ""
        return false, "name"
    end
    local file, err = lib.save(self.scn, self.terrain, name)
    if not file then self:notify("Save failed: " .. tostring(err)) return false end
    self.file, self.dirty = file, false
    if not quiet then self:notify("Saved " .. file) end
    return true
end

function S:openLoad()
    local entries, seen = {}, {}
    for _, f in ipairs(lib.userScenarios()) do
        local label = f:gsub("%.[sS][cC][nN]$", "")
        entries[#entries + 1] = { label = label .. " *", key = #entries + 1, user = true, file = f }
        seen[label:lower()] = true
    end
    for _, dir in ipairs({ "Scenario", "CampaignScenario" }) do
        for _, f in ipairs(fs.list(config.gamedir .. "/" .. dir, "%.scn$")) do
            entries[#entries + 1] = { label = f:gsub("%.[sS][cC][nN]$", ""), key = #entries + 1, dir = dir, file = f }
        end
    end
    self.loadEntries = entries
    self.st.load = { scroll = 0, sel = #entries > 0 and 1 or nil }
    self.preview = nil
    self.dialog = "load"
end

---@param e table   an entry of loadEntries
---@return table?
function S:entryScenario(e)
    if e.scn == nil then
        local data
        if e.user then data = lib.readUser(e.file) else data = fs.read(config.gamedir .. "/" .. e.dir .. "/" .. e.file) end
        e.scn = data and scnMod.parse(data) or false
    end
    return e.scn or nil
end

-- Delete / Backspace in the load list asks "Delete this scenario?" (Game.txt 0385); Yes removes the file.
-- Only scenarios of the user folder can go (the original's list holds the editor's own files).
function S:deleteSelected()
    local e = self.loadEntries and self.loadEntries[self.st.load.sel or 0]
    if not e then return end
    if not e.user then self:notify("The game's own scenarios cannot be deleted") return end
    self:messageBox(strings.get("Game.txt", "0385") or "", " ", " ", true, function(yes)
        if not yes then return end
        lib.deleteUser(e.file)
        self:openLoad()
        self.dialog = "load"
    end)
end

function S:loadSelected()
    local e = self.loadEntries and self.loadEntries[self.st.load.sel or 0]
    if not e then return end
    local scn = self:entryScenario(e)
    if not scn then self:notify("Cannot read " .. e.file) return end
    -- the parsed copy is edited, so a later load starts from a fresh parse
    e.scn = nil
    self:setScenario(scn, e.user and e.file or nil)
    if not e.user then self.file = nil end
    self.mode = "terrain"
end

-- Whether the map takes clicks and scrolls while the open dialog (if any) is up.
---@return boolean
function S:mapDialog()
    local owner = dialogOwner(self.dialog)
    return owner ~= nil and owner.mapDialog(self.dialog)
end

-- Update ------------------------------------------------------------------------------------

-- Developer aid: a click at virtual position (vx, vy), as if made with the mouse.
---@param vx number
---@param vy number
---@param button integer?
function S:devClick(vx, vy, button)
    self:layout()
    local s, ox, oy = self.s, self.ox, self.oy
    self.mx, self.my = vx, vy
    self:mousemoved(ox + vx * s, oy + vy * s)
    self:mousepressed(ox + vx * s, oy + vy * s, button or 1)
    self:mousereleased(ox + vx * s, oy + vy * s, button or 1)
end

function S:update(dt)
    self.clock = self.clock + dt
    for _, sc in ipairs(require("src.game.boot").scripts or {}) do
        if not sc.done and self.clock >= sc.t then
            sc.done = true
            local f, err = loadstring(sc.code)
            if f then
                setfenv(f, setmetatable({ S = self, UI = UI }, { __index = _G }))
                local ok, e = pcall(f)
                if not ok then log.error("--at: %s", tostring(e)) end
            else
                log.error("--at: %s", tostring(err))
            end
        end
    end
    if not self.scn or (self.dialog and not self:mapDialog()) then return end
    local sp = 600 * dt
    self:layout()
    local mx, my = love.mouse.getPosition()
    local down = love.keyboard.isDown
    if down("left") or (mx < 3 and my < self.mapBottom) then self.camX = self.camX - sp end
    if down("right") or (mx >= self.W - 3 and my < self.mapBottom) then self.camX = self.camX + sp end
    if down("up") or my < 3 then self.camY = self.camY - sp end
    if down("down") or my >= self.H - 3 or (my >= self.mapBottom - 3 and my < self.mapBottom) then
        self.camY = self.camY + sp
    end
    self:clampCamera()
    self.terrain:update(self.clock * 1000)
    if self.mmDirty and not self.painting and not self.dragObj then self:buildMinimap() end
end

-- Drawing -----------------------------------------------------------------------------------

---@param side integer
---@return integer
function S:sideColour(side)
    local s = self.scn.sides[side]
    return side == 6 and 6 or (s and s.color or side)
end

-- The editor's own map sprites (Effects1.xcr, registered by FUN_004c28b0: EOS? the start location per shield colour R B
-- G P K Y, EEE0..9 the event squares of radius 1..10, EEBX the effect position X). The original puts them at the cell's
-- centre like any item (not traced in the 1.04 binary yet); false when the install lacks the picture (the callers then
-- draw an outline).
local START_SPRITE = { [0] = "EOSR", "EOSB", "EOSG", "EOSP", "EOSK", "EOSY" }
---@param code string
---@param gx number
---@param gy number
---@return boolean drawn
function S:editorSprite(code, gx, gy)
    local set = anims.get(code)
    if not set or not set:has(0) then return false end
    love.graphics.setColor(1, 1, 1)
    return set:draw(0, 0, 0, gx * CW + CW / 2, gy * CH + CH / 2)
end
S.START_SPRITE = START_SPRITE

---@param layer string
---@param o table     a placed object of the scenario
---@param alpha number?
function S:drawObject(layer, o, alpha)
    local g = love.graphics
    if layer == "effects" then
        g.setColor(1, 0.9, 0.3, 0.9)
        g.polygon("line", o.x, o.y - 8, o.x + 7, o.y, o.x, o.y + 8, o.x - 7, o.y)
        fonts.print(2, o.code, o.x - 30, o.y + 8, "center", 60)
        g.setColor(1, 1, 1)
        return
    end
    local set = anims.get(o.code)
    local anim, dir, team = 0, o.dir or 0, nil
    if layer == "armies" then dir, team = 4, self:sideColour(o.side)
    elseif layer == "buildings" then team = self:sideColour(o.side) end
    if set then
        if layer ~= "armies" then anim = clamp(o.anim or 0, 0, 8) end
        if not set:has(anim) then anim = A.STAND end
        if set:has(anim) then
            local n = set:frames(anim)
            local frame = (n > 1 and layer ~= "items") and (math.floor(self.clock * 1000 / 120) % n) or (o.frame or 0)
            g.setColor(1, 1, 1, alpha or 1)
            set:draw(anim, dir, frame, o.x, o.y, team)
            g.setColor(1, 1, 1)
            return
        end
    end
    g.setColor(1, 0.3, 0.3, 0.8)
    g.rectangle("line", o.x - 10, o.y - 20, 20, 20)
    g.setColor(1, 1, 1)
end

function S:drawMap()
    local g = love.graphics
    g.setScissor(0, 0, self.W, self.mapBottom)
    g.push()
    g.scale(self.ms)
    g.translate(-math.floor(self.camX), -math.floor(self.camY))
    self.terrain:draw(self.camX, self.camY, self.vw, self.vh)
    local x0, y0, x1, y1 = self.camX - 200, self.camY - 100, self.camX + self.vw + 200, self.camY + self.vh + 300
    local list = {}
    for _, layer in ipairs({ "features", "buildings", "armies", "effects", "items" }) do
        for i, o in ipairs(self.scn[layer]) do
            if o.x >= x0 and o.x <= x1 and o.y >= y0 and o.y <= y1 then
                list[#list + 1] = { layer = layer, o = o, y = o.y, i = i }
            end
        end
    end
    table.sort(list, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.i < b.i end)
    for _, e in ipairs(list) do self:drawObject(e.layer, e.o) end
    -- selection
    if self.selected then
        local o = self.selected.o
        g.setColor(0.2, 1, 0.2, 0.9)
        g.ellipse("line", o.x, o.y, 20, 10)
        g.setColor(1, 1, 1)
    end
    -- start locations
    for i = 0, 5 do
        local sd = self.scn.sides[i]
        if sd.used and sd.startX >= 0 then
            local colour = self:sideColour(i)
            if not (START_SPRITE[colour] and self:editorSprite(START_SPRITE[colour], sd.startX, sd.startY)) then
                local c = gamedata.COLORS[colour] or { 1, 1, 1 }
                local cx, cy = sd.startX * CW + CW / 2, sd.startY * CH + CH / 2
                g.setColor(c[1], c[2], c[3], 0.9)
                g.circle("fill", cx, cy, 11)
                g.setColor(1, 1, 1)
                g.circle("line", cx, cy, 11)
                fonts.print(2, tostring(i + 1), cx - 10, cy - 8, "center", 20)
            end
        end
    end
    for _, m in ipairs(EXT) do if m.drawMap then m.drawMap(self, g) end end
    -- brush preview
    local px, py = love.mouse.getPosition()
    if py < self.mapBottom and not self.dialog then
        local wx, wy = px / self.ms + self.camX, py / self.ms + self.camY
        if self.mode == "terrain" and self.brush then
            local _, _, fw, fh = lib.tileInfo(self.brush.id)
            local tx = clamp(math.floor(wx / TW), 0, self.scn.tilesW - fw)
            local ty = clamp(math.floor(wy / TH), 0, self.scn.tilesH - fh)
            g.setColor(1, 1, 1, 0.9)
            g.rectangle("line", tx * TW + 0.5, ty * TH + 0.5, fw * TW - 1, fh * TH - 1)
            g.setColor(1, 1, 1)
        elseif LAYER[self.mode] and self.tool == "place" and self:currentType() then
            local gx, gy, cx, cy = lib.snap(wx, wy)
            self:drawObject(self.mode, { code = self:currentType(), x = cx, y = cy, side = self.side, anim = 0,
                                         dir = 0, frame = 0 }, 0.6)
            g.setColor(1, 1, 1, 0.5)
            g.rectangle("line", gx * CW + 0.5, gy * CH + 0.5, CW - 1, CH - 1)
            g.setColor(1, 1, 1)
        end
    end
    g.pop()
    g.setScissor()
end

function S:drawMinimap()
    local g = love.graphics
    if not self.minimap then return end
    g.setColor(1, 1, 1)
    g.draw(self.minimap, MM_X, MM_Y)
    local t = self.terrain --[[@as Terrain]]       -- the minimap exists with a scenario only
    g.setColor(0.2, 1, 0.2)
    g.rectangle("line", MM_X + self.camX / t.pixelW * 128 + 0.5, MM_Y + self.camY / t.pixelH * 128 + 0.5,
        self.vw / t.pixelW * 128, self.vh / t.pixelH * 128)
    for i = 0, 5 do
        local sd = self.scn.sides[i]
        if sd.used and sd.startX >= 0 then
            local c = gamedata.COLORS[self:sideColour(i)] or { 1, 1, 1 }
            g.setColor(c[1], c[2], c[3])
            g.circle("fill", MM_X + (sd.startX + 0.5) / t.w * 128, MM_Y + (sd.startY + 0.5) / t.h * 128, 3)
            g.setColor(1, 1, 1)
            g.circle("line", MM_X + (sd.startX + 0.5) / t.w * 128, MM_Y + (sd.startY + 0.5) / t.h * 128, 3)
        end
    end
    g.setColor(1, 1, 1)
    reg(self, "minimap", MM_X, MM_Y, 128, 128)
end

-- The type list of an object mode.
---@param mode string
---@return table[]
function S:items(mode)
    self.cache = self.cache or {}
    local items = self.cache[mode]
    if items then return items end
    items = {}
    if mode == "armies" then
        for _, a in ipairs(rules.armyList()) do
            items[#items + 1] = { label = a.name .. (a.hero and " (hero)" or ""), key = a.code }
        end
    elseif mode == "buildings" then
        for _, b in ipairs(rules.buildingList()) do items[#items + 1] = { label = b.name, key = b.code } end
    elseif mode == "features" then
        local group
        for _, f in ipairs(lib.featureList()) do
            if f.group ~= group then
                group = f.group
                items[#items + 1] = { label = group, header = true, indent = 0 }
            end
            items[#items + 1] = { label = f.name, key = f.code, indent = 1 }
        end
    end
    self.cache[mode] = items
    return items
end

---@return string?
function S:currentType()
    return self.type[self.mode]
end

-- Tile tree of the terrain mode: groups and sub groups fold.
---@return table[]
function S:tileItems()
    local items = {}
    if not self.treeInit then
        -- start with every pack folded except the one holding the brush
        self.treeInit = true
        local group
        for i, e in ipairs(lib.tileCatalog().entries) do
            if e.kind == "group" then group = i self.collapsed[i] = true end
            if e.id and self.brush and e.id == self.brush.id then self.collapsed[group] = false end
        end
    end
    local group, sub
    for i, e in ipairs(lib.tileCatalog().entries) do
        if e.kind == "group" then
            group, sub = i, nil
            items[#items + 1] = { label = (self.collapsed[i] and "+ " or "- ") .. e.name, key = i, indent = 0, fold = i }
        elseif e.kind == "sub" then
            sub = i
            if not self.collapsed[group] then
                items[#items + 1] = { label = (self.collapsed[i] and "+ " or "- ") .. e.name, key = i, indent = 1, fold = i }
            end
        elseif not self.collapsed[group] and not (sub and self.collapsed[sub]) then
            items[#items + 1] = { label = e.name, key = i, indent = 2, tile = e }
        end
    end
    return items
end

-- The small picture of the brush tile: "<id>i.bmp" of the tile's archive (BM_SMALL_TERRAIN_TILE, 48 x 32), "xxxx.bmp"
-- in the original when nothing is chosen.
function S:drawTilePreview(p)
    local g = love.graphics
    local it = p:find("IM_TERRAIN_TILE_ICON")
    self.tileIcons = self.tileIcons or {}
    local id = self.brush and self.brush.id
    local img = self.tileIcons[id or ""]
    if img == nil and id then
        local data = require("src.vfs.vfs").find(id .. "i.bmp")
        local ok, res = pcall(require("src.formats.bmp").image, data or "", { key = true })
        img = ok and res or false
        self.tileIcons[id] = img
    end
    if img and it then
        g.setColor(1, 1, 1)
        g.draw(img, p.x + it.e.x, p.y + it.e.y, 0, 48 / img:getWidth(), 32 / img:getHeight())
    end
end

function S:drawModePanel()
    local g = love.graphics
    local mode = self.mode
    local p = self:currentPanel()
    if dialogOwner(self.dialog) then
        return dialogOwner(self.dialog).draw(self, p)
    elseif mode == "events" and not self.dialog then
        return E.drawMode(self, p)
    elseif self.dialog == "new" then
        local saveas = self.dialogKind == "saveas"
        p:hide("BUTT_EDITOR_SCENARIO_SIZE")
        p:setString("BUTT_EDITOR_CREATE", saveas and "Save" or nil)
        -- the original greys Create until a name is typed, and Cancel once Ctrl+R made a random map
        p:setDisabled("BUTT_EDITOR_CREATE", lib.safeName(self.newName) == "")
        p:setDisabled("BUTT_EDITOR_CANCEL", self.randomPending and true or false)
        p:draw()
        textBox(self, "name", self.newName, MID_X + 62, MID_Y + 15, 250, 18, self.focusField == "name")
        if not saveas then
            local size = lib.SIZES[self.newSize]
            reg(self, "size", MID_X + 57, MID_Y + 45, 100, 19)
            fonts.print(12, ("%d x %d"):format(size, size), MID_X + 57, MID_Y + 38, "left", 120)
        end
        textBox(self, "desc", self.newDesc, MID_X + 108, MID_Y + 67, 200, 23, self.focusField == "desc")
        return
    elseif self.dialog == "load" then
        p:draw()
        local entries = self.loadEntries --[[@as table[] ]]       -- the Load dialog is open only after openLoad
        listBox(self, "load", entries, self.st.load, MID_X + 12, MID_Y + 12, 150, 120)
        local e = entries[self.st.load.sel or 0]
        local scn = e and self:entryScenario(e)
        if scn and scn.minimap and #scn.minimap >= 128 * 128 * 3 then
            if self.preview and self.preview.e ~= e then self.preview.image:release() self.preview = nil end
            if not self.preview then
                local img = love.image.newImageData(128, 128)
                for y = 0, 127 do
                    for x = 0, 127 do
                        local o = (y * 128 + x) * 3 + 1
                        local b, gg, r = scn.minimap:byte(o, o + 2)
                        img:setPixel(x, y, r / 255, gg / 255, b / 255, 1)
                    end
                end
                self.preview = { e = e, image = love.graphics.newImage(img) }
            end
            g.setColor(1, 1, 1)
            g.draw(self.preview.image, MM_X, MM_Y)
            if scn.header then
                fonts.print(2, ("%d x %d, %d players"):format(scn.width, scn.height, scn.header.numPlayers),
                    MID_X + 192, MID_Y + 20, "left", 170)
            end
        end
        return
    end
    if mode == "sides" or mode == "options" then return SD.drawMode(self, p) end
    if mode == "items" then return IT.drawMode(self, p) end
    p:draw()
    if mode == "menu" then
        p:setDisabled("BUTT_EDIT_SAVE", not self.scn)
        p:setDisabled("BUTT_EDIT_SAVEEXIT", not self.scn)
        if self.scn then
            fonts.print(5, self.scn.header.name .. (self.dirty and " *" or ""), MID_X, MID_Y + 2, "center", 371)
        end
    elseif mode == "terrain" then
        local items = self:tileItems()
        local st = self.st.terrain
        st.sel = nil
        for _, it in ipairs(items) do if it.tile and self.brush and it.tile.id == self.brush.id then st.sel = it.key end end
        listBox(self, "tiles", items, st, MID_X + 20, MID_Y + 12, 200, 120)
        local _, tsize = lib.tileInfo(self.brush.id)
        p:setString("STR_SMALL80", UI.text(226, tsize) or "")
        self:drawTilePreview(p)
    elseif LAYER[mode] then
        local st = self.st[mode]
        st.sel = self:currentType()
        if mode == "effects" then
            local items = {}
            for i, e in ipairs(self.scn.effects) do
                items[#items + 1] = { label = ("%s  %d,%d"):format(e.code, math.floor(e.x / CW), math.floor(e.y / CH)),
                                      key = i }
            end
            st.sel = self.selected and self.selected.layer == "effects" and self.selected.i or nil
            listBox(self, "effects", items, st, MID_X + 22, MID_Y + 12, 160, 120)
            bmpButton(self, "delete", "Delete", MID_X + 215, MID_Y + 15, 100, false, nil, not st.sel)
            hint(MID_X + 215, MID_Y + 45, "Select an effect in", "the list or the map;", "they can only be", "deleted here.")
        else
            local x = mode == "features" and 20 or 20
            listBox(self, mode, self:items(mode), st, MID_X + x, MID_Y + 12, 200, 120)
            local bx = mode == "features" and 268 or 245
            local by = mode == "features" and 16 or 12
            for i, t in ipairs(TOOLS) do
                bmpButton(self, "tool", t[2], MID_X + bx, MID_Y + by + (i - 1) * 30, mode == "features" and 90 or 110,
                    self.tool == t[1], t[1])
            end
            if mode ~= "features" then
                bmpButton(self, "side", "Side: " .. SIDE_NAMES[self.side], MID_X + 245, MID_Y + 102, 110, false)
            end
        end
    elseif mode == "startlocs" then
        local items = {}
        for i = 0, 5 do
            local sd = self.scn.sides[i]
            local at = sd.startX >= 0 and ("%d, %d"):format(sd.startX, sd.startY) or "not set"
            items[#items + 1] = { label = ("Side %d (%s)%s: %s"):format(i + 1, SIDE_NAMES[self:sideColour(i)],
                sd.used and "" or " off", at), key = i }
        end
        self.st.startlocs.sel = self.st.startlocs.sel or 0
        listBox(self, "starts", items, self.st.startlocs, MID_X + 14, MID_Y + 12, 220, 120)
        hint(MID_X + 255, MID_Y + 30, "Pick a side, then", "click the map to", "place its start.")
    end
end

function S:drawModeButtons()
    for _, m in ipairs(MODES) do
        local disabled = not self.scn and m[1] ~= "menu"
        bmpButton(self, "mode", m[2], m[3], BAR_Y + m[4], 110, self.mode == m[1] and not self.dialog, m[1],
            disabled or self.dialog ~= nil)
    end
end

function S:draw()
    local g = love.graphics
    self:layout()
    g.clear(0, 0, 0)
    self.hits, self.lists = {}, {}
    local mx, my = love.mouse.getPosition()
    self.mx, self.my = self:toV(mx, my)
    if self.scn then self:drawMap() end
    g.push()
    g.translate(self.ox, self.oy)
    g.scale(self.s)
    self.bar:draw()
    if self.scn then self:drawMinimap() end
    self:drawModeButtons()
    self:drawModePanel()
    self:drawMessageBox()
    if self.notice and love.timer.getTime() - self.notice.t < 3 then
        fonts.print(5, self.notice.text, 0, BAR_Y - 24, "center", 800)
    end
    g.pop()
    cursor.standard(require("src.ui.kit").over(self))   -- the original's pointer hand over its active objects
    cursor.draw(self.s)
end

-- Input -----------------------------------------------------------------------------------

-- World position of a window position.
---@return number wx, number wy
function S:mouseCell(x, y)
    return x / self.ms + self.camX, y / self.ms + self.camY
end

function S:paintAt(wx, wy)
    local tx, ty = math.floor(wx / TW), math.floor(wy / TH)
    if tx < 0 or ty < 0 or tx >= self.scn.tilesW or ty >= self.scn.tilesH then return end
    local key = tx .. "," .. ty
    if self.lastPaint == key then return end
    self.lastPaint = key
    lib.paintTile(self.scn, self.terrain, self.brush, tx, ty)
    self.dirty = true
    self.mmDirty = true
end

---@param layer string
---@param i integer
function S:removeObject(layer, i)
    table.remove(self.scn[layer], i)
    self.selected = nil
    self:touch()
end

function S:mapPress(vx, vy, button)
    local wx, wy = self:mouseCell(vx, vy)
    local mode = self.mode
    if mode == "events" then return E.mapPress(self, vx, vy, button) end
    if mode == "items" then return IT.mapPress(self, vx, vy, button) end
    if button == 2 and LAYER[mode] then
        local i = lib.pick(self.scn, LAYER[mode], wx, wy)
        if i then self:removeObject(LAYER[mode], i) end
        return
    end
    if button ~= 1 then return end
    if mode == "terrain" then
        self.painting, self.lastPaint = true, nil
        self:paintAt(wx, wy)
    elseif mode == "startlocs" then
        local gx, gy = lib.snap(wx, wy)
        gx, gy = clamp(gx, 1, self.scn.width - 2), clamp(gy, 1, self.scn.height - 2)
        local side = self.st.startlocs.sel or 0
        lib.setStart(self.scn, side, gx, gy)
        self.scn.sides[side].used = true
        self:touch()
    elseif LAYER[mode] then
        local layer = LAYER[mode]
        if self.tool == "place" and mode ~= "effects" then
            local code = self:currentType()
            if not code then self:notify("Pick a type from the list first") return end
            local gx, gy = lib.snap(wx, wy)
            if gx < 0 or gy < 0 or gx >= self.scn.width or gy >= self.scn.height then return end
            lib.add(self.scn, layer, code, gx, gy, self.side)
            self:touch()
        else
            local i = lib.pick(self.scn, layer, wx, wy)
            if self.tool == "delete" and i then
                self:removeObject(layer, i)
            elseif i then
                self.selected = { layer = layer, o = self.scn[layer][i], i = i }
                self.dragObj = { dx = self.scn[layer][i].x - wx, dy = self.scn[layer][i].y - wy, moved = false }
            else
                self.selected = nil
            end
        end
    end
end

function S:mousepressed(x, y, button)
    local vx, vy = self:toV(x, y)
    if self.mb then self.mb.panel:mousepressed(vx, vy, button) return end
    local p = self:currentPanel()
    if p and button == 1 and p:mousepressed(vx, vy, button) then return end
    local id, extra = nil, nil
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if h.id and vx >= h.x and vx < h.x + h.w and vy >= h.y and vy < h.y + h.h then
            id, extra = h.id, h.extra
            break
        end
    end
    if id then self:click(id, extra, button) return end
    if self.scn and (not self.dialog or self:mapDialog()) and y < self.mapBottom then
        self:mapPress(x, y, button)
    end
end

-- Clicks on the custom widgets.
---@param id string
---@param extra any
---@param button integer
function S:click(id, extra, button)
    local dir = button == 2 and -1 or 1
    local scn = self.scn
    if id:sub(1, 3) == "ev_" and E.click(self, id, extra, button) then return end
    if id:sub(1, 3) == O.ID and O.click(self, id, extra, button) then return end
    if id:sub(1, 3) == SD.ID and SD.click(self, id, extra, button) then return end
    if id:sub(1, 3) == IT.ID and IT.click(self, id, extra, button) then return end
    if id == "mode" then
        self.mode = extra
    elseif id == "minimap" then
        local vx, vy = self:toV(love.mouse.getPosition())
        self.camX = (vx - MM_X) / 128 * self.terrain.pixelW - self.vw / 2
        self.camY = (vy - MM_Y) / 128 * self.terrain.pixelH - self.vh / 2
        self:clampCamera()
        self.draggingMinimap = true
    elseif id == "size" then
        self.newSize = (self.newSize - 1 + dir) % #lib.SIZES + 1
    elseif id == "name" or id == "desc" then
        self.focusField = id
    elseif id == "tiles" then
        local it = self:tileItems()[extra]
        if it and it.fold then self.collapsed[it.fold] = not self.collapsed[it.fold]
        elseif it and it.tile then self.brush = it.tile end
    elseif id == "load" then
        self.st.load.sel = extra
        self.preview = nil
        if button == 1 and self.lastLoadClick and self.lastLoadClick.i == extra
            and love.timer.getTime() - self.lastLoadClick.t < 0.4 then
            self:loadSelected()
        end
        self.lastLoadClick = { i = extra, t = love.timer.getTime() }
    elseif id == "features" or id == "armies" or id == "buildings" then
        local it = self:items(id)[extra]
        if it and it.key then self.type[id] = it.key end
    elseif id == "effects" then
        ---@cast scn -nil               the effects list is drawn with a scenario only
        local e = scn.effects[extra]
        if e then self.selected = { layer = "effects", o = e, i = extra } end
    elseif id == "starts" then
        self.st.startlocs.sel = extra - 1
    elseif id == "tool" then
        self.tool = extra
    elseif id == "side" then
        self.side = (self.side + dir) % 7
    elseif id == "delete" then
        if self.selected and self.selected.layer == "effects" then self:removeObject("effects", self.selected.i) end
    else
        -- list scroll bars and backgrounds: "<list>:up", ":down", ":track"
        local name, part = id:match("^([%w_]+):(%w+)$")
        local l = name and self.lists[name]
        if l then
            local page = math.max(1, l.rows - 1)
            if part == "up" then l.st.scroll = l.st.scroll - 1
            elseif part == "down" then l.st.scroll = l.st.scroll + 1
            elseif part == "track" then
                local _, vy = self:toV(love.mouse.getPosition())
                l.st.scroll = l.st.scroll + (vy < l.y + l.h / 2 and -page or page)
            end
        end
    end
end

function S:mousereleased(x, y, button)
    local vx, vy = self:toV(x, y)
    if self.mb then self.mb.panel:mousereleased(vx, vy, button) return end
    local p = self:currentPanel()
    if p then p:mousereleased(vx, vy, button) end
    if button == 1 then
        self.dragFn = nil
        -- a click on an army or building with the Select tool (no drag) opens its dialog (editorobject.lua)
        local d, sel = self.dragObj, self.selected
        if d and not d.moved and sel and (sel.layer == "armies" or sel.layer == "buildings") and not self.dialog then
            O.open(self, sel.layer, sel.o)
        end
        IT.mouseReleased(self)
        self.painting, self.dragObj, self.draggingMinimap, self.lastPaint = false, nil, false, nil
    end
end

function S:mousemoved(x, y)
    local vx, vy = self:toV(x, y)
    if self.mb then self.mb.panel:mousemoved(vx, vy) return end
    local p = self:currentPanel()
    if p then p:mousemoved(vx, vy) end
    if not self.scn then return end
    if self.dragFn then self.dragFn(vx) end
    if self.it and self.it.drag then IT.mouseMoved(self, self:mouseCell(x, y)) end
    if self.painting then
        self:paintAt(self:mouseCell(x, y))
    elseif self.dragObj and self.selected then
        local wx, wy = self:mouseCell(x, y)
        local gx, gy, cx, cy = lib.snap(wx + self.dragObj.dx, wy + self.dragObj.dy)
        local o = self.selected.o
        if o.x ~= cx or o.y ~= cy then
            o.x, o.y = cx, cy
            self.dragObj.moved = true
            self:touch()
        end
    elseif self.draggingMinimap then
        self.camX = (vx - MM_X) / 128 * self.terrain.pixelW - self.vw / 2
        self.camY = (vy - MM_Y) / 128 * self.terrain.pixelH - self.vh / 2
        self:clampCamera()
    end
end

function S:wheelmoved(_, dy)
    if self.mb then return end
    for _, l in pairs(self.lists) do
        if self.mx >= l.x and self.mx < l.x + l.w + 18 and self.my >= l.y and self.my < l.y + l.h then
            l.st.scroll = l.st.scroll - dy * 3
            return
        end
    end
    if self.scn and not self.dialog then self:zoomBy(dy > 0 and 1.25 or 0.8) end
end

-- Zooms the map view (0.5x .. 2x), keeping the world point under the mouse in place.
---@param f number
function S:zoomBy(f)
    self:layout()
    local px, py = love.mouse.getPosition()
    if py >= self.mapBottom then px, py = self.W / 2, self.mapBottom / 2 end
    local wx, wy = self:mouseCell(px, py)
    self.zoom = clamp(self.zoom * f, 0.5, 2)
    self:layout()
    self.camX, self.camY = wx - px / self.ms, wy - py / self.ms
    self:clampCamera()
end

function S:textinput(t)
    if self.mb then return end
    if E.textinput(self, t) or O.textinput(self, t) then return end
    local f = self.focusField
    if not self.scn and not self.dialog then return end
    if not t:match("^[%w%s%p]+$") or #t > 1 then return end
    if f == "name" and self.dialog then self.newName = #self.newName < 31 and self.newName .. t or self.newName
    elseif f == "desc" and self.dialog then self.newDesc = #self.newDesc < 199 and self.newDesc .. t or self.newDesc
    end
end

function S:keypressed(key)
    if self.mb then
        -- own convenience: Return answers OK / Yes, Escape OK / No
        if key == "return" or key == "kpenter" then self:mbButton(self.mb.question and "BUTT_EDITOR_YES" or "BUTT_EDITOR_OKAY")
        elseif key == "escape" then self:mbButton(self.mb.question and "BUTT_EDITOR_NO" or "BUTT_EDITOR_OKAY") end
        return
    end
    if E.keypressed(self, key) or O.keypressed(self, key) or SD.keypressed(self, key) or IT.keypressed(self, key) then
        return
    end
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if key == "backspace" then
        local f = self.focusField
        if self.dialog and f == "name" then self.newName = require("src.ui.kit").backspace(self.newName)
        elseif self.dialog and f == "desc" then self.newDesc = require("src.ui.kit").backspace(self.newDesc)
        end
    elseif key == "return" or key == "kpenter" then
        if self.dialog == "new" then self:confirmName() elseif self.dialog == "load" then self:loadSelected() end
    elseif key == "tab" and self.dialog == "new" then
        self.focusField = self.focusField == "name" and "desc" or "name"
    elseif key == "escape" then
        if self.randomPending then return
        elseif self.dialog then self.dialog = nil
        elseif self.mode ~= "menu" then self.mode = "menu"
        else self:button("menu", "BUTT_EDIT_EXIT") end
    elseif (key == "+" or key == "kp+" or key == "=") and self.scn and not self.dialog then self:zoomBy(1.25)
    elseif (key == "-" or key == "kp-") and self.scn and not self.dialog then self:zoomBy(0.8)
    elseif key == "s" and ctrl then
        if self.scn then self:saveChecked() end
    elseif key == "r" and ctrl and self.dialog == "new" then
        self:randomMap()
    elseif (key == "delete" or key == "backspace") and self.dialog == "load" then
        self:deleteSelected()
    elseif key == "delete" and self.selected and not self.dialog then
        self:removeObject(self.selected.layer, self.selected.i)
    end
end

-- The widgets of this screen, for the dialogs of editorevents.lua.
S.widgets = { reg = reg, bmpButton = bmpButton, textBox = textBox, listBox = listBox, hint = hint }

return S
