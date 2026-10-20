# Spells

The original game stores the names and descriptions of its 130 hero spells in
`<Lang>/Spells.txt` (13 spheres of 10). The numbers behind them are in the engine; the ones marked **verified** follow
the original (checked in the 1.04 binary where an address is named; the rest is not traced in the 1.04 binary yet).
Anything else is **own** (openwbc3's choice, kept clearly labelled).

- **Id** = sphere * 10 + index (0..9). Spheres: Healing, Summoning, Nature, Illusion,
  Necromancy, Pyromancy, Alchemy, Runes, Ice, Chaos, Poison, Divination, Arcane.
- **Casting skill**: there are no spell points. The spheres are hero skills (ids 10..22 in the order Healing ...
  Arcane); a hero has the magic skills of its race and class (`classes.skillList`, `docs/hero.md`) and raises them with
  the skill points of its levels. The casting skill of a sphere is that skill's level (+1 per Learn Spell or research, side-wide for the battle: `powerups.research`); spell `i`
  is castable while the skill is above `i` (verified, `FUN_0040aae0`; skill lists from `FUN_0054c620`
  in the binary). Open the spell book with `K`.
- **Mana cost**: per-spell table (`M.COST`, 130 values) - verified in the 1.04 binary: the table of 130 words at `0x61b3b0`
  (read by the cost function `FUN_00529fa0`, the cast dispatcher `FUN_005777a0` and nothing else), by spell slot. It
  differs from the table openwbc3 used before in 13 slots; the binary is followed:
  Summon Quasit 12 -> 10, Circle of Power 6 -> 4, Phantom Steed 10 -> 5, Summon Imp 10 -> 14, Gemberry 10 -> 12, Summon Treant
  38 -> 40, Scare 14 -> 6, Awe 16 -> 8, Call Shadow 35 -> 30, Raise Skeleton 10 -> 8, Raise Zombie 10 -> 8, Transmute 22 -> 15,
  Learn Spell (slot 97) 45 -> 55. The slot order of the binary is the order of `Spells.txt` (checked by name for sphere 1). The
  troops' spells (-3..-1) and the extra slots 130 / 131 / 150 / 151 read zeros before / after the table: no mana.
  The cost of a cast (`FUN_00529fa0`): `table * max(25, 100 - discount) / 100` in integer maths, the discount being the army's
  best "mana discount" spell effect (Mana Flow: power `0x24`, value 25, `FUN_00576250`) plus, for a hero, the worn items'
  "mana discount" powers (`FUN_0040c380(side, 0x24)`: first 3 powers of the 7 worn items, doubled by Spellforge,
  zero while another side's Disjunction runs, plus the campaign bonus of the same type - Global.bon has none). There are no
  hero level or skill modifiers. The mana a cast takes (`FUN_005777a0`) is at least 1, and 0 for an item spell; a hero casts from
  the book only when its mana is not below the cost (`FUN_005717e0`).
- **Success level** (the original's "result"): verified in the binary (`FUN_0040aae0` with the roll loop of
  `FUN_005717e0`).
  Level = skill/10 + 1 (one lower when skill%10 <= index; the spell is castable while index < skill). Chance = `50 - 50*(level-1) + 3*Intelligence` +
  Concentration (15 + 5 per level) + the Ritual skill (5 % per level) + Gem of Wisdom (10 + 10 per level, until the
  next cast) + 50 for computer players, at most 100. A failed d100 roll lowers the level by one and adds 50 to the chance; level 0 fizzles. The mana
  is spent either way.
- **Recovery**: after a cast a hero cannot cast for `1000 + max(5, cost) * (index+1) * 10 + 100 * result`
  ms (verified in the binary, `FUN_005777a0`: `10 * (max(5, table cost) * (index + 1) + 2 * (5 * result + 50))`;
  the undiscounted table cost counts). A fizzle is sent with the result -1 (`FUN_005717e0`: the roll loop falls out with -1), so it
  recovers 100 ms less than the 1000 ms base. The mana is spent either way.
- **Casting**: the spell book (`K`, after the original's spell book `FUN_0056f910`: click a spell or press `1`..`0`), a click on the spell bar above the panel (openwbc3's own, off unless Options > Graphics > Spell bar is on; mouse wheel pages), or the hot keys `F1`..`F8`. A hot key is given in the book: hover a known spell and press `F1`..`F8` (`FUN_004258a0`: a spell sits on one key at most; stored with the hero, `shortcuts`). An unassigned key does nothing. The original has eight keys (the eight slots of `FUN_004258a0`), not twelve; `F9`/`F10` stay the fog / grid toggles.
  Spells that need a target (Blink, Pillar of Fire, Transform, Wall of Thorns/Ice) ask for
  a click. The hero casts as soon as it stands still.
- **Radius** of area spells is the command radius, at most 19 (verified, `FUN_00529ea0`); the Command spell adds 25 %
  per level, a few spells add 50 % per success level above the first. The command radius is `5 + Charisma + items`
  (`FUN_0043b550` / `FUN_005267b0`, binary; the `6 + min(Cha/4, 13)` of the bonus formulas `FUN_0054a720` is only in the
  hero help text). The area is a circle of cells and a cast hits at most 24 targets, taken row by row from the top
  (`FUN_004aa840`).
- **Durations** (the `spell.duration` setting): the 1.04 binary's duration function (`FUN_005199e0`, called with
  success level - 1) has eight classes: 0 normal 60 s (+60 a level), 1 very short 5 (+5), 2 / 5 building / arcane 120
  (+60), 3 tower 600 (+120), 4 wall 600 (+600), 6 short 30 (+30), 7 long 120 (+120); its army version (`0x00529f30`)
  adds the Extend power (0x23) and the items' percentage. Which class a spell uses is read from its cast function (the
  argument of the army vtable call `+0x68`). Extend adds 100 % (`FUN_00576150`).
