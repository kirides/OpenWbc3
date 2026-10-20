---
name: multiplayer-test
description: Test openwbc3 network play on one machine - start a host and a client instance that connect over loopback UDP, play into a lockstep battle and capture screenshots of both, and run the UDP layer tests. Use after changes to udp.lua, net.lua, lockstep.lua, commands.lua, the lobby screens, or anything that could break simulation determinism.
---

# Local multiplayer test

1. Transport tests first (fast, headless):

   ```powershell
   pwsh tools/dev/love.ps1 -- --nettest        # expect "all network tests passed", exit 0
   ```

2. Two real instances on loopback. The host lobby with `:auto` starts the game as soon as a
   second player joins; the client with `:join` connects to `::1` on the default port. Start the
   host first and give each its own screenshot:

   ```powershell
   $h = Start-Job { Set-Location $using:PWD; pwsh -NoProfile tools/dev/love.ps1 -Timeout 90 -- --show mphost:auto --shot shots/mp_host.png --after 30 }
   Start-Sleep 3
   $c = Start-Job { Set-Location $using:PWD; pwsh -NoProfile tools/dev/love.ps1 -Timeout 90 -- --show multiplayer:join --shot shots/mp_client.png --after 27 }
   Wait-Job $h, $c -Timeout 120 | Out-Null
   "--- host"; Receive-Job $h; "--- client"; Receive-Job $c
   ```

   Pass: both logs show `world: ...` (the battle started) and no `[error]` / `[warn] desync:`
   lines; both screenshots show the battle. Read `shots/mp_host.png` and `shots/mp_client.png`.
   An on-screen "out of sync" notice or a `desync:` log line means the simulation diverged.

## Determinism checklist (when a desync appears)

The peers exchange only commands and compare `world:hash()` per turn, so every peer must compute
exactly the same simulation:

- player actions must go through `S:issue(cmd)` → `commands.apply`, never mutate the world from UI code;
- no `math.random` outside the simulation (it is reseeded per tick; a draw-time call shifts the stream);
- no wall-clock time (`love.timer`, `os.time`, `os.clock`) or frame `dt` inside `world:update` paths;
- don't let `pairs` order decide simulation results; use arrays + `ipairs`;
- local-only state (selection, camera, fog of the local player, UI) must not feed back into the world.

A headless way to bisect: run the same `--selftest --lua` probe twice with `math.randomseed` fixed
and compare `world:hash()` after N steps; any difference is nondeterminism inside one process.
