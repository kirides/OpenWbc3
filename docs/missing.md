# What openwbc3 still lacks compared with the original

Status of the parity work (see `git log`). "Original" means Warlords Battlecry III 1.04 (GOG). Only open items are
listed here, roughly ordered by how much a player would notice; an item that is finished moves to
`docs/implemented.md` (what it does and where the knowledge came from) and an item that turned out not to exist in the
shipped original moves to `docs/todo/not-in-original.md`. Where the original behaviour is known, where the knowledge
came from is noted (game data file or Ghidra on the binary). Implementation
guides for the open items are in `docs/todo/` (index: `docs/todo/README.md`); an item names its guide as
"(guide: `name.md`)".

## Gameplay

### Units, orders, AI
- [ ] Unit specials, leftovers (done: `docs/implemented.md` "Unit specials" including "Effect emitters", "Psych auras" and
  "Missile accuracy and the Scare / Awe spells"): which spells show the chaos cast effect `ECHC` is in `docs/spells.md`
  "Effect pictures of the spells" (the messages of 90..94 and 97, `FUN_00576860` ... `FUN_00577100`); the draw order of the
  emitters' particles (the grid offsets of the effect-code conversion `FUN_0040ebd0`; openwbc3 draws all particles over the
  map). The original's per-machine ownership gating (`FUN_004a5c40`) of the produced armies does not matter in the lockstep
  simulation.
- [ ] Missile flight leftovers (done: `docs/implemented.md` "Missile flight" with the trail frames, the hit pictures, the solid pixel, the
  breath's rings, the goblin, the titan's armour rule, the start pixel of a shot and the acid / evil / good breath's special attacks):
  the draw order of effect pictures (behind / in front of an army; openwbc3 draws them over the map).
- [ ] Attitudes (done: `docs/implemented.md` "Attitudes as a rule engine", "Attitude slices, threats and the neutral
  armies", "Threat search leftovers": the fog test of human sides, the critters' hunt, `FUN_0051a230`, a tower
  in the threat priority, the shape of the stand-ground box, Ctrl+F = Standard verified; the tower's own search and
  shooting: "The tower's own search and shooting" there). What stays open: a big army is found by its own cell
  only (the original's map holds it in every cell it covers); the fog test's smoothed edge cells and the
  "has been seen" flag a display item gets when drawn (openwbc3 recomputes the simulation's sight at the 250 ms slices); the
  player's order to a tower to attack a chosen target (`FUN_0052d060`, `+0x13c`: the selection's attack order
  `FUN_00531480`, called from `FUN_0041f0b0`, sends it when the first selected item is a building whose type can attack,
  and `FUN_0052d0d0` handles the field; openwbc3 has no command for it).
- [ ] Campaign dialog leftovers (done: the new-battle dialog's race list, the difficulty line per race and the standings behind it,
  the ambush dialog from the original panel with its race list, the diplomacy dialog's four columns and the reward line, see
  `docs/implemented.md` "Campaign battle dialog: the race list" and "Campaign ambush and diplomacy dialogs"). Open: the ambush and
  diplomacy dialogs sit at the 800x600 layout positions and the dialogs' text offsets (about 4 px up from the original's y values) are
  calibrated by eye like the other campaign panels; the replayable suffix of a mission name keeps one of the three leading spaces of
  Game.txt 716 (the strings loader trims them, whether the original keeps them is not verified).
- [ ] Quest dialog leftovers (`src/screens/questdialog.lua`; the dialog itself is drawn from the original's sprites and layout, see
  `docs/implemented.md` "Quest dialog"): it is modal here (the original is not: a click outside it reaches the game and the battle
  keeps running while it is open), its click sounds and the mouse cursor over it (pointer over the buttons, "pointer up" elsewhere)
  were not traced, and it sits at the 800x600 layout position (185, 24) on every window size (the original has its own positions for
  1024, 1280 and 1600 wide layouts, which openwbc3's scaled 800x600 canvas does not have).

## Screens and menus
- [ ] Options screen leftovers (`docs/implemented.md` "Display and sound options" has the rest, including the feature
  ambience, the scroll rates, the volume levels and the music sets): EAX / 3D provider stays greyed "N/A" as
  on any machine without an EAX provider (reasons there: the original's EAX sets a room on a 3D provider that none of its
  2D samples use, so it changes nothing audible; a reverb in LÖVE would be an openwbc3 addition, not parity); the feature
  ambience has no data to play
  in the retail install and ignores the per-feature `delay` one-shots; the menu theme (`Intro`) loops here while the original starts
  the sample without a loop count and lets the idle step's ambient check follow (whether the menus run that idle step was not
  traced); the original's scroll speed (60 / 20
  cell events a second times the rate, verified, see `implemented.md`) is fast but not frame-rate bound; the original moves the view in
  whole cells, openwbc3 continuously, and its Windows timer may deliver slightly fewer than 40 ticks a second.

