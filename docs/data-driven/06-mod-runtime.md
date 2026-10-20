# Stage 6 - mod runtime: folders, manifest, load order, sandbox, manager, saves, scenarios, multiplayer, editor

Prerequisite: stage 1 (loader). Pieces grow as stages 2-5 add kinds; the minimum viable version (6.1-6.4) can ship right
after stage 2 so mods can start using unit data early. Overview: `README.md`.

## 6.1 Mod folder and manifest

```
<userdata>/mods/<folder>/
    mod.lua            manifest (required)
    data/*.lua         define-stage files (return nothing; call content.<kind>:add{...})
    patch/*.lua        patch-stage files
    final/*.lua        final-stage files
    gfx/ sfx/ music/ lang/ override/   assets (stage 5)
    scenarios/ campaigns/              optional maps (scn files, see 6.6)
    README / LICENSE                   shown in the manager
```

`mod.lua` (a plain table, evaluated in an empty environment - no code runs at this point):

```lua
return {
  id = "orc_tweaks",                 -- [a-z0-9_]+, unique; also the namespace of every id the mod adds
  name = "Orc Tweaks", version = "1.2.0", author = "...", description = "...",
  api = 1,                           -- content API version (bumped on breaking changes, see 6.9)
  requires = { "openwbc3 >= 0.9" },  -- engine version range
  depends = { "base_pack >= 2.0" },  -- hard: must be present, loaded earlier
  after = { "balance_mod" },         -- soft: only affects order if present
  conflicts = { "other_orc_mod" },
  scope = "gameplay"|"cosmetic",     -- cosmetic mods (art, text, music) do not enter the multiplayer hash (6.7)
  files = { data = {...}, patch = {...}, final = {...} },   -- optional explicit order, default: sorted file names
}
```

Discovery scans `<userdata>/mods/*/mod.lua`, `--mod <dir>` (repeatable) and `[mods] path=` entries of
`openwbc3.ini`; a `.zip` mod is mounted read-only through LÖVE's `love.filesystem.mountFullPath` if the shipped LÖVE
12.0 provides it (otherwise folders only, stage-6 stretch).

## 6.2 Load order

1. Engine layers: `import/wbc3` (the install) -> `content/base`.
2. Enabled mods ordered by a topological sort over `depends` / `after`, ties broken alphabetically by id (never by
   file-system order), so that every machine computes the same order. The order is part of the saved mod list
   (`<userdata>/mods/enabled.lua`), edited by the manager, and the hash input.
