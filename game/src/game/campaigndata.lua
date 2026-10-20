-- The original campaign definition, read from <Lang>/Campaign.xcr (XML):
--   LOC_*.loc  locations of the world map (position, links, actions, ambushes, variables)
--   ACT_*.act  what you can do at a location (battle, message, choice, mercenary, retinue, item, xp)
--   AMB_*.amb  ambushes on the roads;  MAP_*.map  how a battle is set up
--   Global.var / Global.bon (bonuses) / Global.hnt (hints), <Lang>/Mercenaries.xcr/Mercenaries.xml
local vfs = require("src.vfs.vfs")
local xml = require("src.core.xml")
local text = require("src.core.text")
local log = require("src.core.log")

local M = {}

-- A <Condition>: a check of a variable / a diplomatic rating, or an effect of a victory / defeat.
---@class CampaignCondition
---@field type string               "check" | "diplomacy" | "victory" | "defeat"
---@field id string?                the variable (lower case)
---@field action string?            "eq" / "ge" / ... for checks, "assign" / "add" / "sub" for effects
---@field value number?
---@field rating number?
---@field side integer?
---@field choice integer?

-- A <Diplomacy> step of an action.
---@class CampaignDiplomacy
---@field side integer?
---@field mod number
---@field min number?
---@field max number?
---@field choice integer?

-- A bonus of Global.bon.
---@class CampaignBonus
---@field name string
---@field description string
---@field type string
---@field data number
---@field level number?

-- A mercenary company of Mercenaries.xml.
---@class CampaignMercenary
---@field id integer
---@field cost integer
---@field rarity integer
---@field race integer?
---@field quality integer
---@field name string
---@field units {code: string, number: integer, level: integer, name: string?, text: string}[]

-- A <Side> of a MAP_*.map.
---@class CampaignMapSide
---@field race integer?
---@field resources integer
---@field team integer
---@field relativeai integer?
---@field ai integer?               0 passive or 7 rampant: replaces the level
---@field nohero boolean
---@field noretinue boolean

-- The whole campaign definition.
---@class CampaignData
---@field locations table<string, CampaignLocation>
---@field actions table<string, CampaignAction>
---@field maps table<string, CampaignMap>
---@field ambushes table<string, CampaignAction>
---@field bonuses table<integer, CampaignBonus>
---@field hints {levels: integer, texts: table<integer, string>, conditions: CampaignCondition[]}[]
---@field globals {id: string, value: number}[]
---@field mercenaries table<integer, CampaignMercenary>

---@type CampaignData?
local loaded

---@param name string
---@return string?
local function read(name)
    local d = vfs.read("Campaign.xcr", name)
    return d and text.fromCP1252(d) or nil
end

local function num(v, default)
    return tonumber(v) or default
end

---@param node XmlNode?
---@return CampaignCondition[]
local function conditions(node)
    local out = {}
    if not node then return out end
    for _, c in ipairs(xml.all(node, "Condition")) do
        local a = c.attrs
        out[#out + 1] = { type = a.type, id = a.id and a.id:lower() or nil, action = a.action, value = num(a.value),
                          rating = num(a.rating), side = num(a.side), choice = num(a.choice) }
    end
    return out
end

