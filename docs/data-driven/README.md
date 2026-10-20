# Data-driven openwbc3: overview, audit and roadmap

Goal: everything that defines *what the game contains* (races, units, buildings, power-ups, items, spells and their
effects, status effects, hero classes and skills, abilities, attitudes, victory rules, sites, sprites, sounds, text)
lives in plain Lua tables in a **content registry** held in memory. The tables for the original game's data are
filled at start-up from the player's own WBC3 install (and from openwbc3's engine-authored defaults); **mods**, which
are plain Lua files, patch those tables before the first battle: add, replace, change or remove entries. The
repository never contains a copy of the original assets.

This directory is the plan. Read it in this order:

| doc | stage | what |
|---|---|---|
| `README.md` | - | this file: principles, current-state audit, target architecture, roadmap, decisions, risks |
| `01-content-registry.md` | 1 | registry, ids, record schema, patch API, load phases, validation, `--dump-content` (no gameplay change) |
| `02-entities.md` | 2 | races, units, buildings, power-ups, items, build lists: replaces `gamedata` / `rules` / the code-literal sets |
| `03-spells-effects.md` | 3 | spells, status effects, missiles, damage types, the effect primitive library |
| `04-heroes-abilities-rules.md` | 4 | hero classes / skills / XP, abilities, attitudes, victory, sites, AI tables, economy constants |
| `05-assets.md` | 5 | sprites, sounds, portraits, icons, strings, terrain: asset providers so a mod ships its *own* art |
| `06-mod-runtime.md` | 6 | mod folders, manifest, load order, sandbox, mod manager screen, saves, scenarios, multiplayer, editor |
| `07-verification-legal.md` | all | tests, golden-master parity checks, the "no original assets in the repo" guard, docs for modders |

The stages are ordered so that **the game stays playable and byte-for-byte equivalent in behaviour after every stage**
(the parity bar of `CLAUDE.md`: this is a refactor of *where data lives*, not of how the game plays). Each stage ends
with a golden-master check (`07-verification-legal.md`) proving that nothing moved.

## 1. Principles

1. **Registry first, behaviour unchanged.** Move data, do not change numbers or formulas. A faithful recreation stays
   the default ruleset; "improvements" are mods.
2. **Plain Lua, no schema compiler.** A record is an ordinary table. The engine reads fields directly in hot paths
   (`unit.lua`, `economy.lua`), as it does today with the `.ARM` records. No getter indirection per access.
3. **Original data is imported, never stored.** Importers (`src/import/wbc3/`) turn the install's files into records at
   start-up. Anything a mod adds ships in the mod folder and is the mod author's own work.
4. **Every id a mod can reference is stable and namespaced.** Original content keeps its 4-letter codes (`AHBX`);
   new content uses `modid:name`.
5. **Hard-coded behaviour becomes a field.** "Is this a dragon?" is `unit.tags.dragon`, not `DRAGON[code]` in
   `unit.lua`. "The Undead morph chain" is data on the unit, not a table in `armyabilities.lua`.
6. **Code in data is allowed but fenced.** Spell effects, abilities and AI behaviours need logic. They are Lua
   functions that receive a context object and may only call the engine's primitive library (`fx`, `ctx`), run in a
   restricted environment and use the deterministic RNG. Declarative recipes cover the common cases.
7. **Determinism is part of the contract.** All peers must hold byte-identical content. Content is hashed, the hash is
   exchanged in the lobby and mixed into `world:hash()`.
8. **Strangler migration.** `gamedata.army()`, `rules.*`, `spells.COST` ... stay as thin facades over the registry
   until the last caller is moved, so every step is shippable.

## 2. Current state (audit)

Measured on the repository at `50cacd8`. "Hard-coded" = a table or `if code == "XXXX"` inside engine code.

### 2.1 Already data-driven (read from the install at run time)

