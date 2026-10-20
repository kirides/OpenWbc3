# Heroes, items and menus

Hero numbers are the original game's unless marked **own**. Sources: the game binary (the hero stat function that
fills the hero's abilities, the attribute bonus function, the skill effect function, the experience table and the
class tables, all read with Ghidra), also for kills (the army and building death routines `FUN_005210b0` /
`FUN_0052b3e0`), potions (`FUN_00561d80` / `FUN_00561c30`) and regeneration (`FUN_0051b460`). Where earlier openwbc3
numbers differed in a few tuned values (base life, armour, strength bonuses, skill effects) the binary's value is used.
Everything is in `game/src/game/hero.lua`, `classes.lua` and `items.lua`.

## Attributes, abilities, skills

Attributes: Strength, Dexterity, Intelligence, Charisma. A new hero has `5 + race modifier + class modifier` of each
(`classes.lua`; the modifier tables are the ones `FUN_0054c0a0` builds for the hero creation, checked against the
binary). Every level gives 1 attribute point and 1 skill point (the level gain `FUN_00455b40`). Level cap 999 (the same
function stops there).

| ability | value (binary: hero stat function, attribute bonus function) |
|---|---|
| Combat | 4 + Str + 3 per Ferocity + items |
| Health | class base life + (level-1) x class life per level + 3 Str + 10 per Constitution |
| Damage | 20 + Str + items (slashing) |
| Speed | 8 + (Dex+1)/2 + Running + items |
| Armour | class base armour + Dex/2 + 5 per Armorer + items |
| Resistance | Dex + Warding + items |
| Mana | class base mana + 3 Int + 10 per Lore; a battle starts with a tenth of it |
| Attack speed | min(2 Dex - 10, 60) percent faster |
| Morale | Cha/2 + Leadership + Blessing + items; half of it is added to the army limit (`FUN_005268c0`, read by the side's army limit `FUN_00533dc0`); troops attack every `max(500, 1500 - 10 x morale)` ms |
| Command radius | 5 + Cha + items (the hero placement `FUN_0043b550`, the command getter `FUN_005267b0`; at most 19 for spells and conversion) |
| Command radius bonus | troops of the side and its allies within the radius (checked once a second, at most 19) get +4 combat and +2 speed (half for undead) and the ECM0 cell 0 icon (own side only); fear / awe cancel it, leaving the radius keeps it `max(1, hero morale)` seconds (`FUN_00532a20`, `FUN_0051bd10`, `FUN_0051c460`; `game/morale.lua`) |
| Discount | -5 + Cha + Merchant (+ items) percent; price factor = 100 / (100 + discount) |

Class tables (base life 150-240, life per level 1-4, base armour 0-10, base mana 5-20) are in `classes.lua`.
Heroes have no base resistance from their class in the binary; the unit record's armour/resistance is not used.

Skills (`FUN_0054c620`, binary; tables in `classes.lua`): a hero has up to 10 skills, 5 from its race and 5 from
its class, each with a level from which it can be raised and a starting level (merged when both lists contain the
same skill: availabilities take the earlier, levels add up, +2). Skill names are Game.txt 760 + id - 1. Each level
gives one skill point; a skill can be raised when the hero's level reaches its availability, there is no cap.
The magic spheres are skills too (casting skill, `docs/spells.md`): the race and class skill lists are the only source
of spheres. Effect per level (skill effect function): Ferocity +3 Combat, Constitution +10 Life, Running +1 Speed,
Lore +10 Mana, Regeneration +20 % life regeneration, Energy +5 % mana regeneration, Ritual +5 % casting chance,
Leadership +1 Morale (not command), Merchant +1 discount, Invulnerability +2 Armour, Armorer +5 against piercing,
Warding +1 Resistance for every unit of the side; the other skills are described under "Skill effects" below (the per
level values there are the binary's, the numbers in this paragraph are older). Heroes saved with the earlier openwbc3 skill set are converted (what has no place becomes
skill points).

Regeneration (life: `FUN_0051b460`, binary): `1 + Str/3` life points per 20 s (+20 % per Regeneration level, + item
percentage); mana: `2 + Int/10` points per 20 s at `100 + 5 x Energy + Enervate` percent. Conversion time follows the hero's rating
`8 + level/2` through the original table (39 s at level 1 down to 5 s).

## Experience

Total experience for level n: the original table (level 2 needs 10, 3: 50, 4: 100, 5: 200, 6: 400, ... 51: 70000), then
4000 more for every level above 51 (`FUN_00409ef0` in the binary, table at `0x00607070`). Kills
(the army death `FUN_005210b0`): a slain unit is worth 1, a slain hero its level + 1 (at least 5), a destroyed building 3 (4 if
it can attack, the building death `FUN_0052b3e0`); the killer's side's hero gets the full amount wherever it is (no sharing
radius, no halving). When a battle ends every used side's hero also gets the end-of-battle amount (map size, victory,
quests, kills ... - `src/game/battlexp.lua`, rules in `docs/implemented.md`). The original gains a level during the battle too, but only one
at a time (binary `FUN_004d60f0`: with experience for the next level and the level-up latch clear it adds a level, an attribute
and a skill point and sets the latch, which the level-up dialog's Accept clears when no points are left); the rest is counted
when the results screen is built and given with Continue, followed by the level-up screens (`docs/implemented.md`
"End-of-battle experience and the victory screen"). openwbc3 does the same for a human side's hero (`Hero:checkLevel`,
`levelsDue`, `applyLevels`); computer heroes level at once. Level-ups play `HeroLevelUp.wav` and make the portrait glow; right-click it (or
press `L`) to spend points. Computer heroes spend them automatically.

