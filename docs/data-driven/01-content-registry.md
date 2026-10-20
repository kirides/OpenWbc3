# Stage 1 - the content registry

Goal: one in-memory home for all game content, with a patch API and a loader, **before** any gameplay data moves.
Nothing in the game reads the registry yet; the stage is done when the registry can be filled, patched, validated,
hashed and dumped, and the tests prove it. Overview and principles: `README.md`.

## 1.1 Module layout

```
game/src/content/init.lua      public API (below)
game/src/content/kind.lua      kind definition helper: name, key field, field docs, validators, finalisers, order
game/src/content/patch.lua     deep merge, list operators, REMOVE sentinel
game/src/content/loader.lua    layers and phases, mod load order
game/src/content/sandbox.lua   restricted environments for mod chunks (stage 6 finishes it; stage 1 stubs it)
game/src/content/hash.lua      canonical serialisation + hash of the frozen registry
game/src/content/dump.lua      registry -> Lua source text (--dump-content)
game/src/content/kinds/*.lua   one file per kind, registered by init.lua (empty shells at first)
game/src/tools/contenttest.lua selftest checks (hooked through selftest.M.extra)
```

`core/serialize.lua` already encodes save data; `dump.lua` is separate because it must emit **readable, sorted, stable
Lua source** (modders read it).

## 1.2 Public API

```lua
local content = require("src.content")

-- kinds -------------------------------------------------------------------------------------
content.kind("unit")                       -- returns the kind handle (created by kinds/unit.lua at start-up)
content.unit                               -- shorthand: the kind handle is also content[kindName]

-- reading (engine and mods) -------------------------------------------------------------------
content.unit["AHBX"]                       -- record table (same as :get), nil if absent
content.unit:get(id)                       -- same; errors only with :require(id)
content.unit:require(id)                   -- record or error("unit 'x' not defined (needed by <who>)")
content.unit:all()                         -- ordered array of records (load order, then insertion order)
content.unit:ids()                         -- ordered array of ids
for _, rec in content.unit:each(pred) do end

-- writing (define / patch / final phases only) ---------------------------------------------------
content.unit:add{ id = "mymod:orc_shaman", ... }       -- error if id exists (use :replace)
content.unit:replace(rec)                              -- whole-record replace, keeps its position in :all()
content.unit:patch(id, tableOrFn)                      -- table = deep merge; fn(rec) mutates in place
content.unit:patch(pred, tableOrFn)                    -- every record the predicate accepts
content.unit:remove(id)                                -- also removes it from lists that reference it (see 1.5)
content.unit:alias(newId, existingId)                  -- second key for the same record (renames)

-- list-valued fields -----------------------------------------------------------------------------------
content.append(list, v)  content.insertBefore(list, match, v)  content.removeWhere(list, pred)
content.REMOVE                                         -- sentinel: field = content.REMOVE deletes the field

-- lifecycle (engine only) ----------------------------------------------------------------------------
content.begin()                            -- reset registry, open the "define" phase
content.phase("define"|"patch"|"final")    -- mods are loaded between phase switches (see loader)
content.finalise()                         -- resolve, derive, validate, freeze; returns report
content.hash()                             -- hex string, valid after finalise
content.report()                           -- { errors = {...}, warnings = {...} } with provenance
```

Rules:

- Records are **plain tables**. `finalise` may add derived fields; mods must not depend on derived fields in
  `define`/`patch` (they do not exist yet). Derived fields are documented per kind.
- Writing outside an open phase, or after `finalise`, is an error (dev: metatable on the kind handle; every
  record gets a `__newindex` guard only in `--dev-freeze` runs, to keep release hot paths free of metatables).
- **Provenance**: every record remembers its origin (`rec._src = { layer = "wbc3"|"base"|"mod:<id>", file, line }`
  via `debug.getinfo` in `add`) and a patch trail (`rec._patched = { "mod:x", "mod:y" }`). Errors name the mod and line.
- References between records are **strings** (ids) in `define`/`patch` and resolved in `finalise` into a parallel
  field (`unit.raceRef`) so that the public field stays a serialisable string. Dangling references are errors for
  mods and warnings for the original layer (missing install files must not break the game).

## 1.3 Kinds

Created empty in stage 1, filled by later stages. Each `kinds/<name>.lua` documents its record schema in a comment
block (field, type, meaning, default, "derived?"), registers validators and an `order` (sorted by `sort` field, else
insertion). Planned kinds and where they are specified:

| kind | key | stage | replaces |
|---|---|---|---|
| `resource` | `gold, metal, crystal, stone` | 4 | the literal lists in economy / quests / savegame / battlestats |
| `race` | `human`, ... | 2 | the 16 parallel race arrays |
| `unit`, `building` | 4-char code | 2 | `gamedata.army / building`, `rules.armyInfo`, `rules.buildingInfo` |
| `tag` | `dragon`, `critter`, `undead` ... | 2 | the code sets in `unit.lua`, `powerups.lua`, `economy.lua`, `spells.lua` |
| `buildlist` (per race, derived) | | 2 | `rules.construction / production / requires` |
| `powerup` | 4-char code | 2 | `powerupdata.lua`, rule tables of `powerups.lua` |
| `item`, `itemclass`, `itemset` | | 2 | `items.lua` tables |
| `damagetype`, `missile` | | 3 | numeric damage types, `MISSILE_SOUND`, `ELEMENT` |
| `status` | `poison`, ... | 3 | `status.lua` kinds |
| `sphere`, `spell` | | 3 | `spells.lua` |
| `skill`, `class`, `herolevel` | | 4 | `hero.lua`, `classes.lua`, `herobonus.lua` |
| `ability` | | 4 | `armyabilities.lua`, `buildingabilities.lua` |
| `attitude` | | 4 | `attitude.lua` |
| `victory` | | 4 | `victory.lua` |
| `site` | | 4 | `sites.lua`, `quests.lua` |
| `aiprofile` | | 4 | `ai.lua` tables |
| `terrain` | | 4/5 | `terrain.lua` |
| `sprite`, `sound`, `portrait`, `icon`, `text`, `music` | | 5 | `anims`, `audio/*`, `portraits`, `strings` |
| `setting` | | 4 | single-table constants (XP table, scroll rates, step times) |

Settings (scalar / array constants such as `STEP_TIME`, `XP_TABLE`, `VIEW_RADIUS`) are one kind `setting` keyed by
name, each record `{ id = "xp.table", value = {...} }`, patchable like any other.

## 1.4 Patch semantics (`patch.lua`)

For `patch(id, table)`:

- scalar field: replaced;
- table field: **merged recursively** (field-wise);
- array field: replaced as a whole, unless the patch value is an operator table:
  `{ append = {...} }`, `{ prepend = {...} }`, `{ remove = {...ids or values...} }`, `{ insertAfter = {match = x, value = y} }`,
  `{ replace = {...} }`;
- `content.REMOVE`: field deleted;
- function value: `fn(old) -> new` (computed update, e.g. `cost = function(c) return c * 2 end`).

Arrays whose elements have an `id` (build lists, spell lists) are treated as **keyed lists** by `append / remove /
insertAfter` so a mod does not depend on index positions.

`patch(pred, ...)` visits records in `:all()` order, so the result is deterministic.

## 1.5 Removal and referential integrity

`content.<kind>:remove(id)` records a tombstone; `finalise` then:

1. deletes list entries that point at the removed id (a building's production list, a race's build list, power-up
   requirements, a lair's spawn table, a spell's `summons`) and logs each as a warning with the origin of the
   removal;
2. reports every **hard** reference left (a race whose `hero` unit was removed) as an error naming the referrer.

Scenarios and saves that mention a removed id are handled in stage 6 (`missing = "drop" | "placeholder" | "refuse"`).

## 1.6 Hashing and dumping

- **Canonical serialisation**: kinds in registry order, records in `:all()` order, keys sorted, numbers with `%.17g`,
  functions as `fn:<sha of source text of the chunk and function range>` (source is kept for mod chunks; engine
  functions hash as `builtin:<name>@<version>`). Provenance fields are excluded.
- `content.hash()` = sha-1 or FNV-1a-128 of that stream (LuaJIT + `bit`, no external dependency; a small pure-Lua
  implementation in `hash.lua`). Mods add their manifest (id, version, file hashes) so file formatting changes also
  change the hash - deliberately, peers must have the same files.
- `--dump-content [dir] [kind...]`: writes `<dir>/<kind>.lua` containing `return { ... }` of the merged records, sorted,
  with a header "derived from your local WBC3 install - do not redistribute". Default dir
  `%APPDATA%\LOVE\openwbc3\dump\`. `/dump/` is gitignored. This is the modders' reference ("what can I patch?") and
  also the golden-master source of stage 7.

## 1.7 Work breakdown

1. `content/kind.lua`, `init.lua`: handle with `add/get/require/all/ids/each/patch/replace/remove/alias`, ordering,
   phases, provenance. Plain Lua, no `love.*`.
2. `patch.lua`: merge, operators, `REMOVE`, function values; keyed-list helpers.
3. `hash.lua` + `dump.lua`.
4. `loader.lua`: `loadLayer(name, fn)` (importer / base / mod), phase switching, error collection that never aborts
   half way (collect all errors, then decide: a broken mod is skipped as a whole, `base` errors are fatal).
5. Empty kind shells for every kind in 1.3 with their documentation blocks (so later stages only add content).
6. `boot.lua`: call `content.begin() ... content.finalise()` before `config.load` consumers need it; headless runs
   (`--selftest`, `--convert`) do not touch `love.graphics`, so the registry must not either.
7. CLI: `--dump-content`, `--content-report` (prints errors / warnings and the hash), `--mod <dir>` (collected, used
   from stage 6).
8. `tools/contenttest.lua` through `selftest.M.extra`: merge operators, keyed lists, removal cascade, hash stability
   (same input -> same hash; reorder keys -> same hash; change one value -> different), phase guards, provenance in
   error messages, dump round trip (`load(dump) == registry`).
9. `docs/formats.md` unaffected; add `docs/modding/registry.md` (the API above as the modder's reference) - the
   public API is the one stable promise, record schemas are documented per kind as their stages land.

## 1.8 Acceptance

- `pwsh tools/dev/love.ps1 -- --selftest` passes with the new checks; `--lua tools/dev/syntax.lua` compiles all files.
- `--dump-content` on an empty registry produces the empty shells; `--content-report` prints hash and no errors.
- No game behaviour change (`--selftest --sim Bridges` output unchanged), no new startup cost above 5 ms.