| data | source | module | notes |
|---|---|---|---|
| unit / building stat records (~210 `.ARM`, ~267 `.BUI`) | `.ARM`, `.BUI` (PatchData.xcr overrides) | `formats/types.lua`, `game/gamedata.lua` | lazy, cached per code in `gamedata.armies/buildings`; records are plain tables |
| build lists, production, requirements, per-race overrides, building info masks | `Building.cfg` | `game/rules.lua` | parsed with fixed columns, 16-race masks |
| unit status flags (size / alignment / race / planar / land-air / inf-cav) | `Army.cfg` | `rules.armyInfo` | kept as a **string** that callers slice (`status:sub(3,3) == "U"`, 34 sites) |
| items | `Items.xml` | `game/items.lua` | tiers, slots and attribute text are engine tables |
| strings | `*.txt`, `Help.cfg` | `game/strings.lua`, `core/text.lua` | keyed `[KEY]<tab>text`; language fallback to English |
| scenario / campaign data | `.scn`, `Campaign.xcr` | `formats/scn.lua`, `game/campaigndata.lua` | maps are content too, loaded by name |
| sprites, sounds, portraits, tiles | `.ani/.rle/.bmp`, `.wav`, `.ter` | `gfx/anims.lua`, `audio/*`, `game/terrain.lua` | looked up by 4-letter code through `vfs.find`, which searches **only** the original archives |
| custom AI scripts | `CustomAI/*.ai` | `game/aiparams.lua` | external files |

### 2.2 Hard-coded in the engine (what must move)