The evil dragon's breath (missile `EMF4`, binary `FUN_00527ed0`, `docs/implemented.md` "Missile flight") drains 10 experience from every
army it hurts and leaves alive: a hero's experience falls by 10 (at least 0), its level stays, so it can stand below its level's start
(saved with the hero as `drained`; `Hero.new` otherwise lifts the experience to the level's start).

The player's hero is kept between skirmishes in the save directory (`heroes/raceNN.lua`; its retinue and graveyard are fields
of the hero record, see "Army setup").
A hero that dies is saved at the start of its level. A level-up heals the hero fully (binary). Computer heroes
get a class from their side and race (**own**, the original picks at random) and spend their points in list order.

**Resurrection** is not part of the original game. It is an option of the skirmish picker
(key `R`, off by default) and is never available in campaign battles: a keep then lists
the hero for 100 + 50 x level gold (**own** numbers). It comes back as the avatar the player chose for the hero
(not the race's default unit) and with its voice set.

## Items

`English/Items.xcr/Items.xml` (225 usable items). The icon row is the slot:
Sword, Staff, Armor, Necklace, Shield, Ring (two), Crown, Helm, Banner, Boots, Charm.
Pictures come from `Items.bmp` (70x110 cells from x = 70, row r at y = 110 r).

Applied powers: combat, speed, slow, armor, resistance, morale, command, damage of any type
(flat, whatever the hero's weapon), attack speed, life regeneration, vampirism, critical hit
chance, fire/cold/electricity/magic resistance (percent of that damage type ignored).
Spell powers and `hero skill` powers are only listed in the tooltip for now.

Sources: chests (`ITMH` records, campaign scenarios) and lair bosses (the boss a destroyed lair leaves,
spawned by `FUN_00404cf0` and named `_L@1R8055_`, which the army-produced message handler `FUN_004a49e0` recognises,
drops one random item when killed). Ordinary neutral creatures drop nothing (the earlier
openwbc3 chance of `0.1 + hits/1500` was invented). The original also makes a dead hero drop its backpack
(network message 408, `FUN_004a87f0`) - not implemented; the original hero has 7 worn slots (crown/helm, armour/necklace, sword/staff, shield/banner, two ring/charm, boots) and
a 4-item backpack (11 item places in all), as here. A hero standing next to an
item takes it: worn when the slot is free, otherwise into the backpack. The hero
dialog (`I`, or the shield button of the panel) wears, takes off (left click) and drops
(right click) items.

Item spells: a worn item's "cast spell" power (Items.xml `<Power type="cast spell" data=spell chance level>`) fires when the
hero strikes in melee (d100 below the chance, the hero not recovering from a cast), at the power's level, free of mana; see
`implemented.md` "Item spells". Computer heroes start with random items (`implemented.md` "Computer hero items").

## Potions

Every hero starts a battle with 4 health and 4 mana potions (binary: hero stat function; the shop sells up to 9).
Potions are battle state, not hero-profile state: they live on the hero unit and are kept in a save game's unit record,
so loading a saved battle restores whatever counts it held. The health potion (`FUN_00561d80`) heals `50 + 10 x keep level` life points, the mana potion (`FUN_00561c30`) restores
`10 + 5 x keep level` mana (keep level 0 without a keep, 1 for a keep ... 5). Drink them with `H` / `J` or by clicking
the flasks beside "Backpack" in the hero dialog's Items tab; a potion is not used up when it would be wasted
(full life / mana - **own** convenience).

## Army setup

Before a skirmish, multiplayer or campaign battle the army setup screen (`screens/armysetup.lua`) lets the player
spend the battle's army setup points on regular troops (the race's ordinary troops, cost = the unit's
setup points) and choose which retinue members come along (cost = type points + a level table); those left out stay in
the retinue. After the battle the same screen offers recruits. The retinue has `min(Charisma / 4, 7) + 1` slots; the
Charisma bonus line "+n Retinue Slots" of the Stats tab is the `Charisma / 4` part. All of it is in `docs/implemented.md`
"Retinue in every game type" (the profile stores `rec.retinue` / `rec.graveyard` in `heroes/<id>.lua`).

## Hero info panel

`screens/heroinfo.lua` (`PNL_HEROINFO`) has the original's six tabs: Stats, Combat, Skills, Titles, Retinue, Items. It
opens in a battle and, read-only, from "More Info..." of the hero selection. `game/herobonus.lua` holds what the Stats tab
prints: the lines are Game.txt [0679]..[0695] and the formulas reproduce every value of an original screenshot (Str 8, Dex 4,
Int 3, Cha 6); the original prints +5 life per Strength and a command radius of 6 + Cha/4, which is *not* what openwbc3's
battles use (see the table above). Titles: the eight categories and their thresholds are the table at 0x00614a84 of the
binary, names are Game.txt [0936]..[1096]; only "Battles Fought" is counted so far, the other counters stay 0. Retinue lists
the hero's retinue (slots enabled by Charisma, checked in the binary: `FUN_0040b130`).
"Freeze your hero's level" is saved with the hero and stops experience (original: a flag of the hero record). Own additions: item icons
and tooltips on the Items tab; Combat shows one armour value for all three damage types.

Load Game (hero selection and battle) lists only the saves made with the active hero; saves record the hero's id.

## Menus

* `Esc` in battle: menu (resume, hero, options, leave battle); `P` pauses.
* Options (also from the main menu): music / effects / voice volume, scroll speed, full
  screen. Stored in `openwbc3.ini` in the save directory.
* Dialogs are built from the original `PNL_HEROINFO`, `PNL_HEROLEVELUP_STATS/SKILLS` and
  `PNL_OKAYCANCEL` panels. `love game --panel PNL_NAME --dump --shot f.png` shows any panel.

## Building repair

Taken from the original (the repair dialog, vtable `0x005eaabc`, its costs `FUN_0056cb60`, the building repair
`FUN_0052eb10` / `FUN_0052ebc0`, the computer's repairs `FUN_004fffe0`):

* Orcs cannot repair. Other races get a repair button (`E`) on their own damaged, finished buildings; the dialog
  offers slow (`S`) and fast (`F`) repairs, only one repair per building at a time.
* Cost per resource = missing % of the building's build cost / 2 (at least 5 of every resource the building costs);
  fast repair costs twice that. Slow takes 90 s, fast 45 s. The cost is paid up front; the hits come back in step with
  the elapsed time.
* Computer players repair for free with the fast option: a check every 20 s (knights act on 1 in 10 checks, lords on
  1 in 4) repairs one building at 62.5 % hits or less, after more than 10 idle checks every building at 81.25 % or less.
* Not implemented: the Masonry power-up (halves the cost) - openwbc3 has no power-ups.

## Diplomacy (resource gifts)

`Alt+D` opens the original diplomacy dialog (`FUN_00558810`, sending `FUN_00559690`): pick 50-500 of gold, metal, stone or crystal
and another side and send it. The giver pays, the receiver gets it up to the keep cap. Not available in the tutorial or
after the battle is over. (Despite its name the original dialog does not change alliances; teams are fixed per game.)

## Power-ups

Production items starting with `P` (252 of them, about 40 per race) are permanent upgrades. Their cost and research
time, the order of each race's list (the picture index in `Powerups<Race>.bmp`) and the army statistic bonuses come
from the original game's binary and are in `src/game/powerupdata.lua`; names and descriptions come from `Help.cfg`.
`src/game/powerups.lua` holds the rules:

* bought once; a family (`PCR0`..`PCR4`) in order; cost paid when the research starts
* army bonuses (combat, armor, speed, damage, range) add to every unit of the listed types of the side
  (a number instead of the list is a mask of army type flags from the Army.cfg status string)
* implemented elsewhere: Horde / Supply (army limit), Income / Hard Labor (per mine), Engineering (25 % faster
  building, 25 % more hits), Masonry (half repair cost), Eagle Eye / Daemonic Sight (view range), Farseeing,
  Jihad / Spare Parts / Summoning / Fame / Incubation (unit cost and time), armour power-ups (Mithril, Armorer ...), Trade
* effects the original handles inside its army, hero and combat rules (not all traced in the 1.04 binary yet;
  `powerups.level` is the level the original's power-up test `FUN_00437f70` returns, the highest owned member of a
  family + 1):
  * hero: Courage (3 / 6 / 9), Order of the Lion (+2) and Warmth (+5) morale (also the troops' attack speed when the hero is
    dead, `FUN_0040dc80`), Black Ward resistance +3 per level (heroes and plain units), Dark Lord command +8, Meditation
    casting chance +10 per level, Summon Mana and Healing regeneration 100 / 150 / 200 / 300 ... % (the skill percentages are
    added to it), Holy Relic conversion time x 3/4 (heroes and generals; the Dryad and, with Bronze General, the Bronze Golem
    general always / likewise), Crusade +1 XP per level for every army the hero kills itself, Order of the Grail doubles the
    20 XP of a completed quest (the XP of a quest was missing before)
  * combat: Flaming Arrows (ranged piercing attacks of plain units except Ballista, Barbarian, Sprite and Scorpion hit as
    piercing plus half the damage as fire), Faerie Fire (pixies hit with fire), Doombat (+50 fire armour, strong against fire for
    the Firebat), Paladin (knights x2), Grand Paladin (knights x3 against undead), Fallen Knight (Slayer / Doom Knight x3 against
    humans), Torture (Slayer / Doom Knight x2), Dragon Knight (high elf cavalry x (level + 1) against dragons), Cowards (orcs x2
    against missile troops of that side), Hunting (the shooter's side ignores missile resistance), No Pain / Deflection (orcs /
    chameleons resist missiles: a sixteenth of the damage), Dark Bolt / Flaming Arrows missile pictures; the melee modifiers
    are the original's (before the hit multiplier), only for plain attackers
  * assassins, gnolls and wasps kill outright on a melee hit when the hit roll is at or below 4 % (+3 Dark Order, +3 Blood
    Potion; hero targets lower it by half their level, critters are immune); vampires heal 3 per hit, giant bats 2 with Vampire Bats
  * not implemented yet: the special abilities of buildings that need a power-up (Slave Horde, Brood, Rites of Dawn,
    Storm Call, ... in `buildingabilities.lua`)
* damage types in the type records are 0 piercing, 1 ice, 2 electricity, 3 fire, 4 magic, 5 crushing, 6 slashing (data
  checked: Frost Dragon 1, Storm Dragon 2, Fire Elemental 3). Fire breathing / ice floe and the element resistances of items
  used the wrong numbers before; spells and status effects keep their own numbering (fire 1, ice 2, electricity 3) and
  `unit.lua` converts
* computer players buy power-ups through their resource list (`aiplan.lua`, `docs/implemented.md` "Computer players", which also covers the research / mercenary / quest ones the original's list keeps buying): a timed free power-up (one every 60..300 s by the last `[DEPENDENCIES]` column) is not in the 1.04 binary (its think step `FUN_004fa120` calls no such routine), so the old openwbc3 model was removed. The computer pays real cost and research time; the list takes the first researchable power-up in file order, priority 50 or the script's value

Per-race cost / time / statistic overrides of `Building.cfg [RULES]` are applied to production and units.

## Attitudes, orders

* Attitudes (`Ctrl+right click`, the attitude button, `Ctrl+F` = default): names and descriptions are the original's
  (Game.txt). The behaviour comes from the original's rule tables (set up by `FUN_00506c40`;
  `src/game/attitude.lua`, see `docs/implemented.md` "Attitudes as a rule engine"): every attitude has an active area of
  20 cells around the guard point, enemies are looked for in a box of max(12, own range) cells; Defensive only fights
  inside the active area and returns, Standard fights anything in the box and returns, Aggressive never returns,
  Rampant / Scout wander to random places anywhere on the map (Scout never fights), Stand Ground only hits what is in
  attack range, Cowardly runs from whoever hit it (4 + 4 cells away) and from enemies within 5 cells, and returns to the
  guard point when nothing threatens it. New armies and heroes start Defensive (builder types Cowardly), also the neutral ones, which fight on their own; units look at their attitude once per 250 ms slice, not at once when hit. Custom attitudes (`CustomUnitAI/*.uai`) are listed after these. Not original:
  no 30 % gate on new random moves is kept. Buildings that produce units hand their attitude on to them. Guardian /
  Magic Guardian (follow a designated unit, 20 / 5 cell hysteresis) are covered by the Guard order.
* Orders: `Shift` queues, `Alt` interrupts, `P` patrols between points (shift adds points) and fights what comes
  near, `G` guards a friendly unit, `Esc` stops, `Shift+Esc` / `End` drop queued orders. Orders in the queue are not
  saved.

## Building abilities

`src/game/buildingabilities.lua` (after the building buttons of `FUN_004d2300` and their handlers, checked in the 1.04
binary): the extra command buttons of some buildings - Trade (Market, Quartermaster, Mill, Trading Post, Hostel, Trader,
Merchant for their races or anyone with the Trade power-up, `FUN_004d07e0`; the trade dialog with 50 % rate), Slave Horde
(Reformatory, Prison, Cage: up to 10 slaves for 25 gold each, `0x004d0c50`), Brood (Summoning Tower: up to 8 quasits
for 30 gold, `0x004d0e50`; both once every 3 s), Rites of Dawn (40 crystal, `0x004d11b0`), Dark Citadel (100,
`0x004d1300`) and Storm Call (80, `0x004d18a0`) for the weather, Holy Word 200 crystal (`0x004d1a00` / `FUN_004d1ef0`),
Chaos Plague 1000 crystal (`0x004d1ae0` / `FUN_004d20b0`), Sword of Sirian 200 crystal (`0x004d1bc0` / `FUN_004d2130`),
Famine 500 crystal (`0x004d1c60`; the button only appears once Famine is bought, `FUN_004d06d0`), Elcor's Balm 400
crystal (`0x004d1e10` / `FUN_004d2030`, which takes 300 from a computer side), Summon Wraith 125 / Shadow 250 crystal
(`0x004d1680` / `0x004d1460`), Couatl's Wrath 750 gold (`0x004d1d70` / `FUN_004d2190`) and the Undead / Dark Elf
gravestone morph (free, key `G`, `FUN_004ceee0`). Each handler asks for the price it then takes (the resource message
0x1fe, applied by `FUN_0043eb80`; the side record's gold / metal / crystal / stone are `0x00708fb4` / `fb6` / `fb8` /
`fba`, named by the "need more" lines of the build step `FUN_00524450`); the one-shots and the summons have a one-second
timer that a press arms before the price is checked, Famine takes its crystals also when no mine is found. The buttons are
greyed until the power-up is bought (Slave Horde, Brood and the gravestone also while the army is full; for the weather,
until it makes sense); none is greyed for the price. Computer players use Holy Word (200 crystal), Wrath (750 gold), Chaos
Plague (1000 crystal), Famine (700 crystal, cast without paying, `FUN_005019d0`), Elcor's Balm (Healer, 400 crystal, pays
300) and Rites of Dawn like the computer's ability sweep `FUN_005001d0` / `FUN_00500830` (once a second per side, one
ability per sweep). The special-ability keys of `KeyMap.txt` (`FUN_00427f70` -> `FUN_00426350`, `src/game/abilitykeys.lua`)
ask the same prices without the button timer or target check, find the building in the selection or anywhere on the map
(Holy Word only a `BPCA`) and cast Chaos Plague, Couatl's Wrath and Sword of Sirian without taking anything (see
`docs/implemented.md`, "Hot keys").

