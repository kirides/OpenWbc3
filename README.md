# openwbc3

An open-source re-implementation of the **Warlords Battlecry III** engine in Lua on
[LÖVE](https://love2d.org/) 12.0 (pre-release). It uses the data files of an original installation
(the GOG release) at runtime; no game assets are part of this repository.

Status: early, but playable skirmishes. What works so far:

- reading the original `.xcr` archives (including the encrypted entries), scenario
  (`.SCN`) files, unit/building type records, tile and sprite formats
- intro videos (after conversion, see below), original main menu built from
  `War4Int.xci` / `War4Gfx.xcg` with the game's TrueType fonts, theme and battle music
- skirmish battles on all shipped scenarios (set up in the skirmish screen):
  - terrain, features, buildings, side colours, animated units with the original
    movement timing, A* path finding, fog of war
  - melee and missile combat with the original hit/damage rules, missile sprites,
    combat/death/missile sounds, unit speech (select, order, ready)
  - economy: start with hero, builders and retinue; build a keep and the race's
    buildings (original construction stages), produce units and upgrades, convert
    mines and keeps with the hero, put workers into mines, income every 4 s,
    keep-level resource caps, army limit, standard victory/defeat
  - the original control panel (minimap, hero portrait, info area, command
    buttons, production queue), production/construction dialogs, resource and army
    counters and animated cursors
  - computer opponents that build, convert mines, produce, defend and attack

- heroes: experience and levels, attributes and skills (level-up dialog), items
  (equipment, backpack, chests and neutral drops), the hero dialog, a persistent player
  hero, optional hero resurrection (skirmish only), in-game menu and options
  (see `docs/hero.md`)

Save / load (battle menu, `L` in the main menu and scenario list) stores the whole skirmish; unit orders are not kept, units resume idle.

- spells: the 130 hero spells of 13 spheres with mana, spell points and a spell book (see `docs/spells.md`)

- garrisons: right-click an own tower or keep to put units inside (towers 4, keeps 8); they heal,
  garrisoned towers shoot harder and further, the garrison leaves through the command button

- combat results after a battle: the original statistics screen (hero, resources, units, buildings per player,
  bars relative to the best player; `src/game/battlestats.lua`, `src/screens/results.lua`)

- credits (options screen) from the original Credits.xml

- attitudes, order queue, patrol, guard

- diplomacy dialog (`Alt+D`): send resources to other sides

- repairs: damaged buildings can be repaired slowly or quickly for resources (`E`; not for Orcs), see `docs/hero.md`

- formations: groups march in a box, line, column or wedge (the `F` panel, `[` and `]` rotate) turned towards the
  target and at the speed of the slowest unit

- neutral sites: shrines and mausoleums with the original quests (Quest.cfg and Quest.xcr; send a hero,
  `!` = new quest, `?` = ready), shops (buy and sell items), lairs that breed guards until a hero
  converts them and then recruit their creatures

- scenario events: timers, areas, flags, counters; add/remove/give armies, resources, victory/defeat,
  day/night, storms, uncovering the map, sounds and messages (see `src/game/events.lua`; cutscenes are skipped)

- skirmish setup: map list with preview (skirmish and campaign maps), per-player race, resources, team and computer
  level, visibility (fog / explored / none), start at night, quests on/off, hero resurrection, army setup points
- hero selection (Single Player): several heroes with race, class and portrait, new / delete / details,
  load a saved game; your hero decides your race in a skirmish

- campaign: the original world-map campaign. Travel between the 42 locations of Etheria, visit them for
  battles, shops, mercenaries, retinue, training and news; ambushes on the roads, a journal, bonuses,
  diplomacy with the 16 races, hints and an item stash. All of it is read from the game's own campaign
  files (`Campaign.xcr`), see `src/game/campaigndata.lua`. Your hero keeps level, items and spells.

- multiplayer: host or join a game (LAN list, or an IPv4 / IPv6 address) with up to 6 players against each
  other or the computer. Deterministic lockstep: every player sends commands, the host merges them into
  turns, and all machines run the same simulation (checksums detect desyncs, a player that leaves is
  replaced by the computer). Transport is a small reliable-ordered UDP layer (`src/game/udp.lua`: connect
  handshake, acks, retransmits, fragmentation, IPv4 + IPv6, raw datagrams on the same socket for
  discovery and hole punching). LÖVE's bundled ENet is IPv4-only, hence the own layer. Quests, shops and
  save/load are single player only.

- scenario editor (main menu "Editor", built on the original editor bar): new / load / save scenarios (saved to
  `%APPDATA%\LOVE\openwbc3\scenarios`, listed in the skirmish setup as "(custom)"), terrain tiles (tree of
  all tile packs, big tiles, fill map), features, units and buildings per side (place, select and drag, delete;
  right click deletes), start locations, sides (race, team, computer level), options (name, fog, quests, hidden map,
  victory, heroes). Existing events and effects are kept; effects can be deleted, events can not be edited yet.
  Arrow keys / screen edges / minimap scroll, `Del` deletes the selection, `Ctrl+S` saves.

Options: volumes, scroll speed, full screen and vsync (stored in `openwbc3.ini`).

## Running

1. Get LÖVE 12.0 (codename "Bestest Friend"), which is not released yet, so you need a pre-release build.
   See the [LÖVE 12.0 wiki page](https://love2d.org/wiki/12.0) and the [LÖVE GitHub repository](https://github.com/love2d/love).
   Download either the work-in-progress [GitHub Actions builds](https://github.com/love2d/love/actions?query=branch%3Amain+event%3Apush)
   or the unofficial [nightly builds](https://nightly.link/love2d/love/workflows/main/main).
2. Have Warlords Battlecry III installed (GOG). The game folder is found through the GOG
   registry key or common install paths; otherwise pass it explicitly:

   ```
   love game --data "D:\GOG Games\Warlords Battlecry 3"
   ```

   or put it into `openwbc3.ini` in the LÖVE save directory
   (`%APPDATA%\LOVE\openwbc3` on Windows):

   ```ini
   [game]
   dir=D:\GOG Games\Warlords Battlecry 3
   language=English
   customfont=Segoe UI
   ```

   `customfont` (optional) replaces the game's interface fonts by an installed system font or a font file: a font name as
   shown in the system's font list, a file name (`arial.ttf`) or a full path.

3. Optional: convert the videos (see below) so the intro and campaign videos play.

Useful command line options (after `love game`):

| option | effect |
|---|---|
| `--data <dir>` | original game folder |
| `--lang <English\|German>` | language folder to use |
| `--skip-intro` | start at the main menu |
| `--scenario <name>` | start a battle directly, e.g. `--scenario Bridges` |
| `--load <slot>` | continue a saved game (1-8) |
| `--demo` | in a battle: send the player's army at the nearest enemy, camera follows |
| `--at <s> "<lua>"` | run Lua in a battle after `s` seconds (`S` = screen, `W` = world) |
| `--shot <file.png> --after <s>` | save a screenshot after `s` seconds and quit |
| `--selftest` | headless checks of the archive/scenario readers |
| `--selftest --sim <name> [ai]` | headless battle simulation (`ai`: all sides computer, 10 min) |
| `--selftest --sim all` | 2-minute all-AI run on every scenario |
| `--selftest --ani CODE,...` | dump sprite animation records |

In battle (the keys are those of the original's `KeyMap.txt`):

| input | action |
|---|---|
| left click / drag | select (double click: all of that type on screen, shift: add) |
| right click | context order: move, attack, convert (hero on keys/mines), enter mine (builders), rally point (buildings) |
| `Shift` + order | queue the order behind the current ones; `Alt` + order: do it first, then resume |
| `Esc` | stop; `Shift+Esc` drops the last queued order, `End` all but the running one (cancels dialogs / modes first) |
| arrow keys, screen edges, minimap | scroll; mouse wheel zooms |
| `A` `V` `X` `P` `G` | attack, move, rally point, patrol (`Shift`: more points), guard a unit |
| `B` `W` `K` `E` `O` `Ctrl+C` | build, build walls (drag with the mouse to lay a wall), production dialog, repair, unload a garrison, convert |
| `S` `I` `Q` `H` `M` | spell book, inventory, quest report, healing potion, mana potion |
| `Ctrl+H` / `Shift+H` | select the hero / add or remove it from the selection |
| `F1`..`F8` | cast the hero's spells (click the optional spell bar, Options > Graphics; wheel pages) |
| `Tab`, `Shift+Tab`, `Ctrl+Tab` | cycle producing buildings (`Ctrl`: only units) |
| `.` | next idle builder |
| `Ctrl+A` `Ctrl+Z` `Ctrl+S` `Ctrl+T` | select all, all of the type, all on screen, all of the type on screen |
| `Ctrl+1..9` / `1..9` | store / recall groups |
| `` ` `` , `Space`, `Page Up` | centre on the selection; cycle back through recent events (attacks ...) |
| `R` / `Alt+H` / `Ctrl+N` | show the heroes' command radius; popup help None / Some / All; network statistics (ping, reliability) |
| `F` | formation panel of a group (then pick the formation) |
| `[` / `]` | rotate the formation of a group anticlockwise / clockwise |
| `Ctrl+D` | destroy the selection |
| `F12` | pause; `+` / `-` game speed |
| `Alt+S` `Alt+L` `Alt+R` `Alt+G` `Alt+O` `Alt+D` `Alt+V` | save, load, resign, menu, options, diplomacy, victory conditions |
| `F9` / `F10` | toggle fog of war / cell grid (debug) |

## Converting assets

LÖVE cannot play Bink video. `tools/convert.bat` (Windows) or `tools/convert.sh`
run the converter, which is part of the game code (`love game --convert`):

```
tools\convert.bat [--data <game dir>] [--ffmpeg <ffmpeg.exe>] [--audio] [--force]
```

- `Video/*.bik` → `game/converted/video/*.ogv` (Theora + Vorbis)
- `--audio`: every WAV inside the archives → `game/converted/sound/**.ogg` (Vorbis).
  This is optional; the engine plays the original WAVs directly from the archives.

It needs an ffmpeg build with `libtheora` and `libvorbis`. Some ffmpeg builds ship a
broken libtheora encoder that produces undecodable video; the converter checks
every video it writes, reports this and deletes the broken file. Existing `.ogv` files are
not re-checked or re-converted unless `--force` is given. Recent gyan.dev / BtbN builds work.

LÖVE has no Opus decoder, so audio is converted to Vorbis.

## Layout

```
game/                 the LÖVE game (main.lua, conf.lua)
  src/core/           binary reader, ini, logging, config, screen stack
  src/vfs/            .xcr archive reader and virtual file system
  src/formats/        BMP, sprite (.ani/.rle), scenario (.SCN), unit/building types
  src/ui/             XCI/XCG interface definitions, fonts, panels
  src/gfx/            sprite animation cache
  src/game/           terrain, world, units, path finding, fog, rules, AI
  src/screens/        intro video, main menu, hero selection, skirmish setup, battle
  src/tools/          converter, self tests
tools/                converter wrappers
docs/formats.md       file format notes
```

## License

The code in this repository is MIT licensed (see `LICENSE`). Warlords Battlecry III
and its data are © their respective owners and are not included; you need your own
copy of the game.

openwbc3 is an independent fan project. It is not affiliated with, endorsed by or
sponsored by the rights holders of Warlords Battlecry III. "Warlords Battlecry" is a
trademark of its owner and is used here only to say which game this engine runs.
