-- Parsers of the install's rule files System.xcr/Army.cfg and Building.cfg (columns are fixed-width). They return plain
-- lists of rows with the raw column text; the importers (units.lua, buildings.lua, rules.lua) turn them into records.
local vfs = require("src.vfs.vfs")
local log = require("src.core.log")

local M = {}

---@class CfgArmyRow
---@field code string
---@field index integer
---@field status string                 the eight-letter status column
---@field cache string                  the race columns
---@field shoot string                  "<type>:<missile>"
---@field mana string                   "max:start" or "---:---"
---@field general boolean
---@field label string
---@field hero boolean                  a row of [HEROES]

---@class CfgBuildingRow
---@field code string
---@field index integer
---@field level integer
---@field dataLevel integer
---@field resource string               "-" when not a mine
---@field missile string                "----" for none
---@field missileType string
---@field cache string                  16 race columns each: cache, stop-defeat, armies, build
---@field stopDefeat string
---@field armies string
---@field build string
---@field armyLimit integer
---@field garrison integer
---@field searchable string             "-" = no
---@field lair string
---@field shop string
---@field label string

---@class CfgItem
---@field code string
---@field level string
---@field row integer?

---@class CfgBuilding
---@field buildings CfgBuildingRow[]
---@field construction { letter: string, items: CfgItem[] }[]
---@field production { code: string, letter: string, items: CfgItem[], requires: string[] }[]
---@field dependencies { letter: string, code: string, requires: string[], priority: integer? }[]
---@field rules { code: string, letter: string, values: RaceOverride }[]

