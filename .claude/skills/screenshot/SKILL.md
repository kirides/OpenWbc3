---
name: screenshot
description: Capture and look at screenshots of openwbc3 running for real (battles, menus, setup screens, campaign map, in-battle dialogs, XCI panels), optionally after scripted actions. Use to verify visual or UI changes, to see what a screen currently looks like, or when asked for a screenshot / to show the game.
---

# Screenshots of openwbc3

The game saves a PNG and quits on its own with `--shot <file.png> --after <seconds>`. Run it through
`tools/dev/love.ps1` (repo root, timeout, log output), then **open the PNG with the Read tool** and
actually look at it. Save under `shots/` (gitignored; the wrapper creates the folder). The window is
1280×800 by default.

```powershell
pwsh tools/dev/love.ps1 -Timeout 60 -- <how to get there> --shot shots/<name>.png --after <s>
```

Then: `Read shots/<name>.png`. If the PNG is missing, read the log the wrapper printed (Lua error,
unknown scenario/screen, timeout).

## Getting to the right place

| target | arguments |
|---|---|
| main menu | `--skip-intro --shot shots/menu.png --after 2` |
| battle | `--scenario Bridges --shot shots/b.png --after 5` |
| battle with action | `--scenario Bridges --demo --after 20 --shot shots/b.png` (army attacks nearest enemy, camera follows) |
| battle + scripted state | `--scenario Bridges --at 1 "<lua>" [--at 3 "<lua>"] --shot shots/b.png --after 5` |
| a screen | `--show skirmish`, `--show heroselect`, `--show campaignmap`, `--show multiplayer`, `--show options` |
| a screen state | `--show <screen>:<sub>`, e.g. `skirmish:night` (starts a night battle), `heroselect:new`, `campaignmap:menu`, `campaignmap:location`, `campaignmap:moreinfo`, `campaignmap:action`, `campaignmap:fight`, `campaignmap:hint`, `campaignmap:diplomacy` |
| saved game | `--load <slot 1-8>` |
| original XCI panel | `--panel PNL_HEROINFO [--screen SCR_X] [--dump] --shot shots/p.png` (`--panel ?` lists names, `@<id>` draws an XCG bitmap; `--dump` prints the panel's items and positions) |

`--at <seconds> "<lua>"` runs Lua in the battle with `S` = battle screen
(`game/src/screens/battle.lua`) and `W` = world (`game/src/game/world.lua`); `print` goes to the log.
Useful snippets:

- dialogs: `S:openHero(1)` (tabs 1-3), `S:openSpells()`, `S:openMenu()`,
  `require('src.core.screens').push(require('src.screens.saveslots'), 'save', S)`
- camera: `S:centreOn(x, y)` (pixels), `S.zoom = 0.5`
- state: `W.sides[0].gold = 5000`, `W.night = true`, `S.fog.enabled = false`
- select / order: `S:select({W.eco:heroAlive(W.player)})`, `S:issue({t='move', moves={{id, gx, gy}}})`
  (command formats are listed at the top of `game/src/game/commands.lua`)
- inspect: `for _, u in ipairs(W.units) do if u.side == 0 then print(u.code, u.gx, u.gy, u.hp) end end`

Make `--after` larger than the last `--at` time plus a second for the result to draw.
Timing is wall-clock seconds; the battle runs at real speed.

## Tips

- Compare before/after: shoot the same arguments before and after a change (`shots/x_before.png`,
  `shots/x_after.png`) and read both.
- If a new screen or dialog has states that are hard to reach, give the screen a `S:dev(sub)` method
  (see `skirmish.lua`, `campaignmap.lua`) so `--show screen:sub` can open them.
- `--panel` screenshots are taken on the third frame; other modes after `--after` seconds (default 3).
- Several screenshots can run in parallel only if they don't share a save slot or hero profile.
