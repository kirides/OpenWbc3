# What openwbc3 has implemented compared with the original

The counterpart of `missing.md`: parity work that is done. "Original" means Warlords Battlecry III 1.04 (GOG).
Where the original behaviour is known, where that knowledge comes from is noted (game data file or Ghidra on the
1.04 binary; "not traced in the 1.04 binary yet" marks behaviour without a binary anchor). Items with open sub-items keep those in `missing.md`.

## Gameplay

### Building abilities (`src/game/buildingabilities.lua`)
Done: Elcor's Aura (hero skill 44) adds 20 hit points per level to Elcor's Balm, after the Empower scaling
(verified against the original healing code and the skill effect table); the abilities play their cast sound
(the original's per-ability sound, STEZ%02d.wav from the sound archive, at the building); Couatl's Wrath
fireballs fly from the temple to their spot and burst there for 150 damage (the Titan's balls, see "Missile flight").
Prices, timers and availability of every building button against the 1.04 handlers (`0x004d0c50`..`0x004d1e10`, the
layout `FUN_004d2300` and its tests `FUN_004d0190`..`FUN_004d07e0`; `docs/hero.md` "Building abilities"): Chaos Plague
asks for and takes 1000 crystal (was 500), Sword of Sirian 200 crystal (was 350), Couatl's Wrath 750 gold (was 500), also
for the computer (`FUN_00501940`, `FUN_005018b0`); the computer's Famine (`FUN_005019d0`, 700 crystal) does not pay, its
Elcor's Balm needs 400 crystal and pays 300 (`FUN_005013e0` / `FUN_004d2030`; the 300 used to be the threshold too);
the button's Famine takes its 500 crystal also when no mine is found, and its button only appears with the power-up;
the one-second button timer is armed before the price and the targets are checked; Slave Horde / Brood have a 3 s timer
per side (was per building, only after a successful use); Summon Wraith / Shadow are not greyed when the army is full;
Trade is also offered by the Hostel, Trader and Merchant (`FUN_004d07e0`). The resource fields of the side record
(gold `0x00708fb4`, metal `fb6`, crystal `fb8`, stone `fba`) are named by `FUN_00524450`'s "need more" lines.

### Army abilities (the original's unit command buttons)
Done (`src/game/armyabilities.lua`, command `army`; button order, costs and rules from the original's unit buttons:
button setup `FUN_004d2300`, special-ability buttons `FUN_004d3200`, the drunk message `FUN_004a9a40`, immolation
`FUN_00527720`, cost function `FUN_0040b6b0`; strings from `Game.txt`): Undead morph buttons (Wight, Wraith, Shadow, Slayer Knight, Liche, Doom Knight: fixed prices,
building requirements, group morph), Drunkenness (Dwarves / Minotaurs, +4 combat and speed, psych immune, 2 min,
10 gold), Fanaticism (Minotaur / Barbarian, +6 combat, +4 speed, 1 hit per second, 3 min, rampant), Sacrifice
(4 % per unit for a Daemon, 5 crystal each, 3 s pause), Merge Wisps (four wisps walk together, 100 crystal),
the rotate buttons and the formation panel (the eight formations in the original's order; `src/game/formation.lua`
uses the original's slot tables, extracted from the binary: see "Formations" below). A group has the Formations button in the Patrol slot (Patrol stays on `P`; not verified
whether the GOG build is the patched variant that swaps Move and Patrol). Computer players: drunkenness
when hit, wisp merge (the computer's special-ability sweep `FUN_005001d0`, wisp merge `FUN_004f8290`). Star of Sartek and Follow have no
button: in the original their button functions do nothing (Star of Sartek is a passive power-up).
Also done: the fire-armour bonus of Fanaticism (+15 against fire damage: the army's armour getter `0x00525c80` adds 15 to the
fire slot of the complete armour for immolation type 2, at `0x00526032`), merging wisps never give up (the original's
leader waits at the destination with a wait counter that is never finished; not traced in the 1.04 binary yet), and
savegames keep a merge in progress plus the effects the original's army save record has fields for: drunk, fanatic
(immolation type 2 with its old attitude), poison, disease and invisibility (not traced in the 1.04 binary yet). The
sacrifice button is disabled for 3 s after use (the sacrifice button `0x004ced00` keeps a timeGetTime stamp at
`0x00a47848` and ignores presses within 3000 ms, a static real-time value - not save data, so openwbc3 counts it per side on the game clock instead). Computer players
also morph: the Undead side's morph missions (morph list `FUN_004fd8c0`, task choice `FUN_004fd940`, morph task
`FUN_004f8dc0`, the morph itself `FUN_004cf690`) morph one unit per mission, a target type only considered 50 s or
more after the last morph of that type (the army data's interval between orders, checked by `FUN_004f8600` and stamped by `FUN_004f8750`),
and need the same buildings and pay the same resources as the player's button; which candidate is tried first is
openwbc3's own choice - the original picks one out of its resource list by priority plus a dice roll.

### Unit special abilities (spellcasting troops)
Done (`src/game/armyabilities.lua`, `spells.lua` `unitCast`): spellcasting troops carry mana (the Army.cfg
MANA column "max:start") and regenerate it (the mana regeneration interval `FUN_0051b580`: one point every 3000 ms,
Daemons 6000, minus 100 ms (Daemons 200) for every troop level, divided by the Summon Mana power-up, Mana Freeze
stops it for every side); the HUD shows the mana of spellcasting troops. A selected spellcaster gets its mana-cost
buttons in the original's order (the special-ability button routine `FUN_004d3200` with its mana costs and
icons, `Game.txt` names): Cure, Group Healing, Resist Fire, Ring of
Fire, Fire Elemental, Hand of Ice, Call the Dead, Freeze, Poison Cloud, Shield, Cauterize, Drain Mana, White Ward,
Ring of Ice, Lightning, Berserker, Light / Darkness, Multi-target, Entangle, Pillar of Fire, Raise Zombie, Gate
Imp, Gate Daemon, Summon Bats, Summon Spiders, Scare, Banish, Darkstorm, Invisibility / Blending, Feast, Scavenge,
Earthpower, Doomstones, Stonecall, Purify, Eye of Oros, Plague Cloud, Create Firebomb, Goblin Horde, Summon Blades;
the cast's result is the unit's casting level, (level + 1) / 5 + 1 (`FUN_00426350` with the level of `FUN_00526d80`;
1 up to level 3, 2 from level 4, ...), so the effect is the hero's at that result; Earthpower, the
Chameleon's Blending and the zombie's button need the side's power-up (without it the button is shown disabled), Earthpower
only shows for the Dark Dwarves and Feast for the Undead. A press casts with one unit: the 1.04 handler `FUN_00426350`
takes the first selected caster with the mana (Invisibility, case 0xd: every selected one); Feast and Scavenge take the
first selected unit and work once a second (`FUN_004cfc90` / `FUN_004cfce0`). Checked against the handler's 48 cases:
Ring of Fire casts Pyromancy spell 54 (`FUN_0057fd60`), Purify the hero's Purify, Healing spell 6 (`FUN_0057b6a0`),
Pillar of Fire costs 35, and Freeze is enabled from 45 mana but needs and takes only 20 (`cost` of the record).

### Hero skills without a reader, summoning-spell experience (`src/game/spells.lua` `summonXp`; checked in the 1.04 binary)

- The skills Reave, Thievery, Diplomacy, Fire Missile, Swiftness and Magic Time have no effect because the 1.04 binary has none:
  every reader of a hero skill (`FUN_00556b50` / `FUN_00556ab0`, effect `FUN_00556ea0`, help `FUN_00556fc0`) was read. Skills
  102 .. 106 do not exist in 1.04 (ids stop at 101), Reave (45) is only a help text; see `docs/hero.md` "Skills the binary never
  reads" and `docs/todo/not-in-original.md`.
- The Gate power-up's experience (and the troop-XP lords) now go to every army a summon spell makes, not just the Golem: the
  spell functions of the binary call the initial-experience routine `FUN_00557d90` with the Gate flag and add 0 / 5 / 20 / 50 per spell level
  above the first (table in `docs/hero.md` "Summoning spells: experience of the new armies"; Arcane Elementals count the Gate
  bonus twice). The spell functions that make Spectral Horde / Dragonfear and the production buildings do not pass the flag.

### Power-ups
Done (see `docs/hero.md`, `src/game/powerups.lua`): Crusade, Courage / Order of the Lion / Warmth, Meditation,
Summon Mana, Healing (plain units and the hero), Holy Relic, Bronze General, Doombat, Flaming Arrows, Faerie Fire,
Blood Potion / Dark Order, Vampire Bats, Black Ward, Order of the Grail (quest XP), Dark Lord, Paladin, Grand
Paladin, Fallen Knight, Torture, Cowards, Dragon Knight, Hunting, No Pain, Deflection, Dark Bolt, Melkor's Curse
(while any active side owns it, poison costs 2 hits per second instead of 1, the hit point
regeneration tick `FUN_0051b820`), Library and Sorcery, Rabies, Construction and Zombie Feast. The Palace / Royal / Imperial Guard
have no side effect beyond the statistic bonuses already applied (not traced in the 1.04 binary yet).

Library (`PLI0` / `PLI1`, the High Elf's Library) and Sorcery (`PSO0` / `PSO1`) give 15 more maximum and starting
mana to every unit that has mana: the army's mana setup `FUN_00528cd0` takes the level of the side's `PLIX` power-up
(power-up level test `FUN_00437f70`) and only falls back to `PSOX` when that is 0, and adds level x 15 to both the
maximum and the starting mana, so the Library family wins over the Sorcery one (the power-up mana grant
`FUN_004386d0` with +15 for the Dark Elf Mage agrees). A computer side's army (computer-player flag `DAT_0070d6a4`: every non-human side,
passive ones and the neutral side included) starts with 10 more mana when the type's maximum is at least its starting mana + 10.

Poison and disease of the unit type records (the record's psych effect: type 5 poison / 6 disease, a strength and a
range) are applied to what the unit hits, in the army's hit resolution `0x0051abe0` for both melee and missile impacts: the Zombie `AUBX` (disease,
strength 5) and the Chameleon `ALBX` (poison, strength 6) innately, and a diseased attacker spreads its disease at
strength 5. The chance is `max(1, 50 - (resistance - strength) * 5)` percent. The psych effect's range is not used
there (it belongs to the psych aura system, which only covers types 1..4). Rabies (`PRAB`) gives the Barbarian's
Wolf Rider `AOCX` a disease of strength 5 (the Rabies routine `FUN_00438ca0` writes type 6, strength 5 and range 1
into the army's psych effect); the Wolf Rider's type record has none.

Build skill is the `BUILDING` power of the type record (power id 50 in the record's power list, data 0 the
skill; 14 units have one, from the Giant Ant and the Zombie at 8 to the Treant at 15) and construction time follows
the cost function `FUN_0040b6b0`: `time -= ((skill - 10) * time) / 10`, so a Zombie builds 20 percent slower and a
Chameleon 10 percent faster. Construction (`PCON`) then halves a Chameleon's own building actions
(the army's build actions `0x00525a70`). The Zombie Feast's +4 (the army's build skill `FUN_00523e10`) is not part of that cost -
the original reads the record's value - it only feeds the gates and the computer's choice of builder, so it has no
further effect in openwbc3; the Zombie Feast power-up's code is `PZOM`, whose Help.cfg name is
"Feast of Garok", and it also gives the Zombie its Feast button (already in `armyabilities.lua`).

Missile special attacks: every missile rolls a 4 percent chance of one when it is launched (the army's missile shot
`FUN_00523150` rolls the dice `FUN_00458e70(1, 100, 0) < 5`, and when that fails a second time for damage type 11,
the hot-and-pointy shot of Flaming Arrows, set by the damage getter `0x00526310`: 1 - 0.96^2, about 7.8 %; a tower's shot
`FUN_0052d2f0` rolls none), and a fire / hot-and-pointy one immolates its victim
(immolation `FUN_00527720` type 0: 2 hit points a second for 15 s, and the attitude goes rampant until it burns out);
a melee critical hit (hit type 0 or 1, i.e. deathblow or critical) of a fire / hot-and-pointy attacker does the same
(the melee resolution `FUN_0042ace0`).
A higher immolation type replaces a lower one, so Fanaticism (the original's type 2) wins over a burning victim.
Immolated units carry the original's persistent fire effect `EF04` over them (`FUN_00527720` adds it to the display item).

The other critical-hit special attacks (`FUN_0042ace0` for melee, the missile shot `FUN_00523150` for a missile
that rolled its 4 percent crit) follow the attacker's damage type: a critical piercing melee hit ignores armour
(the armour is zeroed), the ice freeze is an 8 s slow of 6 speed points (the original's slow-all power of 6, which
the army's speed `FUN_0051c460` and fight speed `FUN_0051c6a0` subtract, never below 1; openwbc3 has no fight-speed model
so only the movement speed drops), electricity drains 40 mana, magic dispels (every spell effect except poison and
disease), crushing stuns for 5 s and slashing cleaves splash min(50, damage / 2) (a missile min(50, damage / 2 + 1))
slashing damage as a good hit (hit type 2), armour included, over every enemy army within 2 cells of the attacker and
no further - the original's cleave `FUN_005278a0` sends a radius 2 spell message (`0x1f7`) centred on the inflictor
and the host's spell resolution `FUN_004aa840` applies it to enemy armies only, alive, excluding the attacker (its
movement-type filter has no effect).
The basilisk `AOXX` and the Titan Orc `ATOX` fire the petrify missile `EMM5`, which needs no crit roll: a victim the
hit kills is gone and the inflictor's side gets 50 stone, a victim that survives the hit is
frozen instead. The 40 mana, the 5 s stun, the 8 s freeze, the slow of 6 and the cleave area and formula come from the
original (melee resolution `FUN_0042ace0`, the missile shot `FUN_00523150`, the army's mana drain `FUN_00527a00` /
freeze `FUN_00527b30` / stun `FUN_00527d10` / petrify `FUN_005280c0` / cleave `FUN_005278a0` and the host's spell
resolution `FUN_004aa840`). The Berserker spell (`FUN_0057ffe0`)
also immolates its units - the original's immolation type 2 from a spell: 1 hit point a second and a rampant attitude
for the spell's duration, on top of its verified combat 4+r / speed 3+2r bonus (`src/game/status.lua` kind berserk,
kept in savegames like the other immolation types).

Missile pictures follow the missile-picture routine `FUN_0040ac00`: the Dark Elf Archer's `AKMX` piercing arrows are poison arrows
(`EMAP`) and its hot ones fire-poison arrows (`EMFP`), any other hot shot is a flaming arrow (`EMA2`), and the Dark
Elf Mage's / Spider Priestess's lightning is black lightning (`EMM4`) with Dark Bolt. `EMAP` and `EMFP` have no
sprite in the archives - the original draws nothing for them either - but the arrow still poisons the victim with a
strength of half the shooter's damage, plus half of that again for the fire-poison arrow (the missile impact `FUN_005427e0`).
`EMM4` has an `.ani` but no sheet, and the original draws it as an instant jagged bolt with a dark colour ramp
(the instant, linear and lightning drawing flags of the missile), which openwbc3 draws the same way.

Buildings are missile-resistant by the missile picture (`FUN_0052e790`): arrows, silver,
poison and fire-poison arrows, crossbow, scorpion, ballista and spear bolts, the Minotaur axe, the throwing axe and
the petrify missile take a sixteenth of their damage, at least 1 (2 for hot-and-pointy); the flaming arrow `EMA2` and
the black lightning `EMM4` are not among them. A shooter whose side bought Hunting ignores the resistance either way
(the missile impact `FUN_005427e0`).

Plain troops have experience and levels (the original's troop experience routine `FUN_0040da20`, level table
`DAT_005fbc50`): the XP table and the level in
`src/game/unit.lua`, the "N xp" line and the gold / silver medal strips of `SkillIcons.bmp` in the info panel,
experience for a kill (Crusade counts for plain killers, critter kills give none), the level-up healing, the
shorter regeneration and mana regeneration per level, the original's level-up sprites `EZ12` / `EZ57` and
`GainedLevel.wav`, scenario levels and savegames. Produced armies get the original's initial experience (the hero's
Intelligence / 2 while it lives, plus Telepathy's training power, the initial-experience routine `FUN_00557d90`); Soul
Flame raises the experience of the friendly troops in the command radius and Mind Leech gives them the experience of
what they kill (Soul Flame `FUN_0057f9e0`, Mind Leech `FUN_0057ad20`, the army's energy drain `FUN_00526fe0`).

Summon Mana (PMR0..2) speeds up the mana regeneration of spellcasting troops as well as the hero's.

Elven runes (`RCIE` / `RANI` / `RMAN` / `RVIV` / `RARB` / `RMOR`, the High / Wood / Dark Elf keep research): bought
like any power-up (the original's cost function takes `P` and `R` codes through one branch) and a bought one counts
as a dependency, which is how `[DEPENDENCIES]` unlocks the archers, cavalry and so on (the power-up routine
`FUN_00436500` counts a permanent power-up through the dependency-instance counter `FUN_0040b350`). Costs read from the binary (`FUN_004391c0`, the R cases): Cielos
100 crystal + 100 stone / 60 s, Animos 150 + 150 / 90 s, Manos 200 + 200 / 120 s, Vivos / Arbos / Mortos 300 + 300 /
150 s. The rune hero skills (Life 61 -> Vivos, Forest 62 -> Arbos, Sky 63 -> Cielos, Death 64 -> Mortos, Arcane 65 ->
Manos; Animos has none) make a rune 10 % per level cheaper, applied after the other discounts with a minimum of 1 per
resource (cost function `FUN_0040b6b0`). The computer players buy runes through their normal power-up priorities.
The runes' hit bonuses for the produced units are in `docs/hero.md` "Skill effects".

Research, foreign mercenaries and the Knight's Quest (`powerups.lua`, `screens/choosefoe.lua`; all read from the 1.04
binary: the power-up routine `FUN_00436500`, research `FUN_00438180`, foreign mercenaries `FUN_004382d0`, the quest set-up /
dialog / callback = `FUN_00438d40` / `FUN_00438de0` / `FUN_00438eaf`, the kill XP in the unit death handler `FUN_005210b0`):
- `FUN_00436500` does **not** add Spell Research (`PSPR`), Arcane Research (`PARR`) and the three foreign mercenaries
  (`POMA` / `POMB` / `POMC`) to the side's power-up list, so they stay on offer and can be bought again and again
  (`powerups.ONE_SHOT`; `grant` runs the effect and finishes the production). They do not raise the "research complete"
  voice. The Knight's Quest (`PQKN`) joins the list only when it finishes with three foes already chosen.
- **Research**: `PSPR` = `FUN_00438180(side, 1)`, `PARR` = `FUN_00438180(side, 3)`; with a living hero one random sphere of the 13
  (dice `FUN_00458e70(1, 13, -1)`) gets `max(1, (n + 1) / 2)` casting levels (`PSPR` +1, `PARR` +2) in the per-side sphere
  bonus table at `0x0070d496` (13 words a side) for
  the battle (`side.spellBonus`, saved in savegames); the hero's statistics rebuild adds it to every casting skill
  (`FUN_0054fd50`, `Hero:sphereBonus`; the bonus is the side's, no longer kept in the hero profile). The local player gets
  Game.txt 0129 ("You have gained +%d casting to your %s skill.", sphere names from the binary's English table at
  0x6156a8) and the "learned a new spell" voice (`spellresearch` event); without a hero Game.txt 0131 and nothing else. The
  Learn Spell spell effect (effect type 0x20 in the spell-effect function `FUN_004ac0e0`) calls `FUN_00436500(side, PSPR)`
  **once**, whatever the result level, and only when the caster's side is the local one: so it is one `FUN_00438180(side, 1)`,
  +1 casting in one random sphere (the 1.04 binary has no loop over the result level, and the level argument of
  `FUN_00436500` is unused for `PSPR`). openwbc3 applies it for every human side (the original's
  "caster is the local side" gate would leave the other peers of a network game out of step).
- **Foreign mercenaries**: one random unit of the level's list (28 / 27 / 15 army types, the binary's own tables read from
  `FUN_004382d0`, `powerups.MERCENARIES`) appears at the producing building like a produced army (spawn cell, rally
  point, `produced` event) and is not held back by the army limit. Fame makes them 25 / 33 / 50 % cheaper (cost function
  `FUN_0040b6b0`, every non-zero resource, `economy.lua`).
- **Knight's Quest**: the foes on offer are the first four entries of the binary's 20-entry table (`powerups.QUEST_FOES`: the
  undead / dark elf / orc / daemon / swarm / plague lords heroes and top units by race, then the four elementals) that fit:
  a race entry once per other side of that race in the game, the elementals always. The original builds one list for the
  local player; openwbc3 builds it per side (the side itself left out) so that all peers agree. Buying it opens the
  "Choose a Foe" dialog (the four-choice picture dialog `FUN_0055bc90`: sprite `EMD4` at x 400, y 10, the four army pictures in a 2x2 grid with the
  original's hit boxes, interface frame 3, frame 4 for a foe chosen before, `EMDC` close button; Game.txt 0869) for the
  local human only; the pick is the command `chooseFoe` and goes into the first free of four slots (`side.knightsQuest`,
  saved). Closing without a pick wastes the purchase. A computer side gets nothing (the code path that would give it
  candidates is never called in 1.04). The computer player does buy the research, mercenary and quest power-ups, see
  "Computer players" below. The dialog's draw routine (the four-choice dialog's draw at `0x0055c500`): background
  `EMD4` at (x, y), the close button `EMDC` at (163, 369), the four pictures at x 86 / 185, y 68 / 167, the title
  (Game.txt 0869) in font 1 (FO_LARGE) centred on x 178, y 28 and, under the grid, the name of the foe under the mouse
  in font 2 (FO_SMALL) centred on x 178, y 300; the hit boxes (`FUN_0055c420`) are 91 x 91 and only for foes not chosen
  before. The foe is picked on mouse-up on the same cell (`FUN_0055c160`).
  A plain Knight / Knight Champion / Knight Lord that kills a chosen foe (a non-hero army) gets 25 experience, 50 with
  the Order of the Grail, on top of the normal kill and Crusade experience.
- Checks: `--selftest` ("one-shot: ...", "research: ...", "mercenaries: ...", "quest: ..."), `--sim saveload`.

### End-of-battle experience and the victory screen (`src/game/battlexp.lua`, `src/screens/victory.lua`)
Done, checked against the 1.04 binary
(the end-of-battle experience `FUN_004553f0`, the army-kill table at 0x60C2B0, the 300000 ms test in `FUN_0041c520`, `FUN_00454b70` for the
screen): when the battle is decided every used side's hero gets an amount (a computer hero's shows in the results
statistics). Normal game: 0 / 5 / 10 / 15 for a 64 / 128 / 192 / 256 map, victory 40 with allies (weight above 1) or
80 alone, defeat 4, 10 per quest (50 from six), `kills / 10 * 2` for the armies the hero killed itself (100 from 250
kills), the army-kill table x 5 (`min(20, kills / 50)`), 10 for every defeated side and for every enemy of a winner, the
enemies' levels (Lord 10, Prince 20, Warlord 40, Emperor 80, other 5; shifted by the resource levels against the best
human) divided by the allies' weight (Prince 2, Warlord 3, Emperor 4, a human 2, others 1), 10 per hero slain, then
visibility 80 % (no fog), 90 % (hidden only), 110 % (fog and hidden), tech level `x (5 + tech) / 10` (`>> 3` at tech 0),
"I am the greatest" (`world.advanced.greatest`) +100 for a winner, 3/4 for a hero that fell. Games under five minutes: winner 1 (5 in a pitched
battle, at tech 0 and in the campaign), loser 0 (3 in a pitched battle / tech 0). The local hero: Ironman doubles a
living winner's amount and a dead Ironman hero gets nothing (the profile is already deleted at its death), level 999 gets
nothing, a frozen hero or a No Heroes game gets nothing at all. The victory screen prints "You have gained a N XP bonus"
(TXT_ADVANCEDRESULTS 6), the frozen text (TXT_FREEZEHERO 1) or, in the campaign, the action's extra XP form
(TXT_CAMPAIGN_XP 5) and the reward text (`campaignrun.victoryExtra`), the levels gained, and "saved games deleted"
(Game.txt 0492): the original deletes the hero's `<hero>.wb3` when XP was gained (the NODELETE switch keeps it);
openwbc3 deletes the hero's save slots the same way unless `[game] deletesaves=0` is set. Per-side statistics (heroes
slain, hero fell, quests) are kept in `battlestats.lua` and saved with a saved game. The amounts are tested in
`--selftest` ("battle xp: ..."). "I am the greatest" and the Tournament hero's "no experience" are advanced options (below).

**When the hero levels** (checked in the 1.04 binary, `src/game/hero.lua`, `screens/battle.lua`, `screens/levelup.lua`): the
original levels the local hero in two places. (1) In the battle, the control panel's update `FUN_004d60f0`: when the experience
`0x709d04` has reached the threshold of the next level (`0x709d08`, `FUN_00409ef0`), the hero is not frozen and the level-up
latch byte `0x709d0c` is clear, it adds ONE level, one attribute (`0x709e38`) and one skill (`0x709e3a`) point, sets the latch,
plays `HeroLevelUp.wav` and lights the portrait (`FUN_004d7710` reads the latch). The latch is cleared by the level-up
dialogs' Accept when no points are left (`FUN_00552990` skills, `FUN_00562ba0` attributes, `FUN_00564290`) or by a portrait click
with nothing to spend, so surplus experience waits (`FUN_004d54c0`: a click on the portrait with the latch set opens the
attribute dialog, else the skill dialog). (2) At the end of the battle `FUN_004553f0` only adds the end-of-battle experience to
`0x709d04`; the results screen (`FUN_00454b70`) then calls `FUN_00455b40`, which counts up to four levels still owed
(thresholds of level + 1 .. + 4, none for a frozen hero; points of both kinds are added per level) and sets the "levels gained"
line to the points the hero already had to spend (the larger of the two counters) plus the new levels. The level itself grows
when Continue is pressed (`0x004546F0`, button 0x4b: `level += new levels`, hero saved), then `FUN_00552d90(0, -1)` opens the
attribute screen if attribute points are left, else `FUN_005522e0(0, -1)` the skill screen if skill points are left, else the
retinue screen `FUN_00440b40(0, 0)`; Accept of the attribute screen (`FUN_00553320`) goes on to the skill screen only when
skill points are left (else to the retinue), the skill screen's Accept (`FUN_00552990`) to the retinue. Points may be left
unspent (they stay with the hero and count as "levels gained" on the next results screen). A frozen hero, a removed Ironman hero
(its profile is gone: the handler jumps to the main menu), a temporary Tournament hero (no level-up screens, `0x70adb2`) and the
tutorial get none of it. openwbc3: a human side's hero levels through `Hero:checkLevel` (one level per update, latch saved with
a saved game and dropped by `profile.save`), the closing of the level-up dialog sends the `levelDone` command, the glow and the
portrait click follow the latch, computer heroes level at once (own). At the end `battlexp.lua` only adds the experience for the
local hero; `Battle:prepareLevels` counts (`Hero:levelsDue`) and the victory screen prints it; Continue runs `openLevelUps` (`Hero:applyLevels`, profile saved,
then the attribute / skill screens on the finished hero, also a fallen one, then the recruiting screen). Own: the points are
spent through commands during the battle (the original applies them on Accept), and the profile is saved with the experience
when the battle ends and again after Continue (the original saves the points before and the level at Continue).
Statistics beyond the results screen (treacheries, hero kills by type, upgraded counts): no screen shows them, see
`docs/todo/not-in-original.md`.

### HUD info area (`src/ui/hud.lua`, the original's control panel draw `FUN_004d7710`, 800x600 coordinates)
Done: the panel's y offset is 456 (the control panel setup `FUN_004d6e00` puts the panel top at 0x1c8 = 456 in the
800x600 layout; the todo guide said 455), the info area is (304, 452). Nothing selected shows the morale page (Game.txt 1097..1100: morale, army limit,
"command effect", attack speed, then the total merchant skill). A single unit: name clipped to 168x20, labels
Game.txt 0258 ("Combat:") on, right-aligned at 517, values at 528 as `FUN_004ddeb0` formats them ("base +diff" / "base -diff") from
`Unit:baseStats()` (type record, per-race overrides, hero values, chaos morph) against `Unit:stats()`; damage "-" for
`attackType` 0, "damage / range" for shooters, the `DamageIcons.bmp` type icon at text width + 4 (hot-and-pointy: fire),
armour and resistance (`Unit:resistances()`: Black Ward, statistic list, the Resist spells), the converting
page ("Converting" and the `ProductionBar.bmp` with the percentage), the attitude icon (`SkillIcons.bmp` 80 + 16 * icon,
40; the original's icon numbers of the attitudes, not traced in the 1.04 binary yet), mana, XP and medals, the psych icon. The resistance page prints the complete
armour (`Unit:completeArmour()`: piercing / slashing / crushing, fire / electricity / ice / magic with the Resist
spells and a hero's item resistances) and the resistant / vulnerable lines or Game.txt 0932. The group page
uses the gold box for heroes and level 4+ and shows the shared attitude icon. Buildings: an own garrisonable tower shows
`Garrison.bmp` with the tiny army pictures (a left click on one lets that army out, command `unload` with `uid`), Game.txt 0126 ("Tower")
and the Combat / Hits / Speed / Damage + icon / Range rows with garrison bonuses (`Eco:buildingStats`); an own tower
without garrison the same rows; mines (resource left, " (*)" and the recovery seconds, workers), temples
(operational / rebuilding), shops, quest sites (waiting / quest given / recovery seconds), conversion progress,
construction and repair progress bars; a producing building keeps its queue. The hovered-unit preview uses the original
health frames (`SelectionRings.bmp` 97, 7 * level) in a border of the side colour and the troop's medals.
Computer-player level bonus of a building's combat (`Eco:aiBuildingCombat` / `buildingCombat`, checked in the 1.04 binary:
the building's combat value is `FUN_0052ae70`; with the real-value option (1) it adds Knave -2, Knight 0, Lord +1, Prince +2,
Warlord +3, Emperor +5 (Passive, Rampant and unknown levels 0) when the owner's computer-player flag is set (`DAT_0070d6a4`, level `DAT_00708fa4`
+ 0x2c * side), on top of the garrison; the base value (0) returns the type record's combat alone, and the army's `FUN_0051bd10`
has no such bonus). The real value is used by the info area (`FUN_004d7710`: base and real through the stat formatter `FUN_004ddeb0`,
so a computer-owned building reads "13 +5"; openwbc3 only shows the tower page for own buildings, so this only appears when
watching or controlling a computer side), by the tower's shot (`FUN_0052d2f0`, combat of the missile) and by the melee /
missile resolution for a building as attacker and as target (`FUN_0042ace0`, both calls with 1): `Unit:strike` now uses the
target building's real combat (type + level + garrison) instead of the bare type value. The building's hit chance `FUN_0052d9b0` also
reads the real value, for the tower's accuracy (see "Missile accuracy and the Scare / Awe spells"). A building's attitude
(the building attitude getter `FUN_0052fc80`: a use flag and the attitude) only hands its attitude to the units it produces, which was already done (`commands.lua`
`attitude`, `economy.lua` production). Check: `selftest` "buildings: computer level bonus".
German labels of the single-army rows: `FUN_004d7710` always loads Game.txt ids 0x106 / 0x107 (262 / 263) for the
fifth / sixth row, in the English 1.04 binary and in both German executables (`Battlecry III Deutsch.exe`, the value calls are
the same armour / resistance code, string lookup a plain array index by id). The German `Game.txt` holds "Reichweite:" /
"Sicht:" there, so the original German game itself prints those words next to armour and resistance; `hud.lua` now shows
the table text unchanged in every language (the earlier English fallback is gone).
Hero pages of the info area (overview, skills; `HUD:drawHeroOverview` / `drawHeroSkills`), checked in the binary's
control panel draw (`FUN_004d7710`, page-mode switch cases 6 and 7; call `FUN_0046e350(font, x, y, text)`): both start at
the info area + (14, 5). Overview: name in FO_MEDIUM (font 5); rows at +20 (x + 8) "Race:", +18 "Class:", +18 "Level:",
each label (XCI text 6/3, 6/4, 6/5) + " " + the value, FO_MEDIUM; the race is XCI text 15 / 104 (race - 8), the class
text 8..11; then FO_SMALL (font 2) at +24 (x + 12) Game.txt 0661 with seconds-per-point = regeneration interval / 1000
(`FUN_0051b460`), an undead hero gets Game.txt 0663 at +16 (x + 8 more) and the mana line 0662 (`FUN_0051b580`) 20 below
the last line. Skills: heading XCI text 18/2 in FO_MEDIUM, +24, x + 8, entries of slots 1..10 with level > 0 as
`FUN_00556c90` (Game.txt 759 + id, then format " +%d") in FO_MEDIUM, two columns 140 apart, 18 per row. Undead heroes
(flag 0x4) now also regenerate at twice the rate and only at night (`FUN_0051b460` halves the interval, `FUN_0051b820`
postpones the regeneration of an undead army by daylight; `Hero:isUndead` / `lifeRegen`). Which pages exist and their
order is still openwbc3's reading (see `docs/formats.md`).
Binary: the control panel draw `FUN_004d7710`; the building's combat value `FUN_0052ae70` and damage getter `0x0052e9e0`
(its speed getter not traced in the 1.04 binary yet); the army's armour getter `0x00525c80` (complete armour), its
resistance getter not traced in the 1.04 binary yet.

### Units, orders, AI
Saved games keep the current order (move, attack, task), the order queue, patrol and guard duty of every unit
(units and buildings are referenced by list index; orders that refer to something not saved are dropped; the
`--sim saveload` test checks it); queued orders are plain data (`Unit:enqueue`).

