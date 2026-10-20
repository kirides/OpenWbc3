---
name: game-data
description: Inspect the original Warlords Battlecry III data that openwbc3 reads at runtime - list and extract entries from the .xcr archives, dump sprite animation records, list and dump XCI interface panels, parse scenarios, run Lua probes against the mounted archives. Use when implementing or debugging something that depends on the game's files, formats, strings, configs or UI layout.
---

# Inspecting the original game data

The data lives in the GOG install (`B:\Spiele\GOG Games\Warlords Battlecry 3` on this machine;
`config.gamedir` at runtime). Loose files (`Scenario/*.SCN`, `CampaignScenario/`, `<Lang>/*.txt`,
`Music/`, `Video/*.bik`) can be read directly. Most data sits in `.xcr` archives, some entries
encrypted, so read those through the game's own VFS. Known format details are in
`docs/formats.md`; add to it when you learn something new.

All commands run from the repo root through `tools/dev/love.ps1` (headless, no window):

```powershell
# list archive entries: --ls [lua pattern on the lower-cased name [archive]]
pwsh tools/dev/love.ps1 -- --selftest --ls "%.cfg$"
pwsh tools/dev/love.ps1 -- --selftest --ls "" System.xcr
# extract one entry (decrypted) to a file, then Read it / inspect it
pwsh tools/dev/love.ps1 -- --selftest --dump Army.cfg shots/Army.cfg
# sprite animation records (.ani) and sheet sizes for unit/building codes
pwsh tools/dev/love.ps1 -- --selftest --ani ABBX,BWTB
# run a probe script with the archives mounted
pwsh tools/dev/love.ps1 -- --selftest --lua shots/probe.lua Bridges
```

Interface layout (needs a window, quits by itself with `--shot`):

```powershell
pwsh tools/dev/love.ps1 -Timeout 30 -- --panel ? --shot shots/none.png         # all PNL_* names
pwsh tools/dev/love.ps1 -Timeout 30 -- --panel PNL_HEROINFO --dump --shot shots/p.png
```

`--dump` prints every item of the panel: name, type/subtype, position, size, text id and source
bitmap rect. Read `shots/p.png` to see it.

## Probe scripts

`--lua <file> [args...]` runs the file after `vfs.init`; arguments arrive as `...`. Write probes
outside `game/` (e.g. `shots/probe.lua`; it's gitignored) and delete them when done. Graphics and
audio are not available.

```lua
local vfs = require("src.vfs.vfs")
local boot = require("src.game.boot")
local s = boot.loadScenario((...) or "Bridges")          -- parsed .SCN (src/formats/scn.lua)
print(s.header.name, s.width, s.height, #s.armies, #s.buildings, #s.events)
local cfg = vfs.read("System.xcr", "Building.cfg")       -- archive + entry (case-insensitive)
print(cfg:sub(1, 400))
local data, arch = vfs.find("ABBX.ani")                   -- search all archives
print(arch.key, #data)
local gd = require("src.game.gamedata")                  -- unit/building type records (.ARM/.BUI)
for k, v in pairs(gd.army("ABBX") or {}) do print(k, v) end
```

Useful modules: `src.vfs.vfs` (`read`, `find`, `exists`, `list`, `readFile`), `src.core.bin`
(little-endian reader), `src.core.ini`, `src.core.xml`, `src.core.text` (cp1252 → UTF-8),
`src.game.strings` (localised `[KEY]` string files), `src.game.rules` (race build lists, production),
`src.formats.*` (decoders). Check a module's header comment and exported functions before
using it; names above are the common entry points, not a full API.

## Citing the original

Describe formats and behaviour in your own words and cite the 1.04 binary (`FUN_` / `DAT_` addresses from
the headless Ghidra dump, `tools/dev/ghidra-dump.ps1`) or the data file you read.
