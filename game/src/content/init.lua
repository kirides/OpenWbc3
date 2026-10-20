-- The game's content registry (docs/data-driven): one registry holding every kind of content. Filled at start-up by
-- `src/content/loader.lua` (importers, base ruleset, mods), read by the engine through the kind handles:
--   local content = require("src.content")
--   content.unit["AHBX"]    content.race:all()    content.setting:value("xp.table")
-- Stage 1 (this file): the registry, patch API, hash and dump exist; no gameplay data lives in it yet.
local registry = require("src.content.registry")

-- The kinds of the game's registry with their record classes (src/content/kinds/*.lua). A mod chunk sees the same handles in its
-- `content` (docs/modding/luals/openwbc3-mod.lua).
---@class ContentKinds
---@field setting SettingKind
---@field resource ContentKind<ResourceRecord>
---@field race RaceKind
---@field tag ContentKind<TagRecord>
---@field unit ContentKind<UnitRecord>
---@field building ContentKind<BuildingRecord>
---@field powerup ContentKind<PowerupRecord>
---@field item ContentKind<ItemRecord>
---@field itemclass ContentKind<ItemClassRecord>
---@field itempower ContentKind<ItemPowerRecord>
---@field damagetype ContentKind<DamageTypeRecord>
---@field missile ContentKind<MissileRecord>
---@field status ContentKind<StatusRecord>
---@field sphere ContentKind<SphereRecord>
---@field spell ContentKind<SpellRecord>
---@field skill ContentKind<SkillRecord>
---@field class ContentKind<ClassRecord>
---@field ability ContentKind<AbilityRecord>
---@field attitude ContentKind<AttitudeRecord>
---@field victory ContentKind<VictoryRecord>
---@field lair ContentKind<LairRecord>
---@field aiprofile ContentKind<AiProfileRecord>

-- The two kinds with methods of their own. LuaLS does not carry the record type into a subclass of the generic `ContentKind`, so
-- the methods these kinds are used with restate it (and the fields, which the subclass's index would hide).
---@class SettingKind: ContentKind<SettingRecord>
---@field [string] SettingRecord
---@field name string
---@field def ContentKindDef
---@field cache table<string, any>
---@field _recs table<string, SettingRecord>
---@field get fun(self: SettingKind, id: string): SettingRecord?
---@field require fun(self: SettingKind, id: string, who: string?): SettingRecord
---@field all fun(self: SettingKind): SettingRecord[]
---@field add fun(self: SettingKind, rec: SettingRecord): SettingRecord
---@field value fun(self: SettingKind, id: string, default: any?): any

---@class RaceKind: ContentKind<RaceRecord>
---@field [string|number] RaceRecord
---@field name string
---@field def ContentKindDef
---@field cache table<string, any>
---@field _recs table<string, RaceRecord>
---@field _list RaceRecord[]
---@field get fun(self: RaceKind, id: string): RaceRecord?
---@field require fun(self: RaceKind, id: string, who: string?): RaceRecord
---@field all fun(self: RaceKind): RaceRecord[]
---@field each fun(self: RaceKind, pred: (fun(rec: RaceRecord): any)?): fun(): integer, RaceRecord
---@field bySlot fun(self: RaceKind, n: integer): RaceRecord?
---@field add fun(self: RaceKind, rec: RaceRecord): RaceRecord
---@field replace fun(self: RaceKind, rec: RaceRecord): RaceRecord
---@field playable fun(self: RaceKind): RaceRecord[]
---@field byWord fun(self: RaceKind, word: string): RaceRecord?
---@field byTowerLetter fun(self: RaceKind, letter: string): RaceRecord?
---@field slotOf fun(self: RaceKind, id: string): integer
---@field byLetter fun(self: RaceKind, l: string): RaceRecord?

-- The game's registry: the registry API plus the kinds.
---@class Content: ContentKinds, ContentRegistry
local R = registry.new()

-- The kinds, in the order they are hashed and dumped.
local KINDS = {
    "setting", "resource", "race", "tag", "unit", "building", "powerup", "item", "itemclass", "itempower", "damagetype", "missile", "status",
    "sphere", "spell", "skill", "class", "ability", "attitude", "victory", "lair", "aiprofile",
}
for _, name in ipairs(KINDS) do R.defineKind(require("src.content.kinds." .. name)) end

-- Setting accessor: the value of a `setting` record (default when the setting does not exist).
local settingKind = R.setting
function settingKind:value(id, default)
    local rec = self._recs[id]
    if rec == nil then return default end
    return rec.value
end

-- The unit, building or power-up record of a code (the three kinds share one code space: A.., B.., P.. / R..), and the
-- kind it came from. Mod ids ("modid:name") are searched in all three.
local THINGS = { A = "unit", B = "building", P = "powerup", R = "powerup" }
local ORDER = { "unit", "building", "powerup" }
---@param id string
---@return (UnitRecord|BuildingRecord|PowerupRecord)? rec
---@return string? kind
function R.thing(id)
    local first = THINGS[id:sub(1, 1)]
    if first then
        local rec = R[first]._recs[id]
        if rec then return rec, first end
    end
    for _, name in ipairs(ORDER) do
        local rec = R[name]._recs[id]
        if rec then return rec, name end
    end
end

-- The races a setup screen offers, in slot order.
function R.race:playable()
    local list = self.cache.playable
    if not list then
        list = {}
        for _, rec in ipairs(self._list) do
            if rec.playable ~= false then list[#list + 1] = rec end
        end
        table.sort(list, function(a, b) return a.slot < b.slot end)
        if self.cache.slot then self.cache.playable = list end     -- not before finalise
    end
    return list
end

-- The race a conversation script names by `word` ("knight", "highelf" ...).
function R.race:byWord(word)
    for _, rec in ipairs(self._list) do
        if rec.word == word then return rec end
    end
end

-- The race whose tower type is BWT<letter>.
function R.race:byTowerLetter(letter)
    for _, rec in ipairs(self._list) do
        if rec.towerLetter == letter then return rec end
    end
end

-- The slot of a race id (an error for an unknown id): for named lookups in rules code ("dwarf" -> 1).
function R.race:slotOf(id)
    local rec = self._recs[id]
    if not rec then error(("unknown race '%s'"):format(tostring(id)), 2) end
    return rec.slot
end

-- Race lookups: `R.race:bySlot(n)` (the one translation point between race numbers - scenarios, saves, sides - and race records) and
-- `R.race:view(path)` are the generic slot methods of every kind with slots; the lookups by letter, word and tower letter follow.
function R.race:byLetter(l)
    local idx = self.cache.letter
    if idx then return idx[l] end
    for _, rec in ipairs(self._list) do if rec.letter == l then return rec end end
end

return R