## Editor
- [ ] Editor leftovers (done: events, the object / sides / options / items dialogs including the game mods dialog, the terrain panel
  `PNL_EDITOR_TERRAINNEW`, the message boxes, the random map into the editor, the original's start / event / effect sprites, the
  condition 32 icon list and chest moving; see `docs/implemented.md` "Scenario editor"). Left out: the simulation reading the statistics
  (other than hits) and the behaviour of a scenario army, which the original does not read either; the editor's new scenario starts with
  two sides on while the original switches all six on (the sides dialog of the earlier work follows openwbc3's rule, only the editor's
  random map uses the original's six); the 1.04 binary's editor code (the dialogs, the menu handler `0x004bf3c0`, the event copier
  `FUN_004b8380`) was not traced in detail, so these parts rest on the shipped data and are not verified against the binary yet.

## Presentation
- [ ] Presentation leftovers (the effects themselves are in `implemented.md` "Display and sound options": the building,
  effect and missile emitter tables, the smoke of razed buildings, the critical-hit pictures and sounds, the floating lines,
  the idle fidgets, the frame-rate throttle, the cast flash colours and the effect pictures of the spells - the per-spell casting,
  target and persistent codes from the 1.04 cast functions, persistent emitters, the draw order (`adjustY`) of the pictures, the
  health potion's `EZ53`, "Spell Resisted" for Banish / Mutate / Strip Flesh / Rot - are done and verified there and in
  `docs/spells.md`). What is left: the sound numbers of the troops' own spells (Summon Bats ... , negative slots; they still play
  `Statpop.wav`, the hero spells play their `STEZ%02d.wav` now: `docs/spells.md` "Spell sounds"), which armies a cast marks (openwbc3 compares the world
  before and after the effect function; the original's lists come from each spell function: Disjunction, Spellforge and the Arcane
  spells keep their state in hero or side fields and show their persistent picture on the caster only), the persistent pictures of a
  loaded game (the original saves the picture id), pictures at a cell without an army (the cell variant `FUN_0044ec50` of the
  summon spells' target effect), the lines of the dragon attacks that do not exist yet (drain experience, reduce
  armour, crystallize: wired, nothing sends them), the lights' step table (openwbc3's own envelope with the original's
  lengths and peaks), the 25 ms tick of the building emitters and of the fidget passes with their walking order and turn step
  lists (not traced in the 1.04 binary yet: its main loop was not traced, only the per-army and per-building bytes), the PFX display items'
  throttle (`FUN_0058c220`: no counterpart), the ford / marsh movement sounds (`SplashMove.wav` / `MarshMove.wav` are not in the
  GOG install) and that the original's frame-rate throttle measures its 25 ms ticks where openwbc3 measures drawn frames.
- [ ] Speech leftovers (the rest is in `implemented.md` "System speech"): the increments of the shared select / order /
  deathblow counter (two per 25 ms tick) are not traced in the 1.04 binary yet (it confirmed the limits 90 / 30, the
  resets and the variant thresholds, not who counts it up); the binary sets the deathblow and ambient flags only while a
  game-mode global (`DAT_00608478`) is at least 2, which was not identified (openwbc3 always sets the deathblow flag); the
  hit-list rule for poison (no hit message) is not traced in the 1.04 binary yet (its poison tick was not traced).

## Things implemented with openwbc3's own numbers (not verified against the original)
Re-checked after the tower work; what is still not original:
- the attitude details noted in `attitude.lua`: the simulation's own sight for the fog test (a fog per human side recomputed at the
  250 ms slices instead of the screen fog of the one local player), big armies found by their own cell, every human side treated as
  "the local side" (hit list, the fog test, a tower of a human side never taking a building) because the simulation runs them all;
- the tower's threat centre (the grid column and the middle row) is openwbc3's choice: the 1.04 binary reads the stored point
  (`+0x15e`), but its building placement (`0x005399b0`) does not store it and the code that fills it was not located; "a building with an order in its queue does not look" is
  mapped onto openwbc3's production queue (`b.current` / `b.waiting` / `b.queue`), the only orders an armed building could have;
- the regeneration (units and tower garrison) adds up fractions of a point per update instead of the original's one point at a time at
  a due time (same rate, finer steps); a poisoned unit inside a tower neither loses hits nor recovers (the hidden unit's status effects
  are not run; whether the original's update runs for a garrisoned army was not traced).
The tower healing rate (halved interval, power-ups and the hero's Regeneration skill included) is no longer one of them: see
`docs/implemented.md` "Economy / rules verified against the original".
