-- Content kind `race` (stage 2, docs/data-driven/02-entities.md 2.1): the races, replacing the parallel arrays indexed
-- 0..15. Key: a short name ("human", "dwarf" ... for the original sixteen; "modid:name" for mods).
--   slot       number stored in scenarios, saves and hero profiles (the original races are 0..15; new ones get a slot >= 16)
--   letter     the race letter of the install's config files (Building.cfg / Army.cfg columns and lines)
--   name       the singular English name (a fallback; the displayed name is read from the install's text, see nameLine)
--   plural     English plural used by the engine's own lists;  nameLine  line of <Lang>/WBC3HeroSelectionText.txt (34 + slot)
--   units      role units { hero, general, builder, titan, spectral, dragon }
--   build      what the race constructs: { { id, level, row } ... } (imported from Building.cfg [CONSTRUCTION])
--   powerupOrder   the picture order of the race's production list;  picture  name of its Powerups<picture>.bmp
--   attrMod, skills   hero attribute modifiers { str, dex, int, cha } and the five race skills { id, availableAt, startLevel }
--   towerLetter, wallSet   the race's tower type BWT<letter>; its wall set "good" | "neutral" | "evil"
--   portraits, voices, voicesAlt, avatars   what "Customize Your Hero" offers
--   retinue    { generals = { ten unit ids }, ai = { eight strings, one per army point value } }
--   alignment, mortal, word   the conversation scripts' tests
--   flags      { halvesMineWorkers, breedsInsects }
--   playable   offered in the setup screens (default true)
-- Lookups: `kind:bySlot(n)`, `byLetter(l)`, `byWord(w)`, `byTowerLetter(l)`, `playable()`, `slotOf(id)`, and
-- `kind:view("units.hero")`, a read-only table indexed by race number (the replacement of the old arrays 0..15).

---@class RaceUnits
---@field hero string
---@field general string
---@field builder string
---@field titan string
---@field spectral string
---@field dragon string

-- An entry of a race's construction list ([CONSTRUCTION] of Building.cfg).
---@class RaceBuildEntry
---@field id string
---@field level string
---@field row integer

---@class RaceRecord
---@field id string
---@field slot integer                  a mod race may give "auto" (the slot allocator replaces it when the record is added)
---@field letter string
---@field name string
---@field plural string?
---@field nameLine integer?
---@field units RaceUnits
---@field build RaceBuildEntry[]?
---@field powerupOrder string[]?
---@field picture string?
---@field attrMod integer[]             { str, dex, int, cha }
---@field skills integer[][]            five { skill id, available at level, start level }
---@field lordSkill integer?
---@field towerLetter string
---@field wallSet "good"|"neutral"|"evil"
---@field portraits integer[]
---@field voices integer[]
---@field voicesAlt integer[]
---@field avatars integer[]
---@field retinue { generals: string[], ai: string[] }
---@field alignment string
---@field mortal boolean?
---@field word string
---@field flags { halvesMineWorkers: boolean?, breedsInsects: boolean? }?
---@field playable boolean?

return {
    name = "race",
    doc = "races (slot, letter, names, roles, rules)",
    fields = {},
    ---@param rec RaceRecord
    validate = function(rec)
        if type(rec.slot) ~= "number" or rec.slot ~= math.floor(rec.slot) or rec.slot < 0 then return "needs a slot >= 0" end
        if type(rec.letter) ~= "string" or #rec.letter ~= 1 then return "needs a one-letter config letter" end
    end,
    slotted = true,
    ---@param kind ContentKind<RaceRecord>
    ---@param R ContentRegistry
    finalise = function(kind, R)
        local letters = {}
        for _, rec in ipairs(kind:all()) do
            if letters[rec.letter] then
                R.error("race '%s' (%s) uses letter %s of '%s'", rec.id, R.where(kind, rec.id), rec.letter, letters[rec.letter].id)
            else
                letters[rec.letter] = rec
            end
        end
        kind.cache.letter = letters
    end,
}
