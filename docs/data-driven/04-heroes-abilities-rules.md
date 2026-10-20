# Stage 4 - heroes, abilities, attitudes, victory, sites, AI, economy constants

Prerequisites: stages 1-3 (tags, spell and status records). The pieces are independent of each other; do them in the
order below, each with the golden-master check. Overview: `README.md`.

## 4.1 Hero skills, classes, levels

Today: `hero.lua` applies ~75 skills by numeric id (`h.skill[id]`, 12 `skill[...]` sites plus the item / attribute code),
`M.SKILL_EFFECT` is a 12-entry description table, `OLD_SKILL` maps old string keys to ids, `classes.lua` holds 28
classes, 4 broad groups, race modifiers, race skill lists and class skill lists, `hero.XP_TABLE`, `CONV_TIME`, the
attribute bonus formulas (`B`) and `herobonus.lua` the printed variants.

### Records

```lua
content.skill:add{
  id = "combat", slot = 1,                    -- the original ids (1..~95) stay as slots: profile / saves store them
  name = textref (Game.txt 760 + id - 1), desc = textref | nil,
  maxLevel = 10, icon = iconref,
  group = "attribute"|"combat"|"magic"|"economy"|"lord"|"slayer"...,
  effects = {                                  -- declarative where the original is a simple "+N per level"
     { stat = "combat", perLevel = 3 },        -- hero.SKILL_EFFECT strings become derivable text
     { hook = "lifeRegenPct", perLevel = 20 },
  },
  onLevel = fn(hero, level)?,                   -- for the rest
  requires = { skill = "combat", level = 3 } | nil,
}
content.class:add{ id = "Warrior", broad = "warrior", attrMod = {str=2,dex=0,int=-2,cha=0},
                   life = 240, lifePerLevel = 4, armour = 10, mana = 5, skills = { {skill=..., level=..., at=...} } }
content.broadclass ...                          -- the four picker groups (openwbc3's own, document as such)
content.setting "hero.xp", "hero.conversionTime", "hero.attribute.bonus" (formulas as small tables or functions)
```

Work:

1. Importer-side `base/skills.lua`: the id / slot list, names as string refs, level caps; `SKILL_EFFECT` becomes the
   effect list so `skillDesc` is generated; skills "without an effect" (list in `docs/missing.md`) have `effects = {}`
   and a `todo = true` flag (visible to modders: "this skill is wired to nothing yet").
2. The ~12 sites that read `h.skill[N]` switch to a lookup helper `hero:skillLevel("combat")`; the numeric lookup by
   `slot` remains for profile / save data. Every place that sums a side's skill like the original's per-side skill
   lookup `FUN_00556b50` becomes `content.skillEffect("lifeRegenPct")` over the effect kinds (shared with power-ups:
   one **effect-kind registry** `effectkind`, defined in stage 2).
3. `classes.lua` -> `class` + `race.attrMod / race.skills`; `hero.lua` `BASE_ATTR`, `XP_TABLE`, `CONV_TIME`, `B`
   (`life`, `speed`...) -> `setting` entries; the same formulas, in the same places, read from the setting.
4. `hero.lua M.ATTRS` (4 attributes str/dex/int/cha, `AI_ATTR`) stays 4 - attributes are structural (HUD layout,
   `herobonus`); the **bonus formulas** per attribute are data. Out of scope: adding attributes.
5. `herocustom.lua` portraits / voices / avatars -> `race.*` and `portrait` records (stage 5 supplies art).
6. Item slots (`hero.SLOT_LAYOUT`, `items.SLOTS`) -> `itemslot` records (class membership list, picture, name, count);
   `profile.lua` and saves store item ids and slot index; a removed slot drops the item to the pack with a log line.

## 4.2 Abilities

`armyabilities.lua` (army buttons) and `buildingabilities.lua` (tower / temple / keep abilities) combine data
(`MORPHS`, `ABILITIES`, costs, icons, required power-ups, `RACE` conditions) and the behaviour of each button
(drunkenness, fanaticism, sacrifice, merge wisps, rotate, wrath, ...).

```lua
content.ability:add{
  id = "morphWight", kind = "morph"|"spell"|"timedBuff"|"custom",
  name = textref, req = textref, icon = iconref (CPI index of the original panel icons),
  mana = 0, cost = { metal = 80 },
  for_ = { unit = "AUIX" } | { tag = "undead", race = "undead" } | { building = "BTxx" },
  needs = { buildings = { "BPDM" }, powerups = { "PDRU" } },
  order = 46,                                   -- button order (ABIL_ORDER)
  morph = { to = "AUJX", keepHpFraction = true },     -- data-only kind
  spell = "summoning.gateImp",                        -- data-only kind: reuse a spell (unitCast)
  buff = { status = "drunk", seconds = 120, cost = { gold = 10 } },   -- data-only kind
  run = fn(ctx),                                      -- kind = custom, uses fx
  ai = { ... },                                       -- how computer players use it
}
```

- `ABILITIES` + `ABIL_BY_CODE` + `ABIL_ORDER` move to `content/base/abilities.lua`; units reference abilities by id
  in `unit.abilities` (stage 2 field) instead of `addAbility(id, { codes... }, ...)` binding code lists.