Attitudes as a rule engine (`src/game/attitude.lua`, after the original's attitude system, 1.04 binary block
`FUN_00505a90` .. `FUN_00508d00`, function anchors below): an attitude is an active area, up to 10 rules (up to 5 conditions on me / my hero /
the designated unit, one action, a priority, "overrides player orders") and an idle action; the attitude update `FUN_005070f0`
takes the highest-priority rule whose conditions all hold (rule evaluation `FUN_00507560`: a rule is skipped while the unit
carries out a player order that rules may not divert unless it overrides, a missing subject fails it), else the idle action,
and when there is none stops the unit's own system orders. The nine built-ins are rule tables with the original's
numbers (the built-in set-up `FUN_00506c40`: Cowardly `FUN_00505cc0` ... Standard `FUN_00506180`; Cowardly: 100 under attack -> run from attackers,
90 immediate threats -> run from threats, 80 no guard threats in the area -> move to the guard point; Stand Ground: 100
threats in attack range -> stand ground; Defensive / Standard / Aggressive / Rampant: 100 immediate threats -> handle
them (Defensive limited to the active area), idle move to the guard point / nothing / random movement; Scout: no
rules, idle random movement; Guardian / Magic Guardian: 100 overriding follow beyond 20, 90 designated unit's threats,
80 own threats, 50 follow beyond 5, Guardian `FUN_00506660`; a dead designated unit turns the unit Standard,
`FUN_005070f0`). All nine conditions (the condition routines `FUN_00507560` dispatches) and all eleven actions
(e.g. `FUN_00508300`, `FUN_00508260`) are implemented, including the hit list (add `FUN_00505b90` / prune `FUN_00505c40`:
entries live 4 s, pruned at most once a second, "under attack" and "run from attackers" read them) and the run
(`FUN_00522f40`: two 4-cell steps away from the inflictor with the 0 / +-1 / +-2 / +-3 / 4 direction fan, table at
`0x00611274`; the run is not interrupted, it gets the player-order priority no rule diverts) with the 8-way direction
`FUN_0040a8f0`. Custom
attitudes are the `CustomUnitAI/*.uai` files (`src/formats/uai.lua`, layout in `docs/formats.md`), listed after the
built-in ones in the attitude dialog (name and description from Names.cfg `CUAI_NAME_` / `CUAI_DESC_`, icon from the
file), chosen like any other attitude (the ones that need a designated unit, e.g. Roaming Guardian, ask for it like
Guardian does), stored by name in the save (`unit.attitude`, with the unit's flight / way back flags and
`unit.att`, the original's per-unit attitude state: current action and scout corner). Buildings only carry an attitude for the
units they produce (the building attitude getter `FUN_0052fc80` returns the attitude at `+0x19e` when the flag at
`+0x19c` is set, else -1, and it is handed to the produced army), which
openwbc3 already did. Not original, openwbc3's own choice (header comment of `attitude.lua`): the Magic Guardian / auto spell casting works through the computer hero's spell logic (heroes only). Checked by `attitudetest.lua` (selftest) and `--sim`.

Attitude slices, threats and the neutral armies (`attitude.lua` `M.update` / `due` / `think`, `unit.lua`, `savegame.lua`; checked in the 1.04 binary): the AI tick is `FUN_00429ec0`, called once per frame message of the main loop (`FUN_0041e320` case 9; the main timer is a 25 ms multimedia timer set up in `FUN_00457190`) and acts on every 10th call (counter `DAT_0074c590`, mod 10) = every 250 ms (taken at one frame message per 25 ms timer tick: the timer callback only sets a flag, so at most one per tick; not timed in the running game): the computer-player driver `FUN_00505310` gives ONE computer side a turn (round robin over the seven side slots), whose think step `FUN_004fa120` begins with the side's threat handling `FUN_00532530(side)`; then `FUN_00532530` of the local side and, unless it is the tutorial (`DAT_00748946 == 3`), of the neutral side, and (host only) the critter threat handling `FUN_00532590`. `FUN_00532530` runs through the side's list, skips armies that are off the map (garrisoned) and calls the attitude update `FUN_005070f0` (whatever the army does; the building branch is the tower's own search, `FUN_0052d0d0`). So a unit is looked at once per slice of its side, nothing evaluates it in between: a hit army only gets its has-been-hit flag (the army's hit routine `FUN_00522860`; the damage itself fights back with no order) and reacts at its next evaluation. openwbc3: `attitude.update` (from `world:update`) marks the sides of a slice (the next computer side, every human side - the original runs one process per human, the simulation all of them - and the neutral side, not in the tutorial), a unit evaluates once per mark as soon as it is idle, walking or attacking; the schedule, each unit's last slice and `wasHit` are saved. The hit list is only filled for the armies of human sides (`FUN_00522860` calls the hit-list add `FUN_00505b90` only when `FUN_004a5c40`, the "this peer simulates it" test, is true) and is saved with the inflictor / victim by index and the times relative to the clock. The start attitude is the army type's: the type loader (`FUN_0041b3d0`) turns every ARM default attitude except 0 (Cowardly) into 2 (Defensive), the army constructor (`FUN_00519ae0`) gives heroes Defensive and, in the tutorial, the armies of the other sides Stand Ground (`attitude.initial`); before, every unit started as Standard. Threats are the army's own threat handling (`FUN_0051a470`: reads and clears the has-been-hit flag, critters never find threats, leaves a unit alone that attacks the best threat, otherwise a fight (`FUN_0051da60`) as an overridable system order or the run `FUN_00522f40`; no threat and hit and no order and not Stand Ground -> a random move, `FUN_00522db0`) over the best-threat search `FUN_005334f0` and the threat priority `FUN_00533c40`: the best priority wins (not the nearest) - 50 + max(0, 11 - distance), +30 when what the target attacks belongs to my side, -40 when it cannot attack, 0 beyond 25 cells and for mines, lairs, shops (`BR` / `BL` / `BS`) and the flag in capture the flag - the first in the scan order (rows, columns, ground before air) on a tie. Enemy armies (neutral ones too, critters never, nobody off the map or invisible, nobody the finder cannot hit) and enemy buildings are threats; the neutral side's only buildings that are, are towers with a damage (priority 21, not in the tutorial); a human side skips buildings under conversion (and, see "Threat search leftovers" below, not walls). The Stand Ground action and the "threats in attack range" condition scan the cells around the unit out to its range (the first neutral or non-allied army / building; a neutral one for the condition only with a base damage). Since neutral armies are Defensive like everything else, the lair creatures and every free neutral army fight what comes within 12 cells (and 20 of their guard point) on their own, and the player's idle units attack neutral armies and towers in the same box, as in the original; the old lair guard radius (`AGGRO`, 6 cells), the immediate fight back of a hit unit and the 0.5 s own-order re-check are gone.

Threat search leftovers (`attitude.lua` `bestThreat` / `huntPriority` / `critterRest` / `shapeBox`, `fog.lua` simulation sight, `economy.lua` `buildingAttack`; all read from the 1.04 binary):
- **Fog test.** The best-threat search `FUN_005334f0` asks the local player's fog for every side whose computer-player flag (`DAT_0070d6a4`) is unset: the visibility test `FUN_0047f560` is true when neither fog nor hidden map is on, the cell's "seen now" flag with fog of war (modes 1, 2) and its "explored" flag with the hidden map alone (mode 4); the neutral side counts as a computer player (its flag `DAT_0070d6aa` is set at game start, `FUN_004de740`), so neutral armies see everything. An army counts when its own cell is visible, a (non-neutral) building when any cell it covers inside the box is; for the local side every building must also have been seen (display flag at `+0x131`: set at once without fog / hidden map by the building display set-up `FUN_00536060`, otherwise by the drawing code once the building was in view and seen, e.g. `FUN_0044d480` for a visible cell), which neutral towers need too but not the cell test; critters need neither. This can be done deterministically in lockstep because sight is a function of the world alone: every human side has a fog of its own in the simulation (`world.sight[side]`, a `Fog` that is never drawn, `world.opts.fogMode` 1 / 2 / 4), recomputed at the attitude slices (250 ms, `fog.refresh`), with the explored cells, the visible cells and each building's `seen[side]` saved (`data.sight`, buildings' `seen`), and scenario events that uncover the map and the Farseeing power-up applied to it as well. The screen's fog (one viewer, redrawn every frame, F9) is not read by the simulation. Differences kept: the original's smoothed fog cells for the cells on screen, the per-frame update and the draw-time seen flag (here the four cells of the original's draw-time test, at each slice). `--sim saveload` checks the round trip; `attitudetest.lua` the rules.
- **Walls.** The binary skips only buildings under conversion (`+0x14a`) for the local side; `FUN_005334f0` has no test for the walls and the rampart (`BWIC`, `BWBR` ...), so idle units of a human side do attack walls in the box.
- **The critters' hunt** (a branch of the threat priority for the 11 codes `AMIX ABHX AMGX AMMX AMNX ASCA AOMX AADE AVGX AVJX AVHX`, which carry `behaviour.hunts` in `content/base/tags.lua`; the animals' resting rolls are `behaviour.critterRest` there): a critter in the box (no fog test, no side test, not for a finder that cannot hit it) is prey with priority `1 + min(200, (max hits - hits) / 4)` for a wounded Minotaur `AMIX` (sheep, cow, camel, penguin, seal, turtle), for `AMNX` / `AMGX` / `AMMX` and a Minotaur-race hero (the same and geese), `1` for the Troll `AOMX` (sheep only) and the Catapult `ASCA` (cow only), and `1 + min(200, (7 - mana level) * 4)` for a daemon `AADE` / `AVGX` / `AVHX` / `AVJX` at a Soul while its mana level (`FUN_0051b2c0`: 7 * mana / maximum, a non-hero without mana counts as -1) is below 7. The priorities compete with the real threats (a badly wounded Minotaur prefers a sheep to an enemy). The pick-up fight itself was done with the unit specials.
- **The critter's reaction** (`FUN_0051a230`, called for every real critter of the neutral side - not the Souls - by `FUN_00532590` in each slice, not in the tutorial; the original on the host only, the simulation everywhere) is no flight: most animals rest. A first roll 1 .. 100 lets sheep off up to 79, camels 86, cows / turtles / seals 99, geese / penguins 9; with a second roll an animal that is busy stops with 2 % (roll 1), an idle one walks to a random cell anywhere on the map (1 .. width - 2, 1 .. height - 2) with 75 %. The guarding branch (3 % to stop) and the 1-in-200 guard pick do nothing in the shipped code (the binary only draws the numbers). It replaces openwbc3's old 5 % step of up to 4 cells, which also moved every other neutral army.
- **A tower in the threat priority.** `FUN_00533c40` gives a building the same second half as an army: its target (`FUN_0052a410`, the building's current attack target) of my own side (not an ally) +30, a damage below 1 -40; no target adds nothing. The target is the one the tower's own search chose (next bullet), kept in `b.target`.
- **The tower's own search and shooting** (`attitude.towerThink`, `Eco:buildingAttack`; read from the 1.04 binary). The side's threat handling `FUN_00532530(side)` walks the side's list in the same slices as the armies (see "Attitude slices": the computer side whose turn it is, the local / human sides, the neutral side except in the tutorial) and calls `FUN_0052d0d0` for every building that is on the map (type 1 of the item's vtable `+0x28`; armies go to `FUN_005070f0`). `FUN_0052d0d0` does nothing for a building whose base damage (`+0x7c`) is 0; a player-ordered attack (`+0x13c`: not implemented, openwbc3 has no command for it) is left alone while its target exists; a building with an order in its queue (`+0xbc`: production, research) does not look; otherwise it calls the best-threat search `FUN_005334f0` with the box x +- range, y +- range around the threat centre (`+0x15e` of the display item: the building's column and the middle row of its shape, (grid.x, grid.y + ((height - 1) >> 1)), stored when the building display is placed by `FUN_0053bca0`, slot 4 of the vtable at `0x005eaee0`; `FUN_0052d0d0` reads the stored point) where range is the real value of the building's damage getter `0x0052e9e0`, i.e. the type's plus the garrison's (hero +2, missile unit +1; `Eco:garrisonBonus`), and minimum priority 255 (= any). Found: if it is the target already, nothing changes; else the tower sets its attacking flag and stores the target's side (`+0x134`) and id (`+0x138`). Nothing found: attacking, side, id and the shot timer (`+0x140`) are reset. A target farther than range + 2 (a map inconsistency) is cleared and `FUN_0042d550` repairs the map: not done, cannot happen here. The search itself is the army's with three tower differences, all inside `FUN_005334f0`: the attack type of the building (its record's 1 ground, 2 air, 3 both; the table at `0x006977ec`, 200 bytes a type) selects the layers, an air-only tower passes the ground armies but not the buildings; a tower of the local side (a human side here, as for the fog) never takes a building (the local-side test at the first building branch), so only armies, while a computer side's tower and a neutral tower do take buildings (and a computer side's tower the neutral towers at priority 21); no fog test for a computer side or the neutral side, the fog of the simulation for a human one. `Eco:buildingAttack` is then the finished building's update (code at `0x0052c4d0` - `0x0052c5b0`, which the Ghidra project has no function for; it calls the building's attack `FUN_0052d600` at `0x0052c549` / `0x0052c578`): with a damage and the attacking flag set, a next-shot time of 0 fires at once and sets the next time to now + interval, otherwise a shot when the clock has reached it, the next time = the old one + interval (`+0x148` the interval, set after the shot from the building's real speed). The attack `FUN_0052d600` looks the target up by id and side (`FUN_005322a0`) and does nothing when it is gone, dead (state 8) or in another side's hands (the interval is spent anyway); there is no range test (except for a player-ordered attack), so a tower goes on shooting at a target that has walked out of range until its next turn; the combat message `0x137` follows when damage and range are above 0. The shot `FUN_0052d2f0` takes the missile and damage type of the garrisoned missile unit with the highest base combat. openwbc3 changes from the old rule (nearest enemy, every tick, nothing for neutral towers, ground-only and air-only towers shooting at anything, never at buildings): neutral towers fire, air-only / ground-only towers respect their type, towers of computer sides shoot at buildings. `b.target`, its side, `b.nextShot` (relative to the clock) and the tower's last slice are saved (`attitude.saveTowers`; `--sim saveload` checks them); `attitudetest.lua` ("tower:" / "tower shot:") the rules. `FUN_0052d0d0` has no test for a building under construction, so an unfinished tower looks (and holds a target, which the threat priority and the computer player's "shooting" count read) but does not shoot, as in the update.
- **The shape of a big army.** The Stand Ground action `FUN_00508300` and the "threats in attack range" condition `FUN_00507e40` scan `[x - (w - 1) div 2 - 1 - k .. x - (w - 1) div 2 + w + k] x [y - (h - 1) - 1 - k .. y + 1 + k]` (w, h = the army type's shape, k = max(0, range - 1), the map position the bottom middle cell), so a Catapult (2 x 2, range 14) reaches one cell farther than a single cell army would. At the first cell with something in it the original walks the two layers and lets the second replace the first unless the first is a neutral army that can hurt or the army the unit last stood against; the scan is column by column for a building's cells too (`shapeBox`).
- **Ctrl+F** (KeyMap.txt "Default Attitude", shortcut index 53, case 0x2b of the key dispatcher `FUN_00427fb0`) calls the selection's attitude setter `FUN_00534070` with 6 = Standard for the selected armies (and buildings) when the first selected item is the player's; it is not the army type's default (which is Defensive), openwbc3 already did this.

Computer players: see "Computer players" below (`ai.lua` and its modules). The AI levels are the original's (0..7, named by XCIStrings [0214.*]: Passive, Squire, Knight, Lord, Prince, Warlord, Emperor, Rampant); Passive is a computer side all the same (computer flag `DAT_0070d6a4` set by human / computer alone in `FUN_004494e0` / `FUN_004de740`, an AI object from `FUN_00504a30`) whose turn runs only the side's attitude pass `FUN_00532530` (each army's attitude update `FUN_005070f0`, each building's threat search `FUN_0052d0d0`) and returns at level 0 in `FUN_004fa120`: its armies keep their attitudes and its towers shoot, on the side's round-robin turn and without the local player's fog or hit list, but it builds, groups, casts (`FUN_005001d0`) and resigns nothing, Rampant (level 7, like the neutral side, takes the short path of `FUN_004fa120`, which skips the economy steps and calls the attack `FUN_004fa850`) has no economy and only repairs, defends and attacks.

Hero system (openwbc3's own, see `docs/hero.md`): the new-hero and customise screens exist (`heroselect.lua`,
`herocustomize.lua`, lists in `herocustom.lua`) and store portrait, avatar, voice set, password and mode with
the hero. Used now: the avatar is the hero's unit in battle (the hero placement `FUN_0043b550` puts the avatar's
unit on the map), the voice set replaces the unit code in the hero's speech files (the sound cache's file-name
builder `FUN_00511c10`), the hero selection asks for the password
before choosing, loading a game and deleting the hero (`PNL_PASSWORD`, case-insensitive compare, error sound on a
mismatch, heading = text 142.4; masking of the entry is not verified), Ironman heroes earn double experience and are
deleted when they fall (the army's experience add `FUN_00527100` doubles for hero mode 1 at `0x709d20`, the fallen
hero's deletion `FUN_00522260`, campaign file included; the double experience is off in network
games to keep peers in step).

Hero security (the hero selection screen of the 1.04 binary, `FUN_005549f0` .. `FUN_00555bc0`, with the hero delete
`FUN_00555550`; the Ironman registry helpers `FUN_00452b40` / `FUN_00452db0`):
- The password check is `profile.passwordMatches(rec, text)` (`profile.hasPassword`). Every way to pick a hero - single
  player, campaign and the multiplayer lobby - goes through `screens/heroselect.lua` (the main menu pushes it with a
  callback), exactly as the campaign / multiplayer flags of the original's one hero selection screen, so
  there is no unchecked path; the Delete key used to skip the password and no longer does.
- Delete: Delete button / key -> the generic OK / Cancel dialog (`FUN_004361c0`, the original `PNL_OKAYCANCEL`
  panel, heading `TXT_EXTRAHERO` 0, text 1 + 2 wrapped to 380 px) -> only after OK the password prompt of a hero that has
  one -> the hero, its saved game and campaign files go. The original's order is confirmation first, password second
  (`FUN_00555a70` opens the dialog, its OK callback `0x00555ad0` asks for the password, then the files go).
`PNL_SECUREHERODELETE` is the
  GameSpy "secure hero" database delete and is not used for local heroes.
- Ironman record (`profile.deleteIronman`, the registry test `FUN_00452db0` / record `FUN_00452b40`): a hero
  gets a random 32-bit magic number at creation (four 1..255 dice bytes, `FUN_0054c000`; older heroes get one when first
  listed). When an Ironman hero dies, the sum and xor of its name characters and the magic number go to the first of
  two rolling slots (`LIMHK0_*` -> `LIMHK1_*` in the registry; here `ironman.lua` in the user data directory, same two
  slots), and an Ironman hero file whose magic number is in a slot and whose sum or xor matches is refused and removed
  when the list is built, so a restored backup of a dead Ironman hero disappears again. The original ignores the
  record when the registry keys are missing; openwbc3 does not need them. The original records the death only
  (`FUN_00452b40` is only called by the fallen hero's deletion `FUN_00522260` and the results screen's `FUN_00455d60`),
  not a manual delete; so does openwbc3.
- A resurrected hero (openwbc3's own opt-in rule, `docs/hero.md`) comes back as the player's chosen avatar and with
  the hero's voice set (`World:heroCode`, used for the start hero as well); before it was the race's default unit.

Small rule gaps (the original's behaviour; 1.04 binary anchors where given, the rest is marked as not traced in the
1.04 binary yet):
- Plague piles and Contamination: `heroskills.plaguePiles` counts the live `BPSP` buildings (the Plaguelords build
  them; none of the 115 scenarios places one; the original keeps a counter at `DAT_0070d630`: +1 when placed, -1 on
  death; the binary reads it only in `FUN_0040d9b0` and in the two disease-strength spots of the army's hit resolution
  `0x0051abe0`).
  `heroskills.virulence` (the disease virulence `FUN_0040d9b0`) = piles + Contamination of every living hero:
  a disease lasts 600 s + 15 s per point (the army's disease setter `FUN_0051c060`: `(virulence * 3 + 120) * 5000` ms), the
  combat / speed loss of a diseased unit grows by 1 every `5 + 2 x (resistance - virulence)` seconds (at least every
  second) up to `10 + virulence` (at most 100; `FUN_00532a20`, every 40th call), and a disease attack or a diseased
  attacker gets the piles (not the skill) added to its strength (`unit.lua`).
- Scavenge (Bronze Golem, `FUN_00579410`): one d8 roll per heap of rubble within radius 6 (dx^2 + dy^2 <= 36,
  not a square), the roll table and the dice `FUN_00458e70(level + 1, 20 / 40, 20)` were already the original's; the heaps are
  removed afterwards (the rubble clean-up `FUN_004adc80`), which was missing, so the same wreck could be scavenged every second.
  openwbc3's heap is the wrecked building itself, one per building (own simplification). The 1 s button throttle is
  shared by all casters in the original (one static stamp in the button routine `FUN_004cfce0`).
- Plunder / pillage (the building's death `FUN_0052b3e0`, the branch for everything that cannot really be destroyed,
  `FUN_0052f980`: resource producers and the four temples): a mine pays 10 x its production (at most what is left) to the
  attacker (the owner when there is none) and loses twice that, turns neutral and works again after 4 minutes - or
  is out of commission for good when nothing is left (new: `hp` 0, no recovery). New: a temple (`BTCE`, `BTIN`, `BTDR`,
  `BTEL`) is pillaged too: neutral at once (a hero can convert it again), full hit points after 2 minutes, drawn with
  its special art frames 0 / 1 / 2 (2 from 40 s before the end, 1 from 80 s), "Rebuilding" in the info area (that part
  existed). The `" (*)"` / recovery lines of the info area, the building income `0x0052aac0` ignoring pillaged mines and the attack
  stop on pillaged resource buildings were done before.
- Income of armies (the army income `0x005299d0`): an Ancient Wisp brings 4 crystal and a Leprechaun 2
  gold with every income (army vtable slot +0x34, called by the side income `FUN_00531f10`). Wisps
  do not work in mines (the army's mine-work test `FUN_00523e70`); the elf AIs' order intervals (`FUN_004ff470`)
  add their wisp count to the crystal mine figure (done with the AI).
- Raze all / kill all (conditions 12 / 13 of the scenario event routine `FUN_00514670`): the judged side counts its non-resource buildings /
  living armies, every other side "has something left" with any building (mines too) / any army in its list. The
  asymmetry is only an evaluation order: each side is judged by its own rule first, a side with only mines is
  defeated by its own check and then drops out of everyone else's loop, so openwbc3's one rule (non-mine buildings
  for every side, `Eco:sideAlive`) gives the same result; nothing to change. Fortress and assassins use
  the defeat-stopping test (army `0x0051a1c0`, building `0x0052a3e0`) / the hero the same way.
- Building ability leftovers: the original never offers the Feast button (moved to `todo/not-in-original.md`;
  `FUN_004d2300` has no such button); swords of Sirian (`FUN_0057a3b0`) start with the initial experience
  `FUN_00557d90(side, sword, no training, lords, gate)` and go through the
  Poison Gate / Corruption check of every summoned army (`spells.summonedFor`, which now also asks for army room on
  the corrupting side as the original does); the army-creation case of the host message is the original's place for
  that check. The computer's one-in-N dice use `math.random`: lockstep-safe, the original's dice stream cannot be
  matched (own choice). Couatl's Wrath is the Titan's explosion (spell effect 35, missile `EMTF`): the
  same ten offsets from the binary's table at 0x00608190, which holds signed 16-bit deltas (so the negative offsets
  count) and the same ball sprite `EMF0`; the balls are real missiles now (`EMTF`, very slow high arc: `distance x 15 >> 2` steps of 50 ms,
  see "Missile flight"), and the damage is the ball's burst on landing, not a spell effect of its own.
- Campaign journal: entries carry the first video reward of their action (`state:addJournal(..., video)`, also for
  defeat entries as in the journal writer `FUN_005a1040`), the journal page shows a "Play video" button on those entries
  (`BUTT_CAMPAIGN_PLAYVIDEO`) that plays the converted video again. The eight videos (`Episode1..8.bik`) are all in
  `Video/`, so `--convert` already covers them. The journal page itself is still openwbc3's list, not `PNL_CAMPAIGN_JOURNAL`.
- Spell book (the spellbook dialog, `FUN_0056f910`, vtable `0x005eab34`): the 16-frame sphere animation is only
  counted in the original (never drawn) and its sphere icon buttons do not exist (its button test never finds one; not
  traced in the 1.04 binary yet), so the "leave the dialog with the mouse after using a button" rule can never fire:
  nothing to port. Ported: the cursors of the dialog's cursor routine `0x005703b0` (pointer hand over
  the cancel button, arrow over the pages, pointer-up hand elsewhere in the dialog; `screens.lua` asks a screen's
  `cursorName()`), and the number keys cast only with enough mana (the dialog's keys `FUN_00570200`).
- Fonts: shop, quest dialog, save slots and the spell bar use the game's own text font through `fonts.plain(size)`
  (follows `customfont`) instead of LÖVE's default.
- The spell bar above the panel is openwbc3's own and off by default: Options, Graphics, "Spell bar" (`[options]
  spellbar` in openwbc3.ini).

Game rules from the scenario / skirmish options: tech level (0..5) and No Dragons / Eyries / Titans / Towers /
Walls limit building and production (`Eco:levelOk`, after the original's level test `FUN_0040c990`; the production list tests the
producing building, as the original does - not traced in the 1.04 binary yet), set from the map
header or the skirmish panel. Tough Towers (`gamedata.toughBuilding`, applied in `World:addBuilding`) and No
Heroes (the start force is the race's plain general `AxGX` and two builders instead of the hero, no hero system; see "No Heroes start force" below), both offered in the skirmish mods selector. Towers / walls re-picked to the owning
side's race (`gamedata.raceVariant`, applied in `World:addBuilding`, from the original's building creation
`FUN_004a50f0`): the towers a scenario places are only placeholders, so Circles, Desert Crossing,
The Hill, Lands Divided ... would otherwise show the wrong race's tower with the wrong hits, damage and damage
type; the record's own current hits belong to the old type and are dropped. The orc totem BWTP and the Guardian
buildings BWGC / BWGS / BWGI are not in the original's lists and keep their code. Victory conditions as a
selector in the skirmish / multiplayer setup (`opts.victory`, also read from the map header) with the forced
options (pitched battle: tech 0 and 50 points, King of the Castle / Rich Get Richer: tech 5, raze all / raze
fest / fortress: tech >= 1, Battle of Titans: titans and heroes allowed, no assassination without heroes,
Capture the Flag only in multiplayer): raze all / kill all / fortress with the 5 minute countdown, razefest /
slugfest (30 minutes, most razes / kills wins, a draw extends by 5 minutes), king of the castle, rich get
richer, battle of titans (a titan per side, computer heroes level 50: the text says 50, the computer hero maker
`FUN_0042a0d0` sets 100 for victory condition 10),
capture the flag (one flag per side, cannot be hurt; the conversion test `FUN_0052da90` accepts a flag `BMFL` before
any other test, finished, pillaged or garrisoned, in any game), the countdown clock and the
running-total panel (modes 4, 5, 7, 8, 12). The multiplayer lobby sends tech level, mods and victory condition.
Event forms 18 and 30 fire; forms 11 / 20 / 21 / 22 have no code in the original either. Tech level 0 greys out
the Build button; the skirmish tech level was never passed to the battle before (fixed). Savegames keep the rule,
the countdown and the `titan produced` flag. Header `standardVictory` off: the scenario's events end the battle.
Side flags: the scenario's per-side locks are honoured in skirmish / mphost - a side whose race is fixed shows
that race as plain text, a side that must stay in play cannot be closed, and a side that must be a human player
is taken by one (more under "Skirmish setup rules").

### Conversion and attacking (battle screen)
The neutral side is hostile to every real side (the original's alliance matrix is FALSE whenever one of the two
sides is the neutral one: the 7 x 7 matrix at `0x00748915` filled by the game setup `FUN_004de740`), so right-click attacks neutral units and buildings;
pillaged buildings are never attacked, and shops and quest sites are matched before the attack in the original's
right-click chain (the right-click map action at `0x00421190`, no Ghidra function; that order was not traced in the
1.04 binary yet) - openwbc3 keeping them peaceful
for everyone is its own choice.

What a hero may convert follows the building conversion test `FUN_0052da90`: the
second letter of the code, uppercased, must be K (keep), A (power-up altar), P (production point), R (resource
point) or T (temple) - lairs (the BL.. nests and the BS.. ones too), shops, shrines and walls are not
convertible; a garrison that already holds units cannot be converted (the garrison test `FUN_0052db10` and the unit
count `+0xca` > 0). Right-clicking an enemy only ever attacks: in the original the only way to convert is the Convert button
(the Ctrl+C shortcut only presses that panel button: the shortcut handler `FUN_00427fb0` presses buttons by their icon
through `FUN_004d2290`), the right-click chain has no
convert action at all.

### Mines, garrisons and minotaur feeding (`src/game/unit.lua`, `src/game/economy.lua`)
What may work a mine follows the mine-work test `FUN_00523e70`: only a builder works one,
and the Dwarf Smith / Engineer take two of the eight places (`cmp word [edi+0xca], 8` at `0x00421fa7` of the right-click
action), so heroes, wisps, treants,
eagles and the critters never do. What may garrison a tower follows the garrison test `FUN_0051c240`: not
wider than one cell, `unitValue` 1, not a flyer (the flyer flag 0x200000, the `moveType` 1 of every unit here), not a
builder that is not a hero, not a critter (the critter test `FUN_00528280`: sheep, cow, goose, penguin, camel, soul, turtle, seal),
not an illusion and not the Eye, up to 4 (`FUN_0052db10` refuses a building holding more than 3). The minotaur flag 0x80 is per unit, not per
race: the five Minotaurs of the race (hero, king, plain, shaman, axe thrower). A minotaur right-clicked on one of
its own side's critters gets the plain attack order (the right-click action tests the critter at `0x00422188`) and eats it: when
the critter dies the attacker is healed to `min(maxHits, hits + 20)` with "Eating.wav" (the army death routine `FUN_005210b0`); a Soul
is not a critter for this (the critter test `FUN_00528280` with argument 1), so it is not eaten.

### Unit specials (`src/game/unitspecials.lua`; checked in the 1.04 binary)
One module holds the per-code rules of the army death routine (`FUN_005210b0`), the titan explosion (`FUN_00520f20`), the
explosion (`FUN_00529a40`), the fight activation (the bytes at `0x00523150`, no Ghidra function) and the army damage getter
(between `0x00525c00` and `0x00526b00`); `Unit:die` calls `onDeath` / `onCritterKilled`, `Unit:attackRange` / `Unit:strike` / `updateAttack` the
attack rules. Where older readings differed the binary wins (below).
- Titan (the `T` in the STATUS column): ten balls leave the titan to fixed cell deltas from the table at `0x00608190` (8-byte
  records x, y, speed, height: (-5,5) (-3,-11) (7,4) (1,-4) (-6,12) (11,-8) (1,-12) (-11,-4) (2,8) (4,-3); heights 0 1 2 as
  arc), fire balls `EMTF` (sprite `EMF0`, `STEZ47.wav`) or magic balls `EMTM` (sprite `EMM0`, `STEZ23.wav`) when the third
  character of the code is V A F K U G, plus `STEZ27.wav`; cells outside the map are skipped. Nothing sets a damage on the
  missiles, but a ball that reaches its cell bursts for 150 damage to everything round it (the missile's frame update, see "Missile
  flight"; before this was display only, which the binary does not support). The same ten deltas are Couatl's Wrath's.
- Firebomb `AASX` and Spore `AGSP` die on contact (the fight activation kills them without a target check) and in the death
  routine explode with the unit's damage as a normal hit of fire damage (armour function `FUN_0042bbf0`, type 3) on the army or building in
  each of the 8 neighbour cells and, with half the damage (`SAR word [esp+0x4c],1` at `0x00529bff`;
  it used to be the full damage here), the 12 cells of the ring behind them (tables at `0x00611330` / `0x00611370`), not its own
  side. The "explosion pictures" are two particle bursts, not sprites (see "Effect emitters" below).
- Ancient Treant `AWKX`: two Treants `AWJX` at its place; Spider Priestess `AKOX`: six Spiders `AKKX` with the arrival effect `EZ08`.
- Killed by a hostile army (another side, not in its team): a Succubus `AVIX` leaves a neutral Soul `ACSO` that vanishes after
  120 s (for a critter victim only when a 1..100 roll of the dice `FUN_00458e70` is below 20); a Queen Spider `AKLX` lays Spider Eggs `BMEG` (40 s) at the
  victim's cell for its side. The eggs hatch `min(4, free army slots)` Spiders when the 40 s are up.
  Checked in the 1.04 binary: the building update function has no Ghidra function (it is the code around `0x0052c700`
  .. `0x0052d000`; its `KeepConversion.wav` string is referenced at `0x0052cfeb`); the spell-building expiry block there
  (expiry time less than the time) compares the display item's code with `BMEG` (`cmp [edi+0x34], 0x47454D42`),
  computes the owner's army limit minus its army count (the arrays at `0x00709108` / `0x00709124`), clips it to
  4, and for each one fills an army-produced message (`0xFA`) with `AKKX`, the building's map
  cell, extra experience 0 and the effect `ESSP`, then deletes the building. So it is the expiry, not the destruction;
  eggs that are destroyed leave nothing.
- A Soul killed by a Daemon / Summoner / Daemon Hero / Reaper: a hero gets `min(25, missing mana)`, a Reaper
  that is not a hero 20 experience, the others `min(25, missing mana)` with a ring for the mana leech effect.
- Troll `AOMX` killing a sheep `ACSH`: +1 ammunition (`unit.ammo`), `GettingSheep.wav` (1 s throttle), the
  corpse goes at once; Catapult `ASCA` killing a cow `ACCO` within 20 cells: the same with `GettingCow.wav` and it may fire again
  at once (its next combat time is set to now). The binary knows no seals, turtles, penguins or camels here.
  A Troll after a sheep, a Catapult after a cow, a Minotaur (`AMIX` `AMMX` `AMNX`) after a cow / sheep / goose and a daemon after
  a Soul fight in melee with damage 100 (the damage getter's range 0, the minotaurs' range 0 list is all seven critters).
  With ammunition and a crushing (damage type 5) missile the Troll throws a sheep and the Catapult a cow: damage x3, the
  missile picture `ACSH` / `ACCO`, ammunition -1. The counter is in the HUD (`SkillIcons.bmp` 186,125 / 218,125 at the info area
  + 15, stats point + 4, the count centred below; not traced in the 1.04 binary yet) and in the savegame.
- Army limit: a living Knight Lord `AHEX` adds 2 and a Warlord `ABEX` 1 to the hero's addition (a per-side count, read by the
  hero's army limit function `FUN_005269a0`, written when the unit is made and when it dies).
- Damage spell effects (the army damage getter): the best damage spell effect (Fire Breathing fire at range 5, Ice Floe ice at range
  12, the spell's strength as damage) replaces the base attack only when its damage is at least the unit's or when it gives a
  range to a unit without one; damage, type and range all become the effect's (the range unconditionally in the binary) and
  the power-ups come on top. A weaker effect leaves a shooter alone (it used to turn every unit into a fire shooter).
- Black Mage `AHGB` (not a hero): the mana leech function `FUN_00526de0` gives it 5 mana per kill of a
  non-critter army of another side, at most once a second like the hero's Leech; `spells.onKill` does it now (`lastLeech` is saved).
- Effect emitters (`src/gfx/emitters.lua`, shown by `gfx/battlefx.lua`; the simulation only sends `world:event("emit", entity,
  code)`; all three tables, the frame timing and the building emitters are in "Display and sound options" below). The soul
  sparkle `ESSP`, mana leech `EMLE`, chaos effect `ECHE` and chaos cast `ECHC` have no sprites: they are invisible dummy effects
  (`EDUM`, 16 frames) that spray a particle burst, which is why they had no picture of their own. Where they start (all checked
  in `FUN_005210b0` / the effect spawner `FUN_0044e8f0`): `ESSP` on a Soul left by a Succubus (effect id in the army-produced
  message) and on the Spiders of hatching eggs; `ECHE` as the target effect of the Spider Eggs (the spell message's
  `0x45484345`); `EMLE` on the killer when a hero's Leech / Mana Leech spell or a Black Mage adds mana, and on a non-hero Daemon /
  Summoner that eats a Soul (a hero eating one has no effect, a Reaper gets experience). `ECHC` is the casting effect (caster) and
  target effect (each army or tower the spell changes) of the chaos sphere's Morph Combat / Speed / Hits / Damage / Tower and the
  casting effect of Learn Spell: since the per-spell table was read from the 1.04 cast functions (`docs/spells.md` "Effect
  pictures", "Effect pictures" below) these come from the spell records' `pictures`, not from `emit` events of the spells (the
  troops' Plague Cloud still sends one: it is not in the table, not traced in the 1.04 binary yet).
  Explode's and the Minotaur's meal bursts are the particle calls in `FUN_00529a40` / `FUN_005210b0`. Correction: Mana Leech
  `EMLE` is not an 8 cyan star burst of its own: its `case` has no `break` in the original (`0x0040efe4` runs on into `0x0040f032`),
  so it is Venom Touch's block, one green glow particle per effect frame.
- Checks: `--selftest` ("unit specials" block, `fxtest.lua` for the emitter table), `--sim saveload` (ammunition and unit
  timers; `summonUntil` is saved now, a summoned creature used to turn permanent after a load).

### Psych auras and the chaos status (`src/game/psych.lua`; checked in the 1.04 binary)
The task description of this item assumed that the original's chaos state belongs to the Chaos spells (the morph
spells, Plague, Drain Mana). It does not: the Chaos spells never set it (they change the stored statistics for good, as
before). The chaos state is the flag 8 of the army's psych effect byte (+0xBA of the army data item), one
of four psych effects 1 fear, 2 terror, 4 awe, 8 chaos (+ 0x10 immune) that the **auras** of armies put on enemy armies: an
army type record with a psych effect of type 1 .. 4 (strength, type, range in cells; `type.psych`) - Hydra, Banshee,
Wyvern, Minotaur King, Giant, the elementals, the Vampire, Treants (fear); the Dragons and Titans (terror, strength 5 /
10, range 5); Unicorn, Archon (awe); Doom Knight and Slayer Knight (chaos, strength 12 / 9, range 6 / 5). Before, those
records were only read for poison / disease (types 5 / 6), so none of the auras worked.
- The psych pass is `FUN_00532a20` (called by the main loop `FUN_005468e0`, the counter
  `DAT_00afd4d4` runs to 0x28 = once a second); the aura list is built by `FUN_005332e0`. Per living, non-hero army:
  the psych timer counts down (terror's end clears the orders and the army runs), then for every enemy aura (an own or an
  allied side is the command radius pass of `morale.lua`) within `max(dx, dy) < 20` and `floor(sqrt(dx^2 + dy^2)) < range`:
  nothing if the army already has any psych flag (including the immune flag), if it has the same capability itself or
  terror, or if the psych bonus function `FUN_005286c0` says immune (drunk, mechanical, titan, critter, then the race
  rules: fear Orc slow (x3), High / Dark elf and Undead immune, Wood elf and Daemon resistant (+5); terror Orc slow,
  High elf and Undead immune, Wood elf resistant; awe Orc slow, Dark elf very slow (x2), Undead and Daemon immune; chaos
  Orc slow, Undead and Daemon immune, Minotaur very slow and resistant, Insect resistant); the roll is
  `chance = max(1, (strength - resistance + 10) x 5)` (resistance +5 / -5 / 0 from the bonus flags): a d100 above it makes
  the army immune to psych effects for 30 s (ECM0 cell 7), otherwise the effect starts: fear 45 s, terror 15 s, awe 30 s,
  chaos 30 s (the slow recoveries lengthen it by 2x / 1x of that), the hero's command radius bonus ends. The timers and the
  flag values (0x1E / 0x2D / 0x0F / 0x5A / 0x87 ...) are the immediates of the binary.
- Chaos is in the army armour getter (no Ghidra function, it starts at `0x005260A0`; `test [esi+0xBA], 8` at `0x005260CB`: armour 0,
  strong / weak types kept), the damage getter (starts at `0x00526310`; `test [ebp+0xBA], 8` at `0x0052633D` right after the base
  value is copied: the base damage, type and range are returned) and
  the resistance getter (`FUN_00526b70`: the real value is clipped to the base value); the combat getter `FUN_0051bd10` and
  the speed getter `FUN_0051c460` clip to the base value as well (`+0xBA & 8` near their ends). `Unit:stats`
  (`psych.chaosStats`) and `Unit:resistance` do that: combat and speed never above the base statistics (type record, level
  and the Chaos morph spells), armour 0, base damage, no spell damage effect, power-up bonus or fear / awe changes, the
  resistance never above the base; disease still lowers combat and speed. The command radius bonus is blocked
  (`morale.lua`).
- Terror: starting it drops every order (`stop`, attitude state reset); an army under terror told to attack (a player's
  order or an attitude's own) runs from the target instead (the attack order becomes a run order, not traced in the 1.04 binary yet; `attitude.run`); when the terror ends
  the orders are dropped again; its fight speed is slowed like fear's and awe's. The effects exist as the unit effect
  kinds `fear` / `terror` / `awe` / `chaos` / `psychimmune` of `status.lua` (saved by `savegame.lua`, shown by the ECM0 cells
  3 / 2 / 4 / 1 / 7 and the HUD psych icon, which already knew them).
- openwbc3's own: the original lets only the host apply the effects and sends the army state; here every peer runs the
  pass in the lockstep tick with the world's random numbers. Garrisoned (`hidden`) armies do not radiate (not looked at),
  the neutral side is hostile to everyone (the alliance matrix's neutral row was not looked at), a clear of all spell
  effects (Calm, Dispel) removes fear / awe / terror / chaos but not the immune flag (the original clears spell effects
  only; not checked). The Scare / Awe spells use the same effect through `psych.apply` (see "Missile accuracy and the Scare / Awe spells").
- Checks: `--selftest` ("psych" block), `--sim saveload` (chaos and immunity timers).

### Missile accuracy and the Scare / Awe spells (`src/game/missiles.lua`; checked in the 1.04 binary)
Every missile can miss. The missile constructors (`FUN_0053df60` shoots at an army or building,
`FUN_0053e960` at a cell; the only callers of both accuracy functions) weigh a d100 against the shooter's chance and move
the end of the flight sideways when `chance < roll`:
- The chance is a table by the shooter's real combat skill (index 0 .. 25): armies `FUN_00523ef0` (table at `0x00611294`:
  1 10 20 25 30 35 40 45 50 55 60 65 70 75 78 81 84 87 90 92 94 95 96 97 98 99), armed buildings
  `FUN_0052d9b0` (table at `0x006114e0`: 10 20 25 ... 98 99 99; combat is `Eco:buildingCombat`). Against an army the index is
  halved when the target is within one cell in both axes, then lowered by target speed / 6 (real speed, rounded towards
  zero). An army shooter adds 10 per level it stands above the target (below: minus; `FUN_0048f810` of both cells) and
  loses 20 for each of fear, awe and terror (`+0xBA` flags 1, 4, 2), clipped to 1 .. 99; a building has neither term.
- The roll: an army's d100 is made per attack by the attack message (`FUN_00536e30`, the roll's bits kept at
  `+0x228` of the army), a spell message carries one roll per cast (the host's spell resolution `FUN_004aa840` case 0x10), a tower or other
  building rolls again for every missile. `Unit:updateAttack`, `Eco:buildingAttack`, the missile spells and Holy Word call
  `missiles.aim`; the roll comes from the simulation's random numbers.
- A miss moves the end by 1 + ((roll - chance) >> 5) + (distance >> 2) steps (distance = floor(sqrt(dx^2 + dy^2)) cells, at
  least 1) at 90 degrees to the line of fire (the direction + 6 for an even roll, + 2 for an odd one; direction `FUN_0040a8f0`,
  tables at `0x00611e20` / `0x00611e40`): 1 only moves the drawn end (8 x 4 pixels), 2 .. 6 one cell (16 x 12 .. 48 x 36
  pixels), 7 and more two cells (56 x 42, 64 x 48). What the missile then hurts is the first occupied cell of the 2 x 2
  block (x, y) (x, y + 1) (x + 1, y) (x + 1, y + 1) at its end (the flight check of `FUN_0053fbc0`), when
  an army or building of a hostile side stands there - so a miss to the north or west still hits the target, one to the
  south or east lands in the dirt, and a unit next to the target can take the arrow. In a 6 minute AI game on Bridges the armies' shots had an average chance of 24 %
  (a fifth flew true) and the towers' 70 % (a third of their missiles missed); three in four of all the missiles that missed still hurt something.
- Damage: a missile never rolls the melee combat table. `FUN_0042ace0` (melee resolution) is only called by `FUN_00536e30` for
  range 0 / 1 attackers, and the impact function `FUN_005427e0` takes the damage result `FUN_0042bbf0` with hit type 2 (normal
  hit); `Unit:strike` therefore gives a missile a plain GOOD hit (no deathblow, critical, marginal or miss), the shooter's
  skill only decides the aim (before, ranged troops were resolved twice).
- Spells: Purify, Hand of Flame, Hand of Ice, Ice Storm, Doomstones, Wildfire, Spray Poison and Multi-Target (effect type 0x10
  `CREATEMISSILES`, spell numbers 23 / 83 / 92 / 78 / 101 checked in their cast functions) and the Holy Word building ability
  send one missile per target from the caster, so they miss like arrows (`spells.lua` `fire`, one d100 per cast); the missile
  flies and hits like any other, see "Missile flight".
- openwbc3's own: the height term reads the scenario's per-cell height byte for `FUN_0048f810`'s tile table (assumed equal).

### Missile flight (`src/game/missiles.lua`; checked in the 1.04 binary)
Every missile is an object of `world.missiles` that flies the original's pre-computed steps, one per 25 ms (the FAST pictures)
or 50 ms, hits what it meets and is saved in a saved game (`missiles.save` / `restore`, `savegame.lua`; kinds `unit`, `tower`,
`spell`, `holy`, `ball`; the damage kinds register their handler in the module that fires them). Verified:
- Constructors `FUN_0053df60` (army / building target) and `FUN_0053e960` (cell), step table `FUN_00541120`,
  picture flags `FUN_0053f180` (the `PROFILE` table: arrows 0x82 fast arc, crossbow 0x42, spear 0x224, bolts / axes 0x222, rock 0x44,
  catapult rock 0x510, fireball / sphere / petrify 0x24, lightning 0x2021, titan balls 0x110, ice shards / floe 0x22 / 0x224,
  breath 0x21, sheep / cow / goblin 0x4484 / 0x4510 / 0x4508). The number of steps is `(distance x frames per cell) >> 2` clipped to
  2 .. 80 with 4 / 6 / 12 / 15 frames per cell for fast / medium / slow / very slow (so an arrow over 9 cells flies 9 steps, 225 ms),
  the distance being `floor(sqrt(dx^2 + dy^2))` of the cells (1 at least).
- Heights (arc, curve and high arc tables): an arrow's arc is 1 2 3 2 1 over the flight (the first fifth 2 from a flyer or
  building), a fireball's line 0 all along, a catapult rock 2 4 5 6 5 4 2 ending in 1. A step looks at the first of the four cells (x, y)
  (x, y + 1) (x + 1, y) (x + 1, y + 1) that holds anything (armies on the ground layer, flyers on their own layer for a shot at a
  flyer, buildings, features): an army only counts below height 2, up to 4 when it is huge or a flyer; a building below height 2 or
  when the shooter is a building or a flyer; features, friends and allies are no obstacle (but a feature or a friend on an earlier
  cell hides what stands behind it). A hit by a non-carry-through missile ends the flight there (a fireball stops at the first
  enemy on its line, an arrow flies over the troops in between and hits only what stands under its descent); the carry-through
  pictures (spear, bolts, axes) hit everything and fly on. Splash pictures hit the victim, the eight cells round the step at 3/4
  and the twelve of the second ring at 9/16 of the damage (`FUN_00541e00`), or land alone on the last step.
- Lead: a target that is walking (`state == step`) is led by `time of flight / its time per cell` cells (`gamedata.STEP_TIME`, the
  table at `0x0061178c`) in its direction, pixels 32 x 24 per cell, before the accuracy roll's miss offset (`FUN_0053df60`).
- Impact `FUN_005427e0`: the same victim twice in a row is hit once; nothing happens when the shooter is dead by then (the
  active state 8, unless the missile is forced - the titan balls); the damage is `FUN_0042bbf0` with hit type 2 (armour of the victim,
  also for spells and buildings), then times the height percentage of the table at `0x00611e60` (20 30 40 50 60 70 80 100 120 130
  140 150 200 250 300, index start height - victim height + 7; the start height is the shooter's cell +1 for a building, +1 for a
  flyer), then the missile-resistance rules (a sixteenth for piercing missiles, at least 1) as before. `Unit:strike` has the height
  and the splash scaling now; spells use `Unit.soften` for the armour (the old direct damage skipped it).
- Titan balls (`EMTF` fire type 3, `EMTM` magic type 4; the Titan's death, Couatl's Wrath): a ball that reaches its last step
  without hitting anything bursts for 150 damage (hit type 2, the victim's armour, no attacker) to every army and building in the
  box x - 4 .. x + 4, y - 4 .. y + 3 (the missile frame update at `0x00540bc0`; the rows 0 .. 7 are scanned, an item must be inside the 9 x 9 box).
  A ball that hits something on its last step (any army or building but the dead; the ball has no owner, so friends too) does not
  burst. The old "display only" reading of the titan explosion `FUN_00520f20` was wrong.
- After-images (`trail` of the `missile` records, `FUN_0053f180` offsets `+0x680` / `+0x682` / `+0x684` / `+0x67e`: 5 for the arrows,
  bolts, rocks, fire / magic balls and the Titan's balls, 0 for spears, axes, bolts `EMA4` / `EMA6`, ice and the thrown critters; the
  picture's own `frames` 3 for the flaming arrows, 8 for ice and critters; `dirs` 16, rocks 4, ice 1, critters 8; `spinner` for the
  rocks): a missile stays in the list for `trail` frames after it landed (`m.landed`, `m.ix`, `m.iy`, saved) and the battle view
  draws the picture on its step and the sheet columns `frames ..` on the steps behind it, one frame per 25 / 50 ms like the original
  (the missile drawing, not traced in the 1.04 binary yet; `docs/formats.md` "Missile sheets" has the sheet layout, checked against the
  data). The row of a 16 way sheet follows `FUN_005418a0` (rows 0 .. 7 are the eight directions, 8 .. 15 lie between; the old
  clockwise numbering was wrong), a linear flight keeps one row, the rocks spin through their rows, the thrown critters use the `Z`
  animation. `battlefx` reacts when a missile has landed, not when its trail is gone.
- Pictures at an impact (the pushes of `EMX0` x3, `EMX1` x2, `EZ06`, `EZ07` are in the bytes of the missile frame update; the one-shot
  effect pictures of the install, 50 ms a frame, drawn as `world.effects` sprites): `EMX0` where a missile that hit
  a building without splash ends, where one flies into the void (terrain 9, which also ends its flight when nothing else was on
  the cell) and at the end of a lightning, `EMX1` at every splash landing, `EZ06` / `EZ07` (fire / magic) where a Titan's ball bursts
  (the old plain rings are gone). The impact sounds now follow the binary's table per picture (`missile.sounds`, tail of `FUN_005427e0`):
  arrows 0 / 18, rocks, axes and the Minotaur's axe 4 / 22, fire ball and petrify 6 / 24, magic sphere and ice 7 / 25, sheep 15 / 33,
  cow 16 / 34, goblin 36 / 35; poison and fire-poison arrows, `EMA6`, the lightnings, the Titan's balls and the breath make no sound
  (they played the family's sound before).
- Solid pixel of a building (`missiles.solid`, the building's solid test `0x00539f00` / the sprite test `FUN_00487c60`,
  called with the pixel minus the selection rectangle corner): a missile only hits a building when its pixel on that step
  lies on a pixel of the building's current frame that is neither transparent nor in the palette's shadow range (index 247 and
  up), the frame being the stand animation as if the ambient animations were on (the option differs between machines; the construction
  stages and the pillaged looks as `drawEntity` shows them). The aim point is now the effect point of the target (`position -
  effect origin`, `FUN_0053df60` reads `+0x4c - +0x96`), which is a solid pixel
  of all 264 building pictures of the install (checked with a script; the old aim point `y - 16` missed 54 of them). `battlefx` had
  added the effect origin where the original subtracts it (blood, floating messages, emitters sat below the unit): fixed.
- Dragon breath (`FUN_00542150`, called on the missile's 3rd frame): the victim on the end cell
  (ground layer, then the flying one), then the eight cells round it with 3/4 of the damage (ground, then air), then the twelve of the
  second ring with 9/16 (ground only); the things found on the rings are counted even when they are friends and at most eight are
  looked at; no impact sound, `DragonBreath0.wav` / `1.wav` in turn at the end cell, not twice within 3 s; the evil breath does double
  damage against good armies, the good breath against evil ones (`doubleVs`, the impact function's two flags); a walking army the end cell hurt gets
  the breath's effect picture (`EF01`, `EZ64`, `EZ61`, `EZ21`, `EILE` particles; the acid `EPGA` and good `EBLS` particle emitters
  fire every fifth frame in the original, which `emitters.lua` cannot do, left out); the dragon plays its own breath picture
  (`EFB` / `EIB` / `EAB` / `EVB` / `EGB` / `ELB` + direction modulo 8, 12 frames); the fire, ice and lightning breath always carry their
  special attack (immolate, freeze, drain mana: `FUN_0053f180` sets `+0x67c` for the picture, not by the 4 percent roll).
- Thrown goblin (`AOSX`, the Gobshooter's missile): after its splash it gets up one time in eight (`FUN_00541e00`: the dice,
  the owner's army count below its limit, an empty cell not on the map's border) as a new `AOSX` of the owner with the
  attitude 4 (rampant). openwbc3 also wants a free ground cell and gives a neutral side's goblin no second life (its army limit
  arrays are not known).
- Armour: the impact function reads the shooter's army flag at `+0x1cd` - the same flag the psych bonus function `FUN_005286c0` calls titan, third
  in its list of immunities after the drunk and mechanical ones - and then does the plain damage, no armour at all (all hit types,
  also against buildings). The ignore-armour special attack (`+0x67c == 10`, a piercing missile's critical hit) does the same against
  armies; before, only melee criticals ignored the armour. A basilisk's petrify wins over the critical.
- Special attacks of the acid, evil and good breath (`Unit.breathSpecial`; `FUN_0053f180` sets the picture's special attack at `+0x67c` /
  `+0x67d`: `EMF3` 14 / 2, `EMF4` 12 / 10, `EMF5` 5 / 10; the second switch of the impact function `FUN_005427e0` sends one message per victim army, no
  resistance roll, buildings never, every victim of the breath's cells, the ring ones too; `missile` records field `attack`):
  - Reduce armour (message 0x224, `FUN_00527ff0`, line 863 + the picture `EZ15` at the feet, adjust +2): only an army that is still
    alive after the damage; `+0x20c` of the army (`armorLoss` of the unit) grows by 2 for good, it stacks, is saved with the army and
    is what the army's armour getter (`0x005260a0`, its last line `max(0, armour - [+0x20c])`) subtracts from the base armour after every
    bonus (spells, items, power-ups, Armorer), so it lowers the three physical armours of `completeArmour` and the info panel's armour
    but not the resistances or a hero's skill bonuses; Chaos still zeroes the armour, an illusion has none. No expiry was found.
  - Drain experience (0x223, `FUN_00527ed0`, line 864 "%d ..." and `EZ15`): an army still alive loses 10 experience, at least 0; a troop
    `xp`, a hero `h.xp` (the original only on the machine of the hero's owner, `[+0x2d]` hero flag and the local side; every peer here).
    The level stays (a drained hero keeps its experience below its level's start across a save, `drained` of `Hero:save`); a troop's next
    gain re-checks the levels as before.
  - Crystallize (0x214, `FUN_004a9d90` -> `FUN_00528190` -> `FUN_0051a130(1)` + `FUN_005210b0`, sent before the damage when the victim's
    hits less the damage are below 1, army victims only, skipped when the victim carries the spell effect power 0x3e (Life Ward),
    `FUN_00577520(0x3e)`): the army is removed without a corpse at once, its death runs as usual with the shooter as killer, the
    shooter's side gets 100 crystal (`FUN_0043e9b0`, resource index 2, clipped at the side's cap; the same constant 100 as the petrify
    message - Game.txt line 1148 reads "+100"), the line 1148 shows over a shooting
    army (not a tower) in the good colour, blue particles (`FUN_0058c0d0`: 8, blue, gravity, radial, special sprites, frame random,
    fade out, large) and `Crystallize.wav` at the victim, the sound for the victim's or the shooter's side only and once a second. The
    1.04 petrify message also carries 100 (`uStack_a = 100` in the impact function's case 3, line 1147 "+100 Stein"); `Unit:strike` still pays 50 stone
    (an older value, not the binary's): not changed here, see `docs/missing.md`.
  - The Crystal Tower (`BWTF`) does the same with every army its shot kills: the tower shot `FUN_0052d2f0` rolls no special attack
    of its own, its one special is `+0x67c = 5` / `+0x67d = 100` on the missile when the tower's code is `BWTF`, so the impact sends
    the crystallize message as for the good breath (100 crystal for the tower's side, no line over a tower; tag `crystalTower`,
    `p.crystal` of the tower missile, `economy.lua`).
- Start pixel of a shot (`missiles.startPoint`; the constructors `FUN_0053df60` / `FUN_0053e960` write it to `+0x150` / `+0x154`, the
  army display's combat offset getters at `0x00536490`): the shooter's selection rectangle is the `.ani` frame box of its current
  animation (`-origin`, width, height) at its position (the stand box for types with the `STANDFRAMESONLY` flag 0x20 of `.ARM` `flags`);
  a unit whose `.ARM` combat point (`combatPoints`) for `dir` has an x that is not 0 shoots from that offset from the rectangle's corner (`dir` the way it faces), every other
  unit from the middle of the rectangle (`x + w / 2`, `y + h / 2`), heroes always (the getter returns 0 when the hero byte `+0xb4` is set); a building uses the `.BUI`
  combat point of the direction from its cell to the target's cell (`FUN_0040a8f0`); a missile without a shooter (the Titan's balls) starts in the middle of its
  cell (`FUN_00493940`: x 32 + 16, y 24 + 12). 60 army types (the six dragons, the catapults, the Titans and many ranged troops) and 32 building types have points
  (`docs/formats.md`). The dragon breath's picture is drawn at this pixel too (the original spawns that effect at the missile's start). The
  old (x, y - 20) / (x, y - 40) / (x, y - 60) are gone; the start pixel is part of the saved missile and the solid-pixel test of a
  building reads the path it makes.
- Not modelled / own choices (labelled in the module header): the neutral buildings other than lairs as obstacles, the two multi-burst
  breath emitters, the draw order of the breath picture (the original puts it behind or in front of the dragon).
- Checks: `selftest` "missiles" and "missile flight" (steps, heights, interception, the dead shooter, lead, splash, the ball, a save
  in mid-flight, the trail over a save, a titan's raw damage, the breath's rings, the void, the solid pixel, the goblin, the sheet
  rows), `--sim saveload` (missile kept over a save).

Scare and Awe (cast functions `FUN_0057c7c0` / `FUN_0057c9b0`, effect type 0xd, effect function `FUN_004ac0e0` case 0xd): the message goes to the
enemy armies in the radius that are not undead (the AND / NOT masks at message `+0x135` / `+0x131`, checked in the cast
function at `0x0057c800`), heroes are skipped, and each of the rest gets the psych effect setter `FUN_00528a40`, which fails only for
`FUN_005286c0`'s immunities (drunk, mechanical, titan, critter, the race rules, `psych.bonus`) and otherwise sets the effect
for 45 s fear / 30 s awe (x3 slow, x2 very slow races), ends the command radius bonus, whatever psych flags the army already
carries. There is no resistance roll in 1.04 (see `docs/todo/not-in-original.md`), and Extend does not stretch the time.
`psych.apply`; checks: `selftest` "missiles" and "psych spells".

### Production queue and continuous production (HUD / economy)
The production queue panel is drawn by the control panel routine `FUN_004d7710` (the 800 x 600 positions below were
not traced in the 1.04 binary yet): the `ProductionSlots.bmp` strip at 308,502,
six 32x50 slots at 315+41k,523; the first slot is the current production, or an animated frame of
`SelectionRings.bmp` at 392+32c,619 (c cycles 0..7, one step every 4 ticks) while the queue is frozen because
the head cannot be afforded (the building's production step, not traced in the 1.04 binary yet); armies and
upgrades use the interface sheet, power-ups are blitted from `Powerups<Race>_Small.bmp` at 32*listIndex
(`FUN_00439050`, a 32 x 50 cut-out in `FUN_004d7710`); "+ n" at 562,540; the progress bar bitmap at 319,464 with the
percentage.
A click on a production queue slot removes that item (the click handler was not traced in the 1.04 binary yet; the
removal `FUN_0052d8a0` with index 0 cancels the running one with a refund and does nothing while the queue
is waiting).

Continuous army production (the toggle and the re-adding were not traced in the 1.04 binary yet): a
finished army production goes back to the rear of the queue; the original skips titans (codes `_T_X` - here the
Army.cfg STATUS titan flag) and the hero general, and re-adds only while the army's own requirements are still
met - openwbc3 checks the building's list. The button is the 12x12 outline at 390,478 filled 8x8 when on with
the label of `Game.txt` 0523 (`FUN_004d7710`: the 12 x 12 outline, the 8 x 8 fill while the flag is set, string 0x20b).
The queue, the waiting state and the
continuous flag are saved in savegames.

### Computer players (`src/game/ai.lua`, `aidata.lua`, `aiplan.lua`, `aigroups.lua`, `aibase.lua`, `aiparams.lua`)

The think loop follows the computer player's think step (`FUN_004fa120`, decompiled): enemy choice
(`FUN_004fa5b0`), hero retreat (`FUN_004fc150`), Rampant: best target; defence (`FUN_004fa380`), the unit list, missions in
progress, analysis of buildings / armies / power-ups, then (not Rampant) keeps, mines (`FUN_004fc280`), tower spot, required
building counts, the resource list (the virtual call at slot 0x1c), the groups, every 15 s the build intervals (`FUN_004ff470`), new missions, special
abilities, repairs, resignation. The levels are the original's 0..7 (Passive, Knave, Knight, Lord,
Prince, Warlord, Emperor, Rampant; `docs/implemented.md` "Advanced options" for the resignation). The 17 race classes of
the original only differ in two hooks (elf wisp count, Undead morph weights), so one generic AI is kept.

Checked against the 1.04 binary (decompiled in Ghidra):
the think step `FUN_004fa120` (15000 ms recalculation interval, call order), the level factor `FUN_004ff400`
(15000 / 10000 / 7000 / 5000 / 2500 / 1000 / default 6000, which the interval reset `FUN_004fe250` passes on but never uses),
the per-resource intervals `FUN_004fe300` (intervals, x 4000 ms, the dragon / titan division by 2 / 3 / 4, the
`MR00` exclusion), the production rates `FUN_004ffab0` (all rates below, the custom-script branch: builders 150 %
of "builders in mines", production 150 % of the main army-production value, army research 130 % and armies 250 % of
"army upgrades", power-ups 150 % and power-up research 100 % of "power-up upgrades"), the income levels
`FUN_004ffee0` (caps 20 / 30 / 40 / 70 / 100 / none, default 35), the required building counts `FUN_004fc9a0`
(factors 40 / 60 / 100 / 140 / 180 / 250 / default 120, +2 for the elf keeps `BKE0` `BKW0` `BKT0`, the Undead morph
armies counting for the gravestone), the mine assignment `FUN_004fc280` (mine value 2 / 4 / 8 + Income level, 1 when dry,
workers as extras, `+6` for 4..8 points, "needs a keep" farther than 21 cells from every keep). A timed power-up purchase is not
called by `FUN_004fa120` in the binary: power-ups come from the resource list (real cost, real research time), the older openwbc3
model (a free power-up every 60..300 s) was removed.

Production model (`aiplan.lua`): a resource list of wishes with priority, type bit (1 army, 2 power-up, 4 army research,
8 power-up research, 16 production building, 32 defence, 64 builder) and cost; each item gets a "time between builds" and
may only start when that has passed since it was last started (`FUN_004f8600`; the first three buildings are free of
it); starting an item still needs the real resources (the AI no longer gets production or construction for free;
`economy.lua` lost its computer exception). Rates per level (Knave .. Emperor): armies 10 / 30 / 50 / 90 / 150 / 210,
power-ups 10 / 20 / 40 / 60 / 100 / 150, army research 15 / 35 / 70 / 140 / 280 / 560, power-up research 10 / 35 / 70 /
140 / 280 / 560, production buildings 10 / 30 / 60 / 120 / 240 / 480, defence 0 / 35 / 70 / 140 / 280 / 560, builders
10 / 30 / 60 / 85 / 120 / 150. Build order: `FUN_004ff5f0` (builder first, then fewest prerequisite buildings;
a keep level counts 10), a script's army priorities sort it instead, a generic AI shakes some priorities by -39..40 (1d80 - 40, never the first army of
the order, `FUN_004fc8d0`); army research asks for the next army's missing buildings (priority 150, builder building 220)
and power-ups (140), required counts decide the production buildings (priority 90). The debug view of the wish list is
`world.ai:describe(side)` (`--scenario <map> --at 60 "print(W.ai:describe(1))"`) or the environment variable
`WBC3_AIDEBUG` (logs every side's list every 30 s). Strength by level (all-AI game on Bridges, average armies per side after 8 minutes, Knave .. Emperor): 4.6 / 6.0 / 8.8 / 12.8 / 8.8 / 15.0 (the Warlord run lost units in early fights).

Groups (`aigroups.lua`; compared with the binary, see "Groups compared with the 1.04 binary" below): idle armies join groups
(`FUN_004f59e0`, types normal / long range / mine killer / kick-ass / large / generals / weak / conversion
by `FUN_004f6d90`), activate at their level-scaled minimum size (script sizes or 10 / 4 / 6 / 7 / 15 / 6 minimum) or
when the army is within 4 of its limit, pick a side (`FUN_004f4e30`) and a target (`FUN_004f66f0` with
`FUN_004f5e90`), move with the leader at the slowest speed, regroup, attack, threat-assess within 14 cells,
convert (conversion groups, heroes). A share of the land army (script "armies in towers", default 20 %) is sent into
towers (`FUN_004f71e0` / `FUN_004f72e0`). Towers (`FUN_004f8fa0`: limit 3 / 7 / 13 / 20 / 30 / 45 per
level, the building with the largest need), base relocation (`FUN_004fc020`: safety over 300, 20 random
points, safety under 50) and hero retreat (`FUN_004fc150`: under 200 hits and attacked, back at 250) are done. Saved
games keep the lists, times, army data and groups (`AI:save` / `AI:restore`, `--sim saveload` compares them).

Custom groups of `.ai` scripts (`aiparams.lua` reads the 556-byte records, layout in `docs/formats.md`): not used, as in the
original. Checked in the 1.04 binary: the group type update `FUN_004f6d90` assigns only the types 0 .. 7 and 9 (never 8, custom),
the only reader of a group record is the target priority `FUN_004f66f0` (the custom-groups switch `FUN_004f76c0`, flag at
`+0x328`, attack priorities at `+0x61b` ..; only for a group of type 8), and sub group names / sizes / army lists have no
reader. The loader `FUN_004f76d0` needs the 8440-byte layout, so none of the shipped scripts loads in the 1.04 game
(`docs/todo/not-in-original.md`). Scripts therefore use the general group sizes (`FUN_004f7800`).

Power-ups that stay on offer (Spell / Arcane Research, the three foreign mercenaries, the Knight's Quest) are bought by
the computer like any other, exactly as the original's resource list does it: the power-up step
`FUN_004fead0` of the resource list builder `FUN_004ff3b0` takes the first power-up of the race's `[DEPENDENCIES]`
list that can be built and is neither "researched" nor being researched, and the power-up analysis (vtable slot 2 of the
computer player, `0x004f7f60`) sets "researched" from the built check `FUN_0040b580`, i.e. the dependency instance
count that the power-up routine (`FUN_00436500`) raises through `FUN_0040b350` only for power-ups it puts into the side's list. Research and mercenaries
are never put there (and the Knight's Quest only with three chosen foes, which a computer side never has), so they stay
"not researched" forever: once such a power-up becomes buildable the computer keeps buying it again and again (Arcane and
Spell Research alternate) and the later entries of the list wait behind it. Only the Undead (research), Empire
(research and mercenaries) and Knights (Knight's Quest) lists contain them. A bought Knight's Quest does nothing for a computer side.

Region map, danger map, enemy choice (`src/game/airegion.lua`, `aibase.lua`, `aigroups.lua`; all decompiled from the 1.04
binary):
- Region map: squares of 8 x 8 cells hold regions (connected land or water cells; a building's cells are a region of their own,
  terrain 255) - remap `FUN_00509f30`, square fill `FUN_0050a370`, adjacency `FUN_0050a5c0`,
  passability without armies / without armies and buildings `FUN_0042cc10` / `FUN_0042cda0`; broad terrain types
  (`0x00603ed0`), legality (`0x00603ee0`). The region expansion `FUN_00509320` is a bucket search (ring of 4
  buckets, 500 for the safe search), steps cost 2 / 3, the first discovery fixes a region's cost, building regions are
  reached but not crossed, a safe search adds the arrival square's modified danger (cap 499) and stores the cost as the
  reached building's path danger. The safe search `FUN_0050b0f0` resets the path danger (-1) of the *asking side's own*
  buildings only (the original's slip: the enemy's buildings keep what the last search that reached them wrote, 0 at the
  start; it is saved with the building, the field is the building's `+0x2c`). Own choices: the map is rebuilt from the
  cells buildings and features block when they change (the original remaps on add / remove), adjacency lists are in full-scan
  order, squares are numbered with the real map width, sizes 1 and 2 only, an army target's shared waiting counter is not
  modelled.
- Danger map: every 3 s (`FUN_005095a0`, smoothed by `FUN_00509840`) each unit and
  building adds its strength (army (hits / 4 + combat + speed + damage + range) / 4, armed building hits / 2 + damage + range / 2)
  to its 16 x 16 cell square for every used side not allied to its owner (neutral things count for everybody); the modified
  danger is the square plus half of each of its eight neighbours (by index). Saved with the game (`AI:save`).
- The group target choice `FUN_004f66f0`: a safe search from the leader's region (when it stands on one) gives the buildings a path
  danger; a group whose current target is a building with path danger below half the group strength (hero groups: x
  (25 + boldness) / 100) and not -1 keeps it (the -2 result); buildings whose path danger is -1 are skipped; the priority
  loses `max(0, pathDanger / 2 - strength) / 2` (hero groups: `(max(0, pathDanger / 2 - strength) + 2 x (danger - strength)) x
  (100 - boldness) / 50`, C division). Before this the danger around the target stood in for the path danger.
- The Rampant target choice `FUN_004fa990`: calls the danger lookup `FUN_00509980` with (owner, (x / 16, y / 16)), which divides by 16
  again, so the term is the first square's danger for every target (no effect on the choice); ground targets exclude flyers
  and ships (a third, sea slot exists that nothing uses), the Capture the Flag flag is -500 (never chosen), a target needs a
  priority of 0 or more.
- Hate index: `FUN_00417f80` (called from the game setup) rolls a symmetric 7 x 7 matrix of 1..100 (1..40 in a
  campaign); in a skirmish or tutorial game one random computer side gets 200 towards the local player and every other
  pairing of it is shifted right by 2 (not in network games or campaigns). The enemy choice `FUN_004fa5b0` adds
  `hate[owner][other]` to the score (the rest of the score was already the original's), only counts sides that still own
  something (its side list is not empty) and measures the start spots of both sides (not the AI's relocated base). Rolled in
  `AI.new`, saved in `AI:save` (`extra.hate`).
- The conversion square choice `FUN_004f8820` (including the region expansion `FUN_00509320` from the
  converter's region and `FUN_00509310`, which stores the expansion's army id): the reachability test is the region map's (a ground converter
  on no region gets no square), the candidate cells need the passability test `FUN_0042cb70` (terrain, buildings, features and
  the units of the same layer - openwbc3's single `occ` layer is split by flyer / walker).

Not original, openwbc3's own: a conversion group's leader walking straight to the building when no square qualifies (where
the original walks to (-1, -1)); builders' spots are the nearest legal ones (and spots no
builder could reach are skipped for 3 minutes); an army is only started while the army limit has room; the safe base search is limited per side, not
per game; the group size of a weak group (the original reads past its table)
is 12.

Keep conversion and palace conversions (`economy.lua` `Eco:startKeepConversion` / `updateKeepConversion` / `conversionList`,
command `keepconvert`, `aibase.lua` `palaceConversions` / `shouldPalaceConvert` / `bestConversionSquare`; checked in the 1.04
binary): a keep (second letter K) has a Convert button in slot 5 of its panel (slot and greying not traced in the 1.04 binary yet; greyed while it produces or
converts; the Stop button and any damage end a running conversion: the Stop button `0x004d0aa0` and the building hit
reaction `FUN_0052b180` call `FUN_0052fc00` / `FUN_0052fbc0`). The keep conversion `FUN_0052f9b0` needs a finished keep
without production in progress and at least one building to take in reach (else "nothing here to
convert", Game.txt 65), and runs 150 s over 28 cells for a human side, 120 s over 32 cells for a computer side
(`0x1c / 0x96` against `0x20 / 0x78` in the function, picked by the per-side computer flag `0x0070d6a4`). At the end
(the building update at `0x0052cf20` .. `0x0052cfeb`, which also plays `KeepConversion.wav` for the local side at most once a
second) the conversion `FUN_00532640` takes every building in the circle again: the list `FUN_005489e0` gives up to 8 buildings
that `FUN_0052da90` accepts (K / A / P / R / T codes, finished, not pillaged, no garrison), owned by the neutral side or by
another side (an ally's too, but only for a human converter: the alliance test `!alliance[side][other] || !isAI[side]`),
whose footprint's nearest point is within the range (squared distance <= range squared), rows from the bottom up and left to
right. Converting the keep to another side, or giving it production, ends / blocks it. The same rule about allies now also
holds for a hero's conversions. An army's conversion uses the same list: the army conversion `FUN_0051cbb0` asks
`FUN_005489e0` at the unit's own cell with the army's conversion range (a hero's command radius, at most 19, else 4; +3 for a
computer side) both when it starts (an empty list: "nothing here to convert") and when the
order ends (`FUN_00520c90` -> `FUN_00532640`, max 8, the order's range), so a conversion range is a circle
from the footprint's nearest point and not a Chebyshev distance. The conversion spell (`FUN_005758b0`, spell 65) calls it with
range result / 2 and "mines only" (`FUN_0052b050`: the building produces a resource). When a keep starts converting with buildings of the local player in reach the player is warned
(the network handler `FUN_004af380`: "base under attack" within 20 cells of the base, else "buildings under attack", in
1.04 only while the keep is outside the visible part of the map; the text
GS 1161 is not in the 1.04 files, only the voice plays).

Computer: every 15 s, after the build intervals (`FUN_004ff470`), the palace conversion step (`FUN_004fbb90`) looks whether any army of the
side can convert (hero or general; a per-side "converter exists" flag, true at the start, is set here and steers where further
keeps are built); only when none can, every own keep that is not converting and for which
`FUN_004fbc60` says yes stops its production (`FUN_0052d7e0`: the queue goes, the cost of the running item comes back) and
converts. `FUN_004fbc60`: the first waiting order of the keep must not be a production of anything but an army, and the
other sides (neutral included) must own resource points within 32 cells (squared distance <= 1024) whose 4th code character
digits add up to more than 0 (so level 0 mines alone do not count). The AI repairs skip converting buildings.
The conversion square choice (`FUN_004f8820`, called from the group's convert handler `FUN_004f4940`): the conversion group's
leader asks once per main-action stage for the best square (range - 1 = ring of cells whose floor(sqrt(dx^2 + dy^2)) equals
it, reachable through the region map, 300 per one of up to five buildings of other sides around the target that it still reaches, plus 256 minus the Chebyshev
distance to the converter, first best wins), walks there and converts when within 3 cells. A watchdog that resets the keep-level build times is not in
the binary (`docs/todo/not-in-original.md`).

Neutral side's computer player (`ai.lua` `AI.new` / `think` for side 6, `aibase.lua` `chooseEnemy`, `defend`, `doAttack`; checked in the
1.04 binary): the original's AI system gives side 6 a computer player of its own, always (`FUN_00504a30`, the neutral entry of the player array is
created through the same constructor as the Human race's, `FUN_00509040`; the Barbarian AI class is only the one of the Barbarian *race*, it adds
nothing to the base class). The think step `FUN_004fa120` treats `side == 6` like the Rampant level (`(&DAT_00708fa4)[side * 0x16] == 7 || side == 6`):
no economy, only the enemy choice, the target choice `FUN_004fa990`, the defence `FUN_004fa380`, the unit list, repairs and the attack (`FUN_004fa850`, which
orders every free army at the best ground / air target with the fight order `FUN_0051da60`, which skips an army without an attack). The neutral enemy choice is `FUN_004fa5b0`'s first
branch: a random one of the used, undefeated sides 0..5 on every think, no alliance test. Its base is the side-6 start location of the scenario file
(`(-1, -1)` when it names none); the defence treats every other side as an enemy (the alliance matrix has the neutral side allied to itself only,
`FUN_004de740`). The neutral buildings are repaired like any side's (`FUN_004fffe0`, with the side's own AI level and race from the
scenario record). So the creatures of the lairs (the lair manager only adds neutral armies, with no home or order) and every other free neutral army
go after a random side's best target; openwbc3 runs this think every 2 s like the other sides (the original gives one AI side a turn per 250 ms slice, see "Attitude slices"). Own
choices: the old lair "leash" (guards walking back home when more than 14 cells away) is gone, as it fought the orders of this AI; the neutral armies run the attitude system like the original (Defensive, see "Attitude slices, threats and the neutral
armies"). A Rampant side that is not neutral and the neutral side keep only their
timers / enemy in a saved game. Not checked by watching the original play.

Groups compared with the 1.04 binary (`aigroups.lua` header lists the functions): the objective stages, the activation, the target side, the
reassessment, the threat levels, the unit handlers and the group type update match the Lua. Differences found and fixed: the
threat assessment (`FUN_004f3e70`) takes land and hover armies as ground and *air and sea* armies as air targets (a ground-only attacker does not see
ships), lets an army without an attack pass both tests, rates an armed building by its real damage with a garrison's bonus and not only finished
ones; a regrouping member without an order stays where it is (`FUN_004f4a90`: only a member whose first order is not an attack goes back to the
leader); the group attack type is undefined (compatible with armies that cannot attack only) for a first member without an attack; the "cheap
builder" filter of the idle army pass (`FUN_004f5700`) uses the most hits an army can have (the maximum hits getter), not its current ones, and counts heroes as
builders (the builder test gives 10 for a hero); the tower sender (`FUN_004f72e0`) does not count the free places down (a tower can be sent more units than it
holds) and the tower list stops at 39 buildings (`FUN_004f71e0`); the conversion target list takes unfinished temples / mines too.

Target lists, group slots and idle armies (`aigroups.lua`, `aibase.lua`; binary `FUN_004f6160` attack candidates, `FUN_004f6340`
conversion candidates, `FUN_004f5e90` target priority, `FUN_004f5e00` the resource need, `FUN_004fac00` danger for a unit,
`FUN_004f5570` new group, `FUN_004f5610` group processing, `FUN_004f5700` idle armies, `FUN_004f66f0`): the priorities
(temple 150, lair 1, resource point `(required % / 2) << size + 10` with the 6 start spots' -200 / -100 / -60 / +40, flag 250, keep
40 x (level + 1), wall tower 40 / wall 10, else 25, + max(0, 500 - 2 x distance from the base); army 30 + stored combat / 2 + max(0,
256 - distance) / 8, only for a side without any building) were already the Lua's and are the binary's. Differences taken from the
binary: an entry list holds **200** targets at most (the 201st is dropped); an army's priority uses its *stored* combat (the army record
field `+0x92` that the combat getter `FUN_0051bd10` hands out as the base value: level gain, hero values, morphs, no power-ups / weather /
status) and not the type's; the conversion list walks the map rows 0 .. **width** - 1 (the loop bound is the width, `FUN_00490960`,
where the danger search clamps the rows with the height `FUN_00490990`), so the buildings below row `width` of a map taller than wide
are never conversion targets, rows ascending; the groups live in **100 slots** (`FUN_004f5570` takes the lowest free one and fails
with the 101st: the army stays ungrouped and tries again; groups are processed, and the one reassessed per think is picked, in slot
order: the pointer moves to the next used slot, the group is reassessed and the pointer moves past it); the conversion groups that
already head for a target are counted over the first **10** slots only (a bound of 10 in `FUN_004f66f0`); `FUN_004fac00` doubles an armed building's toughness when the building's current target is the unit (not when the unit is
within its range) and counts unfinished buildings like finished ones, armies that are off the map are skipped. `FUN_004f5700` counts
the armies that are **off the map** (the off-map flag `+0x30`) as "in towers" and in the total: the garrisoned ones and the
builders that are putting up a building (the construction message `FUN_004f6f80` takes the builder off the map and keeps it in the
building); a worker that goes into a mine is *deleted* (`FUN_0051a130` sets the army's state to 8, dead), so the original
only counts it until the dead item leaves the list - openwbc3 removes it at once, which is the same (when the cleanup happens was not
traced). Not verifiable, openwbc3's own: the lists are rebuilt on the game clock (the original reads the wall clock, `timeGetTime`);
the entry order of a map row; the attack list's order (the original's side list order, openwbc3: buildings then armies; only matters
with more than 200 entries).

AI debug overlay: not in the shipped game, see `docs/todo/not-in-original.md`.

Conversion highlight and minimap info box (`battle.lua` `drawConversions` / `drawBuildingRing`, `hud.lua` `drawInfoBox`): a building that the local
player's army or keep is about to convert is drawn with its selection ring and without the health bar (the marker `+0x14a` set by `FUN_0052f870`,
read by the building drawing at `0x00538660`, only for the local side's conversions; the list is the one made when the conversion starts, `FUN_00406260`).
The ring is the 1.04 art of `SelectionRings.BMP` (bitmap 102): the size class and offset come from the building's `.ani` (`selectionSize`,
`selectionOrigin`), the ring rectangles are the tables at `0x00611b0c` .. `0x00611b98` read by the building drawing (green column for own buildings, red one for the others').
The info box (started by `FUN_004dcf70`, drawn by `FUN_004dc850`) is the red box of `esibi.bmp` (bitmap 109, 17 frames of 64 x 64) that shrinks onto the place on the minimap
and stays until the 100th tick (`FUN_004dc850`; the main screen's timer runs 18 ticks a second); only one runs at a time, and every
place openwbc3 logs for the Space / Page Up message log starts one (`logSite`), a finished keep conversion included. Not modelled: the original clears a
building's single flag when the first of two converters stops, and a converter whose target is already marked finishes its order (a per-machine rule
of the local player, not traced in the 1.04 binary yet, which a deterministic simulation cannot have); the box's timer rate (18 ticks a second)
is not measured in the binary.

### Economy / rules verified against the original
Regeneration of plain units (1.04 binary: the regeneration amount `FUN_0051b460` and
the regeneration check `FUN_0051b820`): 1 hit per 10 s, 250 ms shorter for every troop level (`(40 - level) x 250` ms), divided by the
percentage of the Healing power-ups (100 150 200 300 ... 800, the table at `0x0061120c`) plus the Regeneration skill of the side's
living hero (`FUN_00556b50` reads the hero's level of skill 3 with its items, `FUN_00556ea0` gives 20 a level; it applies to every
army of the side, not only the hero), Trolls x4 (`>> 2`), Undead x2 (`>> 1`) and none in daylight, poison / disease stop it (a
poisoned unit loses hits instead); inside a tower the interval is halved again (the in-tower flag at `+0x1c5`, `>> 1` in
`FUN_0051b820`), so the garrison heals at twice its normal rate, power-ups and skill included, for a hero (`FUN_0051b460`: 20 s / the
hero's life regeneration bonus, the same percentages plus the spell and item bonus) at twice the rate of `Hero:lifeRegen`, mana as
outside. The hidden garrison is not updated by the units' own loop, so `Eco:healGarrison` calls `Unit:regenerate(t, true)` and
`Hero:tick(t, true)` (before, units used a flat 2 x 10 s rate and heroes 2 x their regeneration plus a catch-up burst when they came
out; `attitudetest.lua` "tower healing:"). The life regeneration spell effect (the Life spell, heroes only) is not read for troops, as
nothing sets it for them. Potions heal `50 + 10 x keep level` hits and restore `10 + 5 x keep level` mana, the
Potionmaster skill (id 95) adds 10 % per level to the mana potion (healing potion `FUN_00561d80` / mana
potion `FUN_00561c30` of the 1.04 binary); both are applied in `hero.lua` (`Hero:drink`).

### Weather (`src/game/weather.lua`, `src/ui/weatherfx.lua`; checked in the 1.04 binary)
The state lives on the world (`night`, `raining`, `rainTarget`, `lightning`, `shift`, `weatherAt`, `randomWeather`; all
saved in `data.weather`). The state getter (`FUN_0049e320`) only looks at night / rain / storm, so the states the timer
sees are 0, 1, 4, 7, 8, 11 although the state setter (`FUN_0049e690`) knows 14 (day / night x fine, light / medium /
heavy rain, light / medium / heavy storm). The first rain call (the rain start, `FUN_00499aa0`) always starts a 300 drop rain
whatever the level; calling a level while it rains sets the target to 80 / 150 / 512 drops. The weather timer
(`FUN_0049e360`): at most one roll per 100 s of game time (not while the speed is 0), "day, fine" never changes without
random weather, four rolls in order (fine 15, improve 30, worsen 18, much worse 8 %; 12 / 25 / 20 / 10 with random
weather) and the transition tables read from the jump tables (worsening "day, fine" goes to night with a roll under 75,
else light rain). The new state is applied on every peer (the original's host broadcasts it; here the seeded random is
shared). Day / night changes (`FUN_004998e0` night to day / `FUN_00499970` day to night) run a transition of `3 * 18 / 4` frames
per phase, four phases, 18 frames a second (about 2.9 s) and flip the night flag only at the end; the weather spell message is
refused while one runs (the host's spell resolution `FUN_004aa840` returns for kind 4 while the transition mode at `+0x2b5f0`
is set). The weather spells send the original's
kinds (`FUN_004ac0e0` case 4): 0 day / fine, 1 day / rain, 2 night / fine, 3 night / rain, 4 / 5 storm (medium rain,
then light storm), rain kinds only start rain that is not falling yet. Purify sends 0, Light / Darkness flips the night
and keeps the rain (`FUN_0057c8c0`), Darkstorm 3, Storm 1 / 4 by day and 3 / 5 at night (`FUN_0057be40`, 4 / 5 from success
level 2), Change Weather the chosen number 0..3 ("Daytime & Fine", "Daytime & Raining", "Nighttime & Fine", "Nighttime &
Raining", strings at 0x6153e8, `[SPELL_DLG_TEXT_00..03]` of Spells.txt; picked in the original's four-picture dialog `FUN_0055bc90`, see `spells.md` "Four-choice spells"). Rites of
Dawn, Dark Citadel and Storm Call send 0, 2 / 3 and 4 / 5; the scenario events 15 / 16 / 17 call the same functions.
Combat modifiers (the combat value `FUN_0051bd10`, real value, result at least 1): day High Elves and Ssrathi +1; night
Orcs and Undead +2, Dark Elves +1, Humans and Horselords / Barbarians -1, the Shadow (`AUXX`) +5, the hero's Shadow
Strength (`hero.lua`); rain Dwarves -1, Daemons and Undead +1; no rain Wood Elves and Fey +1. Values seen
elsewhere (High Elves +2, Dark Elves +2, fine +2) are not the 1.04 binary's. The 1.04 binary has no rain
penalty for fire spells at all (no fire spell function calls the rain test `FUN_0049bb10`), so none is implemented.
Rain end (rain update `FUN_0049b6d0`, rain start `FUN_00499aa0`, rain finish `FUN_0049bd90`, rain test `FUN_0049bb10`; the
drop state is simulation state, `world.rainDrops` / `rainBase` / `rainEnding` / `rainFrame`, saved and in `world:hash()`):
the finish only sets the ending flag. The rain test stays true (combat modifiers, weather buttons and spells see the rain) while
the update, once per overlay frame (18 a second of game time, openwbc3's reading of the display frame), thins the drops out one
a frame down to the base level, which is the rain start's second argument (80 / 150 / 512 for light / medium / heavy, capped
to the target 300 on the first frame and to any lower target a later call sets); only then the rain stops (the test false,
loop sound closed). A rain starts with 30 drops and grows one a frame to the target, and while it is marked as ending it
neither grows nor shrinks: marked below its base level (a light rain in its first 2.8 s, a medium one in its first 8 s, a heavy
one in its first 15 s) it never ends (the binary's behaviour, kept). The rain start returns at once while the rain test is true, so
a rain spell during the fade-out does nothing. Older saves without the drop record load a rain at full strength.
Display (`weatherfx.lua`, the hash of the frame count instead of random numbers): the night tint with the four phases,
the rain with the simulation's drop count (1 per frame growth from 30 up to the target), lightning from a storm (a step every 3rd frame, next flash
after `1d(150 - drops / 4) + 12` steps, 10 steps long, bright with a 1 in 800 chance per drop and step) with
`SoundFX/Weather/Lightning{L,M,H}{1,2}.wav` (type by the current drops, 80 / 150) and the `Rain.wav` loop at volume drops / 16
of 127 (`FUN_0049b1d0`, `FUN_0049b6d0`). The drop shape (streaks of 1..40 px, 11..20 px per frame, brightness 45 / 35 / 20 %)
is not traced in the 1.04 binary yet. Checks: `--selftest` (modifiers, tables, spells, rain end, save / load), `--sim Bridges storm`, `--sim saveload`.
Re-checked and closed: the options screen has no "weather" entry and the 1.04 binary never reads it; the skirmish
environment "Cycling" and the overlay cycle have no setter in the binary (both in `docs/todo/not-in-original.md`). The
terrain ambience with its night switch is the environment sound (`audio/ambience.lua`, "Display and sound options").

### Advanced options and the game speed (`src/game/advanced.lua`, `src/screens/advancedoptions.lua`; checked in the 1.04 binary where noted)
The advanced options record is eight values (random weather, resignation kills a side, AI can resign, tournament mode +
points, I am the greatest, tough towers, no items). Storage: `openwbc3.ini [advanced]` with the registry value names of the
original (`RandomWeather`, `AICanResign`, `IAmTheGreatest`, `ResignationKillsSide`, `ThoughTowers` (sic), `TournamentMode`,
`TournamentModePoints`, `NoItems`), `gameopts.advanced()` / `setAdvanced()`. Binary (reader `FUN_00450d00`,
writer `FUN_00450b80`, record at `0x749c60`): a value missing from an existing key defaults to random weather on,
AI resign on, resignation kills on, 15 points, the rest off; with no key at all (`FUN_004531e0`) random weather is OFF, AI resign
and resignation kills on, tournament off and **10 points** (not 15 as above). `ini` without an
`[advanced]` section behaves the same. Campaign battles run with AI resign on and random weather off, tutorials and the
developer `--scenario` start with nothing but resignation kills (campaign battle start `FUN_005a1880`, tutorial start
`FUN_004494e0`; not traced in detail in the 1.04 binary).
- Dialog: `PNL_SS_ADVANCEDOPTIONS` from a "More options" button (`BUTT_SS_ADVANCED_OPTIONS` text 28/0) of the skirmish and the
  multiplayer host lobby; the clients of a lobby see the host's values read-only (Cancel greyed, nothing can be toggled). Texts
  `TXT_SS_ADVANCED_OPTIONS` 233 (title, the seven labels, "Hero level: "), `TXT_SS_ADVANCED_OPTIONS2` 236 (tough towers, no
  items), `TXT_SS_GAMESPEEDS` 212; check boxes use `CheckBox.bmp`, the level scroll bar (4..50, greyed unless tournament) is
  drawn from `HSBar170.bmp` (own reading of the strip), the speed is a drop-down. Rules of the boxes (dialog opened by `FUN_004e9570` with the
  handler `0x004e9ab0`; the rules are not traced in the 1.04 binary yet): switching "I am
  the greatest" (single player only) sets random weather and resignation on, AI resign and tournament off and locks every
  other box; tournament is greyed in a No Heroes game. OK stores the values in the ini; the game speed is not stored (the
  setup starts from the options screen's speed, as in the original; not traced in the 1.04 binary yet) and is chosen per game.
- Game speed: `opts.gameSpeed` 0..4 gives `world.speed` (x0.5 .. x2, five timer steps), saved in savegames (`data.speed`);
  in a network game the host's pick travels in the start message with the advanced options, every peer runs the same speed
  (the speed keys do nothing there, as before). Both `opts.advanced` and `gameSpeed` are in `savegame.snapshot` `opts`.
- Random weather: `world.randomWeather` from `advanced.randomWeather` (see Weather).
- Resignation kills a side (the original's confirmation dialog is not traced in the 1.04 binary yet): the `resign` command (Alt+R or the new "Resign" entry of the game
  menu with its confirmation, Game.txt 0308 / 0313 / 0314) neutralises the side (`Eco:neutralize`, binary `FUN_00534340`:
  every army and every standing building changes owner to the neutral side, queues are cleared) and the side is defeated;
  without the option the player just leaves the battle (screen pop; in a network game the others hand the side to the
  computer as for any dropped player).
- AI can resign (the computer player's turn `FUN_004fa120` tests the flag, `FUN_004fc5a0` decides whether to
  resign): a computer side that is not barbarian / passive and not the local side, with no hero, a current army
  limit <= 5 and a maximum <= 15, in a standard victory game, resigns when another used, undefeated side that is not its ally
  has more than 10x its current or more than 2x its maximum limit; an ally that is not a computer side of this game, has a
  hero or exceeds 5 / 15 keeps it in. The computers of every peer run the same code, so no RESIGN message is needed
  (`advanced.shouldResign`, called from `AI:think`).
- Tough towers (the building creation, binary `FUN_004a50f0` at `0x4a52e9`; the other, `FUN_00418700`, sets up the
  random towers): every race tower (the 16 `BWT?` codes) gets 750 hits (current and maximum), speed 3, combat and damage
  doubled, range + 1 (`advanced.toughTower`, applied in `World:addBuilding` on top of the game mod `toughTowers`, which keeps its
  own x3 rule). The binary gives speed 3 everywhere, scenario placed towers included. A tower the scenario
  makes a character (`rec.character`) is left alone (the character flag is tested in both functions).
- Hero-level scaling of towers (`advanced.scaledTower`, `World:towerHeroLevel`, `World:addBuilding`; checked in the binary:
  the building creation `FUN_004a50f0` from `0x4a52e9`, the random tower set-up `FUN_00418700`, callers of the former `FUN_00418700`,
  `FUN_0041c7d0` (the flags of a capture-the-flag game, which are characters) and `FUN_004910e0` (scenario loading)): in game
  type 0 / 1 (skirmish, multiplayer; not the campaign or a tutorial) a race tower that is not a character gets, with L the
  highest level of the human sides' heroes (loop over the six sides that are not computer sides: max of the side panel's level
  `0xa479c8[i]` and the hero's own level `0x709d00` / `0x7091e8 + 0x194 i`; Tournament mode: the tournament level), hits and
  current hits + 10 L, speed + L / 20, combat + L / 10, damage + L / 4 (integer division); the random map's three starting towers
  per side (`FUN_00418700`, `rec.starting`) get speed + L / 50 and damage + L / 5 instead (the binary's values). Tough Towers is applied first and both add up (speed 3 + L / 50 ...). The tower becomes a
  character afterwards, so it is never scaled twice. It happens only when the map is set up (the scenario's buildings, the
  random towers), never to a tower a player builds or a spell conjures (`setupDone`). L comes from the saved hero of the local
  side (`opts.profile`) and `opts.heroes` of a network game (identical on every peer); a game with no hero known (headless
  tests) has L = 0. The level of a tower is in the savegame (`towerLevel`, `towerKind`). The random map generator marks the
  towers (`starting`); the level is applied when the battle's world is made, because the heroes are not known when the map is.
- Hero weapon (the hero part of the army's damage getter, binary `0x00526540` ff., which has no Ghidra function): the item in worn slot 2 (the
  sword / staff slot, `hero.WEAPON_SLOT`) adds its piercing / slashing / crushing / fire / ice / electricity / magic powers
  (item power ids 90..96, first three powers) to the damage and the last of them sets the hero's damage type
  (`Items.bonuses(items, weaponSlot)`, `Hero:applyStats`); items in other slots add no damage, and without a weapon power the
  type record's damage type stays. (The binary has no Fire Missile branch there.)
- No items (flag at `0x749c68`, read by the item effect lookups `FUN_0040c380` and `FUN_0040c500`, the hero skill
  function `FUN_00556ab0`, the hero stat set-up `FUN_0054fd50` and the item spell cast `FUN_00529d20`): the hero's item stats
  and item skills are not added (`Hero:recalc` uses an empty item set), and no item spell fires (below).
- Item spells (the "cast spell" item powers, the item spell activation `FUN_00529d20`, `spells.itemCast` /
  `castItemSpell`): its only caller is the strike function
  (`0x0051ab00`, no Ghidra function): when the army is owned by the machine, a hero, and the target is an army or building,
  it calls `FUN_00529d20` before the hit is resolved - the hero's melee strike (the strike call after the fight activation),
  hit or not; a missile's launch or impact, being hit and periodic effects do not trigger it. The function itself needs the
  hero to be its side's hero (`0x70adb4`), No Items off (`0x749c68`) and no spell recovery running (`+0x268`, the end of the
  recovery). It walks the 7 worn slots of the side's item set (`0x709250`, 16 bytes per slot, the backpack is not
  scanned) and the first 3 powers of each item (item records `0x62dd..`, 0x27c bytes: power type, data, level, chance as
  3 shorts each); for a power of type 98 (cast spell) it rolls `FUN_00458e70(1, 100, 0)` (the dice routine, a d100) and
  casts when the roll is below the chance (a chance of 5 casts on a roll of 1..4, i.e. 4 %), calling the spell dispatcher
  (`FUN_005777a0`) with the power's data as spell, its level as the result, the hero's saved spell target and "use mana" =
  FALSE: no mana is paid, a level below 1 fizzles, and, as for a normal hero cast, the hero's spell recovery
  `1000 + max(5, points) x (spell % 10 + 1) x 10 + 100 x level` ms starts (so at most one item spell per strike and none
  while recovering; the extra powers in the same strike meet the recovery and do nothing). Items.xml has 37 such powers
  (spells 0, 6, 8, 9, 18, 26, 31, 46, 47, 50, 51, 53, 54, 57, 65, 70, 75, 80, 84, 85, 88, 89, 90, 98, 99, 101, 106, 118,
  123; chances 5 / 8 / 10, levels 1 / 2 / 5); none of those spell functions reads the hero's saved target, so they all act
  around the caster. The Disjunction and Spellforge effects are tested in the item effect lookup `FUN_0040c380` only, so they do not touch item
  spells. openwbc3: `Spells.itemCast(unit)` from the melee branch of `Unit:updateAttack`, the cast goes through the spell
  table (`def.fn` with the item level, no spell book entry or mana needed), floating text and light as for a cast
  (`itemspell` event, not counted in the battle statistics: the original counts only spell messages), `recoverUntil` is
  shared with the hero's own casts. openwbc3's own: it runs for every hero of every side on every peer (the original runs
  on the owning machine, the host for computer sides); no cast animation (the original plays none); a hero's multi-hit
  strikes (titan heroes) trigger it once.
- Computer hero items (the computer hero routine `FUN_0042a0d0`, items part read from the binary: tables `0x6084c8` / `0x6084dc`,
  the dice and funky ids; `Items.computerKit`, `World:giveComputerItems`): computer heroes are made with random items. Backpack:
  0,0,1,1,1,1,1,2,2,3 items (`d10`), none when the victory condition (`0x70ae12`) is 3 = Assassin, each item the random
  item of `FUN_0043e260` (1 in 200 - twice for a major item - an artifact / set "treasure", else a minor / lesser item, plus
  greater / artifact ones for a major item, major = 2d(level + 2) + 1 >= 45; duplicates dropped). Worn: 0,1,1,1,2,2,2,3,3,4
  items, each the random catalogue item `FUN_00402f90(minor, lesser, major >= 45, artifact >= 70, set = d2 - 1)` of
  2d(4 level) + 1 points; one
  funky item per hero by the rolls d100 > 95 / 90 / 85 / 80 (Ring of Fire and Ice 8, Thunder Shield 9, Blackfire Axe 15,
  Staff of Pyreakon 7); the last item is always the Boots of Speed (2); an item goes to the slot of its class (swords /
  staffs the weapon slot, armour / necklace body, shield / banner shield, ring / charm the first ring slot only, crown /
  helm head, boots), a later item of the same slot replaces the earlier one. The No Items option does not stop it. openwbc3
  applies it to the computer sides' heroes and the campaign's named side heroes; the hero's stats and the mana (a tenth
  of the maximum) are made after the items. Rolls use `math.random` seeded by the battle seed, as the rest of the set-up.
- Tournament mode (`screens/tournamenthero.lua`, `screens/levelup.lua` standalone, `profile.setTemporary`; checked in the 1.04
  binary): the game-started handler `FUN_004e2660` (the start message, tournament flag at +3 of the received options set and the
  No Heroes flag `0x70ae2d` clear) puts the points in the six side panel levels (`0xa479c8`), closes the lobby panels and calls
  the hero creation opener `FUN_0054b040(TRUE, points)` (temp flag `0xb92518`, level `0xb91428`). So after Start every human, in
  single player and on every machine of a network game, goes through the PNL_CREATEHERO screen (name, race, class, "Customize..."
  for portrait, avatar, password, voice set; Cancel greyed by `FUN_0054b620`, no screen help of its own, F1 still shows it,
  the hero starts as Knight / Warrior like a profile hero), OK (`FUN_0054bbd0`, the hero creation, called from the OK handler after
  the "Hero Already Exists!" check of texts 3 / 5..7, which is not exempt for temporary heroes) makes the hero at the
  tournament level with the experience of that level (`FUN_00409ef0`), does not save it (the hero save call `FUN_0044fef0`
  only runs for a profile hero) and opens the level-up screens (`FUN_00552d90(TRUE, level)`, `FUN_005522e0`, the lines say
  "Temporary hero", text 234 / 7, instead of the experience): the attribute screen starts with the tournament level as its
  points and the skill screen with the same number (the 1.04 code does not subtract one for attributes,
  `advanced.tournamentPoints`); OK is always possible and what is left over stays with the hero (`Accept`, `FUN_00553320`),
  so openwbc3 opens the level-up dialog at the start of the battle while points are left. Then the retinue / army setup and
  the battle follow. In openwbc3: the single player start (`skirmish.launch`) and the host's lobby (`mphost.launch`) run the
  screens first; in a network game the host sends `tournament` to every client, each client makes the hero locally and
  answers `tournhero` with the finished hero (`hero:save()`), the host collects them and forwards the heroes in the start
  message, so every peer builds the same heroes (`World:spawnStartingForces` takes a made hero as it is). The lobby screens
  keep the network session alive while a creation screen is open (`underUpdate`). The hero is a temporary record
  (`profile.setTemporary`, installed by the battle screen for its length): current hero whatever its race, never written,
  no experience, no Ironman, no saving (game menu, Alt+S / Alt+L), its retinue is empty. The customisation screen greys its hero
  mode list for a temporary hero (button 0x148 of panel 0x1b, `FUN_0054e790`). Own: a tournament hero whose race
  differs from its side's keeps the side's hero unit (a network peer only knows its own avatar); the hero's name is not shown
  in battle (no profile hero's is). Computer heroes are made at level `points` (the computer hero routine `FUN_0042a0d0`). Not in a No Heroes game,
  the campaign or a tutorial. Checks: `--selftest` ("advanced: ..."), `--show skirmish:tournament` (screens), a two-instance run
  (`--show mphost:tournament` / `mphost:autotournament` with `multiplayer:join`).
- I am the greatest (single player): the setup is forced and locked (hidden map with fog, no quests, 5 army setup points, tech 5,
  standard victory, mods off but No Walls; the player is side 0 alone in team 0 on very low resources, every other side an
  Emperor computer in team 1 on very high resources with a random race, the player's too: `FUN_004ea050` sets side 0's race to Random), computer heroes are
  at least level 100, +100 experience for a winner. Chat cheat codes do not exist in openwbc3.
- Checks: `--selftest` ("advanced: ..."), `--sim saveload`, a two-instance network run (the options and the speed arrive in
  the client's battle, logged as "advanced options: ...").

### No Heroes start force (`World.new`, `economy.GENERAL`; checked in the 1.04 binary)
The No Heroes start units come from `FUN_00445810` (called from the retinue set-ups `FUN_0043fe30`, `FUN_004406b0` and the computer players' `FUN_00445200` when the No Heroes flag at `0x0070AE2D` is set): one general of the race (id table at 0x0060B5D8: `AHGX ADGX AUGX ABGX AMGX AOGX AEGX AWGX AKGX AFGX AAGX AVGX AHGR ALGX ARGX AGGX`, `economy.GENERAL`) and two builders (table at 0x006095D8, the first id of each race's block = `economy.BUILDER`), created as ordinary armies of that type (level 0). So the general has the stats of its own `.ARM`, speaks with its own `AxGX` voice files and is not a hero. The extras openwbc3 used to give it (fixed stats combat 12 / 160 hits, "<Race> General" names, the keep producing a fallen general, the race's hero voice set as its voice) are not in the 1.04 binary (`docs/todo/not-in-original.md`) and were removed; the earlier version converted the race's hero unit instead. Scenario-placed hero units in a No Heroes game stay real heroes (the binary has no code that converts them; not traced further).

### Hero level-up dialogs
(Flow and when the levels are made: "End-of-battle experience and the victory screen" above.) Checked in the 1.04 binary: after a battle the results screen's OK handler (callback 0x004546F0) opens `PNL_HEROLEVELUP_STATS` (`FUN_00552d90`, the panel opener `FUN_004620d0(0x159, ...)`) while stat points are left, then `PNL_HEROLEVELUP_SKILLS` (`FUN_005522e0`, 0x15A); these are the panels `screens/levelup.lua` builds. `PNL_HEROADVANCE` / `PNL_HA_*` (the "level-up book") is not part of the level-up flow (`docs/todo/not-in-original.md`).

### System speech and unit speech (`src/audio/speech.lua`, `src/audio/voices.lua`, `screens/battle.lua`; checked in the 1.04 binary where noted)
All 29 system speech lines but ally vanquished (10, which 1.04 never plays) are wired (`System[F]<n>.wav` of `GameSpeech.xcr`; the female voice only exists for
English, otherwise the male file plays). The system speech player (`FUN_0050f1b0`, decompiled):
a message plays only when a timer is above 10; victory, defeat, hero near death / under attack / fallen, enemy / allied
hero destroyed and ally / enemy vanquished first set it to 11; every message that passes resets it, also when its file is
then refused. The timer counts display ticks (25 ms: the start-up's multimedia timer, 25 ms with 10 ms resolution, at 0x457f9c), starts at 40, so
11 ticks (0.275 s) separate two lines and the old flat 3 s cooldown is gone. The attack lines (0, 1, 3, 5, 28) are loaded
with the check-time flag (`FUN_00510f90`: a cached sound plays again only when its use counter is above 20); the
counters go up once per 18 calls of the global timer (`cmp eax, 0x12` at 0x458d7b), which is the 50 ms window timer
(timer id 1, 50 ms, set at 0x45a82f; that the 18-counter sits in that timer is not traced in the 1.04 binary yet), so one line of that
kind plays at most every 21 x 18 x 50 ms = 18.9 s (the old code used 10 s). "Too many men" plays only when the army limit
changed since it last played.
Triggers (`onEvent`; the conditions of the original's army and building hit handling, the unit branch checked in the binary
at `FUN_00522860`, the building branch not traced in the 1.04 binary yet): troops under attack (1) / hero near death (5, hero below 50 hits) / hero under attack (3, hit for 2 or
more) only when the unit is outside the view; base (0) / buildings (28) under attack for a building hit for 2 or more
more than ten cells outside the view, "base" being within 20 cells of the side's highest keep (the side's current base point, else
its start position); hero fallen (4), allied (25) / enemy (6) hero destroyed from `herodied`; upgrade complete (7);
research complete (8) for any bought power-up or rune (the power-up routine `FUN_00436500`; not for the research, mercenary and quest ones; learned new
spell (9) is the `spellresearch` event, raised by the spell research `FUN_00438180`); enemy vanquished (11) when a side not allied to the local player is
defeated while another side not allied to it still stands (the side-defeated message 0x21c, `FUN_004af270`; ally vanquished (10) is never played by 1.04); heroic effort (14) at the 50th, 100th ... army killed by the local hero; need more crystal / metal / gold / stone
(20, 19, 17, 18) when a builder reaches its place without the means (`cantbuild` with the resource, checked in that
order as in `FUN_00524450`) and when a building ability or Slave Horde (gold or crystal; the building button handlers,
see "Building abilities") or Drunkenness (gold; not traced in the 1.04 binary yet) is too dear; too many men (2) when a production is stuck
for lack of room (first time only, the production's suspended flag); new armies (22) / buildings (23) / both (24) when the requirements
of a building or army of the race became met (`FUN_00519560` buildings / `FUN_00519630` armies, evaluated once a second
by `Eco:available`, silent for the first check of a battle, not in tutorials); enemy (26) / allied (27) titan for a
titan raised by another side after two minutes (`world:addUnit`); quest lines were there before.
Army limit and summons (`Eco:roomFor`, `fx.roomFor`, `spells.unitCast`, checked in the 1.04 binary): the army-limit check is
`FUN_005776c0` (a refusal when `limit max < current + the type's unit value`; for the local side
it forces "too many men" and plays it, `FUN_0050f190(2)` + `FUN_0050f1b0(2)`). The 1.04 binary has it in the first lines of
**every** summon spell function (spell numbers of the 1.04 dispatcher
`FUN_005777a0`: 10 Quasit, 14 Imp, 15 Arcane Eye, 17 Succubus, 19 Demon, 20 Sprite, 24 Unicorn, 27 Treant, 29 Arcane Elementals
(the picked one), 34 Spectral Forces, 35 Illusory Dragon, 37 Shadow, 40 Skeleton, 41 Zombie, 43 Wight, 47 Call the Dead (unit
value 1, only when a corpse was found), 49 Raise Champion (the picked one), 58 Fire / 79 Earth Elemental, 63 Stone / 68 Bronze
Golem, 102 Wasp, 107 Naga, 109 Spiders (Queen Spider and Spider, each checked), 116 a random White / Red / Black Mage, and the buttons of the
troops below: Giant Bats, Goblin Horde, Summon Blades, Create Firebomb, Summon Spiders), also for a hero; the spell is cast (the mana is
spent, the cooldown runs) and just makes nothing. Only the first army is checked by the spell; the host's spell resolution
(`FUN_004aa840` case 6) then makes the armies one by one and stops as soon as the side's army count has reached its limit (the
count is updated by each new army, `FUN_004a49e0` -> `FUN_00533fb0`; `fx.summon`). There is
no separate Water Elemental check: no 1.04 caller of the check makes one except the
Arcane Elementals' pick. The troops' summon buttons
(`FUN_00426350`: Zombie of the Dark Elf Mage, Imp of the Demon, Demon of the Summoner, Earth Elemental of the Runelord, Giant
Bats of the Vampire, Queen Spider of the Spider Priestess, Fire Elemental of the Scorpion Priest) check before the mana is
spent and make no cooldown (`limit` of the `ability` record; the Fire Elemental one checks the Scorpion Priest's own type, a
quirk of the original that is kept); the other buttons (Goblin Horde, Blades, Firebomb) check inside the spell. The
neutral side is not checked (own choice: its limit arrays are not known). openwbc3's own: the second check of the Spiders
spell sees the units of the first (units are made at once here).
Unit speech: box and click selection speak the best-voiced army (the 1.04 group selections `FUN_005319f0` /
`FUN_00531dd0` end with the best of the selected list, `FUN_00531730`: the first of the highest voice priority, field +0x20e,
in selection order, asks the speech request `FUN_0050be80` for the select line), not the first unit as before. "Designate unit" orders (the guard order with a
unit to follow, also the custom `.uai` attitudes that designate) speak like every order (best of the selected group,
not traced in the 1.04 binary yet). Variant thresholds checked in the 1.04 binary (`FUN_0050c2e0` select,
`FUN_0050c530` order): select 2 files > 55 / 3 files > 70, > 40 / 4 files > 72, > 60, > 40, order 2 files > 55 / 3 files > 90,
> 50 / 4 files > 92, > 80, > 45, each with the last-played exclusions of `pickVariant`; the counter limits 90 (select / order) and 30
(deathblow, `FUN_0050cae0`), the "Ready" timer 15 (`FUN_0050c790`), "Sometimes" 2 in 5 (the speech request `FUN_0050be80`: a roll of
1..5 above 2 skips) all match. Hit conditions: a hit without an inflictor (burning, no-credit spells) is sent with the
victim as its own inflictor (the army's damage intake, vtable entry `0x00522af0`, not traced in detail), so it enters the hit
list like any hit; poison takes its hit points off directly (current hits - 1 per second, no hit message) and no longer sets the
hit flag, the hit list entry or the AI dwarves' drunkenness (the poison tick is not traced in the 1.04 binary yet).
Unit speech: the order line is spoken by the member of the group with the highest voice priority (hero 10000, else
combat x 4 + speed x 2 + hits, +500 for a general, the voice priority) for every order the original voices (moves and attacks,
patrol, guard, shop / search visits, build, mine, garrison, stop, formations, merge wisps). Select and order lines share
one counter (two per tick, above 90 = 1.15 s; the deathblow needs it above 30 = 0.4 s) and the option "Sometimes" lets
2 in 5 requests through; the "Ready" line of a produced army has its own 0.4 s timer and is not spoken for heroes. Which
`Select<n>` / `Order<n>` plays follows the type's number of speech files (`.ARM` field `speech`; heroes have four), a dice
roll and the variant played last (thresholds of `FUN_0050c2e0` / `FUN_0050c530`, above). New lines:
`Deathblow` (the attacker of a melee deathblow against an army, positional), `Build` (the builder when its building is
finished, a hero says `Conversion`), `Conversion` now at the end of a conversion (it used to play at the start),
`CantBuild` only for a blocked place (a lack of resources is the announcer's "need more"), the hero's `Mana` when a
spell is refused for lack of mana. The sound files and the fire / falling sounds were there before. Debug: set
`require("src.audio.sound").trace = print` in an `--at` script to log every file played. Checks: `--selftest`
(timers, variants, event data, availability).

### Wall building (`src/game/walls.lua`, `ui/hud.lua`, `screens/battle.lua`, `commands.lua`)
- Build Wall button (button 33, its routine at `0x004ce7f0`, no Ghidra function): second special-slot button of a single selected
  builder, after Build; shown for builders that are not heroes and not Treant / Ancient Treant (`AWJX` / `AWKX`), greyed
  at tech level 0 and with No Walls and No Towers both on (the special-ability button set-up `FUN_004d3200`). Like in
  the original a button only gets one of the three special slots (at most three: slots 7..9 here), so it can be crowded out
  by convert / spell book. Build and Build Wall open the same construction dialog with row 0 (the
  race's major buildings, also the orc totem under `T`) or row 1 (the walls: tower, three wall pieces, rampart) of the
  race's `[CONSTRUCTION]` in `Building.cfg` (the army's build-action list, vtable entry `0x00525a70`), both through the
  level check `FUN_0040c990`
  (`Eco:constructionList(side, row)`; without a row both rows, what `startConstruction` accepts). Before this change the
  Build dialog listed both rows and cut it at nine entries, so walls were never offered.
- Hot keys: `B` / `W` from `KeyMap.txt` (`keymap` names `build` / `walls`; `W` is the 18th line). Binary
  `FUN_00427fb0` (key handler; table `DAT_0074c434`): index 15 requires tech level > 0 and presses button 31, index 17
  requires tech level > 0 and not (No Walls and No Towers) and presses button 33 (`FUN_004d2290`, the hot key's button press);
  `HUD:pressButton` presses the matching button of the current panel, so a key does nothing without the button.
- Drag-built walls (1.04 binary: `FUN_00429820` adds a section, `FUN_004299b0` re-picks the pieces from the neighbours;
  the rest of the mouse code is not traced in the 1.04 binary yet): with a wall piece (BWG0..2, BWN0..2, BWE0..2, BWRA)
  chosen for placement and neither Shift nor Alt held, pressing the left button on a legal cell starts a drag; every mouse
  move adds the cell under the cursor: inside the map, snapped to the 2-cell grid of the first section, legal for the
  chosen piece, not a duplicate, at most 64 sections, then each section is re-picked from the neighbours two cells away
  (above and below only: `..2`; left and right only: `..1`; anything else, line ends included: `..0`; the rampart keeps
  its code). There is no line fill between two mouse events. Releasing the button sends one `build` command with
  `sections = { {code, gx, gy} ... }` (plain data for lockstep); `commands.lua` gives the first to the builder as its
  order and queues the rest (`Build(..., 1)`), refusing heroes / treants and non-wall codes, and the builder speaks its
  order line. The right button cancels the drag; edge scrolling runs at the slowest rate (rate 1) while
  dragging. The queued builds are ordinary queued orders, so they are saved with the unit (`--selftest --sim saveload`
  checks it). openwbc3's own choice: the first cell must be placeable when the button goes down (the original only checks
  the placement radius and lets the build order fail later); the ghost of each section is drawn translucent.
  Checks: `--selftest` ("walls: ..."), `--selftest --sim saveload`.

### Retinue in every game type (`src/game/retinue.lua`, `src/game/armylevel.lua`, `screens/armysetup.lua`; checked in the 1.04 binary)
The hero's retinue (numbers checked in the 1.04 binary, functions named below) now works in skirmish,
multiplayer and campaign alike and belongs to the hero record (`profile`): `rec.retinue[1..8]` = `{ code, name, level, xp,
battles }`, `rec.graveyard[1..10]`. Campaign saves that kept the retinue / graveyard in `campaign/<hero>.lua` are moved to
the hero when they are loaded.
- **1.04 binary details** (documented in the header of `retinue.lua`): the number of enabled slots is
  `min(Charisma / 4, 7) + 1` (`FUN_0040b130` -> `FUN_0054a720` case 14), not a constant 8 (the hero info tab greys the rest);
  the army setup opener (`FUN_00440b40`) adds the province bonus, caps the points at 100 and adds **neither the Charisma bonus
  nor the Diplomacy skill (106)** to the army setup points (nothing in the binary reads skill 106 for the
  retinue - not implemented, see `docs/hero.md`). Re-read in `FUN_00440b40` once more: its points argument gets the province bonus
  of the side's slot added, is capped at 100 and goes straight to the screen; the Charisma only reaches `FUN_0040b130` (slots).
- **Army setup (select mode, before a battle)**: regular troops and retinue members are bought with the setup points; a member
  costs the type's setup points plus a level table (`0x006095b0`: 0 0 0 0 1 1 1 2 2 3 4 5 6 7 8 9 10 11 12 15, `FUN_00444940`;
  openwbc3's old "one point per level" is gone). Nothing is pre-selected, any click toggles a member, left / right click adds
  / removes a regular troop; a member's cell shows the medals (a gold one per five levels, level mod 5 + 1 silver ones), the
  combat icon and the cost; hovering for 0.65 s opens the statistics popup (combat, hits, speed, damage, range). The chosen
  units are placed around the start location (`FUN_004402d0`: +-5 cells, 5 cells from the edge).
- **Recruiting (after the battle)**: when the victory screen's Continue is pressed (after the level-up screens, if points are left) the retinue screen opens in recruiting mode
  (`PNL_RETINUE`, `STR_LARGE332` "New Recruits"; help 9). `retinue.recruits` is the recruit list
  (`FUN_0043f3e0`): units made during the battle (not scenario armies, the setup army or mercenaries: a per-unit flag),
  level 2+, combat 8+ (with the level gains), not mechanical, not the Eye of Oros, default data, at most 8; a full list gives
  up the weakest copy of a type that is in it twice (combat + 5 x level), else the weakest entry if the newcomer's combat + 3 x
  level is higher; a general of the race (table at `0x00609330`) is added when none qualified and the game lasted 5 minutes
  or was a pitched battle. Unnamed recruits get a name from the naming sets by type / race flags. Click a recruit, then a
  slot (or the other way round) to swap, click a member's name to rename it (11 characters in the editor, the original's characters get a
  "2"). Survivors of the retinue keep their level / experience, the fallen go to the graveyard (10 places, the oldest is
  replaced, the most valuable stays first) and every member counts the battle. Not for a Tournament hero, a removed Ironman
  hero or the tutorial.
- **Army levels** (`armylevel.lua` = the level gain `FUN_0040daa0`, tables at `0x607d70 / 0x607ed0 / 0x608030`): a troop level
  now adds to combat, speed and hits (value-range tables), damage (+2, +1 from level 5 / 10 / 15), resistance and armour
  (+1, +1 from level 5 / 12) - for every unit, not only retinue members (before, levels only showed). Units without an attack
  learn none (own, safe choice).
- **Computer armies** (`FUN_00445200`; table at `0x006095d8` read from the binary): the side's builder first,
  a Knave gets half of the rest, then one of four rolls of the row for min(points, 8), until the points are gone (at most
  50 units). In a campaign the difficulty (0 Easy, 1 Moderate = default, 2 Hard; the campaign options dialog sets it) adds 10 / 4 points
  (d100 < 30 / 75 x difficulty, not for Passive / Rampant sides, not where the map has "no retinue") and may hire a mercenary
  company (hero level 10+: 25, 5..9: 12 per difficulty step, major below the first threshold).
- **Multiplayer**: after Start every human chooses an army (`setup` message with the points, `army` reply, the host starts when
  all arrived and sends `armies` with the start message; handicap points of the table at `0x00603c9c` when the scenario's
  option is on). Armies are placed from the same data on every peer.
- **Campaign mercenary companies** wait in the two mercenary slots until the player picks them in the selection dialog before
  a battle (see "Campaign: extra army points, mercenary selection, options"). Single retinue units (rewards, hire
  actions) go through `retinue.give` (free slot, else the weakest is replaced).
- Checks: `--selftest` ("retinue: ..."), `--selftest --sim saveload` (units keep levels, recruit flags, slots).

### Retinue screens as XCI panels (`screens/armysetup.lua`, `screens/graveyard.lua`; checked in the 1.04 binary and `War4Int.xci`)
- **The retinue name does not exist for the player**: the binary's retinue handler `FUN_00440e80` handles button 217
  (`BUTT_RETINUE_NAME`, opens `PNL_RETINUE_NAME` with the editor 3018) but no panel of the shipped `War4Int.xci` holds the
  button, so it cannot be clicked, and nothing shows the text; see `docs/todo/not-in-original.md`.
- **Retinue screen**: built from the panels `PNL_RETINUE` (background, titles, OK, Graveyard), eight `PNL_RETINUE_ARMYn` (the
  retinue) and eight `PNL_RETINUE_RECRUITn` (troops / new recruits) opened at the slot tables of the binary (`0x00609288`
  / `0x006092c8`), `PNL_RETINUE_POPUP` (statistics: name, Combat / Hits / Speed / Damage / Range, labels Game.txt 0258 ..
  0261, 0755; at the cursor, at most 630 / 450, after 650 ticks of rest, closed by the next mouse move) and
  `PNL_RETINUE_EDIT_NAME` (the 125 x 15 editor, opened 2 / 94 from the slot's corner). The original sets every medal and
  the combat icon of the XCI off the screen and draws the pictures itself (image subtype 25): the unit's picture 2 px in,
  setup points top left (select mode), the green tick (selected) / red cross (not affordable) of `BM_RETINUE_TICK_CROSS`
  (the regular troops use the small cross `BM_RETINUE_SMALL_CROSS` at 64 / 4), the medals at the tables of `0x00609308`
  (silver x 77, y 1 + 15 n; gold x 65, y 1 + 15 n) and the combat icon with the number. A picked up unit is its panel moved
  to cursor - 45 (event 10 of `FUN_00440e80`), so its name travels with it; slots the Charisma does not enable show a
  translucent cross in the recruiting screen only. Regular troops show "name (n)" when taken, the cross says "cannot
  afford". Left click adds a troop, any other button removes one; a retinue member toggles with any button.
- **Name editor**: the XCI editor record limits the text to 11 characters (offset 136 of the record; the editor text setter
  `FUN_0045daf0` refuses a longer text, so a longer name opens an empty editor); the 19 characters of the rename handler
  (`0x00442e30`) and the
  renaming of the original's heroes stay. Own: the dark box behind the editor text (the record's colour fields are not
  understood).
- **Graveyard** = `PNL_GRAVEYARD` + `PNL_GRAVEYARD_PART2` (`FUN_0054f260` opens them, `FUN_0054f6f0` fills them,
  `FUN_0054f980` the stats area, `FUN_0054fc00` its picture): ten stones at x 165 / 420, y 136 + 70 n (the panel's eleventh
  button is never used), each with the unit's interface picture (frame 1, 32 x 50), name, "Level n", "n Battles" (always
  the plural text 280/1) and its number; resting on a stone shows the picture (184, 478), the name, the line "Slain in the
  battle of %s." (only when the game language is English, the scenario "Random" reads "Slain in a random battle.") and
  the medals (silver x 220 + 12 n, gold x 220 + 17 n and 15 px lower, y 512). The old hand-made list is gone.
- **Killer** (the killer record, `FUN_00520e60`, called when a retinue member of the local side dies): `Unit:die` records the
  unit type of the attacker per retinue slot in `world.fallen` (`""` for a building or no attacker; saved), the battle
  settlement copies it into the grave as `killer`. The 1.04 graveyard screen does not show it; it is kept for completeness.
- Checks: `--selftest` ("retinue: a fallen member remembers its killer's type ..."), `--selftest --sim saveload`;
  screenshots `--show armysetup[:recruit|edit|popup|<race>]`, `--show graveyard[:stats]`.

### Campaign: extra army points, mercenary selection, options (`screens/campaignextra.lua`, `campaignmercs.lua`, `campaignoptions.lua`, `game/campaignrun.lua`; checked in the 1.04 binary and `War4Int.xci`)
- **Flow** (army setup opener `FUN_00440b40`, caller `FUN_00417280`): a campaign battle opens the army setup screen only when the
  map's setup points are 1 or more (`FUN_00417280`: `points + handicap < 1` goes straight on, so no extra points can be bought and
  no mercenary goes along there). Over the screen (no screen help in the campaign) the extra points dialog (`FUN_005a8330`) opens
  when the hero has 10 crowns or more; its Continue buys the chosen package, then the mercenary selection
  (`FUN_005a5040`) opens if a company waits in either slot (without the crowns it opens at once); afterwards no points left closes
  the screen like OK (`FUN_004457e0`).
- **Extra army points** = `PNL_EXTRA_APS` at (120, 135) (`FUN_005a8490` sets the texts: Game.txt 0706 heading, 0707 text, 0708 / 0709
  "+%d point(s)", 0710 / 0711 "%d crown(s)", options 0712 / 0713 / 0714, 0715 "no buildings" when the battle's tech level is 0).
  Options: none, 4 points for 10 crowns, 10 points for 30 crowns (`FUN_005a86e0` -> `FUN_00445780` adds the points and takes the
  crowns); the third is greyed below 30 crowns (`FUN_005a8420`). The selected radio is the checked ring of `CheckBox.bmp`.
- **Mercenary selection** = `PNL_CAMPAIGN_SELECTMERCENARY` at (52, 58): per slot the company's picture (`CampaignMercenaries.bmp`,
  90 x 110 per race), name, troop lines, and a Select / Deselect button (TXT 325 / 5, 6); an unselected company is greyed by
  `MercenaryGrayout.bmp` (translucency level 12, drawn here as 0.75 opacity: own reading), a selected one says "Selected for this
  battle" (325 / 4); an empty slot says "Empty" (323 / 2). Done keeps the choice (a selected flag per slot); only selected companies join the
  battle and are disbanded (`FUN_00596590(slot, TRUE)` from the battle start placement `FUN_004406b0`), the others keep their slot. The panel's Disband
  button and the `BUTT_CAMPAIGN_SELECTMERC` areas are never activated by the code, so they are not shown.
- **Campaign options** = `PNL_CAMPAIGN_OPTIONS` at (80, 130) (`FUN_005a4070`, record at `0x060d37ba` = { scroll rate, difficulty,
  menu sounds, resolution }, defaults 1 / 1 / 1 / the global resolution): four drop-downs (difficulty Easy / Normal / Hard, map scroll
  speed Slow / Normal / Fast, resolution, campaign menu sounds Off / On), Cancel, Okay, "Reset Campaign" (message box, then a fresh
  campaign for the hero). The picks change the record at once, Okay saves it, Cancel only closes. The campaign menu's Options entry
  opens it (it used to open the game options).
- **What the difficulty does** (the only readers of the record's difficulty are `FUN_00445200` computer armies, `FUN_005a1790`
  the campaign AI level, `FUN_005a1880` the campaign battle start and `FUN_0042a0d0` the computer hero): computer extra points / mercenaries
  (`retinue.aiExtraPoints`, see "Computer armies"); the AI level of the computer sides (next item); there is no fog of war on Easy;
  computer heroes get half their level on Easy and `+ 2 x difficulty` above Moderate (`campaignrun.computerHeroLevel`). The hit
  point change for passive / barbarian sides uses a separate global option (registry `CampaignDifficulty`, read / written by
  `FUN_00451b10` / `FUN_004521f0`) that nothing else is known to set (not traced further in the 1.04 binary), so it stays at
  Moderate and does nothing.
- **The campaign's AI level** (`campaignrun.aiLevel` = the 1.04 binary's `FUN_005a1790`): starts at 2 (Easy 1, Hard 3, option value 3: 4); the hero's victories
  with the race (`rec.raceWins[race]`, the hero's victories per race at 0x00709d46 + 2 x race) take it to 0 below 1, -1 below 3, +1 above 75;
  -1 when victories <= 2/3 of the games with the race (`rec.raceGames`, games per race at 0x00709d66) and -1 more when
  <= 3/8 of them; +1 from hero level 20 and +1 from 40 (0x00709d00); clamped to 0..5 and then to 2 / 3 / 4 on Easy / Moderate / Hard. The
  counters belong to the hero record: a game is counted when a battle with a hero profile is set up (`FUN_004e2790`: the games of the
  player's race +1, unconditionally), a win when the battle is won (the victory handler at 0x00454987: the victory count and the race's wins +1
  when experience may be gained); openwbc3 counts them in `screens/battle.lua` (`profile.addRaceGame` / `addRaceWin`), a hero from before
  starts with 0 of both (which gives the lowest level until he has won a battle with the race).
  The campaign battle start (`FUN_005a1880`) turns it into the side levels: for a battle on a scenario file every computer side keeps the
  scenario's own level (0 Passive and 7 Rampant stay), anything else becomes `difficulty - 1 + level` clamped to 1..6; a map `<Side>`
  with `relativeai` adds that to the scenario level before the shift, one with `ai` (0 or 7 in the shipped maps) replaces the level and
  no shift. For a random map the base is the AI level (`FUN_005a1790`) + 1 (tables at 0x0061c9cc / 0x0061c9d8 read 1..6): `ai` replaces it,
  `relativeai` gives `difficulty - 1 + base + relative` (1..6), a side with neither plays the base. This replaces openwbc3's old own
  mapping (Knight + `relativeai`). Checks: `--selftest` ("campaign: AI level ...", "side levels ...").
- **The difficulty line of the battle dialog** (the campaign rating `FUN_005966a0`, called by `FUN_005a2fc0` / `FUN_005a3390`, printed
  by `FUN_005a3450` as Game.txt [0700 + rating]: Easy, Average, Hard, Very Hard, Insane, Suicidal; `campaignrun.difficultyRating`):
  the AI level (`FUN_005a1790`) - 1, then for the map's sides 1..7 (and the scenario file's used sides the map does not list): a side in the
  hero's team (non-zero and equal) counts as an ally, any other as an enemy (a team number on an enemy = an "enemy ally"); a side with
  `ai` 0 counts 0, `relativeai` above 0 counts one more, below 0 one less. More allies than enemy allies: `AI level - 3` (the 1.04
  binary deducts twice here); enemy allies > allies + 1: +1; more than two enemies: +1; clamped to 0..5. The old
  hand-made "Easy / Medium / Hard" estimate is gone. The rating is computed for the race picked in the dialog's race list (next
  section).