| area | where | what is hard-coded | target |
|---|---|---|---|
| **races** | `gamedata.RACES/COLORS`, `rules.RACE_LETTER`, `classes.RACE_MOD / RACE_SKILLS / FALLBACK_RACE_NAMES`, `economy.HERO / BUILDER`, `victory.TITAN`, `herocustom.AVATAR_CODES / VOICES / AVATARS`, `powerups.PICTURE`, `spells.SPECTRAL / DRAGON / TRANSFORM`, `gamedata.TOWER_LETTER / WALL_LETTER`, `ai.RACE`, `armyabilities.RACE`, `buildingabilities.RACE`, `conversation.RACES`, three `side.race == N` tests | 16 races as parallel arrays indexed 0..15, loops `for r = 0, 15`, masks of exactly 16 columns | `race` records (stage 2) |
| **unit traits** | `unit.lua` (`DRAGON`, `CRITTER`, `NO_MINE`, `code == "AWGX"`, `"ADBX"`, `"AOCX"`, `"AOMX"`, `"AAEY"` ...), `powerups.lua` (`DAEMONS`, `INSECTS`, `TREANTS`, `KNIGHTS`, `SLAYER_KNIGHT`, `NOFLAME`, `RESISTANT`, `ASSASSINS`, `RESISTANT_MISSILE`), `economy.lua` (`NO_DRAGONS`, `NO_FLIERS`), `spells.lua` (`isEvil / isPlanar / isCavalry / isUndead / isMech` slicing the status string) | ~25 code literals in sets plus ~120 4-letter literals in 20 files | `tags` + typed flags on `unit` / `building` records (stage 2) |
| **power-ups** | `powerupdata.lua` (generated: cost, time, list order, stat bonuses), `powerups.lua` (rules per code: `FLAG`, `VIEW`, `ARMOUR_STEP`, `COURAGE`, `PERCENT` ...) | rule logic keyed by `PAC0`-style codes | `powerup` records with `effects` (stage 2) |
| **economy constants** | `economy.lua` (`START_AMOUNT`, `MINE_*`, `KEEP_AMOUNT`, `HORDE_AMOUNT`, `INCOME_AMOUNT`, `ATTACK_INTERVAL`, `GIFT_*`, `REPAIR_SECONDS`, `RES_LETTER`), `quests.lua`, `battlestats.lua`, `savegame.lua` repeat the resource list | resources are the four literals `gold/metal/crystal/stone` in at least 8 modules | `rules` tables + a `resource` list (stage 4); see "out of scope" for adding a fifth resource |
| **spells** | `spells.lua`: `COST` (130), `DURATION`, `SPHERE_NAMES`, the `D[id]` table of 130 closures with shared local helpers (`each`, `hurt`, `summon`, `place`, `replace`, `revive`...), `SPECTRAL / DRAGON / TRANSFORM / CREATE_TIERS`; spell id = `sphere * 10 + index`, `COUNT = 130` | closures cannot be patched individually, ids are positional | `spell` + `sphere` records, effect primitives (stage 3) |
| **status effects** | `status.lua` (kinds as strings, `STAT`, `NEGATIVE`, behaviour spread through `unit.lua`) | which kinds exist and what they do per tick | `status` records with hooks (stage 3) |
| **missiles / damage types** | `unit.lua` (`MISSILE_SOUND`, `ELEMENT`, `SPELL_TYPE`, `HIT`), `items.lua` (`DAMAGE_TYPES`, `ELEMENT`), `hud.lua` (`PSYCH_ICONS`), `spells.lua` (`COL`) | damage types are 0-6 numbers with string names in 4 places | `damagetype` + `missile` records (stage 3) |
| **heroes** | `hero.lua` (`ATTRS`, `SKILL_EFFECT`, `SLOT_LAYOUT`, `XP_TABLE`, `CONV_TIME`, `OLD_SKILL`, `AI_ATTR`, ~75 skill ids applied by number), `classes.lua` (28 `CLASSES`, `BROAD`, `RACE_MOD`, `RACE_SKILLS`, `CLASS_SKILLS`), `herobonus.lua`, `herocustom.lua` | classes, skills, levels all positional / by name literal | `class`, `skill`, `xp` records (stage 4) |
| **abilities** | `armyabilities.lua` (`MORPHS`, `MORPH_ORDER`, `ABILITIES`, `ABIL_ORDER`, costs, `RACE`), `buildingabilities.lua` (`EFFECT`, `WRATH_OFFSETS`, `RACE`), `hud.lua` (`CPI` ids, `ACTION_ICON`, `COMMAND_TIPS`) | button list per unit derived from code literals | `ability` records bound to units / buildings (stage 4) |
| **attitudes** | `attitude.lua` (`LIST`, `TEXT`, rule bodies in code) | | `attitude` records, optionally rule tables (stage 4) |
| **victory** | `victory.lua` (`NAMES`, `ALIAS`, `TIMER`, `RUNNING`, `TITAN`) | | `victory` records with hook functions (stage 4) |
| **sites** | `sites.lua` (`LAIRS`, spawn tables by code), `quests.lua` (`PREFIX`, `TEMPLES`, `NAMESETS`) | | `site` / `lair` records (stage 4) |
| **AI** | `ai.lua` (`TIME_BETWEEN`, `DELAY_FACTOR`, per-race build orders keyed by `RACE.*`) | | `aiprofile` tables (stage 4) |
| **map / terrain** | `terrain.lua` (`TYPE`, `MOVE`, `LEGAL`, `SIZES`), `editorlib.lua` (`TERRAIN_RGB`, `SIDE_RGB`), `fog.lua` (`VIEW_RADIUS`), `gamedata.STEP_TIME` | | `terrain` / constants tables (stages 4-5) |
| **interface** | `hud.lua` / `spellbar.lua` / `widgets.lua` colour and icon tables, `keymap.lua` | mostly presentation | out of scope except icons and colours bound to content (stage 5) |
| **campaign** | `campaigndata.lua`, `campaignrun.lua`, `campaignstate.lua` read `Campaign.xcr` | | later: campaign registry (stage 6, optional) |

Totals that size the work: ~30 000 lines of Lua, 29 modules with embedded tables, 22 files with 4-letter code
literals (`armyabilities` 63, `powerupdata` 59, `powerups` 50, `spells` 48, `buildingabilities` 25, `sites` 18,
`armysetup` 17, `economy` 11 ...), 34 sites slicing the status string, 26 `armyInfo` and 29 `gamedata` callers,
~55 `rules.*` callers, ~38 direct `vfs.*` reads, ~40 `anims.*` calls, ~50 `strings.*` calls.

### 2.3 Structural obstacles

