# openwbc3 – notes for coding agents

A clean, MIT-licensed re-implementation of the **Warlords Battlecry III** engine in Lua on
LÖVE 12.0 pre-releases (unreleased, codename "Bestest Friend"; LuaJIT: Lua 5.1 + `ffi` + `bit`). The original game's data (GOG install) is read
at runtime; nothing of it is in this repository. `README.md` has the player-facing feature list
and controls; this file is the map for working on the code.

## Ground rules

- **Independent re-implementation.** The tree describes the original game's *behaviour* in its own words and
  cites the shipped 1.04 binary (`FUN_xxxxxxxx` / `DAT_xxxxxxxx` / `0x…` addresses) and the game's own data
  files. Never commit game assets (also no screenshots showing the original's art), extracted files or
  `game/converted/`. `tools/dev/guard.lua` enforces the patterns.
- Numbers the original data does not give (hero formulas, spell values …) are openwbc3's own.
  Say so in the module's header comment and document them in `docs/*.md` (`hero.md`, `spells.md`).
  Behaviour that is *not* original (e.g. hero resurrection) must be opt-in and labelled as such.
- **Stay a faithful recreation.** The goal is to behave like the original game, not to improve on it.
  Before implementing or changing any default value, rule, formula, timing, UI layout or behaviour,
  **verify it against the original**: the 1.04 game binary in Ghidra (preferably the headless dump of
  `tools/dev/ghidra-dump.ps1`: decompiled C per function plus every string with its referencing
  functions, greppable), the game's own data files (configs, `.xci`, `.ARM`/`.BUI`, strings), or by
  observing the original game. Don't guess or rely on memory of how the game "probably" works. Record what
  was verified (and where: the binary address, e.g. `FUN_0042ace0`, or the data file) in a short comment
  or in `docs/*.md`; if something could not be verified, say so there (`not traced in the 1.04 binary yet`)
  and keep it clearly labelled as openwbc3's own choice.
- Format knowledge goes into `docs/formats.md`.
- Don't commit unless asked; the user commits (short, lowercase subjects, e.g. `text alignment`).
- Use Git Bash for cli tooling. Unix tools are better supported for automation compared to Powershell.
- when comparing files, ignore whitespace format changes (e.g. CRLF -> LF)

## Running and checking (skills: `selftest`, `screenshot`, `game-data`, `multiplayer-test`)

Everything goes through `tools/dev/love.ps1`, which runs `lovec` (console LÖVE) on `game/` from
the repo root with a timeout (LÖVE's error screen waits for input forever) and prints the log:

```powershell
pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/syntax.lua   # compile every .lua (~1 s)
pwsh tools/dev/love.ps1 -- --selftest                               # archive/scenario readers (~1 s)
pwsh tools/dev/love.ps1 -- --selftest --sim Bridges                 # 1-min battle sim (~1 s)
pwsh tools/dev/love.ps1 -- --selftest --sim saveload                # save/load round trip (~4 s)
pwsh tools/dev/love.ps1 -- --nettest                                # UDP layer + lobby end to end on loopback (~15 s)
pwsh tools/dev/luals.ps1 [-Path game/src/ui] [-Summary]            # Lua language server check: must stay at 0 (~1 min)
cd server/lobby; go test ./...                                     # the lobby server (Go, docs/lobby.md)
pwsh tools/dev/love.ps1 -Timeout 900 -- --selftest --sim all        # 2-min all-AI run, 115 maps (minutes)
pwsh tools/dev/love.ps1 -Timeout 60 -- --scenario Bridges --shot shots/x.png --after 5   # screenshot
```

Then look at the PNG with the Read tool. `shots/` is gitignored. Options after `--` are passed to
the game unchanged; `-Timeout <s>` (default 120) and `-Tail <n>` go before `--`.

`--content-report` builds the content registry and prints errors, warnings and its hash; `--dump-content [dir] [kind ...]` writes
the merged records as Lua files (default `%APPDATA%\LOVE\openwbc3\dump`, never committed: derived from the install).

Minimum after a code change: the syntax check plus `--selftest`; add `--sim` for simulation
changes, `--sim saveload` when touching state that is saved, `--nettest` / a two-instance run for
network code, and a screenshot for anything visible. Headless runs (`--selftest`, `--convert`)
have no window, graphics or audio modules — code reached from them must not touch
`love.graphics` at require time.

Game *content* (units, buildings, races, power-ups, items, spells, statuses, hero classes and skills, abilities, victory rules, rule
numbers) is plain Lua records in the content registry (`game/src/content/`, base ruleset in `game/content/base/`, install importers in
`game/src/import/wbc3/`, mods in `docs/modding/`). Changes to those or to the facades that read them (`gamedata`, `rules`, `powerups`,
`items`, `classes`, `heroskills`, `spells`, `status`, `victory`) must not move behaviour: run
`pwsh tools/dev/golden.ps1 -Baseline <commit> [-Quick] [-Spells] [-Sims "Bridges"]` (rule data, items, heroes, abilities, victory battles,
power-ups, 1080 spell casts, simulations; output must say `identical`), and `--content-report` for errors and the content hash. Before a
commit that touches `game/content`, `docs` or fixtures: `--selftest --lua tools/dev/guard.lua` (static: no original assets or text
dumps, ratchet on 4-letter code literals) and, with the install present, `--selftest --lua tools/dev/guard-install.lua` (no line of the
install's text files in the tree).

Game data is found via `--data <dir>`, env `WBC3_DIR`, `[game] dir=` in `openwbc3.ini`, the GOG
registry key or common paths (here: `B:\Spiele\GOG Games\Warlords Battlecry 3`). User data
(settings, heroes, saves, campaign progress) lives in `%APPDATA%\LOVE\openwbc3`.

## Code map (`game/src/`)

| dir | what | key files |
|---|---|---|
| `content/` | the content registry: kinds of records, patch API, hash, dump, loader (`docs/data-driven/`, `docs/modding/registry.md`); the engine-authored data lives in `game/content/base/`, the importers of the install in `src/import/wbc3/` | `registry.lua`, `patch.lua`, `loader.lua`, `recipes.lua`, `kinds/*.lua` |
| `content/` | content registry: `registry.lua` (kinds, records, patch / finalise / hash), `kinds/*`, `loader.lua`, `mods.lua` (mod folders), `sandbox.lua`, `slots.lua`; base ruleset in `game/content/base/`, importers in `src/import/wbc3/`, asset layer in `src/assets/` | `init.lua` (`content.unit`, `content.spell` ...) |
| `core/` | infrastructure | `bin.lua` (LE reader over strings, FFI), `config.lua` (game dir, `openwbc3.ini`), `screens.lua` (screen stack), `ini.lua`, `xml.lua`, `serialize.lua` (save data), `text.lua` (cp1252→UTF-8), `fs.lua` (real FS outside LÖVE's sandbox), `log.lua` |
| `vfs/` | original archives | `xcr.lua` (`.xcr` incl. encrypted entries), `vfs.lua` (`read(archive, entry)`, `find(entry)`, `list(pattern)`) |
| `formats/` | file decoders | `scn.lua` (scenarios; keeps raw chunk bytes), `scnwrite.lua` (scenario writer for the editor), `evt.lua` (event records of `EVSH` and the `EVENTS/*.EVT` pool), `sprite.lua` (`.ani` + `.rle`/`.bmp`), `bmp.lua`, `types.lua` (`.ARM` units / `.BUI` buildings) |
| `gfx/` | rendering caches | `anims.lua` (sprite sets per code / side colour) |
| `game/` | simulation & rules | `world.lua` (battle world, `update`, events), `unit.lua` (movement, combat, orders), `economy.lua` (resources, mines, production, construction, victory), `ai.lua`, `path.lua` (A*), `fog.lua`, `terrain.lua`, `rules.lua` / `gamedata.lua` (race build lists, type records), `editorlib.lua` (editor model: tile catalogue, painting, objects, minimap, saving), `hero.lua`, `items.lua`, `spells.lua` (casting rules; the spells themselves are records in `content/base/spells.lua`, their helper library is `fx.lua`), `status.lua` (timed effects), `formation.lua`, `sites.lua` / `quests.lua` (lairs, shops, shrines), `events.lua` (scenario triggers), `savegame.lua`, `profile.lua` (player heroes), `campaign*.lua` (world-map campaign from `Campaign.xcr`), `commands.lua`, `lockstep.lua` / `net.lua` / `udp.lua` (multiplayer), `lobby.lua` (client of the internet lobby server), `boot.lua` (startup, dev CLI) |
| `ui/` | interface | `interface.lua` (XCI screens/panels on a scaled 800×600 virtual canvas), `xci.lua` (`War4Int.xci` / `War4Gfx.xcg` parser), `kit.lua` (immediate-mode widgets for setup screens), `hud.lua` (battle control panel), `fonts.lua`, `cursor.lua`, `spellbar.lua`, `portraits.lua`, `widgets.lua` |
| `screens/` | one module per screen | `battle.lua` (map view, input, drawing), `mainmenu`, `skirmish`, `heroselect`, `campaignmap`, `editor` + `editorevents` (scenario editor and its events dialogs, dev: `--show editor:demo|new|terrain|armies…`, `--at <s> "<lua>"` with `S:devClick(vx, vy, button)`), `multiplayer` / `mphost`, dialogs (`heroinfo`, `levelup`, `spellbook`, `shop`, `questdialog`, `gamemenu`, `options`, `saveslots`), `video`, `cutscene`, `panelview` (dev) |
| `audio/` | sound | `sound.lua` (WAVs from archives), `voices.lua` (unit speech), `music.lua` |
| `tools/` | CLI modes | `selftest.lua`, `simtest.lua`, `nettest.lua` + `lobbytest.lua`, `convert.lua` (BIK→Theora, WAV→Vorbis) |

Entry: `game/main.lua` dispatches `--convert` / `--selftest` / `--nettest`, otherwise
`config.load` → `boot.start(args)` which handles the dev options (`--panel`, `--show`, `--load`,
`--scenario`, `--skip-intro`).

## How things fit together

- **Screens** are tables `S` with optional `enter(...)`, `leave`, `resume`, `update`, `draw`
  and input callbacks; `screens.switch/push/pop`. `S.overlay = true` keeps the screen below drawn
  (dialogs over the battle). Dialogs get the battle screen as their first `enter` argument.
- **UI coordinates** are a virtual 800×600 canvas (`UI.begin()` / `UI.finish()` in
  `interface.lua`), scaled to the window. Original panels come from the XCI files (`UI.panel("PNL_…")`);
  hand-made screens use `kit.lua`.
- **Simulation**: `world:update(dt)` advances a millisecond clock (`world.time`); headless sims
  step `1/30`. `world.units`, `world.buildings`, `world.features`, `world.sides[0..6]` (6 = neutral),
  `world.eco` (economy), `world.player` (local side). Cells are `terrain.CELL_W × CELL_H`
  (32×24) pixels; `gx, gy` are cell coordinates, `x, y` pixels. `world:listen(fn(kind, a, b))`
  delivers game events to the battle screen.
- **Orders go through commands.** Every player action is a plain table applied by
  `commands.apply(world, cmd)`; the battle screen calls `S:issue(cmd)`, which in a network game
  routes it through lockstep instead. Never mutate world state directly from UI code.
- **Determinism (multiplayer)**: the simulation must give identical results on every peer.
  `math.random` is reseeded per tick in network games, so draw/UI code must not call it
  (use a hash of position/time instead, see `battle.lua` effects); no wall-clock time
  (`love.timer`, `os.time`) in simulation code; iterate arrays with `ipairs`, not `pairs`,
  where the order affects results. `world:hash()` is the checksum peers compare.
- **Data access**: archives via `vfs` (entry names are case-insensitive), loose files via
  `vfs.readFile` / `fs`. Unit/building types via `gamedata`, race rules via `rules`, localised
  strings via `strings` (texts are Windows-1252; convert with `core/text.lua`).

## Dev hooks to know

- `--scenario <name> [--demo] [--at <s> "<lua>"]…` starts a battle; `--at` code runs with
  `S` = battle screen and `W` = world after `s` seconds (use it to open dialogs, give orders,
  `print` state). Examples: `S:openHero(1)`, `S:openSpells()`, `S:openMenu()`,
  `S:centreOn(x, y)`, `W.sides[0].gold = 5000`.
- `--show <screen>[:<sub>]` pushes `src/screens/<screen>.lua` over the main menu and calls
  `screen:dev(sub)` if given (e.g. `skirmish:night`, `heroselect:new`, `campaignmap:menu`,
  `campaignmap:fight`, `mphost:auto`, `multiplayer:join`). Give new screens a `dev(sub)` method
  for states worth screenshotting.
- `--panel PNL_A[,PNL_B|@bitmapId] [--screen SCR_X] [--dump]` shows XCI panels; `--panel ?`
  lists all panel names.
- `--selftest --ls [pattern [archive]]`, `--dump <entry> <file>`, `--ani CODE,…`,
  `--lua <file> [args]` (run a Lua script with the archives mounted).
- `selftest.M.extra` is a list of extra check functions (return the number of failures).
- `F9` / `F10` in battle toggle fog / cell grid.

## Style

Match the surrounding code: 4-space indent, `local M = {}` modules (`local S = {}` for screens),
`require("src.dir.module")`, camelCase names, British spelling in names and comments
(`centreOn`, `colour`), lines up to ~120 characters. Every file starts with a comment saying what
it is and, for formats, the layout. Comments explain why and how the original behaves; keep them
sparse elsewhere. No external Lua dependencies beyond what LÖVE ships (LuaSocket, LuaJIT FFI).
Annotate for the Lua language server (`.luarc.json`): `---@class` with `---@field` for objects (fields other modules
set included; the core classes `World`, `Unit`, `Building`, `Side`, `Hero`, `Screen` ... are declared once, extend
them there), `---@param` / `---@return` on public functions, screens as `---@class XScreen: Screen`. Fix diagnostics
by making types true (casts only where the code knows more); `tools/dev/luals.ps1` must report 0. The mod API's
definitions for modders are in `docs/modding/luals/openwbc3-mod.lua`.

The internet lobby (`server/lobby/`, Go, standard library only) is a separate program; the game reaches it through
`[net] lobby=` in `openwbc3.ini` (`OPENWBC3_LOBBY` overrides it for dev runs: `--show mphost:autoonline` and
`--show multiplayer:online` play a game through a local server).
