# The content registry (modder's reference)

Everything that defines *what the game contains* lives in plain Lua tables in the **content registry**
(`game/src/content/`). The records for the original game are filled at start-up from your WBC3 install and from
openwbc3's own base ruleset; mods patch them before the first battle. This page is the API, the one stable promise.
The plan behind it is `docs/data-driven/`.

```lua
local content = require("src.content")      -- engine code; mods get `content` as a global (stage 6)
```

## Kinds and records

A *kind* is a set of records of one sort (`unit`, `race`, `spell` ...). A record is an ordinary table with a string
`id`. Original content keeps its 4-letter codes (`"AHBX"`), mod content uses `"modid:name"`.

```lua
content.unit["AHBX"]               -- the record (nil if absent); ids that equal an API name (`all`, `add` ...) need :get
content.unit:get(id)               -- the same
content.unit:require(id, who)      -- the record or error("unit 'x' is not defined (needed by <who>)")
content.unit:has(id)
content.unit:all()                 -- ordered array (read only), :ids(), :count()
for _, rec in content.unit:each(pred) do ... end
```

Reading is always allowed. Writing is allowed in the three load phases only (`define`, `patch`, `final`), never after
`finalise()`. Mods must not depend on *derived* fields (documented per kind), they do not exist before `finalise`.

## Writing

```lua
content.unit:add{ id = "mymod:shaman", ... }     -- error if the id exists
content.unit:replace(rec)                        -- replaces the whole record, keeps its position
content.unit:patch(id, table)                    -- merge, see below
content.unit:patch(id, function(rec) ... end)    -- mutate in place
content.unit:patch(pred, tableOrFn)              -- every record the predicate accepts (registry order); returns the count
content.unit:remove(id [, ifExists])             -- references to it are cleaned up at finalise
content.unit:alias(newId, existingId)            -- a second id for the same record (renames)
```

`add` takes ownership of the table; `content.clone(rec)` makes a deep copy to start a variant from.

### Patch semantics

| field in the record | value in the patch | result |
|---|---|---|
| scalar | scalar | replaced |
| map (table with keys) | map | merged field by field, recursively |
| array | array | replaced as a whole |
| array | operator table | list operators, below |
| any | `content.REMOVE` | the field is deleted |
| any | `function(old) return new end` | computed update |
| any | `content.value(v)` | `v` is assigned as is (use it to store a function or to replace a map) |

List operators (several in one table apply in this order): `replace = {...}`, `remove = {...}` (values, ids or
predicates), `insertBefore = { match = m, value = v }`, `insertAfter = { match = m, value = v }`, `prepend = {...}`,
`append = {...}`. Elements that are tables with an `id` are addressed by it (*keyed lists*: build lists, spell lists),
so a patch never depends on index positions. Patch tables are copied in.

```lua
content.unit:patch("AHBX", { hits = 99, cost = { gold = 90 }, tags = { append = { "mymod:brave" } } })
content.building:patch("BHKP", { produces = { human = { remove = { "AHBX" }, append = { { id = "mymod:shaman", level = "A" } } } } })
```

Helpers for use inside function patches: `content.append(list, v)`, `content.prepend`, `content.insertBefore(list, match, v)`,
`content.insertAfter`, `content.removeWhere(list, pred)`, `content.pairs(t)` (ordered iteration, use it instead of
`pairs` wherever the order can matter: multiplayer needs every peer to compute the same result).

## Phases and load order

```
 install importers  ->  base ruleset  ->  mods: define -> patch -> final  ->  finalise (resolve, derive, validate, freeze)
```

`define` adds records, `patch` changes existing ones, `final` is the last word. A mod error rolls that mod's changes
back and is reported; the game starts without the mod.

## Removal and references

`remove` leaves a tombstone; `finalise` deletes the list entries, map keys and soft references that point at the
removed id (a warning each) and reports every *hard* reference left (a race whose builder unit is gone) as an error that
names the referrer and the mod that removed the target. A reference to an id that never existed is an error for mods and
the base ruleset, a warning for data read from the install.

## Provenance

Every record remembers its layer (`wbc3`, `base`, `mod:<id>`), for mods file and line, and the layers that patched it:
`content.where("unit", "AHBX")`. Error messages quote it.

