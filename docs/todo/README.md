# Implementation guides for the missing parity features

One guide per feature. Each says what the original does (with the Ghidra anchors in the 1.04 binary where found),
what openwbc3 has, the steps, and how to check the result. The list of open items itself is `docs/missing.md`;
finished work goes to `docs/implemented.md`. CLAUDE.md applies: verify numbers against the binary before using them,
label anything that could not be verified as openwbc3's own.

Ghidra note: the program open in Ghidra is "Battlecry III.exe" = `Battlecry III-orig.exe` in the GOG folder
(md5 d8d6debd538857fec26a133f483342da); it has no symbols, so find functions through strings and constants.

Reference screenshots of the original HUD are in this folder (`*.png`, used by `hud-info-area.md`).

## Suggested order
Rough value / effort; dependencies noted.

| # | guide | what | size | notes |
|---|---|---|---|---|
| 1 | ~~`rune-powerups.md`~~ | elven rune research, unlocks units | S | done, see `docs/implemented.md` |
| 2 | ~~`hud-info-area.md`~~ | building panels, "+bonus" stats, group boxes, resistance page | M | done, see `docs/implemented.md` |
| 3 | ~~`end-of-battle-xp.md`~~ | post-battle XP, victory screen lines, Ironman | M | done, see `docs/implemented.md` |
| 4 | ~~`hero-skill-effects.md`~~ | ~60 hero skills that do nothing yet | L | done, see `docs/hero.md` "Skill effects" |
| 5 | ~~`weather.md`~~ | weather states, storms, day / night / rain combat modifiers | M | done, see `docs/implemented.md` "Weather" |
| 6 | ~~`unit-specials.md`~~ | titan explosion, treant split, souls, sheep / cow ammo, eggs, damage overrides | M | done, see `docs/implemented.md` "Unit specials" |
| 7 | ~~`speech.md`~~ | the 22 missing announcer lines, unit order speech | M | done, see `docs/implemented.md` "System speech" |
| 8 | ~~`advanced-options.md`~~ | PNL_SS_ADVANCEDOPTIONS and its seven options + game speed | M | done, see `docs/implemented.md` "Advanced options" |
| 9 | ~~`research-mercenaries-knightsquest.md`~~ | PSPR / PARR, POMA-C, PQKN | S-M | done, see `docs/implemented.md` "Power-ups" |
| 10 | ~~`wall-building.md`~~ | Build Wall button, W, drag-built walls | S-M | done, see `docs/implemented.md` "Wall building" |
| 11 | ~~`retinue.md`~~ | retinue in all game types, recruiting, AI retinues | M-L | done, see `docs/implemented.md` "Retinue in every game type" |
| 12 | ~~`hotkeys.md`~~ | R command radius, Alt+H, Ctrl+N | S | done, see `docs/implemented.md` "Hot keys" |
| 13 | ~~`formation-tables.md`~~ | the original slot tables from the binary (VA 0x5FBC9C) | S | done, see `docs/implemented.md` "Formations" |
| 14 | ~~`skirmish-setup.md`~~ | side locks, produce heroes, handicap, PNL_SS screen | L | done, see `docs/implemented.md` "Skirmish setup rules" (the random map panel is done too, see "Random maps"; the message boxes are in `multiplayer-lobby.md`) |
| 15 | ~~`random-map.md`~~ | random map generator | L | done, see `docs/implemented.md` "Random maps" |
| 16 | ~~`ai-player.md`~~ | original AI production model, groups, towers, retreat | XL | done, see `docs/implemented.md` "Computer players" (`.ai` custom groups are not in the original, `not-in-original.md`; palace conversions done) |
| 17 | ~~`attitude-rules.md`~~ | rule engine, custom `.uai` attitudes, hit list | M | done, see `docs/implemented.md` "Attitudes as a rule engine" |
| 18 | ~~`multiplayer-lobby.md`~~ | lobby chat, hero names | S-M | done, see `docs/implemented.md` "Skirmish setup rules" (multiplayer lobby) |
| 19 | ~~`presentation-effects.md`~~ | decals, particles, lighting, menu effect, display options | M-L | done, see `docs/implemented.md` "Display and sound options"; leftovers in `docs/missing.md` "Presentation leftovers" |
| 20 | ~~`editor-events.md`~~ | event pool and event editing | L | done, see `docs/implemented.md` "Scenario editor: events" |
| 21 | ~~`editor-tools.md`~~ | selected-object dialogs, items, sides, mods | M | done, see `docs/implemented.md` "Scenario editor: objects, sides, options, items" |
| 22 | ~~`hero-security.md`~~ | passwords everywhere, delete confirmation, Ironman record | S | done, see `docs/implemented.md` "Hero security" |
| 23 | ~~`small-rule-gaps.md`~~ | plague piles, verifications, building ability leftovers, spell book polish | S each | done, see `docs/implemented.md` "Small rule gaps" |
| - | `not-in-original.md` | items closed without implementing (encounters, highscores ...) | - | every row confirmed, kept as the list |

## Working rules for every guide
- Simulation changes go through `commands.lua` and must stay deterministic (seeded random only, game time, `ipairs`).
- New state that lives in a battle is saved (`savegame.lua`, `--selftest --sim saveload`).
- Minimum checks after a change: syntax check, `--selftest`, plus what the guide lists (see the `selftest`,
  `screenshot`, `game-data` and `multiplayer-test` skills).
- Update `docs/missing.md` / `docs/implemented.md` (and `docs/formats.md` for file formats) with where every verified
  rule was checked (binary anchor or data file).