## Skill effects (`src/game/heroskills.lua`)

The per-level effect of every skill is the table of the 1.04 binary (`FUN_00556ea0`, e.g.
Constitution 10, Slayers 10, Lords 2, Engineer 20). Done: items add skill levels ("hero skill" powers), Wealth /
Quarrying / Smelting / Gemcutting (per income, only while the hero lives), Trade (50 + effect, max 90), Engineer (extra
hits for new buildings, binary adds the effect directly), Contamination (disease lasts 15 s longer per point, all heroes),
the racial morale lords, Warding (every unit of the side), the complete armour per damage type (Armorer piercing, Scales
slashing, Thick Hide crushing, the resistance skills; melee / missile damage now uses it, resist spells and item
resistances are flat armour as in the original), Potionmaster (extra mana potions at the start, binary `FUN_0054fd50`; it does
not make potions stronger in 1.04) and the skill help texts (Game.txt templates named by `FUN_00556fc0`).
Troop-XP lords (`Eco:initialXp`, binary `FUN_00557d90`, the starting experience of a new army; the production call
passes training and lords): a produced unit starts with the effect of the lord skill that names it, while the side's
hero lives - Brewmaster dwarves, Slimemaster `AGSL`, Griffonmaster `AARI`, Runic Lore `ADOX`, Memories `AUIX`, Undead
Legion `AUCX`, Barbarian King `ABIX` / `ABCX` / `ABEX`, Taming monsters (flag 0x800), Guildmaster `AKJX`, Knight
Protector `AHFX` / `AHDX` / `AHEX`, Guardian Oak `AWJX` / `AWKX`, Elemental Lore `AAEF` / `AAEE` / `AAEW` / `AAEA`, Mage
King `AHGR` / `AHGW` / `AHGB`, Gate daemons (0x800000), Dragonmaster dragons (0x1000), All-Seeing Eye `AGSP` / `AGGZ` /
`AGFL` / `AAEY`, Golem Master `AAIX` / `AAJX` / `AAGX`. The Gate power-up (`PGAX`, 20 per level) is added to the
experience of the armies summoned by the spells (`FUN_00557d90` called with lords and Gate but no training; the
per-spell part is in "Summoning spells: experience of the new armies" below).

