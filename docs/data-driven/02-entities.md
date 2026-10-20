# Stage 2 - races, units, buildings, power-ups, items

The largest behaviour-neutral move: the records the whole simulation reads. Prerequisite: stage 1. Overview:
`README.md`.

## 2.1 Races

Today a race is an index 0..15 plus a dozen parallel arrays (audit in `README.md` 2.2). New: a `race` record.

```lua
content.race:add{
  id = "human",                -- original races: human, dwarf, undead, barbarian, minotaur, orc, highelf, woodelf,
                               --   darkelf, fey, darkdwarf, daemon, empire, ssrathi, swarm, plaguelord
  slot = 0,                    -- number stored in scenarios / saves / profile heroes; 0..15 reserved, 16.. allocated
  letter = "H",                -- the race letter of Building.cfg / the config files ("H","D","U","B","M","O","E",...)
  name = text"orig:WBC3HeroSelectionText.txt#34",     -- string reference, see stage 5 (never the text itself)
  adjective, plural = ...,
  alignment = "good"|"neutral"|"evil",
  colour = {r,g,b},            -- replaces gamedata.COLORS use where a race (not a side) colour is meant
  units = {                    -- the roles the engine needs (all unit ids)
      hero = "AHHX", builder = "AHBX", titan = "ATHX", spectral = "AHKX", general = ...,
  },
  towerLetter = "C", wallSet = "good",                  -- raceVariant() of gamedata
  attrMod = { str = 0, dex = -1, int = 0, cha = 1 },    -- classes.RACE_MOD
  skills = { {67,1,1}, ... },                            -- classes.RACE_SKILLS (skill ids -> skill ids in stage 4)
  powerupPicture = "Knight",                            -- powerups.PICTURE
  avatars, voices, voiceSet, portraitSet = ...,        -- herocustom
  transform = { spell = "...", unit = "..." },         -- spells.TRANSFORM / DRAGON per race
  build = { ... },                                      -- derived in 2.4
  ai = "profile id",                                    -- stage 4
  flags = { halvesWorkers = false, ... },               -- economy.lua:737 `race == 6 or 7`, powerups `race == 14`
}
```

Tasks:

1. Importer `import/wbc3/races.lua`: the 16 records from the engine-authored table (race names and the numbers that
   are already facts in `classes.lua` / `economy.lua`), name strings as references into the install's text files.
   The numbers move out of the modules into `game/content/base/races.lua`; no text is copied.
2. Replace the arrays one by one, each in its own commit with the golden-master check (07): `economy.HERO/BUILDER`
   -> `race.units`; `victory.TITAN`; `herocustom.*`; `powerups.PICTURE`; `gamedata.RACES/COLORS` (keep `RACES` as
   a facade built from the records); `TOWER_LETTER / WALL_LETTER`; `classes.RACE_MOD / RACE_SKILLS`;
   `rules.RACE_LETTER`; the `RACE = {...}` tables of `ai`, `armyabilities`, `buildingabilities`, `conversation`
   become `content.race:get("dwarf").slot` lookups resolved once at module load (after `finalise`).
3. Replace every numeric race comparison (`side.race == 14`) with a **race flag or tag** (`race.flags.swarm`,
   `unit.tags.insect`). The three literal tests are `economy.lua:737`, `powerups.lua:130, 195`.
4. **Race slots beyond 15**: loops `for r = 0, 15` and the 16-column masks of `Building.cfg` become
   `for _, race in ipairs(content.race:all())`; masks become sets keyed by race id. `world.sides[i].race` stays the
   numeric slot; helper `content.raceBySlot(n)` is the one translation point. New slots are allocated and persisted
   in `<userdata>/mods/slots.lua` (`{ race = { ["mymod:goblin"] = 16 } }`) so scenarios keep meaning the same race;
   the allocation order is the load order **on first sight** and never reused.
5. UI that lists races (skirmish, hero select, editor, armysetup, campaign hero choice) iterates `content.race:all()`
   filtered by `race.playable` (true for the 15 original selectable ones - Empire is selectable only for a subset;
   the existing rule moves into the record as `selectable`).
6. Race removal (a mod that deletes Dark Dwarves): `race.playable = false` is the supported path; `remove` is valid but
   scenarios using it fall back per stage 6.

## 2.2 Units and buildings

### Record schema