- The Undead morph chain (`MORPHS`, `MORPH_ORDER`) is expressed with `kind = "morph"` and the AI's morph missions read
  the same records (the morph target lookup `FUN_004fd8c0`).
- `buildingabilities.lua` gets the same record with `for_ = { building = ... }`; the Wrath fireball `WRATH_OFFSETS` is a
  setting of that ability. The HUD builds buttons from `content.ability` filtered by selection, not from code lists.
- Button positions / icons come from the control panel icon indices (`hud.CPI`): `icon` accepts an `iconref` (stage 5), so
  mods bring their own icon.

## 4.3 Attitudes and AI

- `attitude` records: `id, order, name = textref, icon, rules = {...}`. The built-in attitudes are rule tables in the
  original (`FUN_00505cc0` for the wimp ...); `attitude.lua` now holds them as rule tables with one evaluator and loads the
  custom `.uai` files as additional entries (`docs/implemented.md` "Attitudes as a rule engine"). What is left: `LIST`, `TEXT`
  and the icon ids become records in a data file and `unit.attitude` indexes them, so that mods can write rules.
- `aiprofile`: `ai.lua` `TIME_BETWEEN`, `DELAY_FACTOR`, per-race build orders (`RACE.*` keyed code branches) become
  `aiprofile` records bound to races (`race.ai`) and difficulty levels; the CustomAI `.ai` loader (`aiparams.lua`)
  produces records of the same kind so a mod can ship an AI script as Lua instead of the binary `.ai` file.
  `docs/todo/ai-player.md` lists the original's missing pieces; they are added **as data first** (rates per level, group
  types) so the new systems arrive data-driven.

## 4.4 Victory conditions

`victory.lua`: `NAMES`, `ALIAS` (campaign data names), `TIMER`, `RUNNING`, `TITAN`.

```lua
content.victory:add{ id = "standard", slot = 0, name = textref, alias = { "kill armies" }, timer = 300,
                     running = false,                 -- "razefest", "slugfest", ... need ticking
                     check = fn(world, side) -> "won"|"lost"|nil,
                     setup = fn(world), onDestroyed = fn(world, b) ... }
```

Skirmish / editor / campaign pickers list `content.victory:all()`; the Titan-based victory reads `race.units.titan`.

## 4.5 Sites, lairs, quests

`sites.lua LAIRS` (breeding tables keyed by lair building code), shops (hatred, prices), shrines; `quests.lua`
(`PREFIX`, `TEMPLES`, `NAMESETS`, quest kinds). Records: `lair` (`building`, `min`, `max`, `boss`, `spawns`), `quest`
kind table, `nameset` (the 16 `.nam` naming sets: `id, file`). Unit references are ids, validated in `finalise`.
Quest *kinds* that need code (kind 4 / 8 not shipped) stay engine-side; a mod quest is `kind = "custom", run = fn`.

## 4.6 Economy constants and the resource list

`economy.lua`: `START_AMOUNT`, `MINE_PRODUCE`, `MINE_RESERVE`, `KEEP_AMOUNT`, `HORDE_AMOUNT`, `INCOME_AMOUNT`,
`ATTACK_INTERVAL`, `GIFT_*`, `REPAIR_SECONDS`, `RES_LETTER` and the `RESOURCES = {"gold","metal","crystal","stone"}`
repeated in `quests`, `savegame`, `battlestats`, `events`. All become `setting` records (arrays) plus one
`resource` kind (id, letter, icon, colour `hud.RES_RGB`, name). **Stage-4 scope**: every module iterates
`content.resource:all()` instead of re-declaring the list, with the same four entries. A mod adding a resource is not
a goal (HUD layout, scenario format and save layout assume four) but the single list is the prerequisite.

Same treatment for `fog.VIEW_RADIUS`, `gamedata.STEP_TIME`, `terrain` types / legality, `editorlib` colours,
`gameopts` rates, `hud` side colours (`SIDE_RGB`, `RES_RGB` -> `content.setting`). Rule: **a number that came from the
original** is a setting with a comment naming the origin (the existing comments move with it); **openwbc3's own** numbers
are settings flagged `own = true` so the dump shows which values are inventions.

## 4.7 Formations, hotkeys, UI tables

`formation.lua` KINDS / NAMES and its slot tables (`formationdata.lua`, generated from the binary) become `formation` records;
`keymap` defaults stay engine config (user-bindable, not game content). HUD colour and icon tables not tied to content
(`widgets`, `kit`) stay in code.

## 4.8 Acceptance

- A mod adds a hero class "Warden" (own attribute mods, a custom skill with a stat effect and one with a function
  hook) selectable in hero creation; saved heroes keep their class and skills across restarts.
- A mod adds an army ability (a timed buff with cost) to an existing unit through a patch and the button appears.
- A mod changes starting gold amounts and the mine yield through settings and the skirmish setup reflects them.
- `grep -rn "RES_LETTER\|RESOURCES = {" game/src` finds only the registry definition.
- Golden master for heroes (level 1..60 stats per race x class), economy (`--sim all`), victory rules unchanged.