Rune skills (`Eco:runeHits`, binary `FUN_0043bfb0`, the unit-creation function): the produced unit gets effect percent of
its hits on top (current and maximum), each rune on the hits so far, only while the side's hero lives: Life Rune the
Unicorn `AEDX`, Death Rune the Assassin `AKJX`, Sky Rune every flier (0x200000), Forest Rune the Treants `AWJX` / `AWKX`,
Arcane Rune `AENX` / `AWNX` / `AKNX` (5 % per level).

Melee skills (`heroMeleeBonus` in `Unit:strike`, binary `FUN_0042ace0`, the melee combat routine): only a hero attacker
reads them (other troops get no slayer bonus; Reave and Thievery are not read there). They add to the base damage after
the power-up factors and before the hit type's multiplier: Manslayer vs humans (flag 0x1), Deathslayer undead (0x4),
Dragonslayer dragons (0x1000), Daemonslayer daemons (0x800000), Dwarfslayer dwarves (0x2), Elfslayer the three elf races
(0x38), Orcslayer orcs (0x100), Smite Good / Evil good / evil targets (0x2000000 / 0x8000000), Serpentslayer Ssrathi
(0x1000000), Beastslayer monsters (0x800), Bullslayer Minotaurs (0x80), Trample small targets (0x20000000), Demolition
buildings. Ignore Armor takes its effect off the armour value and 5 percent per point off the 50 percent a strong armour
absorbs (at most 50). Weaponmaster adds its effect to the critical-hit threshold (with the "critical hit" items).