The existing parsed `.ARM` / `.BUI` record is the schema's core; field names stay (`combat, speed, resistance, hits,
view, armor, strong, weak, damage, damageType, range, shape, psych, cost, powers, unitValue, setupPoints, fidget,
moveSound, combatSound, ambient, moveAmount, bones, attitude, fineTune, attackType, shadow, flags, speech, skin,
deathScream, buildTime, sideReq, moveType, fire, rubbleType` - see `formats/types.lua`). `Army.cfg` and `Building.cfg`
columns are merged **into the same record** (today they live in `rules.armyInfo` / `rules.buildingInfo`):

```lua
unit = {
  id = "AHBX", code = "AHBX",
  name = textref, help = textref (name/description/requirement/line1..3 from Help.cfg),
  -- from the .ARM record (unchanged names):
  combat = 8, hits = 30, ..., cost = { gold = 100, metal = 0, crystal = 0, stone = 0 },
  -- from Army.cfg, typed instead of a string:
  size = "small"|"medium"|"large"|"huge", alignment = "good"|"neutral"|"evil", race = "human" (id),
  planar = false, titan = false, moveClass = "land"|"air"|"float"|"sea", cavalry = false, infantry = true,
  advanced = false, missile = { type = "...", id = "EMA0" }, latency = n, ai = n,
  maxMana = n, startMana = n, hero = false, general = false,
  -- new:
  tags = { "builder", "insect" },       -- set of tag ids, becomes tagSet[tag] = true in finalise
  sprite = "AHBX" | spriteRef,          -- stage 5; default = the code
  sounds = {...},                       -- stage 5
  abilities = { "ability ids" },        -- stage 4 (morph chains, spell-like buttons)
  hooks = { onDeath = fn, onKill = fn, onHit = fn }   -- stage 3/4, replaces `code == "XXXX"` specials in unit.lua
  legacyStatus = "SGHLI...",            -- kept until the slicing sites are migrated, then removed
}
```

`building` adds `resource` (mine kind), `garrison`, `armyLimit`, `searchable`, `lair`, `shop`, `stopDefeat`, `produces`,
`requires`, `builds` (see 2.4), `missile`, `fire`, `rubbleType`, `tower = true|false`, `wall = true|false`.

### Importers

`import/wbc3/units.lua` / `buildings.lua`:

1. Enumerate codes: `Army.cfg [ARMIES]/[HEROES]` and `Building.cfg [BUILDINGS]` give the authoritative lists; the
   `.ARM` / `.BUI` files (PatchData first, then every archive, in `gamedata.lookup` order) give the stats. A code in the
   config without a record is a warning and a stub record flagged `missingStats`.
2. Parse eagerly at start-up (~480 small records; measure, expected < 30 ms) - patching needs the full set. Sprites stay
   lazy (stage 5).
3. Typed Army.cfg fields replace `status:sub(i,i)`; `legacyStatus` stays for the transition.
4. `[RULES]` (per-race overrides of cost / time / strength) become `unit.byRace = { dwarf = { cost = {...}, ... } }`
   so that a patch can address them; `rules.override(race, code)` becomes a facade.
5. `Tough Towers` (`gamedata.toughBuilding`) becomes a **game mod of the base layer** (`content.mod` flag set
   consulted by a `rulesets` hook), not a copy-with-multipliers function: the 16 tower records stay untouched and the
   engine applies the declared multipliers `rules.toughTowers = { damage = 3, ... }` (data in `base/rules.lua`).

### Tags (replacing literal code sets)

`tag` records are `{ id = "dragon", doc = "..." }`; units list them in `tags`. Original tags and where each comes from:

| tag | replaces |
|---|---|
| `dragon` | `unit.lua DRAGON`, `economy.lua NO_DRAGONS` (same list, two meanings: see `noDragons` below), `spells.lua DRAGON` |
| `critter` | `unit.lua CRITTER` |
| `daemon`, `insect`, `treant`, `knight`, `slayerKnight`, `assassin` | the `powerups.lua` sets |
| `noFlame`, `resistant`, `missileResistant` | `powerups.lua` `NOFLAME`, `RESISTANT`, `RESISTANT_MISSILE` |
| `noMine` | `unit.lua NO_MINE` (units that cannot work a mine) |
| `builder`, `worker` | `armysetup.lua` and `economy.lua` selection of "the race's builder" |
| `mechanical`, `evil`, `undead`, `planar`, `cavalry`, `infantry` | `spells.lua isMech/isEvil/...`; the last four come from the typed Army.cfg flags |
| `noFliers` (buildings) | `economy.lua NO_FLIERS` |
| `wall`, `tower`, `gate` | `gamedata.TOWER_CODES`, wall prefix checks (`code:sub(1,2) == "BW"`) |

Rule: **every literal 4-letter code in engine code becomes either a tag lookup or a registry lookup by role**
(`race.units.builder`). The remaining literals (about 120, concentrated in `armyabilities`, `spells`, `powerups`,
`buildingabilities`, `sites`) are enumerated by `grep -rnE '"(A|B|P)[A-Z0-9]{3}"'` and driven to zero by stages 2-4;
the guard in `07-verification-legal.md` fails the build if new literals appear outside `content/base`.

Special behaviours keyed on one code (`AWGX`, `ADBX`, `AOCX`, `AOMX`, `AAEY`) become **named unit behaviours**:
`unit.behaviour = { ... }` fields the engine understands (`fogRevealRate`, `conversionDivisor`, `ignoresCritters`),
documented in the kind schema. If a behaviour needs code, it is a `hooks` function written against the stage 3/4
primitive library.

## 2.3 Power-ups

`powerup` record (key = code):

```lua
{ id = "PAC0", name = textref, desc = textref, requirement = textref,
  cost = { gold=100, metal=100, crystal=0, stone=0 }, time = 45,       -- powerupdata.cost
  family = "PAC", level = 0,            -- levelled families (PCR0..4): "buy in order"
  race = { "human", ... } | nil,        -- which races' lists contain it (derived from Building.cfg production)
  picture = { set = "Knight", index = n },    -- powerupdata.order
  effects = {                           -- declarative effects replacing powerups.lua's per-code branches
     { stat = "combat", unit = tag/ids, amount = 2 }, -- bonus table of powerupdata
     { flag = "viewRange", value = 2 },
     { hook = "regen", percent = 20 },
  },
  pending = false,                      -- M.pending: offered at all?
}
```

Work: `powerupdata.lua` (generated) moves to `content/base/powerups.lua` with names kept as codes only (D1). The rule
branches in `powerups.lua` (`FLAG`, `VIEW`, `ARMOUR_STEP`, `COURAGE`, `PERCENT`, `unitResistance`, `damageType`,
`missileCode`, `crusadeXp`, `questXp` ...) are rewritten as **effect kinds** (a small registry `powerupeffect`:
`stat`, `statFlat`, `viewRange`, `regen`, `missileOverride`, `resistance`, `damageTypeOverride`, `incomeBonus`,
`xpBonus`, `buildSpeed`, `castingBonus` ...) each with a function the engine calls from the same places it calls
`powerups.*` today. `powerups.has / level / bonus / applyStats` stay as the engine API; they iterate the owned
records' effects instead of branching on codes. The pending / unimplemented set is a field (`unimplemented = true`).

## 2.4 Build lists and production

`rules.construction`, `rules.production`, `rules.requires`, `rules.priority`, `produces`, `startingForce` read
`Building.cfg`. New shape (derived from the importer, patchable directly):

```lua
race.build = { { id = "BHKP", level = "A", row = 0 }, ... }          -- who builds what, by race
building.produces[raceId] = { { id = "AHBX", level = "A" }, ... }    -- production list per building *per race*
building.requires[raceId]  = { "BHKP", ... }                          -- hard requirements
building.priority[raceId]  = n                                        -- AI wish
```

Keep `rules.buildList(race)`, `rules.produces(race, building)`, `rules.requirements`, `rules.startingForce` as facades
that read these fields. Keyed-list patch operators (stage 1) make `append`, `remove`, `insertAfter` possible.
The upgrade / dependency semantics of `[DEPENDENCIES]` (`E AEMX : RCIE`, runes unlocking units) are kept as
`requires`.

## 2.5 Items

`items.lua` already loads `Items.xml` into `M.list / byId`. Changes: records go into `item` / `itemclass` / `itemset`
kinds; `SLOTS`, `SLOT_COUNT`, `TIERS`, `DAMAGE_TYPES`, `ELEMENT`, `TEXT` (attribute text keys -> strings) become records
(`itemclass` = slot class with its picture row; stage 3 supplies `damagetype`); item **powers** (`<Power id type data>`)
become `{ effect = "statBonus", ... }` descriptors resolved through the same effect-kind registry as power-ups, so
a mod item may use any effect. Mod items reference their own picture through the asset layer (stage 5), as the
original's `Items.bmp` is a fixed atlas.

## 2.6 Facades and migration order

Within the stage, in this order (each step is shippable, each ends with the golden-master check):

1. `types` importer + `gamedata.army/building` read from the registry (identical records).
2. Typed Army.cfg / Building.cfg fields; `rules.armyInfo` facade; migrate the 34 `status:sub` sites.
3. Tags; replace the literal sets (`unit.lua`, `powerups.lua`, `economy.lua`, `spells.lua`, `victory.lua`).
4. Races (2.1) in the order listed there.
5. Build lists and production (2.4).
6. Power-ups (2.3).
7. Items (2.5).
8. Remove facades whose last caller is gone; keep the three public ones (`gamedata.army`, `rules.buildList`,
   `rules.produces`) as documented convenience functions.

## 2.7 Editor, scenario and AI knock-ons

- `rules.armyList()` / `buildingList()` (editor palettes) iterate the registry; hidden entries use `hideInEditor`.
- `scnwrite` writes `code`; `scn` reads `code -> id` through the alias map; unknown code handling is stage 6.
- `armysetup`, `ai` and `skirmish` choose starting forces by role (`race.units`, `race.startForce`), not by index.
- `startingForce(race)` derived logic stays but becomes overridable: `race.startForce = { keep, units }`.

## 2.8 Acceptance

- A mod patch file that sets `content.unit["AHBX"].hits = 99`, removes `PAC0` from every list, and adds a new unit
  `mymod:footman` (clone of `AHAX` with another cost and `sprite = "AHAX"`) appears in the HUD, builds, fights and saves.
- `--dump-content unit building race powerup` equals the pre-refactor `gamedata` / `rules` data (golden master).
- No literal unit code remains in `unit.lua`, `economy.lua`, `victory.lua`, `world.lua`, `hero.lua` (`grep` guard).
- `--selftest --sim all` result table (kills, time to victory per map) equals the pre-stage baseline.
