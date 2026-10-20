# Computer player: the original's production model, groups, towers, retreat, resignation

Priority: high for single-player feel, but the largest item here. Size: very large - do it in stages, each one
playable. Files: `game/ai.lua` (split into `game/ai/*.lua` once it grows: economy, groups, towers, hero),
`game/aiparams.lua` (already reads the `.ai` scripts), `game/economy.lua` (what the AI may pay / build).

Determinism: the AI runs inside the simulation on every peer - only the seeded random stream, no wall clock,
`ipairs` order. The original's AI runs on the owner's PC only and sends messages; openwbc3 runs it everywhere.

## What the original does
Anchors in the 1.04 binary: the computer player's think step `FUN_004fa120` (called round robin from `FUN_00505310`),
its virtual methods through the vtable at `0x005ea578`, the group system around `FUN_004f5610`, the special abilities
`FUN_005001d0`, the repairs `FUN_004fffe0`, the parameter files `FUN_004f7460` / `FUN_004f76d0` and the region danger
map `FUN_00509320` / `FUN_005095a0` / `FUN_00509840`. Functions are found through their constants, e.g. the order
interval factors 15000 / 10000 / 7000 / 5000 / 2500 / 1000 / 6000 of `FUN_004ff400` as immediates.

Think order (`FUN_004fa120`): on the first call remember the start location as main base and build the mine list
(`FUN_004fb550`); the side's threat pass (`FUN_00532530`); Passive returns; the main enemy (`FUN_004fa5b0`), the hero's
retreat (`FUN_004fc150`); Barbarian: best targets (`FUN_004fa990`); defence (`FUN_004fa380`); the unit list
(`FUN_004f9f80`); the missions in progress (`FUN_004f84a0(0)`); the building / army / power-up data (vtable +0xc
`0x004f8070`, +4 `0x004f7d80`, +8 `0x004f7f60`); unless Barbarian: keeps (`FUN_004fd7c0`), mines (`FUN_004fc280`), army
priority (`FUN_004fe180`), the tower location (`FUN_004f8fa0`), the buildings wanted (`FUN_004fc9a0`), the resource list
(vtable +0x1c, `FUN_004ff3b0`), groups (`FUN_004f5610`); every 15 s the times between builds (vtable +0x18,
`FUN_004ff470`) + palace conversions (`FUN_004fbb90`); new missions (`FUN_004f84a0(1)`); special abilities; repairs;
Barbarian: the attack (`FUN_004fa850`); AI resignation (`FUN_004fc5a0`; done: `advanced.shouldResign`,
`docs/implemented.md` "Advanced options").

1. **Production model ("time between builds")**: the AI keeps a resource list of wanted things (builders, defence,
   armies, power-ups, army research, power-up research, production buildings) with priorities (`FUN_004fb400` adds a
   node, `FUN_004fb100` sums the priorities; the army priority modifier is the empty routine `FUN_00485f30` in 1.04).
   Every 15 s `FUN_004fe300` turns, per resource type, the summed priorities, the mine income model and the level
   factor into a time between builds per item; an item is only started when its timestamp allows (`FUN_004f8600` /
   `FUN_004f8750`, already used for the morph missions) and the side can afford it (`FUN_004fb330`).
   `FUN_004ffab0(type)`: rates per AI level when the script's main production value is 0 - armies
   10 / 30 / 50 / 90 / 150 / 210 (Knave .. Emperor), power-ups 10 / 20 / 40 / 60 / 100 / 150, army research
   15 / 35 / 70 / 140 / 280 / 560, power-up research 10 / 35 / 70 / 140 / 280 / 560 (more types follow), otherwise
   from the `.ai` file. `FUN_004ffee0` and `FUN_004fc280`: income per owned mine by size (1 -> 2, 2 -> 4,
   3 -> 8, + Income power-up level; a dry mine 1), mines being converted counted separately, 4..8 gets +6 so one mine
   of a kind still sustains production, mines farther than 22 cells from every keep "need a keep".
   Decide early whether the AI keeps paying real resources (openwbc3 today) and only takes the timing / priority
   model, or follows the original exactly (check in the binary whether the AI's purchases deduct the side's
   resources - the affordability test `FUN_004fb330` suggests they do).
2. **Build order**: the script order `FUN_004fc7e0`, its shuffle `FUN_004fc8d0`, the buildings wanted `FUN_004fc9a0`,
   the multi-level buildings `FUN_004fcc10` (the keep-upgrade reset is not in the 1.04 binary), the automatic army /
   power-up build orders `FUN_004ff5f0` / `FUN_004ff790`, building categories (keep, army production, power-up
   production, tower, mine).
3. **Groups**: idle units are put into groups (`FUN_004f5700`, `FUN_004f59e0`) of a type (normal, long range, mine
   killer, kick-butt, large, generals, a type for weak units, conversion; the `.ai` file's custom groups are never
   created, see `not-in-original.md`); a group activates when full (`FUN_004f4bd0`, `FUN_004f3520`), picks a target
   side (`FUN_004f4e30`) and a target (`FUN_004f6530` / `FUN_004f66f0` with the priorities of `FUN_004f5e90`, threat
   assessment `FUN_004f3e70`, the region danger map), moves with a leader, regroups, converts, attacks
   buildings / towers / armies, recruits. Tower garrisons: `FUN_004f71e0` / `FUN_004f72e0`.
4. **Towers**: `FUN_004f8fa0` / `FUN_004f9400`: candidate points around the base and mines.
5. **Base relocation**: the base safety `FUN_004fbe80`, a new safe base location `FUN_004fc020` (the step that would
   move the base is not in the 1.04 binary).
6. **Hero**: `FUN_004fc150` - retreat when hurt, conversions (`FUN_004f8820`), palace conversions (`FUN_004fbb90` /
   `FUN_004fbc60`).
7. **Defence**: `FUN_004fa380` / the danger at a unit `FUN_004fac00` / damage bookkeeping `FUN_004fa580`.
8. **Save / load**: `FUN_004fb990` / `FUN_004fb730` - openwbc3 must save the new AI state too.

## Steps (each ends in a `--sim all` run that still finishes battles)
1. Instrument: a debug print / overlay of the AI's wish list (the original fills debug labels per group, `FUN_004f4f70`).
2. Production model (1) + build order (2) behind the current behaviour, compare AI strength by level in `--sim`.
3. Groups (3) replacing the current attack waves.
4. Towers, hero retreat, base relocation, palace conversions.
5. Save the AI state in savegames (`--sim saveload`).
6. Document every rule with its binary anchor in the `ai.lua` header and `docs/implemented.md`.

## Checks
`pwsh tools/dev/love.ps1 -Timeout 900 -- --selftest --sim all` after every stage; `multiplayer-test` for determinism
(`world:hash()` on both peers) once the AI touches new state.
