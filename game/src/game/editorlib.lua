-- Scenario editor model: tile / feature catalogues, painting, object placement, minimap and
-- saving. Pure data operations on a parsed scenario (src/formats/scn.lua), so they work without
-- a window; src/screens/editor.lua is the interface on top.
--
-- Tile catalogue: Assets/Terrain/<pack>.<language> (.en / .ge) are XML lists of <Group>,
-- <SubGroup> and <Tile id= name= big=> elements in order; each tile id has <id>.ter / <id>.bmp.
-- A tile is 10x10 cells (320x240 px); tile types of size 1..3 cover 2x2, 2x1 and 1x2 map slots,
-- each slot recording which quadrant ("part", x + 2*y) of the picture it shows.
-- User scenarios are saved as scenarios/<name>.SCN in LÖVE's save directory (the game's own
-- files are never touched) and appear in the skirmish and editor lists.
local vfs = require("src.vfs.vfs")
local xml = require("src.core.xml")
local fs = require("src.core.fs")
local config = require("src.core.config")
local log = require("src.core.log")
local text = require("src.core.text")
local scnMod = require("src.formats.scn")
local scnwrite = require("src.formats.scnwrite")
local evt = require("src.formats.evt")
local terrainMod = require("src.game.terrain")

local M = {}
M.SIZES = { 64, 96, 128, 160, 192, 256 }
M.USER_DIR = "scenarios"
M.LAYERS = { features = "features", armies = "armies", buildings = "buildings", effects = "effects" }

local CW, CH = terrainMod.CELL_W, terrainMod.CELL_H
local FOOT = { [0] = { 1, 1 }, { 2, 2 }, { 2, 1 }, { 1, 2 } }

-- Tiles ------------------------------------------------------------------------------

-- An entry of the tile catalogue: a group, a sub group or a tile.
---@class EditorTileEntry
---@field kind "group"|"sub"|"tile"
---@field name string
---@field id string?                a tile's code
---@field index integer?            a tile's number in the catalogue
---@field default string?           a group's default tile

-- A tile of the catalogue.
---@class EditorTile: EditorTileEntry, ScnNewTile
---@field id string
---@field index integer

---@type {entries: EditorTileEntry[], byId: table<string, EditorTile>}?
local catalog