local function paragraphs(node)
    local out = {}
    for _, p in ipairs(xml.all(node, "Paragraph")) do out[#out + 1] = xml.text(p) end
    return table.concat(out, "\n")
end

local function journals(node)
    local out = {}
    for _, j in ipairs(xml.all(node, "Journal")) do
        out[#out + 1] = { type = j.attrs.type, choice = num(j.attrs.choice), important = j.attrs.important == "yes",
                          text = paragraphs(j) }
    end
    return out
end

local function rewards(node)
    local out = {}
    for _, r in ipairs(xml.all(node, "Reward")) do
        out[#out + 1] = { type = r.attrs.type, data = r.attrs.data, short = r.attrs.shorttext, text = xml.text(r) }
    end
    return out
end

---@param node XmlNode
---@return CampaignDiplomacy[]
local function diplomacy(node)
    local out = {}
    for _, d in ipairs(xml.all(node, "Diplomacy")) do
        local a = d.attrs
        out[#out + 1] = { side = num(a.side), mod = num(a.modification, 0), min = num(a.min), max = num(a.max),
                          choice = num(a.choice) }
    end
    return out
end

---@param root XmlNode
---@return CampaignAction
local function parseAction(root)
    local a = root.attrs
    -- An ACT_*.act action (or an AMB_*.amb ambush, which is a battle).
    ---@class CampaignAction
    ---@field code string
    ---@field type string               "battle" | "message" | "choice" | "mercenary" | "retinue" | "item" | "xp" ...
    ---@field replayable boolean
    ---@field name string?
    ---@field help string?
    ---@field description string?
    ---@field message string?
    ---@field heading string?
    ---@field cost number?
    ---@field costText string?
    ---@field rewards {type: string, data: string?, short: string?, text: string}[]
    ---@field diplomacy CampaignDiplomacy[]
    ---@field map string?               the MAP_* code of a battle
    ---@field conditions CampaignCondition[]
    ---@field journals {type: string?, choice: integer?, important: boolean, text: string}[]
    ---@field options {choice: integer, label: string}[]
    ---@field data {cost: number, race: integer?, image: integer?}?
    ---@field unit {code: string, level: integer, nameset: integer?, random: boolean}?
    ---@field mercenaries {type: string, index: integer, side: integer, minq: integer, maxq: integer, chance: number}[]?
    ---@field items {price: number, list: {type: string, index: integer?, minq: integer, maxq: integer, chance: number}[]}?
    ---@field sell number?
    ---@field chances table<string, number>? an ambush's chance by relation ("ally", "friend", "neutral", "enemy")
    local act = { code = a.code:upper(), type = a.type, replayable = a.replayable == "1" }
    local function t(tag) local c = xml.child(root, tag) return c and xml.text(c) or nil end
    act.name, act.help, act.description, act.message, act.heading = t("Name"), t("Help"), t("Description"), t("Message"), t("Heading")
    local cost = xml.child(root, "Cost")
    act.cost = cost and num(cost.attrs.data, 0) or nil
    act.costText = cost and xml.text(cost) or nil
    act.rewards = rewards(root)
    act.diplomacy = diplomacy(root)
    local map = xml.child(root, "Map")
    act.map = map and map.attrs.code:upper() or nil
    act.conditions = conditions(xml.child(root, "Conditions"))
    act.journals = journals(root)
    act.options = {}
    for _, o in ipairs(xml.all(root, "Option")) do act.options[#act.options + 1] = { choice = num(o.attrs.choice, 0), label = xml.text(o) } end
    local data = xml.child(root, "Data")
    if data then act.data = { cost = num(data.attrs.cost, 0), race = num(data.attrs.race), image = num(data.attrs.image) } end
    local unit = xml.child(root, "Unit")
    if unit then act.unit = { code = unit.attrs.code, level = num(unit.attrs.level, 1), nameset = num(unit.attrs.nameset),
                              random = unit.attrs.name == "random" } end
    local mercs = xml.child(root, "Mercenaries")
    if mercs then
        act.mercenaries = {}
        for _, m in ipairs(xml.all(mercs, "Mercenary")) do
            local x = m.attrs
            act.mercenaries[#act.mercenaries + 1] = { type = x.type, index = num(x.index, 0), side = num(x.side, -1),
                minq = num(x.minquality, 0), maxq = num(x.maxquality, 5), chance = num(x.chance, 100) }
        end
    end
    local items = xml.child(root, "Items")
    if items then
        act.items = { price = num(items.attrs.price, 100), list = {} }
        for _, it in ipairs(xml.all(items, "Item")) do
            local x = it.attrs
            act.items.list[#act.items.list + 1] = { type = x.type, index = num(x.index), minq = num(x.minquality, 0),
                maxq = num(x.maxquality, 1), chance = num(x.chance, 100) }
        end
    end
    local sell = xml.child(root, "Sell")
    if sell then act.sell = num(sell.attrs.price, 40) end
    if root.tag == "Ambush" then
        local ch = xml.child(root, "Chances")
        act.chances = ch and { ally = num(ch.attrs.ally, 0), friend = num(ch.attrs.friend, 0), neutral = num(ch.attrs.neutral, 0),
                               enemy = num(ch.attrs.enemy, 0) } or { ally = 0, friend = 0, neutral = 0, enemy = 0 }
        act.type = "battle"
    end
    return act
end

---@param root XmlNode
---@return CampaignLocation
local function parseLocation(root)
    -- A LOC_*.loc location of the world map.
    ---@class CampaignLocation
    ---@field code string
    ---@field name string
    ---@field description string
    ---@field owner integer?            the race that owns it (diplomacy)
    ---@field x number
    ---@field y number
    ---@field tx number                 where its name is written
    ---@field ty number
    ---@field actions string[]          ACT_* codes
    ---@field ambushes {type: string, code: string}[]
    ---@field variables {id: string, value: number}[]
    ---@field links {to: string, days: integer, kind: string?, label: string}[]
    ---@field conditions CampaignCondition[]
    local loc = { code = root.attrs.code:upper() }
    loc.name = xml.text(xml.child(root, "Name") or { text = "" })
    local d = xml.child(root, "Description")
    loc.description = d and paragraphs(d) or ""
    local dip = xml.child(root, "Diplomacy")
    loc.owner = dip and num(dip.attrs.owner) or nil
    local p = xml.child(root, "Position")
    loc.x, loc.y = p and num(p.attrs.x, 0) or 0, p and num(p.attrs.y, 0) or 0
    local tx = xml.child(root, "Text")
    loc.tx, loc.ty = tx and num(tx.attrs.x, loc.x) or loc.x, tx and num(tx.attrs.y, loc.y - 40) or loc.y - 40
    loc.actions, loc.ambushes, loc.variables, loc.links = {}, {}, {}, {}
    local acts = xml.child(root, "Actions")
    if acts then for _, a in ipairs(xml.all(acts, "Action")) do loc.actions[#loc.actions + 1] = a.attrs.code:upper() end end
    local ambs = xml.child(root, "Ambushes")
    if ambs then for _, a in ipairs(xml.all(ambs, "Ambush")) do loc.ambushes[#loc.ambushes + 1] = { type = a.attrs.type, code = a.attrs.code:upper() } end end
    local vars = xml.child(root, "Variables")
    if vars then for _, v in ipairs(xml.all(vars, "Variable")) do loc.variables[#loc.variables + 1] = { id = v.attrs.id:lower(), value = num(v.attrs.value, 0) } end end
    local links = xml.child(root, "Links")
    if links then
        for _, l in ipairs(xml.all(links, "Link")) do
            loc.links[#loc.links + 1] = { to = l.attrs.code:upper(), days = num(l.attrs.traveltime, 5), kind = l.attrs.type, label = xml.text(l) }
        end
    end
    loc.conditions = conditions(xml.child(root, "Conditions"))
    return loc
end

---@param root XmlNode
---@return CampaignMap
local function parseMap(root)
    -- A MAP_*.map battle set-up.
    ---@class CampaignMap
    ---@field code string
    ---@field file string?              the scenario file, "random" for a random map
    ---@field battle {victory: string, points: number, hidden: boolean, fog: boolean, level: number, quests: boolean}
    ---@field sides table<integer, CampaignMapSide> side 0..7 -> its <Side>
    ---@field heroes {side: integer, race: integer?, class: integer?, level: integer?, relative: integer?, name: string}[]
    ---@field random {size: integer, terrain: integer}?
    local map = { code = root.attrs.code:upper(), sides = {}, heroes = {} }
    local n = xml.child(root, "Name")
    map.file = n and n.attrs.file or nil
    local b = xml.child(root, "Battle")
    local a = b and b.attrs or {}
    map.battle = { victory = a.victory or "standard", points = num(a.points, 10), hidden = a.hidden == "1", fog = a.fog ~= "0",
                   level = num(a.level, 0), quests = a.quests == "1" }
    for _, s in ipairs(xml.all(root, "Side")) do
        local x = s.attrs
        map.sides[num(x.id, 0)] = { race = num(x.race), resources = num(x.resources, 2), team = num(x.team, 0), relativeai = num(x.relativeai),
                                    ai = num(x.ai), nohero = x.nohero == "1", noretinue = x.noretinue == "1" }
    end
    for _, h in ipairs(xml.all(root, "Hero")) do
        local x = h.attrs
        map.heroes[#map.heroes + 1] = { side = num(x.id, 1), race = num(x.race), class = num(x.class), level = num(x.level),
                                        relative = num(x.relativelevel), name = xml.text(h) }
    end
    local rd = xml.child(root, "RandomData")
    if rd then map.random = { size = num(rd.attrs.size, 1), terrain = num(rd.attrs.terrain, 0) } end
    return map
end

---@return CampaignData
function M.load()
    if loaded then return loaded end
    ---@type CampaignData
    local D = { locations = {}, actions = {}, maps = {}, ambushes = {}, bonuses = {}, hints = {}, globals = {}, mercenaries = {} }
    loaded = D
    for _, path in ipairs(vfs.list("%.loc$", "Campaign.xcr")) do
        local d = read(path:match("[^/]+$"))
        if d then
            local ok, loc = pcall(function() return parseLocation(xml.parse(d)) end)
            if ok then D.locations[loc.code] = loc else log.warn("campaign: %s: %s", path, tostring(loc)) end
        end
    end
    for _, path in ipairs(vfs.list("%.act$", "Campaign.xcr")) do
        local d = read(path:match("[^/]+$"))
        if d then
            local ok, act = pcall(function() return parseAction(xml.parse(d)) end)
            if ok then D.actions[act.code] = act else log.warn("campaign: %s: %s", path, tostring(act)) end
        end
    end
    for _, path in ipairs(vfs.list("%.amb$", "Campaign.xcr")) do
        local d = read(path:match("[^/]+$"))
        if d then
            local ok, amb = pcall(function() return parseAction(xml.parse(d)) end)
            if ok then D.ambushes[amb.code] = amb end
        end
    end
    for _, path in ipairs(vfs.list("%.map$", "Campaign.xcr")) do
        local d = read(path:match("[^/]+$"))
        if d then
            local ok, map = pcall(function() return parseMap(xml.parse(d)) end)
            if ok then D.maps[map.code] = map else log.warn("campaign: %s: %s", path, tostring(map)) end
        end
    end
    local g = read("Global.var")
    if g then
        for _, v in ipairs(xml.all(xml.parse(g), "Variable")) do D.globals[#D.globals + 1] = { id = v.attrs.id:lower(), value = num(v.attrs.value, 0) } end
    end
    local b = read("Global.bon")
    if b then
        for _, bn in ipairs(xml.all(xml.parse(b), "Bonus")) do
            local data = xml.child(bn, "Data")
            -- (every bonus has its name and description)
            D.bonuses[num(bn.attrs.index, 0)] = { name = xml.text(xml.child(bn, "Name") --[[@as XmlNode]]),
                description = xml.text(xml.child(bn, "Description") --[[@as XmlNode]]),
                type = data and data.attrs.type or "none", data = data and num(data.attrs.data, 0) or 0, level = data and num(data.attrs.level) or nil }
        end
    end
    local h = read("Global.hnt")
    if h then
        for _, hn in ipairs(xml.all(xml.parse(h), "Hint")) do
            local hint = { levels = num(hn.attrs.levels, 1), texts = {}, conditions = conditions(hn) }
            for _, t in ipairs(xml.all(hn, "Text")) do hint.texts[num(t.attrs.level, 0)] = xml.text(t) end
            D.hints[#D.hints + 1] = hint
        end
    end
    local m = vfs.find("Mercenaries.xml")
    if m then
        for _, mn in ipairs(xml.all(xml.parse(text.fromCP1252(m)), "Mercenary")) do
            local a = mn.attrs
            local merc = { id = num(a.id, 0), cost = num(a.cost, 50), rarity = num(a.rarity, 5), race = num(a.race), quality = num(a.quality, 1),
                           name = xml.text(xml.child(mn, "Name") --[[@as XmlNode]]), units = {} }
            for _, u in ipairs(xml.all(mn, "Unit")) do
                merc.units[#merc.units + 1] = { code = u.attrs.id, number = num(u.attrs.number, 1), level = num(u.attrs.level, 1),
                                                name = u.attrs.name, text = xml.text(u) }
            end
            D.mercenaries[merc.id] = merc
        end
    end
    local nloc, nact = 0, 0
    for _ in pairs(D.locations) do nloc = nloc + 1 end
    for _ in pairs(D.actions) do nact = nact + 1 end
    log.info("campaign data: %d locations, %d actions, %d maps", nloc, nact, (function() local n = 0 for _ in pairs(D.maps) do n = n + 1 end return n end)())
    return D
end

return M