3. Phases across **all** mods: every mod's `data/`, then every mod's `patch/`, then every mod's `final/`. Within a
   mod, files by the manifest or by sorted name. Errors: a Lua error in a mod chunk disables that mod, rolls its
   changes back (each mod's writes go through a journal, `content.begin/rollback(mod)`), and logs; the game starts
   without it and shows a warning on the main menu. A broken **dependency** disables dependants too.
4. `content.finalise()`; conflicts that remain (two mods claim the same `code` or slot) are reported with both mods'
   names and the later one is disabled.

## 6.3 The sandbox

Mod chunks run via `setfenv` in an environment built per mod:

- allowed: `math` (without `random`; `math.floor` etc. are fine), `string`, `table`, `pairs`, `ipairs`, `next`, `type`,
  `tostring`, `tonumber`, `select`, `pcall`, `error`, `assert`, `unpack`, `bit`, `print` (to the log, prefixed), the
  `content` API and the effect library `fx`, constants (`content.REMOVE`), `mod` (this mod's manifest and `mod.path`
  for `dofile`-style relative loading through a safe `include("file.lua")`);
- not available: `io`, `os`, `package`, `require`, `debug`, `ffi`, `love`, `loadstring` with arbitrary chunks (an
  `include` that only accepts files of the mod folder replaces it), `_G`, metatable access to engine tables
  (`getmetatable` / `setmetatable` only on tables the mod created);
- deterministic RNG only via `ctx.rng`; wall-clock sources do not exist;
- functions stored in records are re-`setfenv`'d to the same environment (so a spell effect cannot reach `io` later);
- runtime guards: instruction budget for chunk execution at load time (a debug hook count) and a per-call count
  inside effect functions in debug builds; effect functions are plain Lua at battle time for speed.

Decision D3 applies: this prevents accidents and non-determinism, it is not a hardening against malicious code. The
manager says so and states which mods run code.

## 6.4 Mod manager screen and dev CLI

- `screens/mods.lua` (kit-based like the setup screens): list with enable / disable, order arrows, dependency and
  conflict display, errors from the last load, `scope`, "restart required" notice (content is rebuilt at start-up and when
  leaving the screen; if a battle is running changes apply after it). Reached from the main menu / options.
- Dev CLI: `--mod <dir>`, `--no-mods`, `--content-report`, `--dump-content`, `--mods-list`, `--check-mod <dir>`
  (loads only the base plus that mod, prints the report, exit code != 0 on errors: for CI of mod authors).
- Dev hot reload: `--at <s> "content.reload()"` rebuilds the registry and respawns nothing (types are looked up by id,
  existing units keep their record reference until the battle ends; documented as dev only).

## 6.5 Saves and profiles

- `savegame.VERSION` is bumped. A save stores `content = { hash, mods = { {id, version, hash}... }, slots = {...} }`.
- Loading: identical mod list -> normal; different list -> the load dialog shows the difference and refuses (default) or
  offers "load anyway" for **cosmetic-only** differences. Reasoning: type records are looked up by id at load, and a
  gameplay difference can desync a unit's stats from its state.
- Stored ids: unit / building codes (already), power-up codes, spell **slots**, skill slots, class ids, race slots,
  status kinds (`u.fx`), ability ids. Each loader validates ids against the registry and applies the policy
  `missing = "refuse"` for saves, `"drop"` (with a log line) for hero **profiles** (a hero keeps working when a mod's spell
  is gone: the spell is removed from the hero, the skill points are returned).
- Hero profiles (`profile.lua`, campaign progress): the profile stores the ids and a `mods` list of the mods that
  created the hero's skills / class, shown in the hero select screen (grey with "requires mod X" when absent).
- Allocated slots (`mods/slots.lua`, stage 2) are exported with saves and profiles so another machine can
  re-allocate consistently.

## 6.6 Scenarios and campaigns

- Scenario files store 4-character codes and race numbers. Loader step: `code -> id` through the alias map; race
  numbers through `content.raceBySlot`. An unknown code applies the policy `missing`:
  `"drop"` (skip the object with a warning, default for user maps), `"placeholder"` (a flagged inert dummy for the editor)
  or `"refuse"` (scenario declares `requires` in a sidecar / header comment: not available in the original format, so
  the sidecar `<name>.scn.mods.lua` lists required mod ids, optional).
- Editor: palettes iterate `content.*` (stage 2.7); saving writes `code`; a mod unit without a `code` is greyed out in
  the editor and in `scnwrite`. The editor's "mods" dialog (`PNL_EDITOR_OPTION_MODS` equivalent) keeps listing the
  original game modifiers, plus a "mod set" field written to the sidecar.
- Events, `.act` / `.amb` / `.loc` campaign data are untouched by this plan; **campaigns by mods** use a `campaign` kind
  in a later iteration (they read `Campaign.xcr` today; the campaign loader is a separate refactor).
- Mod-owned maps (`scenarios/*.scn`) appear in the skirmish map list with a mod badge.

## 6.7 Multiplayer and determinism

- `content.hash()` (stage 1) includes every **gameplay** mod (manifest, order, file hashes) and the engine content
  version. `scope = "cosmetic"` mods are excluded from the hash but flagged in the lobby so players can see them.
- LAN lobby (`net.lua`, `mphost.lua`, `multiplayer.lua`): `net.VERSION` is joined by `contentHash` + a mod list in the
  host's broadcast (`info.mods`); the join screen shows a mismatch and which mods differ; the host refuses a client whose
  hash differs at connect time. `lockstep.lua` includes the content hash in the first tick's checksum frame.
- `world:hash()` mixes `content.hash()` once at the start, so a desync caused by content is caught immediately and
  logged as "content mismatch" rather than a mystery state divergence later.
- Every mod-reachable source of non-determinism is closed in 6.3. The remaining places that need a review before
  this stage: effect functions that iterate with `pairs` over keyed tables (the loader provides ordered iteration
  `content.pairs`), and visual effects (`w.effects`) which must not feed back into the simulation (the existing rule).
- `nettest` gets a two-process test with a deliberately different mod set expecting the clean refusal, and a same-set
  test over 5 minutes of AI vs AI.

## 6.8 Documentation and examples (shipped in the repo)

`docs/modding/`:

- `README.md` - getting started: folder, manifest, "hello unit" in 15 lines, how to dump the data.
- `registry.md` - the API of stage 1; `kinds/<kind>.md` - per-kind schema (generated from the kind shells' doc blocks by a
  small script so docs cannot drift).
- `effects.md` - `fx` / `ctx` / recipes (stage 3). `assets.md` - stage 5. `multiplayer.md` - 6.7.
- `examples/` - mod folders **with no original assets**: `balance-patch` (stat patch), `new-unit` (clone + PNG
  sprite generated by script), `new-spell`, `new-race` (reusing original building sprites by reference), `total-conversion`
  skeleton (removes all original races and adds one). They are part of the selftest (6.10).

## 6.9 Versioning

`api` is an integer; additive changes (new kinds, new fields with defaults) keep it; renamed / removed fields bump it. The
loader keeps a **compat shim** table (`content/compat.lua`) for one previous api version (field renames applied to mod
tables as they are `add`ed / `patch`ed, with a deprecation warning) so mods survive an engine update for a release.
The base ruleset has a `content.version` (string) hashed into saves.

## 6.10 Tests

- `contenttest`: example mods load and finalise; patch operators; rollback of a failing mod leaves the registry
  equal to the pre-mod state (hash compare); dependency and conflict handling; deterministic order (shuffle the
  file system listing by injecting a fake `fs.list`).
- Save round trip with a mod unit and spell (`--sim saveload` with `--mod examples/new-unit`).
- `--nettest` with matching and mismatching hashes (6.7).
- A sandbox escape smoke test: a mod chunk touching `io`, `os`, `require`, `love`, `ffi`, `debug`, `loadstring`, `_G`
  must fail with a clear error and not run partially.

## 6.11 Acceptance

A player drops the folder `new-race/` into `mods/`, enables it in the manager, picks the new race in the skirmish setup,
plays against the AI (which has an `aiprofile` for it), saves, quits, reloads; a friend with the same folder joins over LAN;
a friend without it is refused with the mod's name in the message.