- **Game resolution** (option value 0..3): the campaign battle start `FUN_005a1880` hands 800 / 1024 / 1280 / 1600 to `FUN_004e7230` (the battle's selected
  resolution) before a campaign battle. openwbc3 has no separate battle resolution; like its skirmish setup it sets the window to that size
  (800 x 600, 1024 x 768, 1280 x 1024, 1600 x 1200: the dialog's texts) when a campaign battle starts, windowed only, only when the desktop
  is big enough and only once the player has picked a value (the original's default is the global resolution = whatever the window is).
  That window handling is openwbc3's own; the campaign map stays on the scaled 800 x 600 canvas.
- **Map scroll rate**: the original moves the map `10 + 8 x rate` pixels per key event (`0x0059c340`); openwbc3 scrolls continuously
  and scales its 380 px/s by that ratio (own). **Menu sounds**: the dialogs play `Battle`, `retinue`, `xp`, `message`, `Tavern`,
  `Merchant` (action dialogs), `Ambush` and `Land` / `Sail` (travel, by the link type) wavs of `SoundFX.xcr` when the option is On.
- **Found on the way**: `armysetup:done` popped the screen after calling `onDone`, so a battle started from it was popped at once;
  it now pops first.
- Checks: `--selftest` ("campaign: ..." lines), screenshots `--show campaignextra[:poor]`, `campaignmercs[:one|:picked]`,
  `campaignoptions[:reset]`, `campaignmap:extra` / `:mercs` (the real flow from a battle action, the saved campaign is left
  alone) / `:options`.

### Campaign battle dialog: the race list (`screens/campaignmap.lua` `openBattle`, `game/campaignrun.lua`, `game/campaignhate.lua`; checked in the 1.04 binary)
- **The list** (the new-battle dialog `FUN_005a2fc0`, list at 0x0610c8f8, 16 shorts, -1 = end): the hero's own race first, then, in slot
  order 0..15, every other race for which `FUN_00595470` returns 0, i.e. whose standing with the hero is **Ally**. `FUN_00595470` turns
  the standing into a relation: standing (16 shorts at 0x060d2a88 + 2 x race) below -4 -> enemy (3), below 5 -> neutral (2),
  below 15 -> friend (1), else ally (0); the same function picks the ambush chance (`FUN_00596280`) and sorts the diplomacy dialog's
  four columns (`FUN_0059ebf0`). The button `BUTT_DROPLIST170` shows the picked race (Game.txt 277 / 278 = TXT_RACE_ABBREV_1 / _2,
  `FUN_005a3390`), a click opens the drop-down list with the entries (`campaignrun.battleRaces`, `dropdown`), picking one recomputes
  the difficulty line: `FUN_005a3390` calls `FUN_005966a0(action, race)`, which takes the AI level `FUN_005a1790(race)`, so the hero's
  victories / games with that race count (`rec.raceWins` / `raceGames`, a race he never won with is the lowest level). The labels and
  the cost line come from Game.txt 316 / 317 (TXT_CAMPAIGN_NEWBATTLE, so they are localised; they were English before).
- **What the picked race does** (the campaign battle start `FUN_005a1880`, `campaignrun.setup(state, map, rng, race)`): it becomes the race of
  side 0 (`DAT_00a47a38 = param_2`, both for scenario and random maps) and the argument of the AI level `FUN_005a1790` (so also the base
  level of a random map's computer sides). Everything that follows is what a hero playing that race anywhere gets: the start
  buildings, build lists and units are the side's (the race's); the army setup screen lists the **side's** race's regular troops
  (`FUN_00444980` switches on the side slot's race at 0x00708f96, not the hero's); setup points, extra points and mercenaries are the
  map's / the crowns' (no race input); the retinue members are whatever types the hero has and come along unchanged; games and wins
  are counted for the side's race (`FUN_004e2790`, victory handler) so the difficulty of each race follows its own record. The
  **hero unit is the hero's own** (his record's race and avatar, as in a skirmish: `opts.heroRace`, `World:heroRaceOf`), and the
  general a recruiting screen adds (`FUN_0043f3e0`, table 0x00609330) is the **hero's** race's (it reads the hero record's race,
  0x00709cfc, not the side's; the same holds in a skirmish with another race's seat, `screens/battle.lua` now says so).
- **The standings** behind the list were not the original's. `FUN_005939a0` (a new campaign) copies the hero's row of the table at
  0x0061c0c4 (16 x 16 shorts; the own race is 20, the others -10 .. 10, so a new hero has
  no ally but his own race) into the standings; openwbc3 had started every race at 0 with the limits ally 10 / friend 5 and added an
  action's change once up to its limit. Now (`campaignhate.lua`): start values from the table (an older campaign save has the row
  added once when it is loaded, marker `standingsSeeded`), limits ally >= 15 / friend >= 5 / enemy <= -5 (the campaign data's
  `max` 14 / 15 / 20 values are built on them) and `FUN_005955a0`'s step: add the change, and if the result is still short of the
  limit add it once more (to the limit); a change that reaches or passes the limit on the first add stays there (the data's +100
  steps put a race at 100 + its old standing). The effects for the player: allies only come from actions, and the ambush chances read
  the right relation. The diplomacy dialog and the ambush dialog are in the next section.