## Hash and dump

* `content.hash()` - 128-bit hex of the whole registry (kinds in order, records in order, keys sorted, numbers exact,
  functions by source). Equal content gives an equal hash on every machine, so peers can compare it in the lobby.
* `--content-report` prints the errors, warnings, record counts and the hash. `--dump-content [dir] [kind ...]` writes
  `<kind>.lua` files (sorted, readable, `return { ... }`) to `<save directory>/dump` or `dir`: *the* reference for what
  you can patch. The dump is derived from your install: do not redistribute it.

## Records of stage 2 so far

| kind | key | filled by | notes |
|---|---|---|---|
| `race` | `human`, `dwarf` ... | `content/base/races.lua` | `slot` (race number), `letter`, role `units`, `build`, hero creation data, `retinue`, ... (all the former arrays indexed 0..15; see `game/src/content/kinds/race.lua`) |
| `unit` | 4-letter code | `import/wbc3/units.lua` | the `.ARM` stat block + typed Army.cfg columns (`size`, `alignment`, `moveClass`, `planar`, `races` ...), `requires` / `priority` / `byRace` |
| `building` | 4-letter code | `import/wbc3/buildings.lua` | the `.BUI` stat block + typed Building.cfg columns, `produces = { ["*"] = list, [raceId] = list }`, `requires`, ... |
| `powerup` | 4-letter code | `content/base/powerups.lua` | `cost`, `time`, `bonus` list, `view`, `oneShot`, `mercenaries`, `runeSkill`, `questFoes` |
| `tag` | `dragon`, `critter` ... | `content/base/tags.lua` | traits of units / buildings: `from` (implied by typed fields) or listed in `tags`; derived `tagSet` |

| `item` | item number / `modid:name` | `import/wbc3/items.lua` | catalogue of Items.xml; `powers` name `itempower` records |
| `itemclass` | `Sword`, `Ring` ... | `content/base/items.lua` | row of Items.bmp, how many are worn |
| `itempower` | the type names of Items.xml | `content/base/items.lua` | what a power type does: `stat`, `damageType`, `resist`, `skill`, `text` |

| `sphere` | `healing`, ... | `content/base/spheres.lua` | `slot`, `skill` (casting skill), `colour`, `icon`; setting `spell.duration` |
| `spell` | `healing.0`, `troop.1`, `modid:name` | `content/base/spells.lua` | `slot`, `sphere`, `cost`, `ai`, `target`, `effect` (function or recipe), see `effects.md` |

| `status` | `poison`, `stun` ... | `content/base/statuses.lua` | timed unit effects: `stat`, `bonus`, `stats`, `tick`, `expire`, `resist` ... hooks |
| `damagetype` | `fire`, `slashing` ... | `content/base/damagetypes.lua` | `slot`, `spellSlot`, `element`, armour `classes` |
| `missile` | `EMA0` ... | `content/base/missiles.lua` | `flags`, `sprite`, `piercing`, `lightning` ramp |

| `resource` | `gold`, `metal`, `crystal`, `stone` | `content/base/rules.lua` | `letter`, `colour` |
| `setting` | `eco.startAmount`, `unit.stepTime` ... | `content/base/*.lua` | named rule numbers; read `content.setting:value(id)`; engine modules read them when they load, so a mod's values apply from the next start |

| `victory` | `standard`, `raze all` ... | `content/base/victory.lua` | `slot`, `alias`, `timer`, `running`, `defeat`, `setup`, `total`, `winners` hooks |

| `skill` | `Ferocity`, `Leech` ... | `content/base/skills.lua` | `slot`, `mul`, `base`, `help` |
| `class` | `Warrior`, `Healer` ... | `content/base/classes.lua` | `slot`, `broad`, `attrMod`, `life`, `lifePerLevel`, `armor`, `mana`, the five `skills` |

| `ability` | `cure`, `morphWight`, `slaveHorde` ... | `content/base/abilities.lua` | `kind` = `spell` (troop mana buttons), `morph`, `building`; `units`, `mana`, `icon`, `spell`, `order` ... |

`content.thing(code)` finds a unit, building or power-up record by code. `--dump-content unit building powerup race`
shows every field a mod may patch.