Hero combat: Mighty Blow (skill 34) adds its effect to the hero's damage (the army damage getter `0x00526310`, its hero
part from `0x00526540`: item effect 23, then the skill, then the weapon item's powers, whose last damage power also sets
the damage type; see `implemented.md` "Hero weapon"), Vampirism skill + items heal per hit (`FUN_00526f40`), Assassin
(`FUN_00526e70`) is the skill's effect (4 + level) plus assassin items for a hero and 4 (7 with Dark Order, +3 Blood
Potion) plus the army level for a plain assassin, gnoll or wasp, Leech (`FUN_00526de0`, read by the army death
`FUN_005210b0`; the 1 s interval is not traced in the 1.04 binary yet) gives its effect in mana when the hero kills a
non-critter army of another side, together with the Mana Leech spell, at most once a second. Shadow Strength adds its
effect to the hero's combat at night (`FUN_0051bd10`; the other day / night combat modifiers are in `weather.lua`, see
`implemented.md` "Weather"). Not verified: where Leech and Vampirism apply (the callers `FUN_005210b0` / `FUN_00522860`
were not read in detail).

## Skills the binary never reads

Every read of a hero skill in the 1.04 binary goes through two functions: `FUN_00556ab0` (the hero record, used by the hero
info screens `FUN_00551410` / `FUN_005504c0` / `FUN_00550560` / `FUN_00551b20`) and `FUN_00556b50(side, skill, mode, alive)`
(the side's copy at 0x00709200 plus the items' "hero skill" powers, `FUN_00402e30`); the copy itself is only touched by
`FUN_0054fd50` / `FUN_004a4230` (network sync), the sphere check `FUN_00503b50` and the hero screen. Every caller of
`FUN_00556b50`, `FUN_00556ab0` and the effect function `FUN_00556ea0` was read: the ids passed are 1 .. 0x65 and nothing else.