- **Summons are permanent**: the summon message's lifetime (`+0x89`, made the army's end time by `FUN_004a49e0` only
  when not 0) is 0 in every summon routine except the Eye of Oros (class 6: 30 s a result level), Spectral Horde and
  Dragonfear (class 7). Summon Guardian's tower lasts (result + 4) x 120 s (`FUN_005759b0`).
- **Empower** raises damage and healing by `25 + 25*level` percent (`FUN_00576630`, `FUN_0040dd50`).
- Computer heroes learn spells and cast healing, attack, summon and buff spells in battle (never the four-choice spells, see below).

## Effect values (success level `r`; the spell functions behind `FUN_005777a0`, not every value traced in the 1.04 binary yet)

Healing: Heal Self 50r; Cure cures poison and disease + 10r; Blessing morale 1+r (troops attack faster, army limit);
White Ward resistance 5r (not evil); Heal Group 50r; Invigorate speed min(5, 1+r), not undead; Purify 30+20r magic
damage to evil enemies and ends rain; Major Healing 100r everywhere + cure; Life Ward long (not stackable);
Resurrection: dead units of the caster's side (every side from level 3, not undead / timed summons) rise as new units
at full hit points on the caster's side.
Summoning: Quasit r, Imp 1, Soulharvest r, Demongate 1, Eye r+1, Phantom Steed speed 1+r, armour/resistance
5r (cavalry, not the caster); a Black Portal / Circle of Power within the command radius gives +1 level to the spells
that use it and the units appear there; Circle of Power is a placed building (`BMCP`, building duration); Blink jumps
to a random cell within the radius; Banish kills extraplanar enemies of a level below 2r unless their owner has the
Binding power-up (binary: `2r`; troops have no level yet, so only heroes can resist).
Summon counts (1.04 binary, the count `+0x99` of each summon routine's message): only Quasit, Succubus, Wasp, Zombie (r),
Skeleton, Eye (r+1) and Spectral Horde (2r+4) grow with the result; Imp, Demongate, Elementalism, Call Shadow, Wight, Raise
Champion and the other summons make one army (or their fixed number), the result only adds experience. The host makes the armies
one by one and stops as soon as the side's army count reaches its limit (`FUN_004aa840` case 6).
Nature: Gemberry 25r (+ cure from r 2), Entangle -(2+2r) speed 30 s on land units, Shillelagh +5r combat, Call
Lightning 40+20r electricity on every enemy in range (max 24, no rain bonus), Wall of Thorns a placed building
(`BWBR`, 600 s x r), Treant, Unicorn, Elementalism 1, Sprite (summons stay for good).
Illusion: Shadowform speed r, armour/resistance 5r; Scare 45 s / Awe 30 s psych effects on enemy non-undead troops
without a resistance roll, only the race / drunk / mechanical / titan / critter immunities of `FUN_005286c0`, the slow
races x3 / x2 as long (fight speed -3/5, damage halved / no ranged attack; not a stun; binary, `implemented.md` "Missile accuracy and the Scare / Awe spells"); Spectral Horde 4+2r illusions of the race's
infantry (a quarter of the hit points, combat 1, damage 1, no armour), Dragonfear one illusion dragon; Call Shadow one Shadow; Mutate turns
enemies below level r+1 into neutral animals for good; Transform changes min(15, 3r) friendly troops into one random
type for good.
Necromancy: Skeleton 1+r, Zombie r, Wight 1, Vampirism heals r+1 per hit of melee troops, Strip Flesh turns
enemy infantry (small and medium armies too) below level r+1 into skeletons of their own side for good, Call the Dead turns every corpse in range
(max 24) into a skeleton for good, Ring of Ice 25+25r (radius 7, units and buildings), Black Portal a placed building
(`BMBP`), Raise Champion (one army).
Pyromancy: Hand of Flame 10+10r, Cauterize 25r, Soul Flame gives 5+5r experience to the friendly troops in the command
radius (each army's total raised to at most 10r, `FUN_0057f9e0` / the experience handler of the receiver), Resist Fire 25r %, Ring of Fire 25+25r (radius 6, with buildings),
Firebreathing 5+5r (range 5), Berserker combat 4+r, speed 3+2r (120 s, not the caster), Pillar of Fire 60+40r
(radius 3 around the caster), Armageddon 50+50r, Fire Elemental one permanent unit.
Alchemy: Create Item (items by result: r1 minor+lesser, r2 +major, r3 lesser..artifact, r4 major..set), Transmute
rate 40+10r %, Charm Merchant +2r, Golems / Naga / Wasp / Rock Call / Brew Potion (+r health potions) permanent,
Acquire converts buildings within rm/2, Guardian a placed building (`BWGC`/`BWGS`/`BWGI`, (8+2r) minutes),
Disjunction switches the items of every other side off for 30+30(r-1) s, Spellforge doubles item effects.
Runes: Stoneskin armour 10, Gem of Wisdom 10+10r, Dig buildings 10+10r % faster (max 75), Earthpower 200r (buildings
of the side and allies), Resist Magic 25r %, Doomstones 10+20r (units and buildings), Resist Missiles.
Ice: Hand of Ice 15+10r, Ice Armour 5r, Freeze -(1+r) speed 30 s, Wall of Ice a placed building (`BWIC`), Ice Floe
5+15r (range 12, 30 s), Freeze Magic stops the mana regeneration of every side, Ice Storm 50+50r.
Chaos: the morph spells roll once per cast a number in -3r..3r (not 0) and change the combat / speed / damage / 10 x
hit points of every army in range for good (Morph Tower: one random statistic of towers); Wildfire 50r fire (units and
buildings); none of the Chaos spells sets the original's chaos status (psych effect flag 8 at `+0xBA` of the army; that is the psych effect of the Doom / Slayer Knight auras, see `implemented.md` "Psych auras"); Chaos Plague leaves (53-3r) % hit points (at least 5 %) and gives disease; Drain Mana takes 25+25r from
enemy heroes (the caster gains nothing); Learn Spell +1 casting skill in a random one of the 13 spheres for the whole side and the battle, once whatever the result
(one research step, `FUN_00438180(side, 1)`: the binary's effect `FUN_004ac0e0` case 0x20 has no per-result loop; see `docs/implemented.md` "Power-ups"; the original's Time magic sphere is not in openwbc3).
Poison: Poison is a flag (1 hit point per second, 600 s, see `status.lua`); Immunity prevents poison and disease;
Poison Cloud poisons enemy troops (not heroes); Antidote cures poison and disease; Venom Touch gives friends a
poisoning attack; Poison Gate poisons the armies other sides summon; Spray Poison 30+10r piercing on every enemy in
range; Rot drops poisoned enemies below level r+1 to 1/8 of their hit points; Call of Kargoth 8 queens + 8 spiders.
Divination: lores +10 (both also send the persistent effect EZ65 / EZ66 with the special effect type 100, "at the
base": a looping 4-frame aura sprite at the caster's base for the buff's duration, 50 ms a frame, the frame time not
traced in the 1.04 binary yet), See Invisible 120 s, Telepathy +10r experience to the armies the side produces while its hero
lives (`FUN_0057a9a0`, the training power 3 that `FUN_00557d90` adds), Comprehension 20+5r % (max 50) off power-up costs, True Sight +r view,
Mind Leech gives the friendly troops in the command radius the experience of the army they kill (`FUN_0057ad20`;
the kill bonus is read in the army death `FUN_005210b0`, not traced in detail), Psychic Blast stuns 5 s. Arcane: Concentration +15+5r % chance, Command +25r % radius, Enervate +75+25r % mana
regeneration (added to Energy, not a multiplier), Mana Flow 25 % discount, Empower 25+25r %, Corruption makes
armies other sides summon join the caster with 20+10r %, Dispel (radius with 50 % per level) removes every spell
effect but poison and disease, Destruction, Mana Leech 4+r mana per kill, durations arcane (120 s).

Weather spells (Purify, Change Weather, Light / Darkness, Darkstorm, Storm) send the original's weather kinds, see
`implemented.md` "Weather". There is no rain penalty for fire spells in the 1.04 binary.
**Four-choice spells** (checked in the 1.04 binary): Change Weather, Elementalism and Raise Champion do not cast at once; the
cast routine `FUN_005717e0` opens the four-picture dialog `FUN_0055bc90` (`screens/spellchoice.lua`: sprite `EMD4`, the spell's
name as title, Cancel `EMDC`) with the pictures and texts of the spell's table (0x61b4b8 / 0x61b4f8 / 0x61b538; texts
`[SPELL_DLG_TEXT_00..11]` of Spells.txt, `FUN_0056f490`): the weathers 0..3 (`EWTH` frames 0..3), the elementals Air `AAEA`,
Earth `AAEE`, Fire `AAEF`, Water `AAEW` (`FUN_0057dd20`), the champions Shadow `AUXX`, Lich `AUMX`, Vampire `AUGX`, Doom Knight
`AUAX` (`FUN_0057ea70`). All four are always offered (the table's enable bytes are all set), whatever the sphere or the hero's
level. The pick goes out with the cast (the message's +0x18, the dispatcher's cast record +0xc; in openwbc3 the cast command's
`target.choice`, 0..3); Cancel or Escape sends nothing, so no mana is spent. The computer never casts the three: they are not in
its spell lists (`FUN_00502ed0`). Still **own** (labelled in `spells.lua`): a cast without a choice (an item's spell power)
takes the first entry, Transmute / Morph Resources choose the traded resources themselves, Rune Item (the original offers four
fixed items). Not implemented: Time magic. The damage spells that are missiles in the
original (Purify, Hand of Flame, Hand of Ice, Ice Storm, Doomstones, Wildfire, Spray Poison, Multi-Target) are real missiles
that fly to their targets (`missiles.lua`, `implemented.md` "Missile flight"): one d100 per cast against the caster's accuracy, a miss
hurts what stands where it lands, the first enemy on the line takes the hit, the damage goes through the victim's armour and the
height percentage when the missile lands, and a caster that has died by then does no damage. Produced armies now get the original's initial experience (the hero's Intelligence / 2 while it lives, plus
Telepathy's training power, and the troop-XP lord skills; `FUN_00557d90`). Summoned armies get the lords and the Gate power-up's
20 per level instead of the training, plus their spell's experience per result above the first (`docs/hero.md`).

## Effect pictures of the spells (verified in the 1.04 binary)

Every spell function behind the cast dispatcher (`FUN_005777a0`, a switch on the spell number: the number is the slot of
`<Lang>/Spells.txt`, -3..-1 the troops' Heroism / Silver Arrow / Shield, 150 / 151 Drain Mana / Multi-Target) builds a
spell message (type 0x1f7, 0x141 bytes) and sends it; the receiver (`FUN_004ac0e0`) shows what the message names. The
fields: `+0x8d` the casting effect (on the caster), `+0x91` the target effect (on every army or building the spell changed),
`+0x85` the persistent effect (on the same, looping for as long as the spell's statuses last), `+0x95` the special effect
type (100 = "at the base"), `+0x89` the duration in ms, `+7` the sound number (`STEZ%02d.wav` at the caster, see "Spell sounds"
below). The codes are the effect codes of the effect-code conversion
(`FUN_0040ebd0`): an `EZnn` / `EF01` / `EX01` picture of `Effects1.xcr`, or one of the 26 emitter codes of `gfx/emitters.lua`. The
table was read from the cast functions by decoding their code (the stores into the message at those offsets: `FUN_0057b090` ...
`FUN_005813a0` and the rest of the switch, 135 entries) and checked against the decompiler for the ones the decoder could not
follow (Elementalism, Raise Champion, Chaos Plague, Banish, Purify); the spell record's `pictures` is this table. Spells 60, 61, 78
and 96 (Create Item, Transmute, Rune Item, Morph Resources) open a dialog and send no spell message, 50 (Hand of Flame) and the other
missile spells send a message with the missile and the pictures below only.

The receiver's rules (`FUN_004ac0e0` end, the effect maker `FUN_0044e8f0`, see `gfx/effectitems.lua`):
- the casting effect is made at the caster (effect point, in front: `adjustY` +1); then, whatever the spell, the sphere's light
  (`gfx/battlefx.lua`); the target effect on every marked target except the caster when its code is the casting code (in front, +1;
  the codes EZ18, EZ14, EZ08, EZ35, EZ34 and EZ40 stand at the army's feet behind it, -1); the persistent one on every marked target
  made wherever it is (not only on screen), in front (+1) or, for a `base` message, at the feet behind (-2), and ends with the spell
  effect (the army's spell effect record, removed by the end of the status or the death of the army);
- which targets are marked is the spell function's own business in the original (a per-target flag: for example healing marks
  only wounded armies); openwbc3's spell effects work through many helpers, so the battle view compares the world before and
  after the effect function (`gfx/spellfx.lua`: hit points, mana, chaos morphs, timed effects, new armies and buildings, the
  targets of missiles, which `FUN_004ac0e0` case 0x10 marks too; at most 24) and takes the changed ones. A persistent picture goes on the armies that got a timed effect, else on
  the caster, and lasts while one of those effects is on the army or as long as the cast's duration (`ctx.durMs`). This is openwbc3's
  reading, not the original's (the target lists of the original's cast functions were not traced): a spell whose effect is kept in a
  hero or side field instead of `u.fx` (Disjunction, the Arcane spells ...) shows its persistent picture on the caster only, and a
  game loaded from a save shows none of the persistent pictures of its running spells (the original saves the picture's id).

| slot | spell | casting | target | persistent | notes |
|---|---|---|---|---|---|
| 0 | Heal Self | EZ11 |  |  | sound 11 |
| 1 | Cure | EZ20 | EZ20 |  | sound 15 |
| 2 | Blessing | EZ20 |  | EBLS | sound 8 |
| 3 | White Ward | EZ20 |  | EZ22 | sound 7 |
| 4 | Heal Group | EZ11 | EZ11 |  | sound 11 |
| 5 | Invigorate | EZ20 |  | EZ23 | sound 12 |
| 6 | Purify | EZ19 |  |  | sound 10 |
| 7 | Major Healing | EZ11 | EZ11 |  | sound 11 |
| 8 | Life Ward | EZ20 |  | EZ24 | sound 13 |
| 9 | Resurrection | EZ20 | EZ13 |  | sound 14 |
| 10 | Summon Quasit |  | EZ34 |  | sound 5 |
| 11 | Circle of Power |  | EZ36 |  | sound 42 |
| 12 | Phantom Steed | EZ37 |  |  | sound 34 |
| 13 | Blink |  | EZ34 |  | sound 39 |
| 14 | Summon Imp |  | EZ34 |  | sound 38 |
| 15 | Eye of Oros |  | EZ34 |  | sound 37 |
| 16 | Home Portal |  | EZ34 |  | sound 38 |
| 17 | Soulharvest |  | EZ34 |  | sound 32 |
| 18 | Banish | EZ37 | EZ37 |  | sound 30 |
| 19 | Daemongate |  | EZ35 |  | sound 21 |
| 20 | Summon Sprite |  | EZ14 |  | sound 5 |
| 21 | Gemberry | EZ15 | EZ15 |  | sound 15 |
| 22 | Entangle | EZ19 |  | EZ16 | sound 40 |
| 23 | Shillelagh |  |  | EZ17 | sound 29 |
| 24 | Summon Unicorn |  | EZ18 |  | sound 34 |
| 25 | Wall of Thorns |  | EZ18 |  | sound 28 |
| 26 | Call Lightning |  | EZ09 |  | sound 9 |
| 27 | Summon Treant |  | EZ18 |  | sound 33 |
| 28 | Change Weather | EZ19 |  |  | sound 17 |
| 29 | Elementalism |  | EZ14 |  | sound 32 |
| 30 | Shadowform | EILU |  |  | sound 22 |
| 31 | Scare | EILU | EILE |  | sound 31 |
| 32 | Light/Darkness | EZ19 |  |  | sound 17 |
| 33 | Awe | EILU | EILE |  | sound 43 |
| 34 | Spectral Horde |  | EZ34 |  | sound 42 |
| 35 | Dragonfear |  | EZ34 |  | sound 44 |
| 36 | Invisibility | EILU |  |  | sound 40 |
| 37 | Call Shadow |  | EZ08 |  | sound 16 |
| 38 | Mutate | EILU | EZ12 |  | sound 29 |
| 39 | Transform | EILU | EILE |  | sound 42 |
| 40 | Raise Skeleton |  | EZ08 |  | sound 16 |
| 41 | Raise Zombie |  | EZ08 |  | sound 16 |
| 42 | Black Portal |  | EZ05 |  | sound 19 |
| 43 | Raise Wight |  | EZ08 |  | sound 16 |
| 44 | Vampirism | EZ27 |  | EZ26 | sound 20 |
| 45 | Darkstorm | EZ27 |  |  | sound 21 |
| 46 | Strip Flesh | EZ27 | EZ41 |  | sound 29 |
| 47 | Call the Dead | EZ78 | EZ08 |  | sound 9 |
| 48 | Ring of Ice | EZ07 |  |  | sound 23 |
| 49 | Raise Champion |  | EZ08 |  | sound 17 |
| 50 | Hand of Flame |  |  |  | sound 27 |
| 51 | Soul Flame | EZ30 | EF01 |  | sound 15 |
| 52 | Cauterize | EF04 | EF04 |  | sound 11 |
| 53 | Resist Fire | EZ29 |  | EZ28 | sound 25 |
| 54 | Ring of Fire | EZ06 |  |  | sound 47 |
| 55 | Firebreath | EZ31 |  | EZ33 | sound 26 |
| 56 | Berserker | EZ30 |  |  | sound 28 |
| 57 | Pillar of Fire | EZ32 |  |  | sound 35 |
| 58 | Fire Elemental |  | EZ14 |  | sound 32 |
| 59 | Armageddon |  | EZ32 |  | sound 9 |
| 60 | Create Item | - | - | - | no spell message (a dialog) |
| 61 | Transmute | - | - | - | no spell message (a dialog) |
| 62 | Charm | EZ20 |  | EZ39 | sound 43 |
| 63 | Stone Golem |  | EZ34 |  | sound 5 |
| 64 | Brew Potion |  | EZ20 |  | sound 46 |
| 65 | Acquire |  | EZ20 |  | sound 46 |
| 66 | Summon Guardian |  | EZ35 |  | sound 24 |
| 67 | Disjunction | EZ26 |  | EZ69 | sound 26, base |
| 68 | Bronze Golem |  | EZ34 |  | sound 5 |
| 69 | Spellforge | EZ26 |  | EZ80 | sound 26, base |
| 70 | Stoneskin | ERUC |  |  | sound 33 |
| 71 | Gem of Wisdom | ERUC |  |  | sound 13 |
| 72 | Dig | ERUC |  | EZ39 | sound 42 |
| 73 | Earthpower | ERUC | EZ00 |  | sound 24 |
| 74 | Resist Magic | ERUC |  |  | sound 36 |
| 75 | Doomstones | ERUC |  |  | sound 27 |
| 76 | Summon Guardian | ERUC | EZ35 |  | sound 24 |
| 77 | Resist Missile | ERUC |  | EZ40 | sound 39 |
| 78 | Rune Item | - | - | - | no spell message (a dialog) |
| 79 | Stonecall | ERUC | EZ34 |  | sound 32 |
| 80 | Hand Of Ice | EISP |  |  | sound 27 |
| 81 | Storm | EZ27 |  |  | sound 21 |
| 82 | Ice Armor | EISP |  | EIAR | sound 2 |
| 83 | Calm | EISP | EISP |  | sound 40 |
| 84 | Ring Of Ice | EZ07 |  |  | sound 23, function of 48 |
| 85 | Freeze | EISP |  |  | sound 40 |
| 86 | Wall Of Ice |  | EISP |  | sound 28 |
| 87 | Ice Floe | EISP |  | EMIF | sound 3 |
| 88 | Freeze Magic | EISP |  | EIFM | sound 36 |
| 89 | Ice Storm | EIST | EIST |  | sound 9 |
| 90 | Morph Combat | ECHC | ECHC |  | sound 20 |
| 91 | Morph Speed | ECHC | ECHC |  | sound 20 |
| 92 | Morph Health | ECHC | ECHC |  | sound 20 |
| 93 | Morph Damage | ECHC | ECHC |  | sound 20 |
| 94 | Morph Tower | ECHC | ECHC |  | sound 20 |
| 95 | Drain Mana | EZ15 | EZ15 |  | sound 4, function of 150 |
| 96 | Morph Resources | - | - | - | no spell message (a dialog) |
| 97 | Increase Casting | ECHC |  |  | sound 36 |
| 98 | Wildfire | ECHW | ECHW |  | sound 9 |
| 99 | Chaos Plague | EZ19 | EZ25 |  | sound 18 |
| 100 | Immunity | EZ20 |  | EIMM | sound 8 |
| 101 | Poison Cloud | EZ19 | EZ25 |  | sound 18 |
| 102 | Summon Wasp |  | EZ18 |  | sound 34 |
| 103 | Antidote | EZ20 | EZ20 |  | sound 15 |
| 104 | Venom Touch | EPOC |  | ESVT | sound 26 |
| 105 | Poison Gate | EZ19 |  | EPGA | sound 26 |
| 106 | Spray Poison | EPOC |  |  | sound 27 |
| 107 | Guardian Naga |  | EZ18 |  | sound 34 |
| 108 | Rot | EPOC | EPOC |  | sound 15 |
| 109 | Call of Kargoth |  | EZ18 |  | sound 34 |
| 110 | Elemental Lore | EARC |  | EZ65 | sound 33, base |
| 111 | Defense Lore | EDVC |  | EZ66 | sound 33, base |
| 112 | See Invisible | EDVC |  | ESIV | sound 42 |
| 113 | Telepathy | EDVC |  | EZ67 | sound 42 |
| 114 | Banish | EZ37 | EZ37 |  | sound 30, function of 18 |
| 115 | Comprehension | EDVC |  | ECOM | sound 42 |
| 116 | Call Sage |  | EZ34 |  | sound 32 |
| 117 | Mind Leech | EDVC |  | EZ68 | sound 20 |
| 118 | True Sight | EDVC |  |  | sound 13 |
| 119 | Psychic Blast | EDVC | EDVC |  | sound 30 |
| 120 | Concentration | EDVC |  | EZ70 | sound 33, base |
| 121 | Command | EDVC |  | EZ71 | sound 34, base |
| 122 | Enervate | EDVC |  | EZ72 | sound 33, base |
| 123 | Extend | EDVC |  | EZ73 | sound 33, base |
| 124 | Mana Flow | EDVC |  | EZ74 | sound 33, base |
| 125 | Corruption | EDVC |  | EZ75 | sound 33, base |
| 126 | Dispel | EARC | EARC |  | sound 40 |
| 127 | Mana Leech | EDVC |  | EZ76 | sound 33, base |
| 128 | Empower | EDVC |  | EZ77 | sound 33, base |
| 129 | Destruction | EARC | EX01 |  | sound 9 |

## Spell sounds (verified in the 1.04 binary)

The receiver of a spell message (`FUN_004ac0e0`, its last statements) plays the message's sound number `n` (byte `+7`, 1..47) when it
is not 0 and the caster army exists: `sprintf("STEZ%02d.wav", n)` and `FUN_0050f0a0(name, caster cell x, y)`. The same function is
used for the message without a caster (`army id -1`: the cell is in the message, `+0x139`). The casting spell function fills `+7` with
a constant (the "sound" column of the table; for the extra functions: Shield -1 sound 2, Silver Arrow -2 sound 3, Heroism -3 sound 1,
Drain Mana 150 sound 4, Multi-Target 151 sound 5; the receiver's case for message kind 0x23, the titan's balls and Couatl's Wrath, plays STEZ47.wav and STEZ27.wav itself, see `implemented.md` "Titan"). All 47
files `STEZ01.wav` .. `STEZ47.wav` are in `Assets/SoundFX.xcr`.

`FUN_0050f0a0(file, x, y)` is the original's positional one-shot (the same helper plays the other effect sounds): nothing unless
`x` and `y` are within 24 cells (`|d| < 25`) of the view's centre (`FUN_00490900` / `FUN_00490920`: half the window's size plus its origin),
and unless the visibility test `FUN_0047f560` (true without fog, else the visible flag, the explored flag in a hidden-map game) holds for the
cell of the sound or for the view's centre; then it starts the sound at full volume (`FUN_004ca050(name, 0, 0, 64.0, 127, 0)`, no
sound when the file is missing), sets the volume from a distance table (`FUN_0050ef50`: the larger of the two distances, at most 24)
and the pan from the horizontal offset (`FUN_0050f020`, an offset in the window's width of 25 / 30 / 35 / 40 cells). openwbc3's
`sound.playAt` is that helper (volume `(125 - 5 d) / 127`, pan `dx / 25`; the distance table itself was not read: it is built at
run time). The message goes out for a successful cast only (a fizzle sends none: `FUN_005777a0` returns after the failure lines),
so a hero cast, an item spell and a troop's spell all sound, on every machine, whoever the caster is; Create Item, Transmute, Rune Item
and Morph Resources open a dialog and make no sound. In openwbc3 `gfx/battlefx.lua` `spellSound` does this from the "spellcast" /
"itemspell" events (the spell record's `pictures.sound`); it replaces the own `Statpop.wav` at half volume. Still own: the troops'
spells with negative slots that are not hero spells (Summon Bats ...: their messages were not traced) keep `Statpop.wav`.

Spell Resisted (Game.txt 1112): `FUN_004aa840` (the host's pre-processing of a spell message) sends a line to every
target that a spell of four kinds does not take (`FUN_004af9c0` -> message 0x222 -> `FUN_004afa00` -> `FUN_00539fb0`: the line over
the army, level colour, 1000 ms; the "resisted" event of the simulation, shown by `gfx/battlefx.lua`). Banish (kind 23, spells 18 and
114; the message's flag mask is planar `0x2000`): an army dies when its side does not own the Binding power-up `PBIN` and its level
(`FUN_00526d80`: a hero's is the side hero's level, any other army's own) is below 2 x the result, else it resists. Mutate (kind
25, 38; flags: not titan or mechanical `0x4200`, value result + 1) and Strip Flesh (kind 37, 46; flags: infantry, small or average
`0x30010000` and not titan, undead, mechanical, flyer or monster `0x204a04`, value result + 1): an army is taken when it is no hero
(`+0xb4`), its level is below the value and it is no animal (`FUN_00528280`: the eight critter codes ACSH ACCO ACGO ACPE ACCA ACSO
ACTU ACSE), else it resists. Rot (kind 38, 108; value result + 1): an army of a lower level loses its poison / disease as before,
one of the value or more resists, but the line appears only when it is poisoned or diseased. Openwbc3 before this change ignored the
troops' levels (`levelOf` counted heroes only), let Mutate and Strip Flesh take animals, mechanical armies and titans, and Strip Flesh
only took infantry; the target flags of the other message kinds are not mirrored.

## Open points (outside `spells.lua`)

- Mana pool and regeneration: `class base mana + 3*Int + 10*Lore`; `(2 + Int/10)` points per 20 s at
  `100 + 5*Energy + Enervate` % (binary) - implemented in `hero.lua`.
- Initial experience of produced armies: `Int/2` while the side's hero lives, plus the Telepathy training power
  (`FUN_00557d90`) - applied in `economy.lua`'s `spawnNear`; the Mind Leech energy-drain kill bonus is in
  `world.lua`'s `award`.
- Computer heroes spend their points in list order (the original weights randomly).

Timed effects on units (`src/game/status.lua`): stat changes, slow, stun, poison, disease,
invisibility, life ward, resistances (Resist Fire/Magic take the percentage as value), vampirism,
venom, immunity, fear, awe, morale, polymorph / morph, energy drain (Mind Leech). Fire Breathing range 5, Ice Floe range 12 (verified).
Side-wide effects (Charm, Dig, Concentration, Extend, Empower, Mana Flow, Enervate, Command, Telepathy,
See Invisible, True Sight) live on the side record; Day/Night and Rain on the world.
