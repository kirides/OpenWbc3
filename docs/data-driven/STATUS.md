# Status of the data-driven plan

As of 2026-10-14. The plan files describe the target; this file says what exists and what was left out on purpose.

| stage | state |
|---|---|
| 1 registry | done: kinds, phases, patch operators, finalise (references, slots, validation, derived data), hash, dump, snapshot / restore (`game/src/content/`, `docs/modding/registry.md`) |
| 2 entities | done: races, units, buildings, power-up costs and bonuses, items, tags; importers read the install (`src/import/wbc3/`), the engine-authored base is `game/content/base/` |
| 3 spells and effects | done: spheres, spells (recipes and functions, ~40 original spells as recipes), status records with hooks, damage types, missiles (`docs/modding/effects.md`) |
| 4 heroes, abilities, rules | done: classes and skills, abilities, victory conditions, resources and the economy / unit / fog settings, lairs, attitudes, AI level profiles |
| 5 assets | minimum done: `sprite` references on unit / building records, PNG sprite sets with team masks, the placeholder, `override/` (`docs/modding/assets.md`) |
| 6 mod runtime | done: folders, manifests, ordering, sandbox, rebuild without a failing mod, manager screen, content check in saves, lobby and lockstep |
| 7 verification | done: `tools/dev/golden.ps1` (rule data, spells, simulations), `tools/dev/guard.lua`, `tools/dev/guard-install.lua`, selftest checks per stage |

## Left as code on purpose

* **Power-up rules**: what a power-up does (the bonus rows are data; `game/src/game/powerups.lua` still holds the codes of the special ones).
* **Army abilities that need code** (drunkenness, fanaticism, sacrifice, the wisp merge) and `unitspecials.lua`.
* **Formations**: eight, tied to the eight interface buttons and to `formationdata.lua` (numbers read from the binary).
* **Quests and shops**: `quests.lua` (the quest kinds, name sets) and the shop rules in `sites.lua`.
* **Sounds, music, portraits, icons, terrain, text** are not references yet (`override/` replaces a file by name). The plan's `text` kind,
  localisation files and per-unit sound references were not started; their placeholders in the kind list were removed rather than left empty.
* **AI scripts**: `CustomAI/*.ai` stay binary files read by `aiparams.lua`; a Lua form of the same parameters was not added.
* Hero profiles do not remember the mod set they were made with; the Tough Towers rule is still a game option, not a setting.

## Known intentional behaviour change

The army spell buttons follow the original's ordering list (they used to follow the table order of the engine).

## Found on the way

The port of the lair production lists lost them for a while (a patch of a field that did not exist kept its `content.value` wrapper); fixed in the
commit that introduced `lair` records, the golden diff of that commit shows exactly the six lair buildings' `produces` lines.