* **Swiftness (102), Fire Missile (103), Magic Time (104), Thievery (105), Diplomacy (106)** do not exist in 1.04: the effect
  function has no case above 0x65, the help function `FUN_00556fc0` ends at 0x65 (the default branch prints nothing), and the
  skill name is Game.txt `759 + id`, which for 102 and above is an unrelated text. They are not in the 1.04 game
  and are not implemented (`docs/todo/not-in-original.md`). The Diplomacy skill does not
  add army setup points either (`FUN_00440b40`).
* **Reave (45)** exists (effect 5 per level, help string 626) but is read by no function: the melee function
  `FUN_0042ace0` reads 0x21 .. 0x32 except 0x22 and 0x2d. It only shows its help text.
* Other readers (ids only, for later work): Leadership 8 `FUN_005269a0`, Merchant 9 `FUN_00526cf0`, Warding 0x18 `FUN_00526b70`,
  Elcor's Aura 0x3c (the `FUN_0057b090` / `FUN_0057b1a0` / `FUN_0057b560` / `FUN_0057b9d0` message builders), Trade 0x3b
  `FUN_004d1090`, Engineer 0x42 `FUN_0043bd50`, Contamination 0x65 `FUN_0040d9b0`, the income skills 0x37 .. 0x3a `FUN_00531f10`, the
  rune research cost cuts 0x3d .. 0x41 in `FUN_0040b6b0` (done in `powerups.lua`, `RUNE_SKILL`).