- **Race = number 0..15** baked into: array indices, 16-column masks in `Building.cfg`, loops `for r = 0, 15`, the
  scenario side record (`s.race = r:i16()`, wide enough), tower / wall letters, `RACE_LETTER`. Scenarios may contain
  race numbers of an installed mod, so new race numbers must be stable per install (allocated from 16 up in a
  persisted map, see stage 2).
- **Type lookup is by 4-char code** and the code is also the file name stem of sprites (`AHBX.ani`), so a mod type
  needs either a 4-char `code` or an explicit `sprite` reference. Scenario files and the editor store 4 chars.
- **Spell id = `sphere * 10 + index`**, `spells.COUNT = 130`, hero spell lists are bitsets / arrays by id, saves and
  `profile` heroes store spell ids. New spells need ids that never collide and a stable slot in a sphere.
- **Hero skills are numeric ids (1..~95)** applied through per-side skill lookups like the original's `FUN_00556b50`
  (`hero.skill[id]`); profile / saves store them.
- **`vfs.find` searches only original archives.** A mod asset needs a second root with precedence rules.
- **Closures in the spell table share file-local helpers**, so they cannot be moved out one by one until the helpers
  are exported as a library.
- **`powerupdata.lua` is "generated from the binary"** - numbers committed to the repo. See decision D1.
- Save games reference types by code and records by position; lockstep peers must agree on everything.

## 3. Target architecture

```
game/src/content/            registry core (stage 1)
    init.lua                 content.kind(...), get/all/add/patch/remove, finalise, freeze, hash
    kinds/<kind>.lua         one file per record kind: schema (field docs + validators), defaults, indices
    patch.lua                deep-merge / list operators / REMOVE sentinel
    loader.lua               phases define -> patch -> final, load order, dependency resolution
    sandbox.lua              restricted environments for mod code, fx / ctx API tables
    dump.lua                 --dump-content: write the merged registry as Lua (to the user dir, gitignored)
game/src/import/wbc3/        importers: install files -> registry (stage 2+)
    units.lua  buildings.lua  rules.lua (Building.cfg / Army.cfg)  items.lua  strings.lua  assets.lua ...
game/content/base/           engine-authored base ruleset, plain Lua, MIT (stage 2+)
    races.lua  skills.lua  spells/*.lua  statuses.lua  abilities.lua  rules.lua ...
game/src/mods/               mod discovery, manifest, mod manager data (stage 6)
%APPDATA%/LOVE/openwbc3/mods/<modid>/    user mods (also --mod <dir>, [mods] in openwbc3.ini)
```

### 3.1 Load pipeline (once, before the main menu; re-run on "apply mods")

```
 install files --importers--> registry (kind tables, "wbc3" layer)
 game/content/base ----------> registry (engine-authored layer: spell logic, class tables, rules)
 mods in load order:  define -> patch -> final   (data-stage model, like Factorio / Paradox mods)
 content.finalise():  resolve references, derive fields, build indices, validate, freeze, compute hash
```

- **define** - mods add new records (`content.unit:add{...}`) and read nothing.
- **patch** - mods change records that exist (`content.unit["AHBX"].hits = 60`, `content.spell:patch(id, fn)`).
- **final** - last word (balance mods that must come after everyone), still before `finalise`.
- `finalise` resolves string references (`race = "orc"` -> record), derives hot-path fields (race masks,
  `unit.tagSet`, `unit.cost`), checks dangling references, and **freezes** the registry (in dev builds a metatable
  raises on write; release builds trust the freeze).

### 3.2 Records and ids

- Key = `id` string. Original: the 4-char code (`"AHBX"`, `"BHKP"`) or a short name for newly modelled kinds
  (`race "human"`, `spell "healing.minor"`). Mod: `"modid:name"`.
- Optional `code` (<= 4 ASCII chars, upper case) = the alias scenario files and sprite file names use. Original ids
  have `code == id`. A mod that wants its unit in the editor / scenario files claims a unique `code`; conflicts are a
  load error. The editor writes `code`; the loader maps `code -> id`.
