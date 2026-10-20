# Presentation: decals, particles, lighting, main menu effect, and the display / sound options that switch them

**Done** (see `docs/implemented.md` "Display and sound options"; the emitter tables, the critical-hit effects, the fidgets and the
frame-rate throttle came later, also there; what is left is in `docs/missing.md` "Presentation leftovers"). Corrections found while implementing: the main menu has seven entries
(the menu's texts 0..6, y 162 / 207 / 252 / 297 / 342 / 387 / 472), duplicates are allowed (not replaced), the gore "fade
out" is registered but never used, the footsteps option gates only the sounds (footprint decals depend on "decals"),
and the lighting effect is not tied to night.

Priority: low-medium (looks, not rules). Size: medium-large, independent pieces. Files: new `gfx/decals.lua`,
`gfx/particles.lua`, `screens/battle.lua` (draw order), `screens/mainmenu.lua`, `core/gameopts.lua` (options that
already exist), `audio/sound.lua`.

None of this is simulation state: it lives in the battle screen, may use `love.math.random` / hashes freely but
must not call `math.random` (lockstep), and must not be required from headless code at load time.

## What the original does
- **Decals** (registered by `FUN_004795f0` of the 1.04 binary, placed by `FUN_00479a10`, drawn by `FUN_00479e80`): footsteps
  (`EDFS` frames 0..7, small / large x four directions, 30 s, no animation), gore red / green (`EDBL` 0 / 1, 120 s, fade
  out), scorch marks (`EDFS` 8, 45 s), base standard / dirt / snow (`EDBA` / `EDBD` / `EDBI`, permanent, under
  buildings). Placed by the army walking step `FUN_005377a0` (footsteps), `FUN_005374a0`, `FUN_0053bca0` and the dragon
  breath `FUN_00542150` (scorch). Options (registry values of `FUN_004521f0`): `Decals`, `Blood` (also hides gore),
  `FootSteps` (the footstep sounds only, see the corrections above).
- **Particles** (the particle pool `FUN_0058c0d0`, the definitions of `Assets\Particles\*.xml` read by `FUN_00485f60` /
  `FUN_00486010`, the emitter tables `FUN_0040e930` / `FUN_0040ebd0` / `FUN_0040f620`): blood splatter on critter eating and
  hits (position, count, colour, gravity, direction, speed, animation, fade, size), the building splatter `FUN_0052bf20`,
  emitter-based effects for some missiles / spells (the missile-id conversion `FUN_0040f620` returns emitters), soul
  sparkle. Option `ParticleEffectLevel` (none / few / average / many) scales the counts.
- **Lighting** (the light object `FUN_0053db40`, sprite `ELIT`; `FUN_0044edb0` places one): coloured light sprites
  (colour, size, duration, 50 ms frames) under missiles / spells (not tied to night, see above); option
  `LightingEffects` (read by the light pool `FUN_0058c2e0`).
- **Shadows** (option `Shadows`, the sprite blitter `FUN_00487f20`): unit / building shadow frames on or off.
- **Ambient animation** (the ambient animation option, registry string at 0x0060be18): idle fidgets of armies /
  buildings / features (`FUN_005471c0`, the army's fidget roll 0x00539a90).
- **Floating text** (option `FloatingText`, `FUN_0053a010` / `FUN_005349b0`): damage / XP numbers over units.
- **Gamma** (option `GammaCorrection`, the gamma ramp `FUN_00468cf0`): screen gamma ramp - a shader in LÖVE.
- **Combat sounds** (option `CombatSounds`), environment sounds (option `EnvironmentalSounds`: ambient loops per terrain /
  night, `FUN_0050e420` called from the sound update `FUN_0050ea10`), victory / defeat build-up music (option
  `VictoryDefeatBuildup`) and the hero heartbeat (option `HeroHeartbeat`, `FUN_0050e690`).
- **Main menu effect** (the effect object at 0x006566a0: constructor `FUN_004052c0`, add `FUN_00405360`, update
  `FUN_00405500`, draw `FUN_00405330` / `FUN_00405580`): when the mouse moves over a main menu entry, the menu handler
  (0x0041d730) adds its text at x 400 with an effect for 1.5 s with up to 20 px padding, at most 12 at once.

## Steps (each independent)
1. Wire the options that are cheap: shadows, floating text (if openwbc3 has it), combat sounds, footsteps sounds,
   gamma shader, ambient animation (if the sprite sets have fidget frames).
2. Decals with the original lifetimes and fades, gated by the options.
3. Particles: a small particle module for blood and the emitter effects; the level option.
4. Lighting at night.
5. Main menu effect.
6. Remove each item from the "stored but without an effect" list in `missing.md`.

## Checks
Screenshots (battle by day / night with fights, main menu with the mouse over an entry: `--show` + `devClick`).
`--selftest` must stay free of `love.graphics` at require time.