- **Reward line** (`FUN_005a3450`, the briefing's draw routine): it pushes one fixed string, the action record's field at +0x746 (the
  record starts at 0x0610c918: code +0, name +0x24, help +0x54, replayable flag +0xd4, description +0x29c, reward count +0x69c, first
  reward +0x6a0 = type, data, 32-byte data string, 128-byte text, 128-byte short text at +0x746), i.e. the **first reward's short text
  only**; a first reward without short text prints nothing. openwbc3 had joined
  every reward's text; of the install's actions ACT_ENMOUTH is the one that differs (its second reward's "100 Kronen" was added to the
  first one's "Orden von Selentia und 500 Kronen"). The same routine appends Game.txt 716 ("(Replayable)") to the mission name of a
  replayable action (flag at +0xd4), now done too.
- Checks: `--selftest` ("campaign: relations by standing", "diplomatic steps", "the race list ...", "the picked race ...", "the
  difficulty line follows ...", "standings start as the hero's row"), screenshots `--show campaignmap:races` (the dialog with three
  allies, Dwarf picked), `campaignmap:racelist` (the open list), `campaignmap:fightrace` (the real flow with Dwarf: the army setup lists
  the Dwarf troops, the hero stays a Demon).

### Campaign ambush and diplomacy dialogs (`screens/campaignmap.lua` `openAmbush` / `drawAmbush`, `openDiplomacy` / `drawDiplomacy`; 1.04 binary)
- **Correction**: `FUN_005a2ca0` is not the ambush dialog's draw routine (an earlier note said so): it is the location's More Info
  dialog (name, description, race and diplomatic rating of the owner, the action icons: PNL_CAMPAIGN_MOREINFO, `drawMoreInfo`).
- **Ambush** (PNL_CAMPAIGN_AMBUSH, 685 x 530, opened at (57, 35), modal; the opener is the slide callback ending at 0x0059d680 which
  ends with the "Ambush.wav" play, the Fight handler is `FUN_0059dbf0`, the draw routine `FUN_0059db00`, the drop-down caption
  `FUN_0059da70`): the race list is built exactly like the new-battle dialog's (hero's race first, then every race whose
  `FUN_00595470` is 0 = ally, array at 0x060d79f8, selection starts at 0), the drop-down button shows the picked race (texts 277 / 278)
  and Fight starts the map with `FUN_005a1880(map, list[pick])`, so the picked race plays the ambush battle (before: always the
  hero's own). The draw routine writes the ambush's name in font 36 centred at (400, 180), its description wrapped to 300 px (font 23)
  as lines centred at x 400 from y 250 every 20 px in font 27, and "Race:" (text 316 / 6, font 34) right-aligned at (309, 359). There
  is no difficulty line, reward line or cost in it. The dialog cannot be cancelled (modal, one button): Escape no longer drops it.
- **Diplomacy** (PNL_CAMPAIGN_DIPLOMACY, 696 x 484, `FUN_0059eaf0` opens it at (52, 58), title text 314 / 2, Done button; draw routine
  `FUN_0059ebf0`): four headings (texts 315 / 0..3 = Ally, Friend, Neutral, Enemy; font 12) centred at x 155 + 150 x column, y 120, and
  the 16 races in slot order, each in the column of its relation (`FUN_00595470`: 0 ally .. 3 enemy), 20 px apart from y 160, font 27,
  names from texts 277 / 278. The standing numbers and the "Allied / Friendly / Hostile" words of the old hand-made dialog are gone;
  the hero's own race (standing 20) is in the Ally column.
- Own: the text y values are the original's minus 4 (3 for font 36), the offset the other campaign panels use for the same fonts
  (not re-derived from the original's glyph drawing).
- Checks: screenshots `--show campaignmap:ambush`, `campaignmap:diplomacy`, `campaignmap:reward` (ACT_ENMOUTH, two rewards, first
  one shown), `campaignmap:replay` (replayable suffix).

### Neutral sites: lairs, shops, shrines (`src/game/sites.lua`, `src/game/quests.lua`)
Lairs (the original's lair manager): a neutral lair breeds one of its spawn groups every 70..150 s depending on
the lair, and the whole group again the moment it is hit once its 30 s reactivation cooldown has passed; a destroyed
lair leaves its boss at the lair. Group sizes grow with the elapsed game time (a sixth in the first two minutes,
double after an hour) and every creature gets the experience of its level plus 0..3 more; the arrival animation is
`EZ08` at the lair (the original's lair manager sets no home for the creatures, the neutral computer player sends them out, see "Neutral side's computer player"). The intervals, spawn groups, levels and bosses are
the original's lair table, kept with its quirks (the leader count is scaled from the troop count in the first three
time brackets, floored at 1 in the 8..10 minute bracket). Shops (the original's shop manager): two items and
healing / mana potions, an item rarity roll per shop (lesser / minor 79 %, greater 39 %, artifact 4 % while the map
has four shops or fewer, set 1 % while two or fewer), a hatred of 90..110 per side that scales the price, the price
paid out of all four resources at once (item value x10, potions 500, capped at 3000), a bought item gone for good,
nine potions of a kind the most, and no selling in a battle (selling is a campaign feature). Every hit a shop takes
raises the hatred of every shop for the attacker by 50 and of the shop hit by another 50, capped at 300 - the
original calls the shop manager's death notification (`FUN_00408360`) from the building's damage handling (its callers
are `FUN_0052bd10` and `FUN_0052b3e0`), so it happens on hits and on death; the shop manager's hit notification is never
called and its active flag is never read.

Quests (the original's quest code, 1.04 functions below): quest state belongs to a side, not to a building, so several sides can do the
same shrine's quest and a side that is busy gets nothing when it visits another shrine. A shrine picks a quest the
first time a hero visits it, only among the ones this side could actually finish (the legality test `FUN_0043dde0`), and keeps it
until it goes into its idle period; the dialog has the original's four modes (new quest, one already accepted here,
one finished here, a resource quest already paid for), the texts come from `<Lang>/Quest.cfg` with `~NAME~` replaced
by a name from the quest's naming set, and the quest giver's portrait is the 128x160 BMP of `Quest.xcr`. Rewards:
resources, a character named after the quest giver, armies named from a naming set, a power-up, or an item left on
the ground at the hero; the hero gets 20 XP (40 with the Order of the Grail) and the system voice says received /
completed / expired (15 / 16 / 21). A side's quest is dropped when its time limit passes or when the shrine it came
from is gone or changed owner, and the shrine then rests for its idle time.

Quest leftovers (checked in the 1.04 binary: select quest `FUN_0052edb0`, legality `FUN_0043dde0`, dialog `FUN_0056a150` with its
handlers `FUN_0056a840` / `FUN_0056abe0` / `FUN_0056b740`, completion `FUN_0043d560`, naming `FUN_00434e90`; `src/game/quests.lua`,
`src/screens/questdialog.lua`, test `src/tools/queststest.lua`):
- **Kind 4 (provide an answer)** and **kind 8 (build a type)** never occur in the shipped data: all 88 records of `Bmsh.dat` and `Bzma.dat`,
  used or not, are kinds 0..3, 5, 6, 7 and 9, and no `Quest.cfg` has an `_ANSW` key. They are implemented anyway, so a replaced
  `Quest.xcr` works. Kind 4: always legal (the legality switch has no case for it), no Accept button, an entry box instead
  (printable ASCII and the 20 accented letters the handler lists, 15 characters at most, Backspace, Escape closes, Enter tries it); the
  answer is the quest record's data string unless the quest's `[<set>_<nnn>_ANSW]` key in `Quest.cfg` replaces it (the select function reads it, so it
  can be localised), compared case-insensitively (`stricmp`); a wrong one closes the dialog and shows Game.txt 0327 for 3 s, a right
  one turns the dialog into the "complete" page (the `CMPL` text) whose OKAY pays the reward; the side never holds the quest and nothing
  counts for it. Kind 8: counts buildings the side finishes of the code, legal when the race's dependency data registers the code and it is
  not one of the four temples (compared as BTDR, BTCE, BTIN and BTEL, the tag `temple`).
- **Legality** corrections from `FUN_0043dde0`: a kill-armies quest needs 80 % of its count on the map (kill units of a type 90 %),
  a power-up reward the side already owns makes the quest illegal, and "own a building" counts only buildings of sides that are not allied.
- **The quest giver's name** is drawn once when the shrine picks the quest (the original fills `~NAME~` into every text, the title too,
  at that moment) and the character reward carries the same name; armies with named rewards get one fresh name each. Both names are saved.
- **Dialog texts**: the Accept label is Game.txt 0326 in both modes, the "your count" line Game.txt 0325 (the side's stock for a resource
  quest, the counted events otherwise).
- **Naming sets in other languages**: the naming routine `FUN_00434e90` remaps the set through a table of 16 `u16` at 0x608618
  whenever the language (`0x00a27d7a`, 0 = English, 1 French, 2 German, 3 Spanish, 4 Italian, 5 Korean, 6 Taiwanese, 7 Polish, 8 Russian, 9 Japanese; set by
  `FUN_00458fd0` from the command line or the `<Lang>\Credits.xml` probe) is not English: GenericEvil (1) and the two Barbarian sets (12, 13)
  become GenericEvil, Draconic (14) stays, every other set becomes Standard; an unreadable name file gives "Sirian". openwbc3 applies it
  with `config.language` (`quests.nameSetIndex`), so a German install names the hero's retinue, quest givers and rewards from
  Standard.nam, as the original does.
- **Quest dialog** (`src/screens/questdialog.lua`; hit areas, modes and keys checked in the 1.04 binary, the text layout not
  traced there yet: constructor `FUN_0056a150` with the 430x417 size and the 800x600 position (185, 24), mouse down /
  move / up `FUN_0056a6f0` / `FUN_0056a480` / `FUN_0056a840`, keys `FUN_0056abe0`): the background is the sprite `EMDQ`, the 30x30
  cancel button `EMDC` at (79, 345) and the 180x36 button `EMDE` at (156, 341) (both sheets of cells normal / hover / pressed), the
  portrait at (78, 75), the title (font 24) centred on x 213, y 28, up to 13 text rows (font 19; 142 wide at x 217 for rows 0..8,
  290 wide at x 70 for rows 9..12, row 9 back at x 217 when narrow; y 72 + 20 * row), the progress line (font 19) centred on x 216,
  y 317 and the Accept text (Game.txt 0326, font 5) 12 px down on the button. There is no OKAY / Not now / Close text and no reward
  line: the original lists none (the completion `FUN_0043d560` shows only the "another hero completed your quest" text of the
  loser, and the acceptance `FUN_0043d350` only plays the system voice, not at all for a quest paid at once), so the old English strings and the
  "Quest accepted" / "Quest completed" messages are gone. Behaviour: a new or instant quest has Accept (click on the button or
  Enter); a quest already accepted here has only the cancel button; a finished one has no button, a click anywhere, the cancel
  button or Enter hands it in, Escape only closes (the 1.04 binary does not complete on
  Escape). A kind 4 quest's entry box is the outline (220, 180, 80) at the button's place, its hint (Game.txt 0358, font 2) under it on
  a 50 % black strip (the translucent fill `FUN_00476400` at level 8 is `(src + dst) / 2`). Not like the original, see `docs/missing.md` "Quest
  dialog leftovers": it is modal; it closes itself when the hero dies or the shrine loses its quest.
- **Quests as commands** (`quests.command`, `commands.lua` `{ t = "quest", op = "accept"|"complete", bid, hero, answer? }`): the dialog
  only issues the command through `S:issue` and closes, so a network game carries it by lockstep like every other order. The
  simulation does the rest: the visit event (`world:event("visit")`, run by every peer when a hero reaches the site) makes the shrine
  pick its quest and the quest giver's name (`quests.offer`, human sides only; the dialog's `quests.visit` is read only), accept /
  complete hand out the reward and the naming draws at the command's tick, where `math.random` is the per-tick seeded stream.
  The command checks that the hero is the side's own, alive and within 3 cells of the shrine, that the side holds no other quest
  (accept), and for a kind 4 quest it compares the typed answer again (the dialog's right-answer page is only a preview). A resource
  quest the side can already pay is finished by the accept command itself (the dialog's "instant" mode). Accepting plays the
  received voice from a `questaccepted` event (not for a quest paid at once, as in the original) instead of from the dialog. `world:hash` now includes a shrine's picked
  quest and a side's quest id and count. The quest key (Q) opens the page of the side's own quest read only, from anywhere (the
  old code could pick and accept a free shrine's quest from afar; which page the original's key shows was not traced). The original's
  multiplayer games have no shrines at all (`mphost.lua` forces quests off, as the original's lobby does), so this only matters for
  the sync of the code path; verified with `--selftest` (`quest command: ...`, two peers with the same seeded stream pick the same
  quest and giver) and a two-instance loopback game (no desync).

### Random maps (`src/game/randommap.lua`, `formats/gom.lua`, `ui/randompanel.lua`; checked in the 1.04 binary where noted)
- **Entry**: "Random Map" (Game.txt 0287) is the first entry of the skirmish / host list whatever the size and player filters
  say (the scenario list's random map entry) and the default pick; six sides are on offer. While it is
  picked `PNL_SS_RANDOMMAP` is drawn at (30, 22) over the minimap (`FUN_004e0590` / `FUN_004e4000` open it with the handler
  `0x004e1390`): five drop-downs - size (texts 180: 64 /
  128 / 192 / 256), terrain (216 + 250: Grasslands, Plains, Highlands, Desert, Lava, Outlands, Caverns, Snow, Wetlands, Jungle),
  utilities (345, on the button named `BUTT_RM_ISLANDS`), animals (182) and resources (183), each with "Random" (83.0) last. The
  defaults without a stored choice are the registry reader's (`FUN_00450970`: large, first terrain, no utilities, a few
  animals, medium resources); the last choice is kept in `openwbc3.ini [randommap]`. "I am the greatest" forces a few animals,
  3 utilities, X-large, medium resources and any terrain and greys the buttons (the values are set by `FUN_004ea050`); a joined player
  sees the host's values greyed. Long button texts are cut to the 128 px button (own choice; the original's German texts overflow).
- **Seed and settings** are the whole map: `randommap.build{seed, size, terrain, temples, critters, resources, quests, victory,
  sides}` gives the same scenario on every peer, so the host sends the description (`random` in the start message; the lobby
  message carries the five values) and a saved game stores it (`random` in the save) instead of the map. "Random" entries
  resolve in the original's order (temples, terrain, size, animals, resources) from the seed (the setup copy into the game data, `FUN_004de740`).
- **Generator** (verified in the binary, `FUN_00582310`): the original's own random number generator (see `docs/formats.md`;
  only 16 bits of the seed matter, as in the original); `ceil(size / 30)` pieces per row; the start piece is one of 2..6 (one
  of 7..26 for lava, caverns and wetlands, whose low pieces block the map), later pieces must match the right edge of their left
  and the bottom edge of their upper neighbour, are never piece 0 (never a piece below 7 in those three sets) in the first row
  and column, a tried-pieces list per spot and a restart when stuck; tiles come from the part-0 slots; features are moved by the
  piece's position and dropped by the original's test `x / 10 + offset < size` (pixels against cells: on a 128 map most features
  right of cell ~100 and below row ~100 are missing; the binary does the same); the four corners (4 cells in) must be joined or
  the map is made again.
- **Finishing** (`FUN_00583960`; the binary was checked only for the pieces above, the rest is not traced in it yet): start
  locations in side order by `FUN_00419440` (250 scored candidates, corners favoured 4 times in 5, away from the sides placed before; the
  conditions loosen after 250 / 500 tries); around each start the 2x2 feature tiles whose edge types all agree in the 5x5 tiles from
  (start - 30) become plain ground (`T?X0`, caverns use the rock and ruins the jungle set) and the features within 20 cells are
  removed; the event list is the standard victory event only. **No keep is placed**, **no
  chests are made** and the starting force is the skirmish's own (hero, two builders, army).
  Then three race towers per side (not for Pitched Battle or `noStartingTowers`), the mines (`FUN_00418df0`: four level-3
  mines of each kind near every start, then a shuffled grid of `players * (level + 1)` mines per kind scaled by the map size, levels
  3 / 3 / 2 / 2 / 1 of 5), shrines and mausoleums when quests are on, `utilities` temples / lairs / shops from the 17 entry list, and
  critters (4 / 9 / 16 / 24 plus 1d5-3, times 1.5 / 2 / 2.5 on 128 / 192 / 256 maps, the six-entry table per terrain, a spot with fewer
  than two water cells 8 cells away, 20 tries).
- **Building placement** (the 1.04 binary's `FUN_00435320`, called
  from `FUN_004183b0` towers, `FUN_00418df0` mines, `FUN_00418ce0` shrines / mausoleums, `FUN_00418ae0` temples, lairs and shops,
  which `FUN_00583960` (the finish) runs on the host after the start spots; every test below is the binary's):
  `randommap.lua` `bestPlacement`. A block of (shape width + 5) x (shape height + 5) cells is wanted (+ 3 for the 18 tower and
  mortar codes `BWT?` / `BWMO`): three passes mark each cell with "the run of that many cells ending here" for equal terrain
  height (1), none of water / lava / marsh / ford / void (terrain 3, 5, 6, 7, 9) (2), and not blocked for land units, move cost
  not 0 and not reserved for building (4); a column walk then wants that many rows of equal height with all three bits and takes
  the block's cell (start + (n - 1) / 2 of the run in x and y) with the least cost = Chebyshev distance to the target + Chebyshev
  distance to the search rectangle's centre, the first in column-then-row order on a tie. Search rectangles: towers 24x24 around
  the target, mines near a start 24x24, grid mines 30x30, shrines / temples 40x40; the temples also refuse a cell past the map
  size, as in the binary. Versus the earlier own rule ("nearest cell with a margin of 1 / 2 cells, reachable from the corners"): the
  block replaces the margin, reachability is no longer asked (a mine can stand on an island, as in the original), and a tall
  building's upper rows lie in the block while the lower ones may reach past it (the building's cell is its top middle, the block's
  centre is its middle). Over 40 seeds (every terrain / size / side count) no map stayed the same (the placements also change the
  stream: failed tries draw dice); the buildings fell from 2166 to 2053, mostly shrines and mausoleums (81 to 53, they need the
  largest block) and level 0 / 1 mines. The same seed still gives the same map on every peer.
- **Generating screen** (`PNL_RM_GENWORLD`, `randompanel.showGenerating`): the random map entry `FUN_00582180` opens it for a game (not for the
  editor) before the map is made and the load code closes it before the army setup / the battle: the full-screen picture
  (bitmap 483) with the anvil animation (bitmap 29) and the texts 289.0 / 289.1 centred (`STR_LARGE750`, `STR_MEDIUMDLG_300`). The
  original only redraws it from the generator's housekeeping ticks. openwbc3 draws and presents one frame before the generator
  runs (host start, and a joining peer building the map from the host's seed); the animation stays on its first picture and the
  panel is not shown for a loaded game (the original saves the map, openwbc3 rebuilds it).
- **Own choices** (not readable in the original): one random stream for everything (the original's finishing steps use the game's dice routine,
  synchronised by host messages); the 6x6 cells around each start are kept free of buildings (they stand in for the original's
  "reserved for building" test, which nothing sets while a map is made; the hero and builders are put on the start cell);
  start locations and critters must be in the corner-connected area; the flood fill uses 8 directions; loop guards instead of the
  original's endless loops; the starting towers get no hero-level bonus (`FUN_00418700`); lobby map line shows the stub's size.
- Dev: `--scenario random:<seed>[:terrain=3,size=1,temples=2,critters=2,resources=1,sides=4]` (also for `--sim`, values are the
  drop-down indices; side i plays race i), `--random-map <seed> [--rm key=value,...]`, `--show skirmish --at 1 "S:selectIndex(1)"`.
- Checks: `--selftest` (all 647 GOMs read, set sizes, the random generator, three maps with invariants, same seed = same map and
  world hash), `--selftest --lua tools/dev/randomseeds.lua 300` (every terrain, size and side count: corners joined, starts free,
  reachable and uncrowded, towers present; 0 problems), `--selftest --sim random:12:sides=4,size=1`, `--sim saveload random:5:sides=3,size=0`,
  the two-instance loopback run (both peers build the same map, no desync), screenshots of every terrain.

## Screens and menus
Done: the options screen after the original's (`PNL_GAMEOPTIONS`: Gameplay / Graphics / Sound tabs of drop-down
buttons, Okay / Cancel, Credits; the old slider dialog is gone), the victory / defeat screen (`PNL_VICTORYDEFEAT_NEW`:
hero name, Victory / Defeat, troops and buildings counters, levels gained, advanced results), screen help
(`ScreenHelp.txt`, shown once per screen, F1 again), multiplayer chat (Enter = all, Ctrl+Enter = allies,
Shift+Enter = enemies; beside the lockstep turns, `--nettest` covers it).

Options screen: these are stored in `openwbc3.ini` and used by the game: popup help level (None / Some / All,
battle tooltips), scroll rate, game speed (start speed of a battle = option + 1 of the five timer steps; the 1.04
binary's first-run options block `FUN_00453280` gives the option 2, so the default is x1; earlier text here said x1.5,
which was wrong), group move (slowest unit or as fast as possible, Ctrl does the other), spacebar
pauses / visits the last message, left / right click interface (left: a left click on the ground or an enemy
orders the selection, right click deselects), system voice (female `SystemF<n>.wav` is the original's default),
tips, SFX / music volume, unit speech, the music set, mouse click effects, resolution (window size), plus openwbc3's own full
screen, vsync and interface scale buttons. Unit speech frequency "Sometimes" is 2 in 5 for select / order lines,
as in the sound request `FUN_0050be80`. The original's graphics / audio / main options screens (`PNL_OPTIONS_GRAPHICS`,
`_AUDIO`, `PNL_MAIN_OPTIONS`) are older prototypes that the game does not open (the retail options screen is
`PNL_GAMEOPTIONS`); the in-battle options dialog is replaced by the same screen.

Left-click interface (the 1.04 map action `0x00423050`, right button without a command mode): right click on an own
building whose race "build" column of Building.cfg is set and that is not running its keep conversion (`FUN_0052e730`,
`FUN_0052fc00` == 0) selects it and opens its production menu (action 0x30); with an own building selected whose race
"armies" column is set (`FUN_0052e710`) it sets the rally point (action 0xc), snapped onto an own resource building under the
cursor; an unfinished building does not open the menu here (the original skips it only while a unit with the Build skill is
selected and the site has no builder; what the menu does for an unfinished building was not traced); a left click on one of our own towers / mines with units selected gives the garrison / mine order.
Resume-building is not needed as openwbc3 never leaves an abandoned construction site.

Message log: it keeps 8 map positions only, no texts (Space / Page Up cycle the view back through them, 2 s
tolerance); openwbc3 logs the place of every info box event for the player, not only attacks.

Credits: the campaign has an end condition - once all its one-off battle missions are done the menu offers to
finish, giving a reward and rolling the credits back to the main menu. The original resigns on a count of
provinces still to conquer, which openwbc3 has no model for, so the trigger and the reward are openwbc3's own
choice.

Screen help: the new-hero screen, the army-points screen (the army setup screen now carries that help - its texts
describe buying troops for the battle), the journal hint after a campaign battle, the replayable-battle note on a
replayable briefing and the item stash help are all triggered as in the original.

The campaign's own "Options" dialog (difficulty, map scroll speed, resolution, menu sounds, reset): see "Campaign: extra army points, mercenary selection, options".

Standard mouse cursors: every screen but the battle view draws the original's pointer hand instead of the system
cursor (the menu cursor routine `FUN_00456a30`: POINTER over an active UI object, POINTERDOWN while a press that
began on one is held (button-down flag `DAT_00a27dad`), POINTERUP elsewhere). Its enable flag `DAT_0060c3ec` is on everywhere
except the battle (the setup screen's start switches it off, `FUN_00456a20(0)` at 0x004e6ad0), so `core/screens.lua` draws it over
the kit hit boxes of a hand-made screen or the XCI panel drawn last, and the battle view, the editor and the
campaign map say so with `ownCursor`. The in-battle dialogs use their own cursor routine instead: POINTER over an
active control, POINTERUP elsewhere, no POINTERDOWN (trade dialog 0x00572dd0, production dialog `FUN_00568e30`).

## Formations
`src/game/formation.lua` follows the original's formation placement (1.04 binary `FUN_00530f80`, called from the
group move `FUN_00530870`) and its formation-change test
(`FUN_0040c770`); the format of the table is in `docs/formats.md` ("Formation slot tables").
- The slots are the compiled table at VA 0x005FBC9C, extracted by `tools/dev/genformations.lua` into
  `game/src/game/formationdata.lua` (8 formations x group sizes 1..32, the table's row 32 - n holds the n slots).
- The units are ranked by range (longest first), then by combat (lowest first), equal ones in selection order, and take
  the slots in the table's order (archers first: the rear of a block, the middle of the ring).
- Eight facings (0 TOP, 1 TOPLEFT, 2 LEFT, 3 BOTTOMLEFT, 4 BOTTOM, 5 BOTTOMRIGHT, 6 RIGHT, 7 TOPRIGHT): the table is in
  the frame of BOTTOM; RIGHT / TOP / LEFT swap and negate the offsets, the diagonals combine them halved with an
  arithmetic shift. The slots are centred on the order's target cell.
- The facing changes only for a target 5 or more cells from the group's centre (whole cells), by the quadrant of the target
  and a 2 : 1 ratio between straight and diagonal; a new army starts with the Defensive Ring (formation 1, "ranged middle")
  facing TOP (army initialisation `FUN_00519ae0`: type byte 1, direction byte 0 at +0x104 / +0x105).
- The type and the direction are stored per army (unit), the bytes at +0x104 / +0x105 of the army record (setters
  `FUN_00523100` / `FUN_00523110`), not per selection: `u.formationType` / `u.formationDir` in openwbc3 (nil = the
  defaults), kept in saved games (`fmType` / `fmDir` of the unit record; older saves load with the defaults).
  Verified in the binary (1.04):
  - A group move (`FUN_00530870`) reads type and direction from the **group leader** only: `FUN_00531400`
    (the leader choice) walks the selection and takes the army with the highest short at +0x9e, strictly greater so the first
    of equal ones, starting from -1 (that field is the army's damage: damage, damage type and range are at +0x9e / +0xa0 /
    +0xa2, and `FUN_00530f80` ranks by the range at +0xa2 and the combat at +0x92). openwbc3 uses `stats(true).damage`.
  - It averages the positions of the selected armies (integer division) as the group's centre, calls
    `FUN_0040c770` (the formation-change test) with target - centre and the leader's direction; only when that changes the
    direction `FUN_00532900` writes the leader's **type and the new direction to every selected army**. When the target is
    near, nothing is written and every army keeps its own values.
  - The formation panel buttons (code at `0x004ce8d0`) set the formation of the leader alone; the rotate
    keys `[` (0x5b, `FUN_004ce9f0`: direction + 1 mod 8, anticlockwise) and `]` (0x5d, `FUN_004ce960`: direction - 1) step
    the leader's direction alone, only when the selection is a group of 2 or more armies (key dispatcher `FUN_00427fb0`);
    the rotate buttons of the panel are the same functions. All three then send the group to the **leader's own cell** with the
    group move (`FUN_00530870(x, y, 0, 0, 1, 1)`: no slowest-pace, queue status 1 = insert, ignore threats), so the
    5-cell check above applies to them too, and the leader's change reaches the others only through that.
  - `F` ("Formations", the default shortcut of `KeyMap.txt`) only presses the Formations button (the way the hot keys
    press a panel button by its icon, `FUN_004d2290`; its case in the binary's key dispatcher was not traced): it opens the panel when the
    selection has one. The `T` key that cycled the formation was openwbc3's invention and is gone.
- Because the commands carry the resulting cells, the state is local to the issuing player (no lockstep or hash
  involvement), and it is only simulation-relevant through the cells of the move command.
- openwbc3's own choices: the original selects at most 32 armies, a larger group fills the table for 32 and puts each
  further batch of 32 two cells behind the previous one; the pop-up "Formation: ..." notice of the old `T` / panel code is
  gone (the original shows none); a single unit also records the facing (its slot is (0, 0) in every formation, verified
  in the table). Not traced: whether the AI or other code paths (e.g. group creation by Ctrl+number, new units of a
  production building) touch the two bytes besides the army constructor, the setters above and `FUN_00532900`; the only
  writers found by cross-reference are those.

## Hot keys
Verified in the 1.04 binary's key dispatcher (`FUN_00427fb0`: the shortcut table `DAT_0074c434` is read from `KeyMap.txt`
by `FUN_00426060`, 61 entries, and a `switch (index - 10)` runs the action; the order of `keymap.NAMES` is the table's).
- **R ("Show Radius", index 34, case 0x18)** toggles the radius display: `FUN_00532940` collects the local side's heroes,
  `FUN_0049a6c0` takes the hero's command (`FUN_005267b0(1)`) capped at 0x13 = 19 (nothing for a dead or hidden one) as
  the radius. openwbc3 draws what the radius overlay `FUN_00499e60` draws (the shape and colours were not re-checked in
  the 1.04 binary): an ellipse of r * 32 by r * 24
  pixels round the hero as an arc of 200 degrees that circles round, fading from white to blue (5-bit 31,31,31 to
  1,12,31). The circling speed is openwbc3's own choice (one turn in 1.5 s; the original advances 15 degrees per drawn
  frame). It is the command radius now, not the conversion radius, and only heroes get one (generals do not). The state
  is saved with the game (`radius` in the save; the original keeps it in its saved options too).
- **Alt+H ("Help Popups", index 42, case 0x20)**: the popup help level goes (level + 1) % 3, stored like the options
  screen's setting (`gameopts` `helplevel`), and Game.txt 0067 / 0068 / 0069 (0067 + level, "Popup Help: Off /
  On (Limited) / On (Full)") is shown for 2 s (a notice at the top left, as the speed keys do; the original's centred
  panel is not reproduced).
- **Ctrl+N ("Network Stat's", index 59, case 0x31)**: only with no dialog open (`src/ui/netstats.lua`). The dialog is
  400 pixels wide and players * 25 + 45 high, centred (the constructor `FUN_00566760` sets exactly those); headings
  "Reliability" / "Ping" (Game.txt 0405 / 0406), name, shield, `%3.2f %%`, `%ld ms` and a colour bar per player as the
  dialog's layout intends. The 1.04 draw routine (reached from the vtable at 0x005EAA1C, code at 0x00566A60) formats the constants
  1000 ms and 100.00 % for every player, so the original's dialog is a stub (bar 40 pixels, colour 255,200,0). openwbc3
  shows real figures instead (its own choice): the smoothed round trip time of the UDP peer (`Peer:stats()` in
  `udp.lua`) and the share of reliable packets not sent again, refreshed once a second; in a single player game the one
  local row (0 ms, 100.00 %). The figures are every player's link to the host (the lockstep hub): the host measures
  each client and sends the table to all of them once a second as a `netstats` message (`Session:sendStats` in
  `lockstep.lua`; own choice, DirectPlay's per-player latency has no equivalent here), so every machine shows every
  player; a dropped player shows "-". The table is outside the turns and the world, so it cannot change `world:hash` or
  the lockstep; before the first table arrives a client shows its own link to the host. The 1.04 draw routine was re-checked
  (the loop at 0x00566A60 pushes the integer 1000 for `%ld ms` and the double 100.0 for `%3.2f %%`, the bar is 40
  pixels). The bar
  value table (5..65, penalties for loss and ping) can be checked in 1.04 only at its one constant
  case (not traced in the 1.04 binary yet otherwise). Esc or a click closes the dialog.
- **C ("Current Radius") and Ctrl+V ("Lock view to item")** do nothing in the original: the dispatcher has no case for
  them (`docs/todo/not-in-original.md`), and openwbc3 does nothing either.
- **Special-ability keys** (`src/game/abilitykeys.lua`, the `key*` fields of `content/base/abilities.lua`): `FUN_00426060`
  reads the 48 lines after the 61 shortcuts into a second table (`DAT_0074c52c`, defaults in `FUN_00425bf0`; the shipped
  English file has `H` for Goblin Horde where the default is `G`). `FUN_00427fb0` gives every key to `FUN_00427f70` before
  any other shortcut: it runs the case of `FUN_00426350` (line n = case n) of every ability key that matches, in table
  order, until one reports done; a key that is not done goes on to the normal shortcuts (Shift+H: Healing, Goblin Horde,
  then Add / Remove Hero). The unit ability buttons call the same cases (`0x004cfa80` ... push the case number).
  - Unit cases pick one caster (`FUN_00427cf0`): per caster type in order, the first selected army of the type with the
    mana (`FUN_0051b340`: mana >= cost and a mana pool), else the player's first one of that type inside the cells the
    screen shows (column by column from the left, each top down). Entangle (case 0xc) looks for a selected Treant first,
    then an Ancient Treant, then a Treant anywhere. Done once the caster passes the army limit (summons) and, for Feast
    (case 0x19), the Feast power-up; Earthpower's key (0x18) asks neither power-up nor race.
  - Invisibility (case 0xd) first casts with every selected Black Guard, Chameleon with Blending or ASWM with the mana
    (ASWM: a code no button offers and no army has); when one did, the key is not done. Else one Black Guard / ASWM as above.
  - Drunkenness (0xf) presses the Drunkenness button (`FUN_004cf7d0`), not done; Star of Sartek (0x10) has no case.
  - Building cases (Holy Word 0x13 only a BPCA, not the Tower of the Moon, Elcor's Balm 0x14, Chaos Plague 0x22, Couatl's Wrath 0x24,
    Famine 0x2a, Sword of Sirian 0x2e) need the power-up and look for the building in the selection, else anywhere on the
    map (`FUN_00427e30` with its whole-map flag), ask the button's price (else "need more ...") but have no button timer
    and no target check, and are never done. **Quirk of the original, reproduced:** Chaos Plague, Couatl's Wrath and Sword
    of Sirian are cast from the key by calling their casts directly (`FUN_005771f0` / `FUN_0057a1e0` / `FUN_0057a3b0`),
    without the resource message, so the key casts them for free once the price is there; Holy Word (`FUN_004d1ef0`),
    Elcor's Balm (`FUN_004d2030`) and Famine pay. The key does not ask whether the building is finished.
  - The picks happen on the pressing player's machine and go out as `army` / `ability` commands with `key = true` and the
    chosen ids, so network games stay deterministic. Unlike the binary's selection passes, which do not look at the owner,
    openwbc3 only picks the player's own armies and buildings (a command acts for its own side only).
  - The troops' spell buttons of the control panel go through the same cases (`hud.lua` -> `S:abilityCase`; the 1.04
    actions `0x004cf9d0` .. `0x004cfc20` push the case and call `FUN_00426350`), so a press picks its caster the same way,
    on-screen fallback and Invisibility's loop included. Whether a button is shown or greyed stays the button builder's
    (`FUN_004d3200`). Feast and Scavenge keep their own actions (`0x004cfc30` / `0x004cfc60`: the first selected army),
    and the building buttons are their own handlers (`0x004d1a00` ...), with timer, target check and payment.

## Presentation
Construction sites show the building's three `Z` sheet stages at 0 %, 34 % and 67 % of the build time (buildings without a
`Z` sheet fade in instead); a destroyed building stays as a wreck - the first construction stage, the abandoned-mine sprite
for a mine, the base's first stage for an upgrade level (openwbc3's fallback, those codes ship no `Z` sheet) - and fades out
over the last quarter of its stay before it is removed from the world altogether. Rubble type 0 (`.BUI` offset 150; walls, temples, flags)
leaves nothing behind; the length of the stay is openwbc3's own.

Fires on damaged buildings: three fires at 3/4, 1/2, 1/4 of the hits at the `.BUI` fire points, effects EF01..EF03
(the animation speed is openwbc3's own); a burning building loops the fire sound.

Cursors: patrol and guard modes, the search cursor (`RUIN`: hero over a shrine, lair or shop), the "no orders
while something of another side is selected" arrow, the FIGHT cursor over anything attackable (including the
neutral side) and RESUMEBUILDING over own mines, following the battle cursor choice `FUN_00420390` (its details
were not re-checked in the 1.04 binary). Its mismatch tests answer SELECT when the selected units cannot attack what is under the pointer:
attacking ground is `attackType & 1` and attacking air is `attackType >= 2` (attack types 0 none / 1 ground / 2 air /
3 ground and air), and a flyer is `moveType` 1 (army flag 0x200000, bit 21),
so a ground-only unit over a flying one and a flyer over anything else get SELECT instead of FIGHT. RESUMEBUILDING
also covers a garrison with room (the garrison test `FUN_0051c240`) and a minotaur over one of the original's
critters (the critter test `FUN_00528280`: sheep, cow, goose, penguin, camel, soul, turtle, seal), which
issues an attack order and heals the attacker to `min(maxHits, hits + 20)` when the critter
dies with "Eating.wav" (`FUN_005210b0`). The transport branch of the cursor choice is dead in the original
(its transport and ship flags are 0) and the abandoned-construction one needs nothing
because openwbc3 never leaves an abandoned site.

Campaign map cursors: the standard pointer glove. The map is a full-screen button, so it shows `POINTER` (regular glove) and
`POINTERDOWN` while pressed; `POINTERUP` only over dead areas of dialogs and the menu (the menu cursor routine `FUN_00456a30`).
The `ARROWSWORD` / `ARROWBOOK` branch of the older province-based campaign screen needs the province files (`Etheria.prv`,
read by `FUN_00587c70`), which are not in the GOG install, and is not used.

## Display and sound options
The options of the options screen (`core/gameopts.lua`) and what each one switches. Everything here is presentation: it
lives in `gfx/battlefx.lua` (one object per battle that the battle screen drives with `update` / `drawGround` /
`drawOver` and one world listener), reads the simulation and its events, never changes simulation state and never calls
`math.random`, so network peers with different options stay in step. `tools/fxtest.lua` checks the rules below in
`--selftest`. The behaviour is the original's; details are checked in the 1.04 binary where noted, the rest was not
re-checked there.
- **Shadows / lighting effects** (the sprite blitter `FUN_00487f20`): with shadows off the sheet palette ranges whose effect is
  "shadow" (1) render transparent (11), with lighting off the coloured-light ranges (effects 2..7) do; `gfx/anims.lua`
  renders and caches the images per setting and flushes them when an option changes (`gameopts.version`). Footprints and
  the grass-level shadow sprites are shadow-effect sheets, so they vanish with the option, as in the original.
- **Combat sounds** (the attack sound `FUN_0050d300`, the missile impact `FUN_005427e0`): the attack and missile-impact sounds
  (`Unit:attackSound`, `Unit.missileImpactSound`) are silent with the option off; death screams, voices and spell
  sounds are not gated.
- **Footsteps** (a move order requests the move sound; the per-tick sound update `FUN_0050ea10` keeps the loops):
  `audio/footsteps.lua` loops Walk / Stomp / Trot / ...
  `.wav` (the army type's move sound, heroes walk) - at most three loops, one per sound type from the nearest marching
  army within 25 cells that the player sees (an army with a plain move order, not a critter), volume and pan by distance.
  Not available: the ford / marsh variants (`SplashMove.wav` / `MarshMove.wav` are not in the install).
- **Environment sounds**: `audio/ambience.lua` loops `SoundFX/Terrain/Plains.wav` (Desert / Arctic by terrain type of a
  random map, `world.opts.terrainType`; plains for every other map as the original's zeroed options give) and
  `Night.wav` at night. **Features** (1.04: the three sound loader calls at 0x50e2bb /
  0x50e348 / 0x50e39a): a feature type whose `.FEA` record has the ambient sound flag plays `<code>Ambient.wav` of `SoundFX.xcr`
  (`FUN_00511c10`, sound kind 4) as a loop while within 25 cells of the view centre and seen, volume / pan by distance; the
  flag is the byte at offset 60 of the 68-byte record (`FUN_0041b730` copies it to `0x704618 + 68 n`), see `docs/formats.md`.
  The retail data never sets it (0 of 121 feature types, none of the 115 scenarios uses another), the files `FI00`..`FI05` and
  `FML0Ambient.wav` belong to types the install lacks, so nothing is audible without extra data; the loops are there for
  archives that add such types (`--selftest` "feature ambience" checks the shipped types). The per-feature `delay` attribute of
  the feature XML (a one-shot every `delay` ms, all 0 in the shipped files) is not read.
- **Scroll rate, volume levels, music sets** (options screen, all verified in the 1.04 binary): the scroll rate is the number
  of map cells (32 x 24 px) the view moves per event, an event being a 25 ms tick of the main loop at the screen edge
  (`timeSetEvent(25, ..)` in `FUN_00457190`, `FUN_0041e020` via `FUN_00458bb0`) or a 50 ms window-timer event (`FUN_0041e320`
  case 9, edge and arrow keys; the keys only there), 1 while a wall is dragged: 60 x rate cells a second at the edge, 20 x rate for
  the keys; `battle.lua` scrolls continuously by that (the old 900 px/s x 40..150 % numbers were openwbc3's own). Re-checked because
  it looks too fast (rate 3 = 180 cells = 5,760 px a second at the edge, 800 px in 0.14 s): the unit is cells for certain
  (`FUN_00490880(0)` returns the view's left cell, `* 0x20` only for the pixel variants; `FUN_004907d0` stores the new left / top cell,
  clamped to the map size minus the view size in cells; `FUN_004939e0` copies it to the current view at once, no slide), the rate
  is added unscaled, and the 25 ms tick handler is cheap (it only moves the view and steps the animation timers
  `FUN_004958c0` / `FUN_004872f0`; drawing is the idle loop `FUN_00458c70`), so a slow frame rate does not slow it down. The edge
  tick `FUN_0041e020` and the timer case of `FUN_0041e320` make the
  40 + 20 events a second. The original therefore really jumps up to 60 x rate cells a second; the scroll rate is the only
  brake (very slow = 60 cells/s), and the original's own view is 25 x 25 cells (800 x 600), so a larger openwbc3 window crosses
  its own, wider view more slowly. Rates 1..5 are
  the drop-down index + 1 (setter 0x0040fd60), the first-run rate is 3. Sound effects levels set the overall effects volume to 0 / 30 / 60 /
  90 / 120 (0x0040fea0) on Miles' 0..127 scale, so full is 120 / 127 = 94.5 % (positional sounds: `(125 - 5 d) x n / 127`), the
  music level n sets the music sample to `n << 5` (`FUN_00510330`: 0 / 32 / 64 / 96 / 128, 128 taken as the clamped maximum), first-run
  levels Full and High (3). `[audio] effects` / `music` keep the percentages, a scroll rate is `[options] scrollrate`. The
  **music set** drop-down (the tenth Sound button) lists the `Music/*.ini` files with a `[SOUNDTRACK] Title` (`FUN_00413c00`: at most
  20 files, newest list entry first) and keeps the chosen file as `[audio] musicset` (`MusicINIFile`); a missing file falls
  back to `Battlecry3.ini` (`FUN_00510570`); `Tracks` (default 5), `AmbientN` and `Intro` are read from it, and Okay with a changed
  set restarts the menu theme (the options save `FUN_00414160` compares the set names; the restart itself not re-checked in 1.04). **Victory / Defeat themes** (verified in the
  1.04 binary): the victory screen's builder (`FUN_00454560`, called from the battle teardown `FUN_0041c520(won, 1, 0)`) calls the
  music start `FUN_005101d0(2)` when the battle was won and `(3)` otherwise (0 = intro, 1 = a random ambient track other than the last
  one, 2 = the set's `Victory` file, 3 = its `Defeat` file, both defaulting to `\WBC3_Theme.mp3` like `Intro`, `FUN_00510710`); it
  does nothing at music volume 0 and replaces whatever plays. The sample is started without a loop count (`FUN_00510330`), so the
  theme plays once; the idle step `FUN_00510520` (from the main loop `FUN_00458bb0`) looks every 5 s (`timeGetTime`) whether a track
  is still playing and, if not and the music was not stopped on purpose, starts an ambient track. openwbc3: `music.play("victory" |
  "defeat")` from the victory screen's `enter` (not the `--show victory` sample), and the ambient follow-up through the same 5 s
  check for every ended track (`music.update`). The install's set names `WBC3_Theme.mp3` for both, so it is the menu theme that plays.
  The install has the one set. **EAX / 3D provider** (`PNL_GAMEOPTIONS` slot 7, `3DProvider` and the
  Miles `Msseax*.m3d` providers): the original only enables it when a provider reports EAX hardware support
  (`FUN_00411430`), otherwise the button shows "N/A" greyed - which is what openwbc3 always shows. What EAX is there: Creative's
  environment reverb on Miles' 3D samples. The game picks a room style (`FUN_004c9c10` in 1.04): plain 19, stone room =
  alley 14, cave = generic 0, stone corridor = hallway 12, forest = living room 4, mountains = parking lot 20, quarry = stone room 5,
  underwater 22 (EAX environment numbers), per map from the dominant terrain / random-map type, the menus and the lobby using the
  stone room / corridor. It is a listener-wide reverb of the Miles **3D provider**, and it only reaches samples allocated through
  that provider (`AIL_allocate_3D_sample_handle`, the 3D branch `FUN_004ca480` of the channel init, flag = its 4th argument). Every
  call of that init in game code passes 0 for the flag (read at the call sites of `FUN_0052c2c9`, `FUN_0053ff4a`, `FUN_0050e2d9`,
  `FUN_0050e3b4`, the heartbeat `FUN_0050e690`: `(id, 0x8c, 0, 1)`, and a sample of the sound loaders; none of
  them passes 1), so the game plays everything as plain
  2D samples with pan and volume, and the EAX room is set on a provider no sample uses. The option therefore changes nothing you
  can hear: no equalizer, no filter on the 2D mix, just a dummy listener setting. (Not a volume effect: the writes of `EAX effect
  volume` in the binary are all 0.0, but a room write restores the preset's levels, EAX 2 header "sets all listener properties",
  and `NONE` is how the game mutes it; that is not why it is silent.) Not checked: every one of the ~40 call sites, and no EAX
  hardware was available to listen. Nothing to mimic: openwbc3's greyed "N/A" EAX entry is the faithful state, and a reverb on
  the 2D mix would be an openwbc3 addition.
- **Victory / defeat build-up** (`FUN_00513e00` with `Victory.wav` / `FUN_00513c80` with `Defeat.wav`): the fanfare plays first, the announcer and the result
  banner follow when it has ended; with the option off (or the effects volume at 0) there is no fanfare and the result
  comes at once. **Hero heartbeat** (`FUN_0050e690`, `audio/heartbeat.lua`): ten steps at max hits / 11 x n hits;
  fast heartbeat for the five lowest, delay 300 + 70 n ms, volume 125 - 10 n of 127, five seconds then fading.
- **Gamma** (`ui/gamma.lua`, verified in the 1.04 binary `FUN_00468cf0`): each channel scaled by
  (0xffff - 0x1fff x g) / 0xffff for g = 0..3 (identity at 0); g = 4 is 0x3fff + 3/4 of the identity (lifted blacks). Drawn
  over the finished frame (`love.draw`), so menus are affected too.
- **Ambient animation and idle fidgets** (`gfx/fidget.lua`, the army's fidget roll read from the bytes at 0x00539a90 of the 1.04
  binary, it is no Ghidra function): with the option off buildings and features keep their first stand frame instead of
  cycling (the animation steps, e.g. the feature's `FUN_0053d250`, advance them only with the option on) and armies do not fidget. A
  standing army (stand animation, no sequence running) rolls d100: up to the type's fidget rate (.ARM offset 204, 0 .. 75) when the flags have the ambient bit
  0x04 it plays its ambient animation (the frames of the ambient sheet at 100 ms each), and when they have the rotation bit 0x08
  the bands rate + 2 / + 4 / + 5 / + 6 are a narrow turn left / right and a wide turn left / right (the type's flags 0x10, complex
  rotation, walk the turn on their walk frame 1). The rest: the check (`FUN_005471c0`) is made on every
  fifth 25 ms tick, over the armies from two rows above the view to six below it and six columns beyond it sideways, rows from the
  top, each from the left, and ends at the first army that fidgets (armies in the top left of the screen therefore fidget far more
  often than the rest, and one fidget starts per 125 ms at most); a narrow turn shows stand frame 1 for 100 ms with the facing one
  step on and then stand frame 0, a wide turn two steps, and the army keeps the new facing. It is display only, as in the
  original: the dice are hashes of the army and the tick, the simulation no longer fidgets (openwbc3's old 4 % roll with
  `math.random` in `Unit:update` is gone), `u.view` carries the result to `Unit:draw`, and an order or fight drops it. Not
  verified in the binary: the ticks of a pass, the walking order and the step lists of the turns.
- **Floating text** (`gfx/floattext.lua`, the floating text lines `FUN_005348e0` / `FUN_005349b0`): lines from `Game.txt` over armies - "Critical: Ignore Armor /
  Cleave / Stun / Freeze / Burn / Mana Drain" (1113..1118, the `tinymsg` event of `Unit:strike`; the cleave's line is the hit
  army's, as in `FUN_005278a0`), "Healing: %d pts" (1121, `spells.lua heal` and the health potion), "Gained Level %d" (1109),
  "Spell Cast (Level %d)" (1111, the spell's casting level), "Spell Failed" (1110), "Recovering" (1150, the local player asks a
  hero to cast while it recovers: the UI refusal, the original says it in its cast function, `FUN_005777a0`, for the local
  side only) and "Recovered" (1151, the local side's army whose recovery has ended, with ten white stars 20 pixels above its effect
  point: `0x0051c8f0`), "Mana potion: %+d" (1119, with the sparkle picture `EZ00` and `Sparkles.wav`, `FUN_00561c30`), "Petrify"
  (1147, over the shooter that killed with the petrify missile, `FUN_004a9c90`), "Assassinate" (1146, over a killer that is no
  hero, `FUN_004a9e90`; with the picture `EZ43` at the victim and `Assassination.wav` at most once a second), and the lines the
  drain-experience / reduce-armour (864 / 863, `FUN_00527ed0` / `FUN_00527ff0`, bad) and crystallize (1148, `FUN_004a9d90`)
  attacks make, which show when the simulation sends them (it has not got those dragon attacks yet, see `missing.md`). "Spell
  Resisted" (1112, `FUN_00539fb0` via message 0x222 and `FUN_004afa00`, level colour) is sent by the host's spell resolution (`FUN_004aa840`) for the
  targets that Banish, Mutate, Strip Flesh and Rot do not take: the "resisted" event of those four spells (rules and flags in
  `docs/spells.md` "Spell Resisted"). A failed cast also
  sprays twelve yellow stars (`FUN_005777a0`, `gfx/emitters.lua` `fizz`). All lines: at most two per army, 40 px above the effect point, rise 25 px over 1000 + 1500 ms and fade over the
  last 1500 ms in 16 steps; stagger rules as in the line start `FUN_005349b0`; fonts 37..41 (white / green / red / cyan /
  yellow), own and allied armies see good in green, others bad in red. Only for armies on screen that the player sees.
- **Critical-hit pictures and sounds** (`battlefx.lua` `critFx`, the `critfx` event of `Unit:strike`; `FUN_00527b30` Freeze,
  `FUN_00527d10` Stun, `FUN_005278a0` Cleave, `FUN_00527720` Immolate, `FUN_00527a00` drain mana, `FUN_005427e0` missile hit,
  `FUN_004ac0e0` spell effect): piercing `EZ60` at the victim's effect point with `PiercingCrit.wav`, cleave `EZ62` at the
  attacker with `SlashCrit.wav`, crushing `EZ63` at the victim's feet with `CrushCrit.wav` and, while the stun lasts, `EZ10` on it
  (the 1.04 call passes 0x30315a45 to `FUN_0044e8f0`: the first version drew `EZ01`, a misreading of the code's byte order),
  freezing `EZ64` with `IceCrit.wav` and the blue light, burning `EZ50` and the persistent `EF04` with the yellow light,
  electricity `EZ61` with `ElectricCrit.wav`; each picture plays 50 ms a frame, the sounds are not gated by the combat sounds
  option and play only for armies within the view (cells, no margin). The draw order is the `adjustY` of the effect-picture calls
  (see "Effect pictures"): +1 piercing, cleave, burning, electricity and the persistent stun and flame pictures, +2 crushing and freezing.
- **Effect pictures** (`gfx/effectitems.lua`, `gfx/spellfx.lua`, `battlefx.lua`; presentation only, no `math.random`): what the
  original makes with its effect-picture call (`FUN_0044e8f0`; `FUN_0058bf70` makes the effect display item, `FUN_0053c870` sets it up, the frame
  function is at `0x0053cc20`). Verified there: `feet` (the picture at the army's position instead of its effect point), the
  on-screen gate (four cells), `adjustY` (`FUN_00535150` files the item in the display list at the army's row + adjustY; the list
  is drawn row by row, so +1 is in front of the army and the next row, -1 / -2 behind; the item's sort value is the bottom of its row,
  0x0053ca40), the frame time (50 ms, 120 ms for `EX01` .. `EX04`, 40 + 3d10 ms for `EZ09` / `EZ11` / `EZ32`), the
  emitter counter (starts at 1000, counted per frame before the test) and that a persistent picture loops and follows its army
  (`FUN_00535460` puts it on the army's effect list, `FUN_005351d0` moves the list with the army). The battle screen puts the pictures into its draw list among the armies and buildings.
  Callers (all with the `FUN_0044e8f0` arguments read from the binary): the spell effect function `FUN_004ac0e0` (casting effect +1,
  target effect +1 or, for `EZ18 EZ14 EZ08 EZ35 EZ34 EZ40`, at the feet -1, persistent +1 or, for a base message, at the feet -2; the
  per-spell codes are the spell records' `pictures`, table in `docs/spells.md` "Effect pictures of the spells"), the critical hits
  above, the level gain of an own army (`FUN_00527100`: `EZ12` at the feet behind, -1, `EZ57` at the feet in front, +1; the
  pictures play at 50 ms a frame now instead of the 1.6 s of the first version), `EZ43` of the assassin's kill (+2,
  `FUN_004a9e90`), `EZ00` of the mana potion (+1, `FUN_00561c30`) and the health potion's `EZ53` (+1) with `STEZ11.wav` and the white
  sphere-0 light (`FUN_00561d80`, the hero's spell message with casting effect `EZ53`, sound 11, kind 20 = heal). The persistent
  stun `EZ10` and the burning army's `EF04` (+1, effect point, `FUN_00527d10` / `FUN_00527720`) are made when the view first sees the
  status (`statusPictures`); the flame picture used to be drawn at the army's feet, it is at the effect point now as in the call.
  Which armies a spell touched is not a list of the simulation: `gfx/spellfx.lua` compares the world before and after the effect
  function (the "spellbegin" / "spellcast" events) - openwbc3's own reading, see `docs/spells.md`. The sound of a cast (`FUN_004ac0e0`'s last
  statements: `STEZ%02d.wav` at the caster through the positional helper `FUN_0050f0a0`, `battlefx` `spellSound`, `docs/spells.md`
  "Spell sounds") plays for hero, item and unit casts alike. Left out: pictures at a cell without an army (the cell variant `FUN_0044ec50` of
  summons that found no army), `EZ15` of the dragon attacks (no sender yet).
- **Decals** (`gfx/decals.lua`; the decal types `FUN_004795f0`, placement `FUN_00479a10`, drawing `FUN_00479e80`): one per cell, priority replacement. Footprints (`EDFS`, 30 s) on sand
  and snow when a walking army leaves a cell (move sound walk / stomp / trot / wagon / pad / skeleton; two decals for a
  2x2 army); gore (`EDBL`, 120 s, 0.8 s on water, lava and marsh, none on cells without move cost) - three decals around an
  army that dies unless its blood type is white or brown; green for type 2; scorch marks (`EDFS` row 8, 45 s) where a
  dragon breath missile (`EMF1..6`) lands on dry ground; the permanent dirt / snow / standard base under a building's
  `.BUI` base cells (read from offset 154), removed with the building. "Decals" off creates and draws none, "blood" off
  no gore. The original registers a fade-out for gore but never uses it: decals just end.
- **Emitters** (`gfx/emitters.lua`; the three tables are verified in the 1.04 binary, `FUN_0040e930` per building code,
  `FUN_0040ebd0` per effect code, `FUN_0040f620` per missile code; every entry is a record with the particle fields, the counter
  limit `every`, the pixel and grid offsets and an optional light):
  - *Buildings*: the points are the three emitter points of the `.BUI` record (offset 188, pixel offsets from the top left corner of the
    building's selection rectangle = position less the picture's origin; `formats/types.lua`); 23 building types of the
    install have them (the five Doomspires, the Pit, Chaos Shrine, Siege Workshop, Workshop, Foundry, Ironworks, Smithy, Blacksmith,
    three ore mines, a Shop, the Cess Pool, Shaman's Hut, Plague Shrine, Fire and Ice Caves and the Plague Tower; the furnaces
    and Halls of Plague, which the table names, have none). Every 25 ms tick (`0x0053b44a`, the
    building's frame check, read from the bytes) a finished building that is not fogged, not destroyed and within 8 cells of the
    view counts up from a random start below `every` and at the limit sprays its emitter at each point: plague buildings
    (`BKG0-4 BWTG BASM BACP BPPS BPLB`) 3 green glows against gravity every 9 ticks, the fire cave yellow or, on a 1 in 2 roll,
    red stars, the ice cave cyan stars, a furnace (`BKA0-4`) white cloud puffs every 10 ticks (red sparks on a 1 in 4 roll, 5
    glow particles with gravity), every other building white cloud puffs every 10 ticks. A razed building (`FUN_0052b3e0`,
    after it has been removed) makes smoke: n = the smaller of width and height less one; a first roll 2..4 up to n gives a
    second roll 2..4 smoke effects (it may exceed n), else n; each is an `ESMR` dummy effect (5 white cloud particles, medium,
    three respawns) at a cell near the building's.
  - *Effects*: a dummy effect has 16 frames of 50 ms, the effect that keeps its picture (the good breath's `EZ21`, 8 frames) the
    picture's; the counter starts at 1000 and goes up on every frame before the test, so the first frame fires and then every
    `every`-th: the good and acid breath's `EBLS` / `EPGA` (5) fire at frames 1 and 6 / 1, 6, 11 and 16, Mana Leech and Venom
    Touch (1) every frame, the chaos / divination / illusion casts (20 .. 100) once. The table has 26 codes (casts of the poison
    `EPOC` with a small green light, rune `ERUC`, arcane `EARC`, divination `EDVC`, illusion `EILU`, ice sparkle `EISP`, chaos
    `ECHC`, wildfire `ECHW`, ice storm `EIST` (12 cyan, huge, four respawns), freeze magic `EIFM`, ice armour `EIAR`, immunity
    `EIMM`, comprehension `ECOM`, see invisible `ESIV` ...) but only the ones above are started: which spell sends which effect
    id lives in the 120 cast functions behind `FUN_005777a0` and was not traced.
  - *Missiles*: the counter counts the flight frames (25 or 50 ms), the first frame fires, the burst is at the previous frame's
    position and a light at the new frame's cell (`0x0053fbc0`, read from the bytes): the silver arrow `EMA1` 2 white stars every 3
    frames, the flaming arrow `EMA2` one burst of red sparks, the poison arrow `EMAP` (drawn as `EMA0`) a green glow every frame, the
    fire poison arrow `EMFP` (as `EMA2`) every 5, the Minotaur's axe `EMS0` (as `EMM3`) a red puff every frame, the ice shards
    `EMIS` and the ice floe `EMIF` (both the invisible `EDUM`: the particles are all there is of them), the titan's balls one big
    spray, and the lights only of the fireball `EMF0` / magic sphere `EMM0` (small, short, every 2 frames, red / blue) and the
    lightnings `EMM1` / `EMM2` (medium, one cell above the shooter's, red / blue); the table of the mortar `EMMF` has no user.
  - The lights' step table is still openwbc3's own (see Lighting).
- **Frame-rate throttle** (`gfx/frameload.lua`, `FUN_0048fb80` and the users of the frame-problem counter `DAT_00a38c94`): the drawn frames' rate
  (sum of `1000 / ms` over eleven frames divided by ten, a quirk of the original) raises a counter 0 .. 20 below 13 frames a second
  (to 20 below 7) and lowers it above; new particle bursts stop from 12 on, shrink to a quarter without respawns from 8 and to half
  from 4, new lights stop from 4, new decals from 8 and the decals are not drawn from 12. The pools of the original are 400 particle
  and 100 light display items. openwbc3 measures its drawn frames, not the original's 25 ms ticks, and ignores a frame that took
  more than half a second.
- **Particles** (`gfx/particles.lua`; the particle pool `FUN_0058c0d0`): the 400 pre-computed paths (radial / fountain, gravity /
  none / anti, splash, bounce) generated from a private fixed-seed generator, steps every 25 ms; point particles with a
  five-step trail or the `EPA0..6` sprite blobs with fade / frame animation per path step. The option scales the count
  (0 none, 1 half and no respawn, 2 three quarters and half the respawns, 3 all). Blood on every hit (8 + damage / 8 red /
  green / brown blobs; 10 + damage / 4 points for a building) when "blood" is on; Titan fireball / magic-ball landings
  throw bouncing lens sparks. (The original only creates the damage blood on the host; openwbc3 does it on every peer.)
- **Lighting** (`gfx/lighting.lua`; the glow display item `FUN_0053db40`): the `ELIT` glow in the effect colour for 6 / 16 / 26 steps
  of 50 ms, sizes small / medium / large, option level 1 / 2 / 3 as in the light call `FUN_0044edb0`; shown at a spell cast (large,
  long), a dragon breath landing (medium, short; fire / good yellow, ice white, acid green, evil / lightning blue), the
  Titan balls (red / white, large, long) and critical freezing (blue) and burning (yellow) hits (medium, long). Drawn by
  day and night alike, as in the original (it is not tied to night). The colour of the cast flash per magic sphere is the table
  at 0x0060e5e0 read by the spell effect function (`FUN_004ac0e0`: white, purple, red, green, purple, yellow, blue, white, blue,
  red, green for spell / 10 = 0..10; the flash is large and long and is made for every cast whose caster is on the map);
  the earlier "own choice" had the same colours. Not verified against the binary: the step table (an own envelope with the same
  lengths and peaks per size).
- **Main menu effect** (`ui/menueffect.lua`; the hover effect `FUN_004052c0`, add `FUN_00405360`, update `FUN_00405500`): moving onto an entry adds a copy of its text (font 26,
  centred at x 400, y 162 / 207 / 252 / 297 / 342 / 387 / 472 for campaign / skirmish / multiplayer / tutorial / options /
  editor / quit) whose letter spacing grows 0 -> 20 px and whose translucency goes from level 9 to 15 over 1.5 s; at most
  twelve at once, duplicates allowed. `--show mainmenu:hover` shows it for a screenshot.

## Scenario editor

### Scenario editor: events (`screens/editorevents.lua`, `formats/evt.lua`, `formats/scnwrite.lua`, `game/editorlib.lua`)
The original's editor events mode (pool list `FUN_004b7be0`, adding a template `FUN_004b8380`, the condition dialog
`FUN_004b8ec0` / `FUN_004b9a30`, the effect dialog `FUN_004bacd0`, the map clicks `FUN_004c39d0` / `FUN_004c3c70`, the
standard victory event `FUN_00513c30`) and the XCI panels / `XCIStrings.txt` / `Game.txt` strings the dialogs use (the format is in `docs/formats.md` "Events").
- Format: `evt.lua` reads one 1196-byte event record (the same code reads the `EVSH` chunk) and the pool `EVENTS/*.EVT`
  (39 templates, in file name order, named by `Names.cfg` `[EVENT_<code>]`, "Unknown Event" for a code it lacks, like
  the name lookup `FUN_0058a380`); `scnwrite.lua` now writes events from their tables (128 slots, unused ones zero) and keeps the
  unedited bytes of a record; all shipped scenarios round-trip byte for byte (selftest "scenario events round trip").
- Model (`editorlib.lua`): slot 0 is the standard victory event, kept and never listed (a new scenario gets it, an older
  editor file without it is given it on loading); `addEvent` copies a pool template the way `FUN_004b8380` does
  (position 0,0, no seconds, radius at least 1, at most 128 events), `removeEvent`, `moveEvent`.
- Events mode: the list of the scenario's events (list name from the code), `Events` opens the pool dialog, `Modify` /
  double click the modify dialog; a timer event (kind 0) has its seconds edited next to the list ("Condition Time"),
  any other shows "Condition Position" and takes a click on the map as its position (cells, as `FUN_004c39d0`; the
  squares of all events and their radius are drawn on the map).
- Pool dialog (`PNL_EDITMODE_EVENTS_POOL`): `>` or a double click on a template adds a copy, `<` or a double click on an
  event removes it, Done closes. Modify (`PNL_EVENTS_MODIFY`): Condition and Effect One..Four (greyed when the slot is
  unused; the pool's effects decide what an event does, as in the original). Condition dialog (`PNL_EVENTS_CONDITION`):
  owner button (side 1-6 / everyone), the kind button cycling 0-9, 23-29, 31-35 (`onMap` is set unless it is the timer;
  the type resets to "any" / the first entry), radius, the flag button pair (flag 0-15 must be on), the number edit and
  the type list per kind exactly as `FUN_004b9a30` fills them (units and buildings with "any", race, side, item, resource,
  character, button icon, counter side); the timer's number is its loop count (`shots`). Effect dialog
  (`PNL_EVENTS_EFFECT`): the owner button cycles the five owner types in the original's order, the number / text edits and
  type list per effect kind as `FUN_004bacd0` fills them (damage amount + radius, resources, flag, units, explosion,
  sound / video / scene file names, text message, pause, feature, mana, storms, day / night, character names, popups
  with "Bing!", scroll, uncover, clock minutes + flag, AI level, counters), and a click on the map sets the effect's
  position (a red X; cells, default 4,4). A fourth-effect character name for condition 31 is stored in effect 4's text
  (kept as a used effect of kind -1).
- Own additions (not in the original, which has no reordering): Ctrl+Up / Ctrl+Down moves the selected event; a counter
  increment's loop count sets only `shots` (the original also writes it into the run-time `loopCount`, which would make
  the event loop forever); a number field may be 0 where the original ignores 0 (e.g. flag 0); the radius is limited
  to 10 (the editor has ten square sprites, `EEE0` .. `EEE9`); the effect labels for sound, video and scene
  files, "Button icon" and the radius / position hints are openwbc3's own wording.
- Not in the binary-checked set: the labels and the strings come from the 1.04 data files; the dialog layout follows the
  XCI panels; the editor routines named above are anchors only, their details were not re-checked in the 1.04 binary.
- Checks: selftest ("scenario events round trip", "event pool", "editor events: ..." incl. an edited timer event firing in a
  battle), `--show editor:events` (+ `_pool`, `_modify`, `_cond`, `_effect1`..`4`), a saved scenario run with
  `--scenario <name> --at 4 "print(W.events.flags[9])"`.

### Scenario editor: objects, sides, options, items (`screens/editorobject.lua`, `editorsides.lua`, `editoritems.lua`, `editorfields.lua`, `game/chests.lua`)
The original editor's dialogs (selected army handler 0x004c7b40, the map click action `FUN_004c4670`, sides 0x004b5b40, side edit
`FUN_004b5f00` / 0x004b6580, AI file 0x004b70c0, options 0x004be720 / mods 0x004bef80, items 0x004b5a00 / chest 0x004c8260 / chest view
0x004c8400, item click `FUN_004c3f90`, item record `FUN_004c8980`, item list `FUN_004c8790`, the new-scenario defaults, height painting and
flatten `FUN_005d1840`), the editor's army creation `FUN_004c8ad0`, the scenario's army / building / item chest / AI hero / options records,
the ITMH / ARMH loaders, the chest pick-up `FUN_0053a1a0`, and the XCI panels and strings the dialogs use; the routines are anchors only,
their details were not re-checked in the 1.04 binary. The scenario formats are in `docs/formats.md`.
- Formats: `scn.lua` / `scnwrite.lua` now read and write every field the dialogs edit - the full army / building records (behaviour, script,
  tag, character flag, statistics, level, experience), the ITMH chest (112 bytes, not 32 as `formats.md` said), the SAIH AI records (custom AI file
  per side), all fields of the options record and mod locks, the side lock flags, "must be human / on" and the start resources. A side's SAIH file becomes its
  `aiFile` (the scenario's AI script is used by the side; 5 sides of 3 shipped maps have one). Every shipped chunk is written back byte for byte
  (selftest "scenario chunk round trip", 7191 chunks); `rules.armyInfo` / `building` carry the type index (the number at the start of
  an `Army.cfg` / `Building.cfg` line), which matches all shipped scenarios except 33 placeholders (the tower variants of Forest Lakes, one unit).
- Selected army / building dialog (`PNL_EDITOR_ARMY_SELECTED` / `_BUILDING_SELECTED`): a click on an object with the Select tool (no drag) opens it and
  blocks the map until Done. The owner button cycles the sides 0..6 (a critter / a lair, shop or shrine always neutral; "(not in use)" for a side the
  scenario does not use), the edits are the character name (a name makes it a character), the ID tag and, for an army, the level (shown as
  level + 1; Done stores the experience of that level, `Unit.XP_FOR_LEVEL`; the original reads its table before clamping a typed 0, openwbc3
  clamps first; a hero's scenario level is its hero level). New armies / buildings start as `FUN_004c8ad0` makes them (normal behaviour, alive, the
  type's own statistics, current hits, type index).
- Own additions (the original's panels have no button for them, the original never opens them and the 1.04 data ships the panels
  without the background pictures of the stats dialogs, bitmaps 81 / 86): Behaviour (the five behaviour types 66.0-4 and a typed script code), Character
  (name, level, experience; at most nine characters on a map, as the original refuses a tenth) and Stats (combat / speed / resistance /
  hits / view, armour / strong / weak, damage / type / range, current hits; Apply switches `useDefault` off as the original's building stats writer does; no counterpart found in the 1.04 binary). The
  simulation uses the hits of a non-default army; the other statistics and the behaviour are stored but not read by the game (as in the original,
  whose production does not apply the stored behaviour; not traced in the 1.04 binary yet).
- Sides mode (`PNL_EDITMODE_SIDES`): six rows with check box, shield colour (cycles 0..5) and race button; a side can be switched on only after the lower ones
  and off only before the higher ones, sides 1 and 2 stay. Side edit (`PNL_EDITOR_SIDES_EDIT`): race (16 races), resources (0..4), team (0..4, the
  `IM_ICON_TEAMS` pictures), computer level (0..7) each with its lock flag, "Must be on" / "Must be human"; the AI file button opens
  `PNL_EDITOR_SIDES_AIFILE` ("None" and the `CustomAI/*.ai` scripts of the side's race or race -1, sorted by name); a file locks the race
  (greys the race button), "None" unlocks it. The original's order of the XCI objects (which row is which side) is not known: the left column is
  sides 1-3 and the right 4-6 (openwbc3's reading).
- Options mode (`PNL_EDITMODE_OPTIONS`): hidden map, fog (0 none / 1 fog / 2 line of sight; the last plays as fog), handicapping, quests, tech level 0..5
  (`TXT_TECHLEVELS`) each with a lock flag, the army setup points bar with its lock (the original sets no range; 0..50 as the skirmish
  slider) and the Rules button for the seven game mods with a lock flag each (`PNL_EDITOR_OPTION_MODS`, texts 238). openwbc3's own: the "produce
  heroes" / "standard victory" toggles (debug keys in the original) sit at the bottom of the panel, and name and description are edited in the
  Save As dialog (they were edit boxes of the old options panel). A new scenario now starts with the original's options (hidden map on, quests on, tech
  level 5, choose city setup) and empty AI records.
- Terrain mode now uses the original's `PNL_EDITOR_TERRAINNEW` (tile list, "Fill map", the `<id>i.bmp` icon and the size text 226, "1x1" ...). Its
  "Smooth map" button is not shown: the final game greys it and moves it off the panel (the smoothing `FUN_00493040` has no callers in
  1.04). Height mode (`PNL_EDITMODE_HEIGHT`: brush size, smoothing, height change, flatten map / screen) is never entered in the original
  and its height painting and map flatten call `FUN_005d1840`, a bare return in 1.04 (the map click of editor mode 11 goes there: jump table
  `0x004b2ab4`, call `0x004b26a4`); openwbc3 has no height mode: a leftover of the 3-D height maps of the earlier games, nothing to implement. `PNL_EDITOR_INTERLACE`
  is the click-blocking pad over the editor bar while a dialog is open (openwbc3 disables the bar buttons) and `PNL_EDITOR_STRATMAP_LOAD` the
  minimap picture shown over the new / load dialogs.
- Items and chests: in the original the items mode exists only in an in-house build (its `i` key is not in the release; not traced in the 1.04 binary yet); the released
  editor can only select chests that are already on the map. openwbc3 offers it on the `I` key: types Item (own addition: a numbered
  item of `Items.xml`, never a mod item, whose "modid:name" does not fit the record's i16 item number; the original's list shows 16 hard-coded names but `FUN_004c8980` returns a random item) / Random / Resource (gold, metal, stone,
  crystal), modes New / Edit / Delete; a click puts a chest on the cell or, if there is one, adds a numbered item to it (never a random item, at most
  four, never to a resource chest, as `FUN_004c3f90`); Edit opens `PNL_EDITOR_ITEMS_CHEST` ("Item One" .. "Four", greyed beyond the count) and
  `_CHEST_VIEW` (Random item / Resource / the item's name and powers, Remove - not for the last item). In a battle every item of a chest becomes an item
  on that cell (the original opens a dialog to take one), a random item is the tier-2 roll chests always used here, a resource chest gives 500 of its
  resource to the side of the hero that comes next to it (the chest pick-up `FUN_0053a1a0`; saved with the game; `World:dropResource`). Not
  reproduced: the original's resource chest in the editor cannot be placed (`FUN_004c8980` leaves the item index at -1 and `FUN_004c3f90` then breaks).
- Message boxes (`PNL_EDITPANEL_MB` / `_MB_QUESTION`, the original's `FUN_004bf5a0`, `S:messageBox` in `editor.lua`): the panel sits at (290, 448) over the
  editor bar under the interlace picture (`PNL_EDITOR_INTERLACE`, which blocks every click until the box is answered); its three
  `STR_SMALL200` are the title and two lines, top to bottom (by position, as the original's index 0..2 of that id). The original's
  box handlers (OK 0x004bf830, yes / no 0x004bf760) and confirmations (overwrite 0x004c21b0, save after the start location warning
  `FUN_004c26a0` / `FUN_004c0990` for Save As, exit 0x004b1af0, delete 0x004c2750, the menu panel handler); the texts are the game's own (`XCIStrings` 184 start location
  error, 185 save / exit, 223 scenario exists; `Game.txt` 0385 "Delete this scenario?"). Flows: the menu's "Save" button (named
  `BUTT_EDIT_SAVEEXIT` but it only saves) checks that every used side has a start location (else the
  error box, whose OK saves all the same) and then shows "Scenario Saved" / "Scenario NOT Saved"; Save As and New ask "This scenario
  already exists / Overwrite?" when the name is taken (No leaves the dialog open, Yes carries on: Save As with the same start check,
  New creating the map); Exit always asks "Exit Editor / Are you sure / you wish to exit?" (openwbc3's earlier "press Exit again" is gone);
  Delete / Backspace in the load list asks to delete the selected scenario (only a scenario of the user folder, the install's own cannot
  go). Create stays greyed until a name is typed (the name field's edit event). Own: Return / Escape answer the box (OK / Yes and OK / No), Ctrl+S goes
  through the same checks, a name that exists only in the install's `Scenario` folder is not asked about (openwbc3 saves to its own folder).
- Random map into the editor (Ctrl+R in the New Scenario dialog, `S:randomMap`, `editorlib.randomScenario`): the handler is in the 1.04
  binary (the code at 0x4bfd2b copies "Random" into an empty name and compares the size with 64 / 128 / 192 / 256, in the
  new scenario dialog's handler at 0x004bfb50; Ghidra has no function there). It rolls 1d7 - 1 for the terrain (Grasslands .. Caverns of the
  same numbering as the skirmish's) and 1d3 - 1 for the resources, a few animals, no utilities, then `FUN_00417120` ->
  `FUN_00582180` with the editor flag set makes the piece map only: the start locations, towers, mines, quests, utilities and animals come
  from `FUN_00583960`, which only the game's battle setup `FUN_004179f0` calls, so the editor map has tiles and features
  only (`randommap.generate{editor = true}`). The editor then switches all six sides on (race = side, no start locations) and gives the
  standard victory event; the dialog stays open with Cancel greyed until Create takes the name and description. The generating screen is
  not shown for the editor (`FUN_00582180` opens it only for a game). Own: the 96 and 160 cell sizes of openwbc3's size list are
  generated by the same piece rules (the original has 64 .. 256 here, and for 512 its island count is uninitialised), the seed is any number.
  The G / D / R / W keys of the menu (export of a random map piece) are left out of the final build and the binary has
  no "Grass\Goms" string: not in the final game (`docs/todo/not-in-original.md`).
- Map sprites of the editor (`FUN_004c28b0`, `Effects1.xcr`): the start locations are drawn with the shield colour's `EOSR / B / G / P /
  K / Y` picture (108x108, centred on the cell), the events' squares with `EEE0` .. `EEE9` (radius 1 .. 10; a faint shadow of r x r cells:
  the sprite is not the square the game tests, which is +-radius/2 cells, the event system set-up `FUN_00513f90`, so the selected event keeps openwbc3's
  outline of the real area) and the effect's position with the `EEBX` X; the outlines remain where an install lacks the pictures.
- Condition 32 (button press): the type list is the 98 control panel icons with the title the button help `FUN_00414ef0`
  gives each (a help line of `Game.txt`; blank, disguise, next and earthquake have no case and, like an empty line,
  show "-*-", `FUN_004babf0`); the chosen row is the condition's target. The table is `ICON_TITLE` in `editorevents.lua`
  (the pairing of icons and `Game.txt` lines was not re-checked against the switch of `FUN_00414ef0`).
  The event system's side (`Events:button`) already took the icon number.
- `Events.txt` of `FUN_004b8380`: the match file lookup `FUN_0044f4e0` looks for `<language folder>/Events.txt` and keeps the template's own name when
  the file is missing; no install has it (English / German folders, archives), so the template's name staying is the original's behaviour.
  The event list shows the `Names.cfg` name (`FUN_0058a380`, list refill `FUN_004b7680`), as here.
- Chests: in the Edit mode a drag moves a chest (own, like the armies and buildings) and a click without moving opens the dialog; the
  original's way, a right click on an empty cell with the chest selected (the editor's move action for an item), works too
  (`editorlib.moveChest`; not onto another chest). The stats dialogs' pictures (bitmaps 81 `EditStatPanel.bmp` / 86 `EditStatPanelSingle.BMP`
  of `GText.xcr`) are in no archive or folder of the install: confirmed absent (`docs/todo/not-in-original.md`).
- Checks: selftest ("scenario chunk round trip", "editor object: ...", "editor sides: ...", "editor chests: ...", "editor battle: ..." - the saved scenario
  loads in a world and keeps owner, name, level, building name, chests and AI script), `--show editor:object[_building|_behaviour|_character|_stats|_used]`,
  `editor:sides[_edit|_ai]`, `editor:options[_mods]`, `editor:items[_chest|_view|_resource]`, `editor:terrain`; the leftovers: selftest ("editor chests: a chest moves ...",
  "editor random map: ..."), `editor:mb`, `mbfail`, `mbstart`, `mbexit`, `mbexists`, `random`, `events_cond32`, `events_effect1`, `startlocs`.

## Verified against the original since
The hero skill system (race / class skill lists, casting skills instead of spell points, mana and regeneration,
command radius, item slots) and the spell effect values (`docs/spells.md`); attitudes, computer power-up buying,
Slave Horde / Brood / weather costs, garrison numbers (behaviour only, not checked against the 1.04 binary), game
speed steps (x0.5, 0.75, 1, 1.5, 2: the game clock `FUN_00458dd0`).

Power-ups again: Library / Sorcery mana, the innate poison / disease of the unit type records and the spreading of a
disease, build skill and construction time, the Chameleon's Construction, the missile special attack roll and
immolation, the missile pictures of `FUN_0040ac00`, the poison arrow's poison and the missile resistance of buildings
(behaviour only, not re-checked in the 1.04 binary unless an anchor is given).

The mouse cursors: the rules of the battle cursor choice (`FUN_00420390`) and the right-click order translation that
matches them (0x00421190), the standard pointer hand of the menu cursor routine (`FUN_00456a30`, its enable flag `DAT_0060c3ec`
turned off for the battle at 0x004e6ad0, active object types button / edit field / scroll bar / list box) and the dialog variant
(trade 0x00572dd0 / production `FUN_00568e30`), the mine and garrison predicates (garrison `FUN_0051c240`; the mine test not
traced in the 1.04 binary yet), the critter test `FUN_00528280` and the army flag values (behaviour; the details were not
re-checked in the 1.04 binary); the 16 cursor ids of `War4Gfx.xcg` and the absence of the campaign province files, both read
from the game's own archives.

### Skirmish setup rules (`screens/skirmish.lua`, `screens/gamemods.lua`, `screens/mphost.lua`)
The original's setup screen, scenario loading and hero placement (behaviour; not re-checked in the 1.04 binary unless an
anchor is given); the handicap table and the army setup flow were already checked in the binary (see "Retinue in every game type").
- **Scenario locks, all of them parsed** (`scn.lua`; offsets in `docs/formats.md`): per side the team, resources and AI level
  lock flags (the offsets are those of the 44-byte side record, and the shipped maps
  confirm them: Eldritch Tower locks team + resources of every side, Dwarven Tunnels the computer level of side 2); per option
  tech level, army setup points, fog of war, hidden map, quests, handicapping and each of the seven mods. A locked value is
  drawn as a dimmed box without arrows (`lockedBox`) and ignores clicks: team / resources / level of a side, the tech row, the
  setup points slider, quests, handicapping, the visibility cycler (it keeps the fog part and / or the hidden-map part of the
  current mode when only one of the two is locked, like the original's two buttons) and the mod check boxes. A side with an
  AI lock plays at the scenario's level.
- **Computer levels**: a computer side starts at the scenario's level (a level above Warlord is taken as Knight - the original
  clamps it that way), and offers Passive .. Emperor when the scenario side is Passive, Squire .. Emperor otherwise; Rampant
  is not on offer (not traced in the 1.04 binary yet).
- **Rules dialog** `PNL_SS_GAMEMODS` (`screens/gamemods.lua`, button "Rules..." = XCI text 28/1 next to "More options"): the
  seven check boxes (texts 238.1 .. 238.7) with OK / Cancel; locks are greyed, No Heroes also with the Assassin victory
  condition or Tournament mode, Battle of Titans locks No Lords / No Heroes (openwbc3's own, as before). In single player
  and for the host the boxes work, a client opens it read-only from the lobby (the lobby message carries the mods).
- **Handicapping**: the setup has the option (XCI texts 177.0 "Handicapping On" / 177.3 "Handicapping Off"); in a single player
  game it is forced off and greyed (not traced in the 1.04 binary yet), the host of a network game toggles it unless the scenario
  locks it; the points come from `retinue.handicap` (binary `0x00603c9c`) when the host hands out the army points.
- **Produce heroes**: a scenario whose header "produce heroes" byte is off gets no hero
  unit for any side and no resurrection; all 115 shipped scenarios have it on, so only editor-made maps can switch it off
  (the editor's Heroes button). In 1.04 the hero placement `FUN_0043b550` puts a hero down only when the flag `DAT_00748a97` is
  set (a random map sets it, `FUN_00417280`); that this flag is loaded from the scenario header was not traced.
- Checks: `--selftest` ("setup locks", "produce heroes"), screenshots `--show skirmish:locks|flags|rules`,
  `--show gamemods[:locked|viewer]`, `--show mphost`, the two-instance loopback run.
- **The setup screen is the original's `PNL_SS`** (rebuild; the setup screen handler 0x004e5120, the side panels `FUN_004eb4d0`,
  the scenario list `FUN_004072b0`, positions from `War4Int.xci` and the side panel opener `FUN_004f19f0`): background, the
  map list (`LB_SS_MAPS` with `SBAR_V156B`, map names from `<language>/scenario.cfg` `[SCEN_<file>]` lines, sorted, only
  the Scenario folder plus editor maps - the campaign scenarios are no longer in the list; like the AI script and unit AI lists
  it goes through `fs.fileList`, the limits of the original's file list `FUN_00402ad0`: 1024 entries, names in 40-byte slots,
  so a file name of 40 or more characters, which overruns its slot in 1.04, is left out), the size filter (widths 64 / 128 /
  192 / 256, "any") and the player count filter (2..6, "any") as the `SSMapSizeButton` / `SSMapPlayersButton` icon sheets, the
  minimap at (29, 19), six drop-down option buttons in the original's order (victory, keep level, hidden map, fog,
  handicapping, quests; texts 172 / 173, 174, 175, 176, 177, 178), the resolution button (changes the window size), the
  army setup points bar `SBAR_H170` with its value, the game speed button (212), More options / Rules.. (text 28) and the
  thumbs buttons (Cancel / Start). The three help lines at the bottom follow the hovered control (texts 179 / 196 / 197,
  174, 175, 176, 177, 178, 171, 210, 237, and for the side panels 207 / 208 / 209).
  One `PNL_SIDESEL_SIDEn` per used side at (22, 201 + 31 n): the player button (your name, `KI: <level>` = text 214, closed =
  text 103.1), race (texts 15 / 104, "Random" = 83.0, last in the list), resources (102) and the team shield (click cycles the
  team 0..3; the shield colour comes from the scenario's side colour; the original's side colour buttons are switched off). The
  player button's drop-down is the original's (callback 0x004eb110): your name (single player: sits you on that
  side, the side you left becomes a computer), the computer levels (a Passive scenario side starts at Passive), Closed
  (not for a "must be on" side). The scenario's locks grey the same buttons as before; the victory modes that force the
  teams (raze fest, slug fest, fortress, king of the castle, rich get richer: team 0; against the horde: side 0 team 1, the
  rest team 2) back up the teams and restore them on leaving, like the original's team backup. A side the scenario says must be human
  is the player's seat. Right-click on a computer side: the AI hero panel `PNL_VIEWHERO` (`screens/aihero.lua`, see "AI hero panel"), whose "AI File" button opens `PNL_SELECTAIFILE` (`screens/aifilelist.lua`).
  In a network game the chat frame / edit field and the map name line are shown. New shared widgets: `ui/scrollbars.lua` (vertical `VSBAR156.bmp` and horizontal `HSBar170.bmp`),
  `ui/listbox.lua`.
- Multiplayer lobby (the chat message `FUN_004e3040` and the chat lines `FUN_004e1e80`, the side panels; the strings are `Game.txt` 226 / 237 / 238): Enter in the chat edit field sends "`<hero name> - <text>`" to
  everybody, the sender included (a client sends the text to the host, which formats it with the name it knows and relays
  it as `lobbychat`); an empty line only keeps the field. The last three lines show in `STR_SMALL500`, newest at the bottom,
  each cut by its last character until it is at most 325 px wide, every new line plays the click sound. System lines go
  through the same channel: "%s has joined the game..." when somebody joins, "%s has left the game..." when somebody
  leaves, and the host's own chat starts with "Game started... IP Address is %s". The side panels show the hero's name of
  every human (the hero name goes with the join request). A joined player sees the host's `PNL_SS` read-only
  (`screens/mpjoin.lua`, the screen of `skirmish.lua` with `canEdit()` false): the host's `lobby` message (every change and
  every 2 s) carries the map (file, label, size, checksum; a map the client lacks shows by name only), the options (victory,
  keep level, fog, handicap, quests, points, mods, advanced options, speed, locks) and every seat (race, resources, team,
  computer level, open / closed / player; see "Network lobby: seats, ready, maps"), the "More options" / "Rules..." dialogs open read-only. Leaving sends a disconnect. The host's `/HIDE ON|OFF`
  (hides the races of the other players on the side panels) is not part of the original game:
  the 1.04 binary has no such string and `Game.txt` has no text 1162 / 1163; only the community builds
  (`Battlecry III-.exe`, `-dbg.exe`) contain it, so it is not implemented (typed, it is an ordinary chat line).
  The network statistics show every player's link to the host (the host relays its table). Boot, own race and the end of a game: see "Boot,
  own race, after the game" below.
- Own choices (not verified against the original, also in the `skirmish.lua` header): the list row height and highlight; no
  "line of sight" fog choice (openwbc3 has no such fog); in a network game the host's player sits on the first seat after
  every map change (the original leaves him without a seat until he picks one); hero resurrection (openwbc3's own opt-in
  rule) moved from the setup screen to the options screen (`[skirmish] resurrect`); the "start at night" option is gone from
  the screen (the night flag comes from the scenario header). The ready boxes, Open seats and map sending of network games
  are described under "Network lobby: seats, ready, maps".
- Checks: `--show skirmish[:locks|flags|filter|seat|ai|rules|advanced|greatest]`, `--show mphost`; `--show` now runs
  `--at <s> "<lua>"` scripts with `S` = the screen (main.lua `runScripts`), e.g. `--at 1 "S:start()"`.

### Network lobby: seats, ready, maps (`screens/mphost.lua`, `screens/mpjoin.lua`, `ui/msgbox.lua`, `game/mapxfer.lua`)

The original's side selection protocol over
openwbc3's own UDP messages (`net.VERSION` 2; the host's `lobby` message carries per seat `open` / `closed` / `player`, per
player name / race / `ready`). Verified in the 1.04 binary (the side selection message ids are 3000 and up; the dispatcher is
`FUN_0049eb60`):
- **Seats**: the seat state per panel (`0xa498dc`, 0 open, 1 player, 2 computer, 3 closed). The map change handler `FUN_004e0590`
  (message 0xbc7) and `FUN_004e7760` (0xbcc, map finished) zero it: every seat of a new map is Open and nobody has a seat
  (`DAT_0060f198` = -1). The side panel handler `FUN_004eb4d0` (case 0x80, the player button) cycles it; the host's seat
  request handler `FUN_004f3210` (0xbdc) gives an Open seat to the first asker and broadcasts it plus "not ready", or answers
  with 0xbe1 (denied). openwbc3: a joined player clicks an Open seat (`seat` message; `seatdenied` when it was taken), clicks
  his own to give it up (`unseat`), and changes the resources / team of his own seat (`side`) until he is ready; the host's
  drop-down offers his name (when he has no seat), the computer levels, Open and Closed (the last two not for a "must be on"
  side); the race of a human seat is his hero's. A seat that is neither human nor computer is unused when the game starts
  (`FUN_004eac50`: seat state 1 or 2). A player without a seat when the host starts gets "Game already started / Alas... The
  time for battle has passed you by..." (texts 286.7, 287.0, 287.1; the game start message `FUN_004e2660`) and leaves.
- **Ready**: the ready check box (`BUTT_SIDESEL_READY`, 21 x 20 at (511, 3) of the side panel, bitmap 546: eight rows,
  unchecked / checked x normal / hover / pressed / greyed; computer seats greyed and checked, Open and Closed greyed and
  unchecked) toggles the seat's ready flag (binary `FUN_004eb4d0` case 0x7d: sends field 5 of message 3000). Ready greys the player's
  own seat and the Cancel button. The host's click is refused with a message box unless `readyToStart` holds: "Sorry / You
  must wait until all other players have pressed Ready before you can" (Game.txt 1140-1142) or, with nobody else in the
  game, "Sorry / You cannot play a multiplayer game with yourself" (1143-1145; `FUN_004b10f0` < 2 players). **readyToStart**
  = `FUN_004eacd0` (it also greys the Start button): no player lacks the map, the host has a seat, every human seat is
  ready, at least two seats are human or computer, and the played seats are not all in the same non-zero team (the
  binary compares the teams as signed shorts, as done here). Every
  change of the host unreadies everybody: the unready routine `FUN_004eaaf0` (chat message 3012 with the reason text,
  never shown to the host, then field 5 = 0 for every ready human seat; 20 call sites, the texts checked at the random map
  options 747, the option buttons 748, More options 749, the side panels 745; the AI seat callback 746 and Rules 750 not
  traced in the 1.04 binary yet). The reason shows only to the players who were ready (More options / Rules: to everybody). openwbc3 finds the
  changes by comparing the setup before and after (`mphost.lua` `checkChanges`); a new map unreadies everybody without text.
- **Maps** (the host sends `mapinform`, players answer `hasmap`): when all have the map the host changes it at once
  (`mapchange`, each player answers `mapok`, then `mapfinished`); if somebody lacks it Send Map (`BUTT_SS_SENDMAP`, hint
  210.0) gets active and the Start button stays grey (the map is never ready) until the host presses it (`mapchange` to all).
  A player without the map (or with another version: the original compares a header CRC that openwbc3's editor does not
  keep, so openwbc3 compares its own XOR checksum and the size) gets the message box "Scenario error / You do not have this
  scenario / Do you wish to download it from the host?" (284.7, 284.2, 284.3; "Different version of scenario found" 284.4;
  buttons No left, Yes right = 285.3 / 285.2: `FUN_0042d7b0` puts string 4 on the left button, which returns FALSE). Yes shows
  "Changing maps / Please wait..." (284.0 / 284.1) and requests the file (`mapreq`), No leaves the game. The binary sends the
  file in pieces of 0x3ea (1002) bytes in message 0xbcd (host handler `FUN_004e7270`: piece number, piece count = size / 1002
  + 1, a 20 ms pause between pieces); openwbc3's pieces are 4096 bytes (`game/mapxfer.lua`). A received map is stored with
  the editor's maps (`scenarios/` of the user directory) and the list shows it afterwards; a player joining without the map
  is asked right after the first lobby message (`joinmap`). Players joining while a map changes or somebody else joins wait
  ("The host is busy / Changing maps", 284.6, 284.0: `hold`, shown on the join screen); the others see "Player joining /
  Please wait..." (284.5, 284.1: `joinlock`, not sent to the joiner himself).
- The message boxes are one widget (`ui/msgbox.lua`) on the original's panel 341 `PNL_MESSAGE_BOX` (one button at x 309, two at
  216 / 403, y 345; title and text lines), owned by the lobby screen so that it keeps receiving messages; the `PNL_SS_MB_*`
  panels are dead code (see `docs/todo/not-in-original.md`).
- Checks: `--selftest` ("lobby: ..."), `--show mphost`, the two-instance run (`--show mphost:auto` + `--show multiplayer:join`:
  the joiner takes the first Open seat and readies, the host starts). Developer scripts used: `--at <s> "S:readyClicked(S:mySeat())"`,
  `S:sendMapClicked()`, `S.devLack = "editordemo.scn"` on the joined screen (treats that map as missing until it was received).

### Boot, own race, after the game (`screens/mphost.lua`, `screens/mpjoin.lua`, `screens/mainmenu.lua`)

Verified in the 1.04 binary (side selection message ids 3000 and up, dispatcher `FUN_0049eb60`):
- **Boot**: the host's click on another player's player button (side panel handler `FUN_004eb4d0`, case 0x80, panel state 1)
  opens the generic message box `FUN_0042d7b0` with texts 287.2 / 287.3 / 287.4 ("Remove player? / Should this warrior be
  removed from the battlefield?") and the buttons No (285.3, left) / Yes (285.2); the hover help is 207.6 ("Left-click to remove
  the player from the game", `FUN_004ead70`). Yes (the box's answer handler at 0x004ed610): the host's panel becomes Open, a
  booted message (3011 = 0xbc3) with the panel and the player's comms id goes to everybody and a panel change (3000) with player
  -1 follows. The booted player's handler is `FUN_004f0b00` (message 0xbc3,
  compares the id with its own): the leave function `FUN_004f0bc0` (chat "has left the game" 237, panel change, closes the
  session), the main menu set-up `FUN_0041d2c0`, then a message box 286.0 / 286.1 / 286.2 ("Farewell / The host considers you
  unfit for battle / You have been removed from the game") with Okay (285.0). openwbc3: `S:bootClicked` / `S:boot` (host),
  message `booted`, `mpjoin S:booted` pops to the main menu and `mainmenu:message` shows the box; the host drops the player when
  his connection ends (his "has left the game" chat), a player that does not leave is disconnected after 4 s.
- **Own race**: the player button's race drop-down on a player's own seat works in the original (`FUN_004eb4d0` case 0x7b on the
  player's own panel: the 16 races of texts 15 / 104 and Random, unless the scenario defaults are in force; help text 207.0 "Changes the race
  you will play"; greyed by a locked race or ready). Taking a seat does not change its race (`FUN_004f3210`);
  the game start copies the panel's race to the side, Random is drawn then (`FUN_004de740`); the hero unit
  comes from the hero's own record (the hero placement `FUN_0043b550`: its avatar code), the army and buildings from the side's race. openwbc3: the seat's
  race is `sd.race` (nil = Random) and the player changes it with the `side` message (`field = "race"`, -1 = Random); the host
  resolves Random in `S:start` and sends the result; the army setup opens with that race (`setup` message); `World:heroRaceOf`
  gives the hero unit of the hero's own race (every peer knows it from the start message), `World:profileRace` lets the profile
  find the hero whatever the race of the side in a network game. Tournament heroes keep the side's hero unit as before.
- **Race of a human seat and his hero** (single player skirmish and network alike; binary `FUN_004de740`, `FUN_004e7760`,
  `FUN_004e47e0`, `FUN_005a1880`): the start copy `FUN_004de740` takes every side's race from its panel's race (the field at
  `0xa47a38 + 0x38 * panel`, Random = 16 is replaced by the pre-drawn random race) and nothing in it looks at the hero's race, so
  a human plays the race of his seat and the hero comes along unchanged: the hero unit is the hero's own record
  (`FUN_0043b550`, its avatar code), the army and buildings are the seat's race. Where the panel's race comes from: the host and the
  single player (`FUN_004e47e0` sets the "setup open" flag `0x60f104` to 1 for them) copy the race of every scenario `SIDH`
  record (+2) into the panel whenever a map is loaded (`FUN_004e7760`, also the human's panel); a locked race (`SIDH` +4)
  greys the button, so it stays the scenario's; the "I am the greatest" option and the random map set every side, the human's
  too, to Random (`FUN_004ea050`, `FUN_004e0590`); the campaign launcher `FUN_005a1880` gives the human the campaign's race
  (its `param_2`) and the others the scenario's (Random when outside 0..15). The race button of the human's own panel works in
  single player as well (`FUN_004eb4d0` case 0x7b); sitting on a panel or leaving it does not change the panel's race. openwbc3:
  `skirmish.lua` `scenarioRace` gives every side the scenario's race on the setup screen (before, every side started on
  Random and the single player's race was his hero's and greyed), the single player picks his seat's race like anybody,
  `S:start` resolves Random for all seats the same way, the army setup opens with the seat's race, and `opts.heroRace`
  (the hero's own race, single player only; saved with the game) makes `World:heroRaceOf` / `World:profileRace` behave as
  in a network game: the hero unit is the hero's race, the profile hero is found whatever the seat's race. A Tournament hero
  (made for the seat) and the campaign keep the side's race as before. Check: selftest "skirmish seat race", screenshot
  `--show skirmish:locks` (Eldritch Tower: the scenario's locked races on every seat, the human's too), a start of that map
  (side race 12 Empire, hero race 11 with its own hero unit and the army setup of the Empire).
- **After a game**: the retinue screen's exit handler `FUN_00440e80` (every game type but the campaign) closes the comms and runs
  `FUN_0041d2c0` (the same set-up the lobby's Cancel ends in): everybody, the host included, is on the main menu; there is no
  return to the lobby (`FUN_004b0730` closes the session, then `FUN_0041d2c0`). openwbc3: `screens.popToBottom()` in
  `mphost` / `mpjoin` `resume`.
- Checks: selftest "lobby: a player picks his seat's race ...", two-instance runs (`--show mphost` + `--show multiplayer:join` with
  `--at` scripts: the joiner picks race 4 and the battle shows it on both peers, the host boots the joiner and the joiner's
  screenshot is the main menu with the box, popping the battle leaves both on the main menu).

### AI hero panel (`PNL_VIEWHERO`)

Right-clicking a computer side on the setup screen opens the AI hero panel (`screens/aihero.lua`; `game/aihero.lua` has
the rules). Verified in the 1.04 binary: opening `FUN_004edd00` (panel 0x157 = 343, modal, title text 288.0 "AI Hero", the
race / class labels 3.3 / 3.4, the stat lines 288.1-4 stay "Strength : ?" ..., button "AI File" 288.6), the display function
`FUN_004ed7e0` and the button handler (code at `0x004ee060`, no Ghidra function) over the 42 byte
AI hero records (race +0, portrait +2, level +4, class +8, AI file name +10; the global copy at `0xa498f8`, the
panel's working copy at `0xa499f8`):
- unset values (-1) are filled in whenever the panel shows: race = the side's race (a random hero race 0..15 when the side's
  race is random), level = the local hero's level + 1d11 - 6 (at least 1), class = a random one of the **28** classes (the
  binary has no Monk); the portrait is `Portrait<race>.bmp`.
- race drop-down: the 16 races (texts 15 / 104); class drop-down: the 28 classes in number order (texts 8..11, eight per
  group); level arrows: right adds one (below 4 -> 4, 51 -> 4), left takes one (3 -> 50, below 4 -> 4); "AI File" opens
  `PNL_SELECTAIFILE` (races filtered as before) and only changes the panel's copy; Okay copies the panel's copy back (the
  filled-in defaults too, and in a network game sends it as message 3037, pushed at 0x004ee27e), Cancel drops it.
- The scenario reader `FUN_0041bd90` clears race / class / level / portrait / personality / file of all six records
  after reading a scenario's `SAIH` chunk, so a scenario's own values never reach the setup; a map change (`FUN_004e0590`) and a
  race change (the drop-down callback 0x004eb110) clear the AI file (the latter not traced in the 1.04 binary yet).
- Applied by the computer hero maker `FUN_0042a0d0` (called with the side index): a chosen level (> 0) is the hero's level, otherwise
  it is made from the humans' hero levels (the highest one, tournament points, AI level scaling); "I am the greatest" then raises it to
  100 and the Battle of Titans sets 100 (binary; openwbc3 keeps its existing 50, see `victory.lua`). The hero's race is the chosen race
  (`FUN_0054be60`, otherwise the side's race) and decides the hero unit (`AxHX`, the same table as `economy.HERO`) and the
  skills / attributes; the class is the chosen one (`FUN_0054bea0`) else a random one.
openwbc3: `sd.aiHero = { race, class, level }` (missing = unset) per side of the setup, copied to `scn.sides[i].aiHero`, the
world's `sides[i].aiHero` (computer sides only; `World:heroCode`, `spawnStartingForces`), the saved game (`aiHero` of a side)
and the network start message (`sides[i].aiHero`, `mphost.lua` / `mpjoin.lua`). An unset level / class keeps openwbc3's own rule
(the local hero's level, a class from side and race). Check: `--show skirmish:ai`, `--show aihero:set`, `--show skirmish:aihero
--at 3 "..."`, selftest "ai hero: ...".