- Numeric ids that the original data fixes (race 0..15, spell 0..129, skill 1..95, damage type 0..6) stay as `slot`
  fields (`race.slot`); new records get slots from the persisted allocation table `mods/slots.lua` so scenarios and
  saves stay valid when mods are added or removed.

### 3.3 Hot-path compatibility

`gamedata.army(code)` becomes `content.unit[code]`; the record keeps today's field names (`hits`, `combat`, `cost.gold`,
`shape`, `psych`, `powers` ...), so `unit.lua` does not change in stage 2 except where a literal set is replaced by
`rec.tags.x`. Derived data (the parsed status string) is exposed as typed fields and the old string kept as `legacyStatus`
until the 34 slicing sites are gone.

## 4. Roadmap

```
Stage 1  registry core, patch API, loader, dump          (no importers yet; unit tests)
Stage 2  entities: race / unit / building / powerup / item   <- biggest behavioural-neutral move
Stage 3  spells / status / missile / damage types           (needs stage 2 for tags)
Stage 4  heroes, abilities, attitudes, victory, sites, AI, economy constants
Stage 5  asset providers + strings (can start after stage 1, in parallel with 2-4)
Stage 6  mod runtime: manager, saves, scenarios, multiplayer, editor   (needs 1; completes after 2-5)
Stage 7  verification / legal / docs run through every stage
```

Dependencies: 1 -> {2, 5}; 2 -> 3 -> 4; 5 independent after 1; 6 needs 1 and grows with each stage (each stage
adds its kind to the manifest hash, save references and the editor lists). Rough size (one developer, working
through the existing selftest / simtest loop): stage 1 small, stage 2 large, stage 3 large (130 spells), stage 4
large but mechanical, stage 5 medium, stage 6 medium.

**Milestones a modder can feel**

| after | a modder can |
|---|---|
| 1 | write a mod folder that is discovered, validated and dumped (no effect on the game yet) |
| 2 | change unit stats, costs, build lists; add a unit that reuses an original sprite; add / remove a race's building; rename things; remove units from the game |
| 3 | add a spell composed from primitives; retune any spell; add a status effect |
| 4 | add a hero class / skill, an army ability, a lair, change the AI's build pacing |
| 5 | bring new art and sounds (own PNG / OGG), localised text |
| 6 | enable / disable mods in a screen, play multiplayer and load saves with a verified mod set |

## 5. Decisions needed (with the recommended default)

- **D1 - Numbers extracted from the binary.** `powerupdata.lua`, the spell mana table, XP tables and the like are
  facts (numbers), derived by the project's own analysis, and already in the repository. They are not art, text or
  code of the original. Recommendation: keep them, but move them into `game/content/base/` so they are visibly "the
  base ruleset", never include names / descriptions / pictures / sounds / `.cfg` text, and add the repository guard of
  `07-verification-legal.md`. An alternative (runtime extraction from `WBC3.exe` into a user-dir cache) is possible
  but needs the binary parser to ship and is not recommended unless the legal position is questioned.
- **D2 - Where mods live.** `%APPDATA%\LOVE\openwbc3\mods\` plus `--mod <dir>` and `[mods]` in `openwbc3.ini`
  (LÖVE's sandbox cannot read arbitrary folders, `core/fs.lua` already reads the real filesystem).
- **D3 - Mod code trust.** Mods are code. The sandbox (no `io`, `os`, `ffi`, `love`, `require` of engine internals) is
  defence against accidents and against non-determinism, not a security boundary; the mod screen states this and
  mods are never auto-downloaded.
- **D4 - Sides stay 0..5 (+6 neutral)** and resources stay four by default. A mod-defined resource list is a stage 4
  stretch goal (see "out of scope").

## 6. Out of scope (first iteration)

Changing the number of sides, a fifth resource type (touches the HUD layout and the savegame; stage 4 keeps the
resource list in one place so it can follow), new terrain *movement* types, replacing the lockstep protocol, a
scripting API for the battle UI, in-game mod download. Each is noted where it would plug in.