-- { entries = { { kind = "group"|"sub"|"tile", name, id, default }... }, byId = { ID = entry } }
---@return {entries: EditorTileEntry[], byId: table<string, EditorTile>}
function M.tileCatalog()
    if catalog then return catalog end
    catalog = { entries = {}, byId = {} }
    local dir = config.gamedir .. "/Assets/Terrain"
    local ext = config.abbrev or "en"
    local files = fs.list(dir, "%." .. ext .. "$")
    if #files == 0 then files = fs.list(dir, "%.en$") end
    local index = 0
    for _, file in ipairs(files) do
        local data = fs.read(dir .. "/" .. file)
        local root = data and xml.parse(data)
        for _, el in ipairs(root and root.children or {}) do
            local tag = el.tag:lower()
            local e
            if tag == "group" then
                e = { kind = "group", name = text.fromCP1252(el.attrs.name or ""), default = el.attrs.default }
            elseif tag == "subgroup" then
                e = { kind = "sub", name = text.fromCP1252(el.attrs.name or "") }
            elseif tag == "tile" and el.attrs.id then
                index = index + 1
                e = { kind = "tile", id = el.attrs.id:upper(), name = text.fromCP1252(el.attrs.name or el.attrs.id), index = index }
                catalog.byId[e.id] = e
            end
            if e then catalog.entries[#catalog.entries + 1] = e end
        end
    end
    return catalog
end

-- The tile a new map is filled with: the default of the first pack called "Grass" (or any).
---@return EditorTile
function M.baseTile()
    local cat = M.tileCatalog()
    local pick
    for _, e in ipairs(cat.entries) do
        if e.kind == "group" and e.default and (e.name == "Grass" or not pick) then pick = e.default:upper() end
        if pick and e.name == "Grass" then break end
    end
    return cat.byId[pick or ""] or cat.entries[1] --[[@as EditorTile]]
end

-- Tile footprint in map slots (w, h) and the terrain type record.
---@param id string
---@return table? type the terrain tile type
---@return integer size 0..3
---@return integer w slots
---@return integer h
function M.tileInfo(id)
    local t = terrainMod.tileType(id)
    local size = t and t.size or 0
    local f = FOOT[size] or FOOT[0]
    return t, size, f[1], f[2]
end

---@param tile EditorTile
---@param part integer
---@return string
local function record(tile, part)
    local t, size = M.tileInfo(tile.id)
    return scnwrite.tileRecord(tile.id, tile.index, part, t and t.animated, t and t.frames or 1, size)
end

---@param scn Scenario
---@param terrain Terrain?
---@param tx integer
---@param ty integer
---@param tile EditorTile
---@param part integer
local function setSlot(scn, terrain, tx, ty, tile, part)
    local t, size = M.tileInfo(tile.id)
    scn.tiles[ty * scn.tilesW + tx] = { id = tile.id, raw = record(tile, part), part = part, size = size }
    if terrain then terrain:setSlot(tx, ty) end
end

-- Paints `tile` with its top-left slot at (tx, ty); returns the slots changed as { {x, y}... }.
-- Slots of a big tile that is partly overwritten fall back to the base tile.
---@param scn Scenario
---@param terrain Terrain?
---@param tile EditorTile
---@param tx integer
---@param ty integer
---@return {[1]: integer, [2]: integer}[]
function M.paintTile(scn, terrain, tile, tx, ty)
    local _, _, fw, fh = M.tileInfo(tile.id)
    if fw > scn.tilesW or fh > scn.tilesH then return {} end
    tx = math.max(0, math.min(tx, scn.tilesW - fw))
    ty = math.max(0, math.min(ty, scn.tilesH - fh))
    local changed, base = {}, M.baseTile()
    local inside = {}
    for dy = 0, fh - 1 do for dx = 0, fw - 1 do inside[(ty + dy) * scn.tilesW + tx + dx] = true end end
    for dy = 0, fh - 1 do
        for dx = 0, fw - 1 do
            local x, y = tx + dx, ty + dy
            local old = scn.tiles[y * scn.tilesW + x]
            local oldInfo = old and select(2, M.tileInfo(old.id)) or 0
            if oldInfo ~= 0 then
                local ow, oh = FOOT[oldInfo][1], FOOT[oldInfo][2]
                local ox, oy = x - (old.part % 2), y - math.floor(old.part / 2)
                for ey = 0, oh - 1 do
                    for ex = 0, ow - 1 do
                        local sx, sy = ox + ex, oy + ey
                        local i = sy * scn.tilesW + sx
                        if sx >= 0 and sy >= 0 and sx < scn.tilesW and sy < scn.tilesH and not inside[i]
                            and scn.tiles[i].id == old.id then
                            setSlot(scn, terrain, sx, sy, base, 0)
                            changed[#changed + 1] = { sx, sy }
                        end
                    end
                end
            end
            setSlot(scn, terrain, x, y, tile, dy * 2 + dx)
            changed[#changed + 1] = { x, y }
        end
    end
    return changed
end

---@param scn Scenario
---@param terrain Terrain?
---@param tile EditorTile
function M.fillMap(scn, terrain, tile)
    local _, _, fw, fh = M.tileInfo(tile.id)
    for ty = 0, scn.tilesH - 1 do
        for tx = 0, scn.tilesW - 1 do
            if fw == 1 and fh == 1 then
                setSlot(scn, terrain, tx, ty, tile, 0)
            else
                -- big tiles repeat on a grid of their own size
                setSlot(scn, terrain, tx, ty, tile, (ty % fh) * 2 + (tx % fw))
            end
        end
    end
end

-- Features: every <code>.FEA of the archives, grouped by the archive they sit in (the type record
-- holds the 20-character name at offset 4). Returns { { code, name, group }... } sorted by group, name.
---@type {code: string, name: string, group: string}[]?
local featureCache
---@return {code: string, name: string, group: string}[]
function M.featureList()
    if featureCache then return featureCache end
    featureCache = {}
    for _, path in ipairs(vfs.list("%.fea$")) do
        local group, code = path:match("([^/]+)%.xcr/(%w+)%.%w+$")
        local data = code and vfs.find(code .. ".fea")
        if data and #data >= 24 then
            local name = data:sub(5, 24):match("^[^%z]*"):gsub("%s+$", "")
            featureCache[#featureCache + 1] = { code = code:upper(), name = name ~= "" and name or code, group = group }
        end
    end
    table.sort(featureCache, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.code < b.code
    end)
    return featureCache
end

-- Scenario --------------------------------------------------------------------------

---@param name string
---@param size integer cells
---@param description string?
---@return Scenario
function M.newScenario(name, size, description)
    local scn = scnwrite.new({ name = name, size = size, description = description, tile = M.baseTile() })
    for i = 0, scn.tilesW * scn.tilesH - 1 do
        local t = scn.tiles[i]
        local _, tsize = M.tileInfo(t.id)
        t.size = tsize
    end
    return scn
end

-- A new scenario made by the random map generator, the editor's Ctrl+R in the new-scenario dialog (its handler 0x004bfb50
-- in the 1.04 binary compares the size with 64 / 128 / 192 / 256 and calls the editor's random map set-up FUN_00417120
-- -> the generator FUN_00582180 with the editor flag set). The original rolls the terrain with one 7-sided die minus 1
-- (the first seven sets: Grasslands .. Caverns), resources with one 3-sided die minus 1, a few animals and no utilities;
-- the editor only gets the piece map's tiles and features (see randommap.generate `editor`), then all six sides are on
-- with race = side, no start locations and the standard victory event, like a new scenario made after the question.
-- `seed` is any number (the original rolls with its time-seeded dice).
-- The 96 and 160 cell sizes of openwbc3's size list (not in the original) are generated with the same piece rules.
---@param name string
---@param size integer
---@param description string?
---@param seed number
---@return Scenario
---@return table info what the generator made (randommap.generate)
function M.randomScenario(name, size, description, seed)
    local rm = require("src.game.randommap")
    local scn = M.newScenario(name, size, description)
    local rng = rm.rng(seed * 7 + 3)
    local terrain = rng:dice(1, 7, -1)
    local resources = rng:dice(1, 3, -1)
    scn.header.numPlayers = 6
    for i = 0, 5 do
        local sd = scn.sides[i]
        sd.used, sd.race, sd.color = true, i, i
        sd.startX, sd.startY = -1, -1
    end
    local _, info = rm.generate(scn, { seed = seed, cells = size, terrain = terrain, resources = resources, critters = 1,
                                        temples = 0, editor = true })
    scn.header.name, scn.header.description = name, description or ""
    for i = 0, scn.tilesW * scn.tilesH - 1 do
        local t = scn.tiles[i]
        if t and t.size == nil then t.size = select(2, M.tileInfo(t.id)) end
    end
    return scn, info
end

---@param wx number
---@param wy number
---@return integer gx
---@return integer gy
---@return number x the cell's centre
---@return number y
function M.snap(wx, wy)
    local gx, gy = math.floor(wx / CW), math.floor(wy / CH)
    return gx, gy, gx * CW + CW / 2, gy * CH + CH / 2
end

-- The statistics of a type record copied into a placed army / building, as the original's editor army creation
-- (FUN_004c8ad0) / building creation does (general stats, damage, armour, current hits); the object still plays with its
-- type's own values while `useDefault` is set.
local function copyStats(rec, t)
    if not t then return end
    rec.combat, rec.speed, rec.resistance, rec.hits, rec.view = t.combat, t.speed, t.resistance, t.hits, t.view
    rec.armor, rec.strong, rec.weak = t.armor, t.strong, t.weak
    rec.damage, rec.damageType, rec.range = t.damage, t.damageType, t.range
    rec.curHits = t.hits
end

-- Adds an object to a layer at cell (gx, gy); returns it.
---@param scn Scenario
---@param layer "features"|"armies"|"buildings"|"effects"
---@param code string
---@param gx integer
---@param gy integer
---@param side integer?
---@return table rec the new ScnFeature / ScnArmy / ScnBuilding / ScnEffect
function M.add(scn, layer, code, gx, gy, side)
    local x, y = gx * CW + CW / 2, gy * CH + CH / 2
    local rec = { code = code, x = x, y = y, anim = 0, dir = 0, frame = 0 }
    if layer == "armies" then
        rec.owner, rec.side = side or 6, side or 6
        -- the SCN's level counts from 0 for plain troops; a hero's level starts at 1
        local rules = require("src.game.rules")
        local info = rules.armyInfo(code)
        rec.level = info and info.hero and 1 or 0
        -- the editor's army creation (FUN_004c8ad0): normal behaviour, no script, no name, alive, the type's own statistics
        rec.xp, rec.behaviour, rec.script, rec.name, rec.tag = 0, 2, "", "", ""
        rec.globalIndex = info and info.index or 0
        rec.alive, rec.useDefault, rec.character, rec.hero = true, true, false, false
        copyStats(rec, require("src.game.gamedata").army(code))
        if require("src.game.unit").isCritter(code) then rec.owner, rec.side = 6, 6 end
    elseif layer == "buildings" then
        rec.side = side or 6
        local info = require("src.game.rules").building(code)
        rec.globalIndex = info and info.index or 0
        rec.name, rec.tag, rec.useDefault, rec.character = "", "", true, false
        rec.level = info and info.level or 0
        rec.resources = { 0, 0, 0, 0 }
        copyStats(rec, require("src.game.gamedata").building(code))
        if info and info.searchable then rec.side = 6 end
    elseif layer == "effects" then
        rec.anim, rec.dir, rec.frame = nil, nil, nil
    end
    local list = scn[layer]
    list[#list + 1] = rec
    return rec
end

-- The owner after `rec` was cycled by one (the selected-object dialogs' owner button, the army / building dialog
-- handlers 0x004c7b40 / 0x004c7ef0): sides 0..6 and round again; a critter (army) or a searchable
-- building (a lair, shop or shrine) always ends up with the neutral side.
---@param layer string
---@param rec ScnArmy|ScnBuilding
---@return integer
function M.nextOwner(layer, rec)
    local owner = ((rec.side or 6) + 1) % 7
    if layer == "armies" then
        if require("src.game.unit").isCritter(rec.code) then owner = 6 end
    else
        local info = require("src.game.rules").building(rec.code)
        if info and info.searchable then owner = 6 end
    end
    return owner
end

---@param layer string
---@param rec ScnArmy|ScnBuilding
---@param owner integer
function M.setOwner(layer, rec, owner)
    rec.side = owner
    if layer == "armies" then rec.owner = owner end
end

-- Done of the army dialog (handler 0x004c7b40): a name makes the army a character, the level is the typed one minus 1
-- (never below 0) and the experience the table's value for it. The original reads the table before clamping a typed 0
-- (index -1); openwbc3 clamps first. A hero's level counts from 1 (no minus 1 for it: its SCN level is the hero level).
---@param rec ScnArmy
---@param name string?
---@param tag string?
---@param levelText string|number|nil
function M.applyArmy(rec, name, tag, levelText)
    rec.name, rec.tag = name or "", tag or ""
    rec.character = rec.name ~= ""
    local lvl = math.floor(tonumber(levelText) or 1)
    local unit = require("src.game.unit")
    local hero = rec.hero or (require("src.game.rules").armyInfo(rec.code) or {}).hero
    if hero then
        rec.level = math.max(1, math.min(require("src.game.hero").MAX_LEVEL, lvl))
        -- heroes get their experience from the hero tables, the scenario keeps what it had
    else
        lvl = math.max(0, math.min(unit.MAX_ARMY_LEVEL, lvl - 1))
        rec.level = lvl
        rec.xp = unit.XP_FOR_LEVEL[lvl + 1]
    end
end

-- What the level edit of the army dialog shows: the stored level + 1 (a hero's scenario level is its hero level already).
---@param rec ScnArmy
---@return integer
function M.levelNumber(rec)
    local hero = rec.hero or (require("src.game.rules").armyInfo(rec.code) or {}).hero
    return hero and (rec.level or 1) or (rec.level or 0) + 1
end

---@param rec ScnBuilding
---@param name string?
---@param tag string?
function M.applyBuilding(rec, name, tag)
    rec.name, rec.tag = name or "", tag or ""
    rec.character = rec.name ~= ""
end

-- Characters on the map (named armies and buildings): the original allows at most nine (a count above 8 greys the
-- character button; not traced in the 1.04 binary yet).
---@param scn Scenario
---@return integer
function M.characterCount(scn)
    local n = 0
    for _, a in ipairs(scn.armies) do if a.character then n = n + 1 end end
    for _, b in ipairs(scn.buildings) do if b.character then n = n + 1 end end
    return n
end

-- Chests (the scenario's ITMH records, editor items click FUN_004c3f90 / chest view 0x004c8400; format in docs/formats.md) -
-- A chest holds up to four items, each a random item (index -2) or a numbered one of the item table; or it is a resource
-- chest with one entry (500 of a resource when a hero opens it, the chest search FUN_0053a1a0).
M.RANDOM_ITEM = -2
M.MAX_CHEST_ITEMS = 4
-- the resources a chest can hold in the editor's list order (gold, metal, stone, crystal; FUN_004c8980): the game's item
-- type code (14 gold, 15 stone, 16 metal, 17 crystal) and the picture direction of the chest (the random map generator's
-- mapping, not traced in the 1.04 binary yet)
M.CHEST_RESOURCES = { { name = "gold", code = 14 }, { name = "metal", code = 16 }, { name = "stone", code = 15 },
                      { name = "crystal", code = 17 } }
M.RESOURCE_AMOUNT = 500

-- Whether an item id fits a chest of a scenario: the ITMH record keeps the item number as an i16 (docs/formats.md), so only the
-- numbered items of the install do; a mod item's "modid:name" cannot be saved, the editor neither lists nor places it.
---@param id any
---@return boolean
function M.chestItemId(id)
    return type(id) == "number" and id >= 0 and id <= 0x7fff and id == math.floor(id)
end

local function emptyChestItem() return { index = 0, resource = false, data = 0, itemIndex = 0, x = -1, y = -1 } end

-- A new chest record at cell (gx, gy): `kind` "random" (one random item), "item" (the numbered item `which`) or "resource"
-- (`which` 1..4 into CHEST_RESOURCES). The picture of an ordinary chest looks at direction 4, a resource chest's colour is
-- its direction.
---@param gx integer
---@param gy integer
---@param kind "random"|"item"|"resource"
---@param which integer?
---@return ScnItem
function M.newChest(gx, gy, kind, which)
    local x, y = gx * CW + CW / 2, gy * CH + CH / 2
    local c = { items = {}, count = 1, opened = false, resource = kind == "resource", x = gx, y = gy }
    for k = 1, 4 do c.items[k] = emptyChestItem() end
    local first = c.items[1]
    first.x, first.y = gx, gy
    if kind == "resource" then
        first.index, first.resource, first.data, first.itemIndex = 0, true, M.CHEST_RESOURCES[which].code, -1
    else
        first.index = kind == "item" and which or M.RANDOM_ITEM
    end
    return { code = "IMAP", anim = 0, dir = kind == "resource" and (which - 1) or 4, frame = 0, x = x, y = y, chest = c }
end

-- Moves a chest to cell (gx, gy) (the editor's move action for an item; not traced in the 1.04 binary yet); false when
-- another chest is there.
---@param scn Scenario
---@param rec ScnItem
---@param gx integer
---@param gy integer
---@return boolean
function M.moveChest(scn, rec, gx, gy)
    local at = M.chestAt(scn, gx, gy)
    if at and at ~= rec then return false end
    rec.x, rec.y = gx * CW + CW / 2, gy * CH + CH / 2
    local c = rec.chest
    c.x, c.y = gx, gy
    for _, m in ipairs(c.items) do m.x, m.y = gx, gy end
    return true
end

---@param scn Scenario
---@param gx integer
---@param gy integer
---@return ScnItem?
---@return integer? index
function M.chestAt(scn, gx, gy)
    for i, it in ipairs(scn.items) do
        if math.floor(it.x / CW) == gx and math.floor(it.y / CH) == gy then return it, i end
    end
end

-- Adds the item `kind` / `which` to the chest at (gx, gy) or makes a new chest there. Returns the record, or nil and why
-- ("resource": a resource chest holds nothing else; "full"; "noresource": only a numbered item goes into an existing chest;
-- "moditem": a mod item has no item number, see chestItemId).
---@param scn Scenario
---@param gx integer
---@param gy integer
---@param kind "random"|"item"|"resource"
---@param which integer?
---@return ScnItem?
---@return string? why
function M.placeChest(scn, gx, gy, kind, which)
    if kind == "item" and not M.chestItemId(which) then return nil, "moditem" end
    local at = M.chestAt(scn, gx, gy)
    if not at then
        local rec = M.newChest(gx, gy, kind, which)
        scn.items[#scn.items + 1] = rec
        return rec
    end
    local c = at.chest
    if c.resource then return nil, "resource" end
    if kind == "resource" then return nil, "noresource" end
    -- the original refuses a random item (a negative item index) for a chest that is there already
    if kind ~= "item" then return nil, "noresource" end
    if c.count >= M.MAX_CHEST_ITEMS then return nil, "full" end
    c.count = c.count + 1
    local m = emptyChestItem()
    m.index = kind == "item" and which or M.RANDOM_ITEM
    m.x, m.y = gx, gy
    c.items[c.count] = m
    return at
end

-- Removes item i (1..count) of a chest; the last item cannot be removed (the original does nothing then).
---@param rec ScnItem
---@param i integer
---@return boolean
function M.removeChestItem(rec, i)
    local c = rec.chest
    if c.count <= 1 or i < 1 or i > c.count then return false end
    for k = i, 3 do c.items[k] = c.items[k + 1] end
    c.items[4] = emptyChestItem()
    c.count = c.count - 1
    return true
end

-- Sides (the editor's sides panel handler 0x004b5b40) -----------------------------------------------------------------------

-- Whether the number of used sides may change by switching side i (0..5) on or off: sides 1 and 2 always play, a side can be
-- switched on only when all lower ones play and off only when no higher one does.
---@param scn Scenario
---@param i integer
---@param on boolean
---@return boolean
function M.canSwitchSide(scn, i, on)
    if i < 2 then return false end
    if on then
        for j = 0, i - 1 do if not scn.sides[j].used then return false end end
    else
        for j = i + 1, 5 do if scn.sides[j].used then return false end end
    end
    return true
end

-- Index of the object of `layer` nearest to the world position within `radius` pixels (objects
-- are anchored at their foot, so sprites are hit slightly above it).
---@param scn Scenario
---@param layer "features"|"armies"|"buildings"|"effects"|"items"
---@param wx number
---@param wy number
---@param radius number?
---@return integer?
function M.pick(scn, layer, wx, wy, radius)
    local best, bestD = nil, (radius or 36) ^ 2
    for i, o in ipairs(scn[layer]) do
        local dx, dy = o.x - wx, (o.y - 14) - wy
        local d = dx * dx + dy * dy
        if d <= bestD then best, bestD = i, d end
    end
    return best
end

-- A scenario without a SAIH chunk gets the six empty AI hero records of a new scenario (no custom AI file, class / level /
-- race / personality -1).
---@param scn Scenario
function M.ensureAI(scn)
    if scn.ai then return end
    scn.ai = {}
    for i = 0, 5 do scn.ai[i] = { race = -1, portrait = 0, level = -1, personality = -1, class = -1, file = "" } end
end

-- Events (src/formats/evt.lua): slot 0 of a scenario is the standard victory event, which the editor does not list;
-- `userEvents` are the others. Positions are cells, the same as the effects'.

-- Makes sure slot 0 is the standard victory event (scenarios saved by older editor versions had none).
---@param scn Scenario
function M.ensureEvents(scn)
    scn.events = scn.events or {}
    local first = scn.events[1]
    if not first or first.cond.condition ~= 10 then table.insert(scn.events, 1, evt.standardVictory()) end
end

-- Events the editor lists (all but slot 0): the scenario's list, entry i being scn.events[i + 1].
---@param scn Scenario
---@return ScnEvent[]
function M.userEvents(scn)
    M.ensureEvents(scn)
    local list = {}
    for i = 2, #scn.events do list[#list + 1] = scn.events[i] end
    return list
end

-- Adds a copy of a pool entry (evt.pool()) at the end; nil when the 128 slots are full (the editor's FUN_004b8380).
---@param scn Scenario
---@param entry EvtPoolEntry
---@return ScnEvent?
function M.addEvent(scn, entry)
    M.ensureEvents(scn)
    if #scn.events >= evt.MAX then return nil end
    local e = evt.fromTemplate(entry)
    scn.events[#scn.events + 1] = e
    return e
end

---@param scn Scenario
---@param i integer
---@return ScnEvent?
function M.removeEvent(scn, i)
    M.ensureEvents(scn)
    return table.remove(scn.events, i + 1)
end

-- Moves user event i up (-1) or down (+1) in the list (not in the original, which has no reordering); returns the new i.
---@param scn Scenario
---@param i integer
---@param dir integer
---@return integer
function M.moveEvent(scn, i, dir)
    M.ensureEvents(scn)
    local j = i + dir
    if j < 1 or j > #scn.events - 1 then return i end
    scn.events[i + 1], scn.events[j + 1] = scn.events[j + 1], scn.events[i + 1]
    return j
end

-- Start location of a side (cell coordinates; -1 = none).
---@param scn Scenario
---@param side integer
---@param gx integer
---@param gy integer
function M.setStart(scn, side, gx, gy)
    scn.sides[side].startX, scn.sides[side].startY = gx, gy
end

-- Minimap (128x128 BGR, as stored in the SM24 chunk) ----------------------------------

local TERRAIN_RGB = {
    [0] = { 70, 116, 40 }, { 120, 88, 52 }, { 190, 168, 104 }, { 38, 64, 128 }, { 116, 116, 116 }, { 204, 64, 24 },
    { 76, 100, 64 }, { 90, 128, 152 }, { 228, 228, 240 }, { 0, 0, 0 }, { 90, 76, 70 },
}
local SIDE_RGB = { [0] = { 217, 38, 25 }, { 51, 89, 242 }, { 38, 191, 38 }, { 179, 51, 191 }, { 51, 51, 51 },
                   { 242, 217, 77 }, { 153, 153, 153 } }
M.TERRAIN_RGB, M.SIDE_RGB = TERRAIN_RGB, SIDE_RGB

---@param scn Scenario
---@param terrain Terrain
---@return string
function M.minimap(scn, terrain)
    local w, h = scn.width, scn.height
    local px = {}
    for y = 0, 127 do
        local gy = math.min(h - 1, math.floor(y * h / 128))
        for x = 0, 127 do
            local gx = math.min(w - 1, math.floor(x * w / 128))
            local c = TERRAIN_RGB[terrain.terrain[gy * w + gx]] or TERRAIN_RGB[0]
            px[(y * 128 + x) * 3 + 1], px[(y * 128 + x) * 3 + 2], px[(y * 128 + x) * 3 + 3] = c[3], c[2], c[1]
        end
    end
    local function dot(o, size, rgb)
        local cx, cy = math.floor(o.x / CW * 128 / w), math.floor(o.y / CH * 128 / h)
        for dy = 0, size - 1 do
            for dx = 0, size - 1 do
                local x, y = cx + dx, cy + dy
                if x >= 0 and y >= 0 and x < 128 and y < 128 then
                    local i = (y * 128 + x) * 3
                    px[i + 1], px[i + 2], px[i + 3] = rgb[3], rgb[2], rgb[1]
                end
            end
        end
    end
    for _, b in ipairs(scn.buildings) do dot(b, 3, SIDE_RGB[b.side] or SIDE_RGB[6]) end
    for _, a in ipairs(scn.armies) do dot(a, 2, SIDE_RGB[a.side] or SIDE_RGB[6]) end
    local out = {}
    for i = 1, 128 * 128 * 3, 4096 do
        out[#out + 1] = string.char(unpack(px, i, math.min(i + 4095, 128 * 128 * 3)))
    end
    return table.concat(out)
end

-- Files ---------------------------------------------------------------------------------

---@param name string?
---@return string
function M.safeName(name)
    name = (name or ""):gsub("[^%w _%-%.]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return name
end

---@return string[]
function M.userScenarios()
    local list = {}
    if love and love.filesystem then
        for _, f in ipairs(love.filesystem.getDirectoryItems(M.USER_DIR)) do
            if f:lower():match("%.scn$") then list[#list + 1] = f end
        end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    return list
end

-- Whether a scenario of that name is in the user folder (the original asks "This scenario already exists / Overwrite?" for
-- a name its scenario list has; file names compare without case).
---@param name string
---@return string? file
function M.userScenarioExists(name)
    local want = (name .. ".scn"):lower()
    for _, f in ipairs(M.userScenarios()) do
        if f:lower() == want then return f end
    end
end

-- Deletes a scenario file of the user folder (the load list's Delete key).
---@param file string
---@return boolean
function M.deleteUser(file)
    return love.filesystem.remove(M.USER_DIR .. "/" .. file)
end

---@param file string
---@return string? contents
---@return any ... (love.filesystem.read's other results)
function M.readUser(file)
    return love.filesystem.read(M.USER_DIR .. "/" .. file)
end

-- Writes the scenario as scenarios/<name>.SCN; returns the file name or nil, message.
---@param scn Scenario
---@param terrain Terrain
---@param name string?
---@return string? file
---@return string? err
function M.save(scn, terrain, name)
    name = M.safeName(name or scn.header.name)
    if name == "" then return nil, "no name" end
    scn.header.name = name
    local players = 0
    for i = 0, 5 do if scn.sides[i].used then players = players + 1 end end
    scn.header.numPlayers = players
    scn.minimap = M.minimap(scn, terrain)
    love.filesystem.createDirectory(M.USER_DIR)
    local file = name .. ".SCN"
    local ok, err = love.filesystem.write(M.USER_DIR .. "/" .. file, scnwrite.write(scn))
    if not ok then
        log.error("editor: cannot save %s: %s", file, tostring(err))
        return nil, tostring(err)
    end
    return file
end

return M
