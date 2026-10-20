---
name: selftest
description: Run openwbc3's headless self tests (Lua syntax check, archive/scenario readers, battle simulations, save/load round trip, UDP network tests) and read their results. Use after changing game code in game/src, before reporting work as done, or when asked to test / verify / check that nothing broke.
---

# openwbc3 self tests

All tests run through `tools/dev/love.ps1` from the repository root. It starts `lovec` on `game/`,
kills it after `-Timeout` seconds (exit code 124) and prints the log. They need the original game
data (found automatically on this machine; otherwise `--data "<dir>"` after `--`).

## Pick the tests that match the change

| run | checks | time | pass criteria |
|---|---|---|---|
| `pwsh tools/dev/love.ps1 -Tail 3 -- --selftest --lua tools/dev/syntax.lua` | every `.lua` under `game/` compiles | ~1 s | `syntax: N files, 0 errors`, exit 0 |
| `pwsh tools/dev/love.ps1 -Tail 2 -- --selftest` | `.xcr` decryption, WAV/BMP lookup, all 115 `.SCN` parse | ~1 s | `ok   parse scenarios 115/115`, `0 failures`, exit 0 |
| `pwsh tools/dev/love.ps1 -- --selftest --sim <map>` | 1-minute battle, player army attacks the nearest enemy | ~1 s | no `[error]` / Lua traceback; per-minute side summary printed |
| `pwsh tools/dev/love.ps1 -- --selftest --sim <map> ai` | 10 minutes, every side computer controlled | ~5 s | as above; look at the `t=Nmin` lines for sane economies |
| `pwsh tools/dev/love.ps1 -- --selftest --sim saveload [map]` | simulate 2 min, snapshot → serialize → restore, compare, run 2 more min | ~4 s | `save/load: units a/a buildings b/b gold g/g` equal, no assertion |
| `pwsh tools/dev/love.ps1 -Timeout 900 -- --selftest --sim all` | 2-minute all-AI run on every scenario | minutes | `all scenarios: 0 failures` |
| `pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/guard.lua` | no original assets or data dumps tracked, ratchet on 4-letter code literals outside the base layer | ~1 s | `guard: 0 failures`, exit 0 |
| `pwsh tools/dev/love.ps1 -Timeout 300 -- --selftest --lua tools/dev/guard-install.lua` | no line of the install's text files repeated in the tree (needs the install) | ~10 s | `0 matching lines`, exit 0 |
| `pwsh tools/dev/golden.ps1 -Baseline <commit> [-Quick] [-Spells] [-Sims "Bridges"]` | rule data, items, heroes, abilities, victory battles, spell casts, simulations equal to a baseline commit (content / facade changes) | ~1-10 min | `golden: identical to <commit>` |
| `pwsh tools/dev/love.ps1 -- --nettest` | reliable UDP layer on loopback (handshake, spoofing, roaming, outage) | ~5 s | `all network tests passed`, exit 0 |

`<map>` is a scenario name (`Bridges`) or a path relative to the game folder
(`CampaignScenario/C_Brax.SCN`).

Always run the syntax check and plain `--selftest`. Add:
- `--sim <map>` / `--sim <map> ai` for anything in `game/src/game/` (units, economy, AI, spells, rules);
- `--sim saveload` when state that is saved changes (`savegame.lua`, new fields on units/buildings/sides);
- `--sim all` (run it in the background) for broad simulation changes, AI or scenario events;
- `--nettest` and the `multiplayer-test` skill for `udp.lua`, `net.lua`, `lockstep.lua`, `commands.lua`;
- a screenshot (`screenshot` skill) for anything drawn.

## Reading results

- `--sim` modes always exit 0; judge them by the log. A crash shows as `[error]` or
  `Error: ... stack traceback`. For `--sim all` filter the output:
  `pwsh tools/dev/love.ps1 -Timeout 900 -- --selftest --sim all | Select-String "error|failures"`.
- `--selftest` and the syntax check exit 1 on failure.
- Exit 124 means the timeout hit: something looped or waited on input.

## Adding checks

- One-off probes: write a Lua file and run `--selftest --lua <file> [args]` (archives are mounted,
  `require("src....")` works, `print` goes to the log, `os.exit(1)` to fail). No `love.graphics`/audio
  in headless mode. Put throwaway probes outside `game/` (e.g. `shots/` or a temp dir).
- Permanent data checks: add a function to `require("src.tools.selftest").extra` returning the number
  of failures, or extend `selftest.lua` / `simtest.lua` directly.