## Summoning spells: experience of the new armies

The summon spell functions of the binary (one per spell: `FUN_0057e010` ... `FUN_0057f630`, `FUN_005756b0`, ...) start
every summoned army with the starting experience of a new army (`FUN_00557d90`, called with training off, lords and the
Gate power-up on, so the lord skills that name the unit and 20 XP per level of `PGAX`) plus an own amount per spell
level above the first. The old openwbc3 only did that for the Golem (spell 63); `spells.summonXp` does it for every
summon spell the binary passes the Gate flag to:

| per level above the first | spells (unit code) |
|---|---|
| 0 | `AVBX` (10), `AVIX` (17), Create Firebomb `AASX`, Goblin Horde `AOSX`, Summon Blades `AHLX`, `AAWA` (102) |
| 5 | `AUBX` (41), `AUIX` (40) |
| 20 | `AAIM` (14), `AASP` (20), `AEDX` (24), `AWJX` (27), `AUXX` (37, Raise Champion), `AUJX` (43), Call the Dead `AUIX` (47), Golem `AAIX` (63), `AAGX` (68), `ALGX` (107), Spiders `AKLX` / `AKKX` (109, 8 each), the random Mage King `AHGR/W/B` (116), Summon Bats `AABA`, Summon Spiders `AKLX` |
| 50 | `AADE` (19), Fire / Earth Elementals `AAEF` (58), `AAEE` (79), Summon Elemental (29) |

Arcane Elementals `AAEY` (15) start with the lords and Gate experience plus the Gate power-up's 20 per level a second time (the
function adds `PGAX * 20` to the value that already contains it). Spectral Horde / Dragonfear (34, 35) and the armies the
production buildings make do not pass the Gate flag. The lord, Gate and per-level amounts are the binary's; which unit code each
openwbc3 spell number maps to follows `spells.lua`.
