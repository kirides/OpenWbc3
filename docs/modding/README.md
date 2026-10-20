# Modding openwbc3

Everything that defines *what the game contains* - races, units, buildings, power-ups, items, spells and their effects, status effects,
hero classes and skills, abilities, victory rules, rule numbers - is a plain Lua record in the **content registry**. The records of the
original game are filled at start-up from your own WBC3 install and from openwbc3's engine-authored base ruleset
(`game/content/base/`); a **mod** is a folder of Lua files that adds, changes or removes records before the first battle. The
repository contains no original assets and a mod must not either: reference the install's art and text by id, ship only your own.

* `registry.md` - the API (`content.unit:patch`, list operators, phases, hash, dump): the one stable promise.
* `effects.md` - spells: records, the effect library `fx`, recipes.
* `kinds.md` - every kind of content and what a mod does with it.
* `assets.md` - art: sprite references, PNG sprite sets, `override/` to replace an original file.
* `examples/` - runnable mods: `balance-patch`, `new-unit`, `new-spell`, `new-race`. The self test loads them.
* `--dump-content` writes every record of the running game as readable Lua (`<save directory>/dump`): *the* reference for what you
  can patch.

## A mod in 15 lines

```
mods/shaman/
    mod.lua              the manifest
    data/shaman.lua      adds records (define phase)
    patch/units.lua      changes records that exist (patch phase)
    final/balance.lua    the last word (final phase)
```

```lua
-- mod.lua
return { id = "shaman", name = "Orc Shaman", version = "1.0", author = "me", api = 1 }

-- data/shaman.lua
local shaman = content.clone(content.unit["AOIX"])      -- start from an original unit
shaman.id, shaman.label = "shaman:shaman", "Shaman"      -- ids of a mod are "modid:name"
shaman.hits = shaman.hits + 20
content.unit:add(shaman)
content.unit:alias("MSHA", "shaman:shaman")             -- four letters for scenario files and the editor
```

Put the folder into `<save directory>/mods/` (on Windows `%APPDATA%\LOVE\openwbc3\mods\`), enable it in **Mods** (the link at the
bottom of the main menu) and restart. For development use `--mod <folder>` (repeatable) instead: the folder is loaded for that run
without being enabled, from anywhere on disk; `[mods] path=<dir>` of `openwbc3.ini` adds a folder that contains mod folders.

## The manifest

`mod.lua` returns a table (it is evaluated without any environment: no code runs at this point).

| field | |
|---|---|
| `id` | `[a-z][a-z0-9_]*`, unique; the namespace of every id the mod adds |
| `name`, `version`, `author`, `description` | shown in the manager |
| `api` | the content API version the mod was written for (1) |
| `requires` | `{ "openwbc3 >= 0.1" }` |
| `depends` | `{ "other_mod >= 2.0" }`: must be enabled and is loaded earlier |
| `after` | `{ "balance_mod" }`: only matters for the order when present |
| `conflicts` | `{ "other_mod" }`: the later of the two is left out |
| `scope` | `"gameplay"` (default) or `"cosmetic"`: art, sound and text only, no `data` / `patch` / `final` files, not part of the multiplayer check |
| `files` | `{ data = {...}, patch = {...}, final = {...} }`: explicit file order (default: sorted names) |

## Load order and phases

```
 install importers -> base ruleset -> mods: define -> patch -> final -> finalise (resolve references, derive, validate, freeze)
```

Every mod's `data/` files run first (they add records, the install's records exist), then every mod's `patch/` files, then `final/`.
Mods load in dependency order, ties by the order in the manager, then by id: every machine computes the same order. A Lua error in a
mod file drops that mod as a whole (the registry is rebuilt without it) and names the file and line; the game starts without it.
`--check-mod <folder>` loads only that mod, prints the errors and warnings and the content hash, and exits 1 on errors (for CI).
`--mods-list` shows what was found.

## The sandbox

Mod files run in an environment that has `content` (the registry API and the kinds), `fx` (the effect library), `mod` (your manifest),
`asset` (builders for art references, see `assets.md`), `include("lib/file.lua")` (run another file of the mod in the same environment), `print` (to the log), and copies of `math` (without
`randomseed`; `math.random` works inside the functions you store in records, not while the files load), `string`, `table`, `bit` and the
basic functions. There is no `io`, `os`, `require`, `package`, `debug`, `ffi`, `love`, `loadstring`, `getmetatable` or `_G`; a file that runs
longer than three seconds while loading is stopped. This prevents accidents and non-determinism (every peer must build identical
content, which is checked); it is **not** a defence against hostile code: mods run Lua, enable only what you trust.

For completion and checks in your editor, point the Lua language server (LuaLS) at `docs/modding/luals/openwbc3-mod.lua`: add its
folder and openwbc3's `game/src` to `workspace.library` of your mod's `.luarc.json`. It declares the sandbox globals with the record
classes of the registry (`UnitRecord`, `SpellRecord` ...), so `content.unit["AHFX"].hits` and `fx.each(c, ...)` are known and typos
are flagged.

## Slots

Races, spheres, hero skills, classes and victory conditions have a number that scenarios, saves and hero profiles store. Give a mod
record `slot = "auto"` and it gets the next free number, kept in `<save directory>/mods/slots.lua` and never given to another id, even
when the mod is gone. A spell without a `slot` takes `sphere.slot * 10 + index`.

## Saves, scenarios, multiplayer

* A save stores the mod set it was played with (ids, versions, a hash of the files). Loading it with another set is refused with the
  difference named. Saves from before mods count as made with the original content.
* A scenario file stores four-letter unit and building codes: give a mod unit an alias (`content.unit:alias("MSHA", "shaman:shaman")`) to
  place it in the editor. Race numbers 16 and up belong to mods.
* The lobby compares the content hash: a client with another mod set is refused with the difference named, and the lockstep checksum
  includes the content, so a difference that slipped through shows up as a desync at once, not as a mystery later.

## Verifying that nothing moved

`pwsh tools/dev/golden.ps1 -Baseline <commit> [-Spells] [-Quick]` compares the rule data of the engine (units, buildings, build lists,
power-ups, items, heroes, abilities, victory rules, 1080 spell casts, battle simulations) at a baseline commit and in the working tree.
It is how the registry was introduced without changing a single number of the game.