local function sections(text)
    local out, cur = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name = line:match("^%[(.-)%]")
        if name then
            cur = {}
            out[name:upper()] = cur
        elseif cur and line ~= "" and not line:match("^%s*//") then
            cur[#cur + 1] = line
        end
    end
    return out
end

-- The .ARM / .BUI bytes of a code: PatchData.xcr first, then every archive.
---@param code string
---@param ext string      ".arm" / ".bui"
---@return string?
function M.lookup(code, ext)
    local patch = vfs.archive("PatchData.xcr")
    local data = patch and patch:read(code .. ext)
    return data or vfs.find(code .. ext)
end

---@type { rows: CfgArmyRow[] }?, CfgBuilding?
local armyCache, buildingCache

-- Army.cfg [ARMIES]/[HEROES]: "NNN CODE STATUS CACHE SHOOT LATENCY AI MANA GENERAL NAME".
-- Returns { rows = { { code, index, status, cache, shoot, mana, general, label, hero } ... } } in file order.
---@return { rows: CfgArmyRow[] }
function M.army()
    if armyCache then return armyCache end
    local rows = {}
    local text = vfs.read("System.xcr", "Army.cfg") or ""
    if text == "" then log.error("import: Army.cfg missing") end
    local sec = sections(text)
    for _, name in ipairs({ "ARMIES", "HEROES" }) do
        for _, line in ipairs(sec[name] or {}) do
            local c, status, cache, shoot, latency, ai, mana, general, label =
                line:match("^%d+%s+(%w%w%w%w)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.-)%s*$")
            if c then
                rows[#rows + 1] = { code = c:upper(), index = tonumber(line:match("^(%d+)")), status = status, cache = cache,
                                    shoot = shoot, mana = mana, general = general == "G", label = label,
                                    hero = name == "HEROES" }
            end
        end
    end
    armyCache = { rows = rows }
    return armyCache
end

-- Building.cfg. Returns { buildings = rows of [BUILDINGS], construction = rows of [CONSTRUCTION],
-- production = rows of [PRODUCTION], dependencies = rows of [DEPENDENCIES], rules = rows of [RULES] }.
---@return CfgBuilding
function M.building()
    if buildingCache then return buildingCache end
    local out = { buildings = {}, construction = {}, production = {}, dependencies = {}, rules = {} }
    local text = vfs.read("System.xcr", "Building.cfg")
    if not text then
        log.error("import: Building.cfg missing")
        buildingCache = out
        return out
    end
    local sec = sections(text)
    -- [CONSTRUCTION] "H0 0:BKK0 0:BAGA ..." : race letter + row, then level:code pairs ("----" = empty slot)
    for _, line in ipairs(sec.CONSTRUCTION or {}) do
        local letter, row, rest = line:match("^(%u)([01])%s+(.*)$")
        if letter then
            local items = {}
            for lvl, code in rest:gmatch("(%S):(%S%S%S%S)") do
                if code ~= "----" then items[#items + 1] = { code = code, level = lvl, row = tonumber(row) } end
            end
            out.construction[#out.construction + 1] = { letter = letter, items = items }
        end
    end
    -- [PRODUCTION] "CODE R l:item ... | req req req req PRI"
    for _, line in ipairs(sec.PRODUCTION or {}) do
        local code, letter, rest = line:match("^(%u%u%w%w)%s+(%u)%s+(.*)$")
        if code then
            local left, right = rest:match("^(.-)|(.*)$")
            left = left or rest
            local items = {}
            for lvl, item in left:gmatch("(%S):(%S%S%S%S)") do
                if item ~= "----" then items[#items + 1] = { code = item, level = lvl } end
            end
            local req = {}
            for r in (right or ""):gmatch("(%u%u%w%w)") do req[#req + 1] = r end
            out.production[#out.production + 1] = { code = code, letter = letter, items = items, requires = req }
        end
    end
    -- [DEPENDENCIES] "R CODE : d0 d1 d2 d3 PRI" (the [PRODUCTION] list wins)
    for _, line in ipairs(sec.DEPENDENCIES or {}) do
        local letter, code, rest = line:match("^(%u)%s+(%u%w%w%w)%s*:%s*(.*)$")
        if letter then
            local req = {}
            for r in rest:gmatch("(%u%u%w%w)") do req[#req + 1] = r end
            out.dependencies[#out.dependencies + 1] = { letter = letter, code = code, requires = req,
                                                        priority = tonumber(rest:match("(%d+)%s*$")) }
        end
    end
    -- [RULES] per-race overrides of cost / time / statistics of one type (fixed columns, "----" = unchanged):
    -- code 0, race letter 5, gold 7, metal 12, stone 17, crystal 22, time 27 (4 wide), strength 32, hits 36,
    -- speed 40, resistance 44, damage 54, range 58 (3 wide)
    for _, line in ipairs(sec.RULES or {}) do
        local code, race = line:sub(1, 4), line:sub(6, 6)
        if code:match("^%u%w%w%w$") and race:match("%u") then
            local function num(i, w)
                local s = line:sub(i + 1, i + w)
                return s:match("^%d+") and tonumber(s:match("^%d+")) or nil
            end
            out.rules[#out.rules + 1] = { code = code, letter = race,
                values = { gold = num(7, 4), metal = num(12, 4), stone = num(17, 4), crystal = num(22, 4), time = num(27, 4),
                           combat = num(32, 3), hits = num(36, 3), speed = num(40, 3), resistance = num(44, 3),
                           damage = num(54, 3), range = num(58, 3) } }
        end
    end
    -- [BUILDINGS] fixed columns (0-based): code 4, levels 9/10, resource 12, missile 31/33, race masks 14 (the
    -- CACHE column), stop-defeat 38, armies 55, build 72 (16 columns each), army limit 89, searchable 91,
    -- garrison 93, lair 95, shop 97, name 99.
    for _, line in ipairs(sec.BUILDINGS or {}) do
        if line:match("^%d%d%d ") and #line >= 99 then
            local function col(i, n) return line:sub(i + 1, i + (n or 1)) end
            out.buildings[#out.buildings + 1] = {
                code = col(4, 4), index = tonumber(line:match("^(%d+)")), level = tonumber(col(9)) or 0,
                dataLevel = tonumber(col(10)) or 0, resource = col(12), missile = col(33, 4), missileType = col(31),
                cache = col(14, 16), stopDefeat = col(38, 16), armies = col(55, 16), build = col(72, 16),
                armyLimit = tonumber(col(89)) or 0, garrison = tonumber(col(93)) or 0, searchable = col(91),
                lair = col(95), shop = col(97), label = line:sub(100):gsub("%s+$", ""),
            }
        end
    end
    buildingCache = out
    return out
end

-- Drops the parsed files (the next call reads them again).
function M.clear() armyCache, buildingCache = nil, nil end

return M
