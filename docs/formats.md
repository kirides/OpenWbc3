# Warlords Battlecry III file formats

Notes on the data formats as implemented by openwbc3. All integers are little-endian;
records use natural alignment (no packing pragmas). "fourcc" ids are four ASCII
characters (e.g. `AHFX`).

## Archives (`.xcr`)

```
header  (28 bytes)  char id[20] = "xcr File 1.00" (rest of the field is garbage)
                    i32  count
                    u32  archive size
entries (532 bytes each, `count` of them, right after the header)
        +0   char name[256]       lookup key, compared case-insensitively
        +256 char sourcePath[256] authoring path, informational
        +512 u32  offset          absolute
        +516 u32  size
        +520 i32  type            always 0
        +524 u32  crc             XOR of all u32 words of the stored bytes
        +528 u8   checkCrc
        +529 u8   encrypted
```

No compression. When a name occurs twice the first entry wins.

Encrypted entries use a fixed byte substitution. To build the table, run a 16-bit LCG
`s = (25173*s + 13849) mod 65536` from `s = 728`. Map each step to `r = floor(s*256/65535)`,
clamped to 255. Skip values already taken. The i-th new value `r` encodes plain byte `i`,
so decoding is `plain = dec[stored]`. Encrypted types are scripts and configs (`.ani`,
`.arm`, `.bui`, `.fea`, `.ter`, `.cfg`, `.xml`, …). Pictures, `.rle` and `.wav` are stored
plain.

The original mounts these in order: `Assets/Terrain/*`, `Assets/Features/*`,
`Assets/Sides/*`, `PatchData.xcr`, `Assets/Effects/*`, `<Lang>/GameSpeech.xcr`,
`Assets/SoundFX.xcr`, `Quest.xcr`, `Assets/Graphics.xcr`, `<Lang>/GText.xcr` and
`Assets/Heroes/Portraits.xcr`. `PatchData.xcr` overrides `.ARM`/`.BUI` records.

## Sprites (`<CODE>.ani` + `<CODE><suffix>.rle|.bmp`)

`.ani` holds 9 records of 26 bytes, one per animation. The animations and their file
suffixes are: stand "", walk W, fight F, die D, ambient A, special Z, convert C,
spell S, interface I. Each record:

```
u8 used, u8 frames, u8 effect[2],
u16 originX, originY, width, height, effectOriginX, effectOriginY,
    selectionOriginX, selectionOriginY, selectionSize, effectType, effectActivation
```

On the sheet, frame `f` facing direction `d` sits at `(f*width, d*height)`. Directions
are 0 = north, then clockwise. A sprite is drawn at `position - origin`.
`effectActivation` is the frame on which an attack hits.

`.rle`, tag `RL`, or `RS` for sheets with shadow runs:

```
char tag[2], u32 dataSize, u16 w, u16 h, u16 palettes[8][256] (RGB565),
u32 blockSize, u32 blockTotal, u16 numBlocks, pad  -> pixel data at offset 4118
pixel data: h x u32 row offsets (relative to the data), then per row a byte stream:
  255 n   skip n transparent pixels (n = 255: rest of the row is empty)
  250 n   n shadow pixels (RS only)
  other   one palette index
```

The 8 palettes are times of day. Indices 224–238 are replaced by the side colour ramp.
Indices 239–246 and 247–254 are "effect" pixels driven by `effect[1]` and `effect[0]`:
shadow levels, coloured lights, translucency or additive blending.

8-bit `.bmp` sheets use index 255 as transparent.

Side colour ramps: 15 steps of `start + i*inc` per channel (8-bit RGB). The values are
in `src/formats/sprite.lua`.

## Scenarios (`.SCN`)

The file is a sequence of chunks `{fourcc id, u32 size including this 8-byte header}`:

| id | contents |
|---|---|
| `SCNH` | header: version[16], code[16], name[32], players, width, height (cells), description[200], options, type |
| `SIDH` | 7 × 44-byte side records (6 players + neutral): used, race, colour, team, resources, AI level, start cell, start resources |
| `SAIH` | 6 AI hero records (42 bytes: race, portrait, level, personality, class i16 and the side's custom AI file name char[32]) |
| `SM24` | 128×128 minimap, BGR |
| `MAPH` | tile grid, `ceil(W/10) × ceil(H/10)` records of 16 bytes: fourcc tile, i16 runtime, u8 part, u8 animated, u8 frame, u8 frames, u8 flags, u8 size |
| `ARMH` | placed unit: code, owner, x, y (world px), then the unit's stats |
| `BLDH` | placed building: code, anim, dir, frame, x, y, then its stats; the owning side is at +76 of the stats block |
| `FTRH` | placed feature: code, anim, dir, frame, x, y |
| `ITMH` | treasure chest: the picture record (code `IMAP`, animation, direction, frame, x, y) and the chest, 112 bytes |
| `EFFH` | particle effect: name[20], x, y |
| `EVSH` | 128 × 1196-byte event records (condition, 4 effects, timer, flags), see "Events" below |
| `ENDX` | end |

Cells are 32×24 pixels. The cell centre is at `(gx*32+16, gy*24+12)`.

Chunk sizes seen in all shipped scenarios: `SCNH` 352, `SIDH` 316, `SAIH` 260, `SM24` 49160,
`MAPH` 8 + 16 per slot, `FTRH` 32, `ITMH` 112, `BLDH`/`ARMH` 160, `EFFH` 36, `EVSH` 8 + 1196 per
event, `ENDX` 8. The object chunks are not grouped (features, buildings and units are
interleaved), so readers must not assume an order.

### Events (`EVSH` and `EVENTS/*.EVT`)

An event is one 1196-byte record (reader `src/formats/evt.lua`, writer
`scnwrite.lua`). A `.EVT` file of the game folder's `EVENTS` directory is exactly one record (the editor's event pool,
39 templates such as `EDAY.evt`); the `EVSH` chunk holds 128 of them, the used ones (`used` byte +1193) first and
without gaps, the rest zero-filled in files written by openwbc3 (the originals leave garbage in them, and behind the
zero terminator of strings). Slot 0 is the standard victory event (condition 10, owner 6, no effects, `shots` 1, `loopCount` 1, position -1,-1; identical in all 116 shipped scenarios) that the original's editor creates for a new scenario and does not list; every shipped scenario has it.
All numbers are little endian, the booleans one byte.

| offset | field |
|---|---|
| +0 | condition: u16 owner (0-5 a side, 6 everybody), u16 condition kind, u16 number, 2 bytes padding, u32 target (a 4-letter type code packed first letter lowest, a side, a counter or -1 / `0xFFFFFFFF` for "any"), u16 flags (event flags 0-15 that must be set), u16 radius (cells, 1 = the single cell) |
| +16 | 4 effects of 284 bytes: u8 used, 1 padding, u16 ownerType (0 everybody, 1 the condition's side, 2 everybody else, 3 side `ownerData`, 4 everybody but `ownerData`), u16 ownerData, u16 effect kind, u16 number, u16 location, u32 type, char text[260] (file name, character name, text), i32 x, i32 y (cells) |
| +1152 | char code[4]: the pool template the event came from; `Names.cfg` `[EVENT_<code>]` is its list name ("Unknown Event" for an unknown code) |
| +1156 | u16 loopCount (run-time counter, 0 when saved), +1158 u16 shots (how often the event may fire, 0 = forever), +1160 u8 onMap (0 for a timer) |
| +1161 | char name[20] |
| +1182 | u16 seconds (the timer), +1184 i32 x, +1188 i32 y (cell of the condition), +1192 u8 done, +1193 u8 used, 2 bytes padding |

What the condition and effect numbers mean is the header of `src/game/events.lua`. The numbers an event carries
are checked against the 39 pool templates and 324 shipped events: read -> write gives the same record byte for byte
(the selftest does it for every scenario). A pool template differs from the scenario event made from it only in the
fields the author edited (e.g. `EVIC` against the victory event of `C_DoomwoodAmbush`: condition kind, radius, the owner
type of effect 1 and the position). The pool's `Army.lst`, `Building.lst`, `Feature.lst` and `item.lst` (a count line,
then `"Name" CODE`) are not read by the 1.04 editor's code (its dialogs list the type tables), so openwbc3 ignores them.
The conditions that read text take it from an effect: 23 (character lost) from the first effect's text, 31 (character
moves to a square) from the fourth's, even when that slot is "unused" in the original; the editor keeps such a slot
as a used effect of kind -1 (a kind no handler knows), so that `events.lua` finds the name.

Offsets from the start of a chunk, for the fields the editor writes (`src/formats/scnwrite.lua`;
everything else is kept as read):

| chunk | fields |
|---|---|
| `SCNH` options | from +284 (the game options record): fog i16 +0, fog locked +2, hidden map +3, hidden locked +4, combat random +5, handicapping +6, handicap locked +7, custom resources +8, quests +9, quests locked +10, environment i16 +12, victory i16 +14, tech level i16 +18, tech locked +20, base setup i16 +22, army setup points i16 +26, points locked +28, then seven (mod, mod locked) byte pairs: no dragons, no fliers, no lords, tough towers, no towers, no walls, no heroes |
| `SCNH` | version +8 (16), code +24 (16), name +40 (32), players +72, width +76, height +80 (i32), description +84 (200), the options record above from +284 (fog i16 +284, hidden map +287, quests +293, victory i16 +298 ... ; also "standard data" +300, "choose city setup" +308), scenario type i16 +328, first side only +330, produce heroes +331, standard victory +332, show map on the selection screen +333 (u8 bools); the original editor writes the version "BC2" |
| `SIDH` | side *i* at `8 + 44i`: used +0, race i16 +2, race locked +4, colour i16 +6, team i16 +8 (0..4), team locked +10, resources i16 +12 (0..4), resources locked +14, AI level i16 +16 (0 passive, 1 .. 6 Squire .. Emperor, 7 rampant), AI level locked +18, start cell x/y i32 +20/+24, random start +28, start gold / metal / crystal / stone i16 +32.. +38, must be human +40, must be on +41 (u8 bools; the shipped maps confirm the lock offsets) |
| `SAIH` | six records at `8 + 42i` (the computer hero set-up of a side): race i16 +0, portrait +2, level +4, personality +6, class +8 (-1 = unset, a new scenario has -1 / 0 / -1 / -1 / -1), custom AI file name +10 (32, a `CustomAI/*.ai` name, empty for none; 5 sides of the shipped maps have one: `C_KorOrc`, `C_KorDwarf`, `Land of the Lost`) |
| `ARMH` | code +8, owner +12, x +16, y +20 (i32), then the army record from +24 (natural alignment): level i16 +24 (counts from 0 for plain troops, heroes start at 1), experience i32 +28, behaviour type i16 +32 (0 wimp, 1 defensive, 2 normal, 3 aggressive, 4 mad: stored, never read by the game), script code +34 (30), index in the Army.cfg type table i16 +64 (the number at the start of a `Army.cfg` line), character name +66 (20), ID tag +86 (20), alive +106, spell active +107, use type stats +108, is a character +109, combat / speed / resistance / hits / view i16 +110.. +118, current hits i16 +120, damage / damage type / range i16 +122.. +126, armour / strong vs / weak vs i16 +128.. +132 (+2 x i16 unused), psych effect (u8 strength, u8 type, i16 range) +138 (type 1 fear, 2 terror, 3 awe, 4 chaos aura, 5 poison, 6 disease; the auras are `game/psych.lua`), unit value i16 +142, is hero +144, powers available +145 (4), current psych effects i16 +150 (bit 1 fear, 2 terror, 4 awe, 8 chaos, 0x10 immune; openwbc3 keeps them as unit effects), expiry time i32 +152, side i16 +156 |
| `BLDH` | code +8, anim +12, dir +16, frame +20, x +24, y +28 (i32), then the building record from +32: index in the Building.cfg type table i16 +32, use type stats +34, character name +35 (20), ID tag +55 (20), is a character +75, combat / speed / resistance / hits / view i16 +76.. +84, armour / strong / weak i16 +86.. +90, damage / type / range i16 +96.. +100, current hits i16 +102, psych effect +104, side i16 +108, level u8 +110, resources available (gold, metal, crystal, stone i16) +112 |
| `ITMH` | the picture record: code +8 (`IMAP`), animation +12, direction +16 (4 = an ordinary chest, 0..3 = the gold / metal / stone / crystal chest), frame +20, x +24, y +28 (pixels); the chest record from +32: four item entries of 16 bytes (index i16 into the item table, -2 = a random item; resource flag u8 +2; data u16 +4 = the resource type of a resource chest: 14 gold, 15 stone, 16 metal, 17 crystal; item index u16 +6; x, y i32 +8 / +12, cell), number of items i16 +96 (1..4), opened +98, resource chest +99, x, y i32 +100 / +104 (cell), being viewed i32 +108. The unused item slots hold leftover memory in the shipped files (all 58 shipped chests hold one random item); a resource chest is worth 500 |
| `MAPH` slot | tile fourcc, i16 index in the editor's tile list (unused by the engine), u8 part (+6, `x + 2y` of the quadrant), animated +7, frame +8, frames +9, flags +10, size +11 (0 = 1×1, 1 = 2×2, 2 = 2×1, 3 = 1×2 slots) |

The editor's tile list comes from `Assets/Terrain/<pack>.<en|ge>` (XML: `<Group default= name=>`,
`<SubGroup name=>`, `<Tile id= name= big=>` in order).

## Terrain

Each map tile slot is 320×240 px (10×10 cells). Tile pictures are `<id>.bmp` (8-bit)
in `Assets/Terrain/<pack>.xcr`. Big tiles (640×480, 640×240, 320×480) span several
slots, and a slot's `part` (0–3) picks the quadrant. Animated tiles stack their frames
vertically.

`<id>.ter` is 1652 bytes:

| offset | contents |
|---|---|
| +4 | `cell[20][20]` (x-major), each `{u8 height, u8 terrain, u8 moveCost, u8 flags}` |
| +1605 | animated |
| +1606 | frames |
| +1607 | size |
| +1612 | `u32 frameTimes[8]` |

Terrain types: grass, dirt, sand, water, rock, lava, marsh, ford, snow, void, mountain.
A move cost of 0 means impassable for anything but fliers.

## Unit and building types

`<code>.ARM` (332 bytes):

| offset | contents |
|---|---|
| 0 | id |
| 5 | movement type (land, fly, sea, float) |
| 6 | name[20] |
| 28 | build time |
| 30 | combat, speed, resistance, hits, view |
| 40 | armour, strong-vs, weak-vs |
| 50 | damage, damage type, range |
| 56 | shape |
| 94 | cost (gold, metal, crystal, stone) |
| 104 | 4 powers |
| 211 | per-frame walk move amounts `u8[32]` |
| 248 | walk fine-tuning `i16[4]` |
| 262 | number of speech files (how many `Select<n>` / `Order<n>` lines the unit has; ABBX 3, hero AMHX 4) |
| 268 | eight combat points: `i16 x, y` per direction (0 north, clockwise), the pixel offset from the top left corner of the selection rectangle a shot leaves from; all 0 for most types (60 codes of the install have points: the dragons, catapults, the Titans, many ranged troops), then the shot leaves from the middle of the rectangle |
| 300 | eight wake points: the same for a ship's wake (all 0 in the install) |

`<code>.BUI` (200 bytes) has a similar layout, with the shape at 62. A shape is
`u8 w, u8 h, u16 exclusion[16]`; bit x of row y set means that cell is not occupied.

`<code>.FEA` (a feature type, 68 bytes, read by `FUN_0041b730`, the same layout in memory): `char id[4]` at 0, `name[20]` at 4, the
shape (`u8 w, u8 h, u16 exclusion[16]`) at 24, then `u8 canWalkOver` at 58, `u8 canFlyOver` at 59, `u8 ambientSound` at 60 and
unused bytes. With `ambientSound` set the feature loops `<id>Ambient.wav` of `SoundFX.xcr` (`src/audio/ambience.lua`); no shipped
type sets it. The feature XML (`Assets/Features/*.en` / `.ge`) gives per type `id`, `icon`, `delay` (one-shot interval of the
ambient sound, 0 everywhere) and `frame1`.

Walking one cell takes `STEP_TIME[speed]` ms (1200 ms at speed 0 down to 235 ms at 30).
Speed changes by −8 uphill and +8 downhill.

### Race columns of `Army.cfg` / `Building.cfg` (CACHE)
The 16-character column after STATUS (armies, 0-based columns 18-33) / after the resource letter (buildings, columns
14-29) has a letter at the position of every race (Human 0 ... Lizardmen 15, the order of `rules.RACE_LETTER`) that has
the unit or building and `-` elsewhere. `rules.raceSets(race)` returns the codes in file order; the original's
`FUN_00519480` walks the same lists (at most 30 buildings and 25 armies) for the "new armies /
buildings available" announcement.

## Interface

`War4Gfx.xcg` lists bitmaps (archive name + file name), cursors, legacy bitmap fonts
and animated images. `War4Int.xci` lists UI objects (buttons, strings, images, …),
panels (objects with positions) and screens.

Text comes from `<Lang>/XCIStrings.txt`: one line per sub-string in resource order,
with the first 9 characters dropped. Fonts are defined in `<Lang>/Font.ini`; the
`Fonts/*.fnt` files are TrueType.

Button bitmaps stack their states vertically: normal, focus, pressed, disabled.
Magenta (`#FF00FF` after RGB565 conversion) is transparent.

Image objects of subtype 25 have no art in the file: the game draws them itself (the picture of a retinue slot
`IM_RETINUE_PICTURE_ARMY` / `_RECRUIT`, the gravestones `IM_GY_STONE_PICT`, the graveyard's `IM_GY_PICT`, a hero's
`IM_AVATAR` ...). Several buttons of subtype 4 / 5 name the generic `BM_BUTTON200` (bitmap 4) or the empty placeholder
(1) as their bitmap and are plain hit areas (`BUTT_RETINUE_ARMY`, `BUTT_GY_BUTTON`). Editor objects (type 1) keep their
font number at offset 60 and the longest text they take at offset 136 of the record body (the 284 byte record from the
id: object + 44 + 60 / 136; the edit box setter `FUN_0045daf0` refuses a longer text): `EDIT_RETINUE_ARMY_NAME` font 2 /
11 characters, `EDIT_RETINUE_NAME` font 1 / 20, `EDIT_PASSWORD` font 5 / 16. A panel can hold an object several times;
the `extra` field of the panel entry is its index for the string setter `FUN_00464a90(panel, item, index)` (`PNL_GRAVEYARD`'s ten
`STR_PARCHMEDIUM_L250` are indexed 0 .. 10 that way, the order of the file is not the order of the places).
`BUTT_RETINUE_NAME` (id 217) is defined but no panel of the file contains it.

## Screen help (`<Lang>/ScreenHelp.txt`)

Text file with `[KEY]<tab>text` lines. `[CLICKTOCONTINUE]` is the footer; `[SCREENnn_TEXTmm]` is block `mm` of screen
`nn` (0 main menu, 1 hero selection, 2 hero creation, 3 customization, 4 journal hint, 5 replayable, 6 item stash,
7 campaign, 8 army points, 9 retinue, 10 side selection, 11 multiplayer, 12 graveyard, 13 results, 14 victory / defeat).
A text starting with `<>` is a paragraph, `<x,y>` a paragraph that points at that screen position (a line is drawn to it
while the mouse is over the block), anything else a centred heading. The help is drawn on `ScreenHelp.bmp` (500x360 at
150,120, magenta transparent, black 50 % transparent) in fonts 15 (normal) / 16 (highlighted).

## Options

The original keeps them in the registry (read by `FUN_004521f0`, written by `FUN_00451b10`). First-run defaults (the 1.04
binary's `FUN_00453280` fills the record, then writes it to the registry): help level 2 (None 0,
Some 1, All 2), scroll rate 3 (1..5), game speed 2 (0..4, the game starts at value + 1 of the game clock `FUN_00458dd0`'s steps x0.5 / 0.75 / 1 /
1.5 / 2), music volume 3 (0..4, sample volume `n << 5`), sound effects volume 120 (set from the drop-down as 0 / 30 / 60 / 90 /
120 of 127), group movement on (slowest unit), spacebar pauses on, right-click interface on, unit speech 1 (Never / Sometimes /
Always), system voice 0 (female, `SystemF<n>.wav`; male `System<n>.wav`), tip of the day on, particles 1, lighting 1, gamma 0.
Also stored: `3DProvider` (the Miles provider name) and `MusicINIFile` (the chosen `Music/*.ini`, default `Battlecry3.ini`). The texts
of the options screen are XCI text resources 259 (tabs), 263 / 274 (gameplay), 264 / 265 / 270
(value names), 266 / 267 / 346 (graphics), 268 / 269 (sound), 312 (tips).

## Formation slot tables (`Battlecry III.exe`, VA 0x005FBC9C)

There are no formation files in the install: the formations are a compiled table of points, `[8][32][32]`, at VA
0x005FBC9C of the 1.04 executable (`.data`, file offset 0x1FBC9C; 8 x 32 x 32 x 4 = 32768 bytes). An entry is `i16 x, i16 y`; entry
`[formation][32 - n][slot]` is slot number `slot` of a group of `n` units (the other slots of the row are zero), in the
formation panel's order (Block, Defensive Ring, Wedge, Skirmish, Double Line, Single Column, Wide Line, Double Column).
The offsets are in cells, +y is the front for the facing BOTTOM. `tools/dev/genformations.lua` writes them out as
`game/src/game/formationdata.lua`; how they are used is in `docs/implemented.md` "Formations".

## Building fire points and emitters (`.BUI`)

Offset 188 holds three emitter points, `i16 x, i16 y` pixel offsets from the top left corner of the building's selection rectangle
(its position less the picture's `originX` / `originY`) where the chimneys, vents and fires of the building spray particles
(`src/gfx/emitters.lua`); the original only tests the first point's `x` (0: no emitter). The shape that follows the attack type
(offset 154, 34 bytes) ends at 188 and the three points end the 200-byte record.

Offset 106 of the 200-byte record holds three fire points, `i16 x, i16 y` pixel offsets from the building's anchor where
the fires of a damaged building burn, followed by eight combat points (at 118: `i16 x, y` per direction like the `.ARM` points, 32 buildings of the
install have them: the towers, gates, walls ... `missiles.startPoint`), the rubble type at 150 and the attack type at 152 (in the 1.04 binary's type table at
`0x00697754`, 200 bytes a building: the building display set-up `FUN_0053a8a0` turns rubble type 1 / 2 / 3 into the
codes `EDB0` / `EDB1` / `EDB2`, the selection's attack order `FUN_00531480` tests bit 0 of the attack type). The rubble
type is 0..3 in the shipped data - 0 for walls, temples, flags and the mine buildings, which is read as "leaves nothing behind", 1..3 for the
buildings that leave a wreck.

## Construction and wreck sprites (`.ani`)

The `Z` (special) sheet of a building holds its construction stages: the sheet is three frames wide even though the `.ani`
record says one frame (checked for `BABA` 3 x 232, `BAGR` 3 x 128, `BWTB` 3 x 168, `BKD0` 3 x 288, `BTEL` 3 x 320), and the
stages go from the bare shell to the almost finished building. Only the base codes have one: the upgrade levels (`BKA1`..`BKA4`
…) and the walls, mines and temples have no `Z` sheet at all. The `D` (die) sheet exists only for the four mine types
(`BRG` / `BRC` / `BRM` / `BRS`), one frame, the abandoned mine. No separate rubble sprite sets exist in the archives, so the
wreck of a destroyed building is drawn from the building's own sheets. The original keeps the dead display item and
drops it after a while (not traced in the 1.04 binary yet);
how long it stays and the fade-out over the last quarter of that are openwbc3's own.

## Missile sheets (`EM??.ani` and the thrown `ACSH` / `ACCO` / `AOSX`)

The stand sheet of a missile has one row per direction and one column per frame; the `.ani` record only counts the frames of the
picture itself, the sheet is wider. Columns `0 .. frames - 1` are the picture (`frames` is 1, 3 for the flaming arrows `EMA2` / `EMFP`,
8 for the ice shards and the thrown critters), the next `trail` columns are the after-images drawn on the steps behind it (5 for the
arrows, rocks, fire / magic balls, the Titan's balls; checked against the sheet widths: `EMA0` 120 x 320 is 6 columns of 20 x 20, 16 rows).
`frames`, `trail` and the rows (`dirs`: 16, the rocks 4, the ice 1, the thrown critters 8) are set by the missile set-up
(`FUN_0053f180`, offsets `+0x682` / `+0x680` / `+0x684`), see the `missile` records. A 16 row sheet is ordered like the original's
direction table (`FUN_005418a0`): rows 0 .. 7 face north, north east, east, south east, south, south west, west, north west, and the rows 8 ..
15 lie between them (8 north-north-east, 9 east-north-east, 10 east-south-east, 11 south-south-east, 12 south-south-west, 13 west-south-west,
14 west-north-west, 15 north-north-west). The thrown critters use the `Z` (special) animation of their unit sheet. The dragon breath
has no missile sheet: `EFB0 .. EFB7` (fire), `EIB` (ice), `EAB` (acid), `EVB` (evil), `EGB` (good), `ELB` (lightning) are 12 frame
effect pictures, one per direction modulo 8, played at the dragon. `EMX0` (a missile that ended against a building, the void or a
lightning's end, 8 frames) and `EMX1` (a splash landing, 8 frames) are plain effect pictures, as are `EZ06` / `EZ07` (the Titan's balls
bursting, 20 frames), all at 50 ms a frame.

## Random map pieces (`RandomData.xcr`, read by `src/formats/gom.lua`)

`RandomData.xcr` holds 647 `.GOM` files (the "geomorphs") and nothing else: `clear` 61, `grass` 81, `HighGrass` 81,
`oasis` 61, `lava` 41, `sand` 68, `cavern` 34, `snow` 61, `water` 55, `jungle` 73 pieces numbered from 0, which the ten
terrain sets of the generator use, and the 31 `desert` pieces no set uses (their `TDS?` dirt tiles are in no tile
list either). The `.WRM` water layouts and `*.SCN` pieces of the generator's islands variant are not shipped, and
the binary's random map entry (`FUN_00582180`) only calls the no-islands function (`FUN_00582310`), so they are not read.
A GOM is a 3x3 block of terrain tiles (30x30 cells):

| offset | contents |
|---|---|
| +0 | `u16` 123, 2 bytes of padding (garbage) |
| +4 | `char tile[9][4]`, row by row (`TGX0`, `TGF2` ...) |
| +40 | `u16 part[9]`: 0 for a tile's own slot, 1..3 for the other slots of a 2x2 / 2x1 / 1x2 tile |
| +58 | `u16 edge[4]`: terrain type of the north, east, south, west edge: 0 dirt, 1 sand, 2 grass, 3 water, 4 snow, 5 road, 6 high grass, 7 high dirt, 8 high rock, 9..12 dirt specials (the shipped files use 0..6, 11, 12) |
| +68 | 7 side records (44 bytes each): start locations; every shipped file holds -1 / -1, the generator draws its own |
| +376 | chunks: `FTRH` features (32 bytes: `char code[4]`, `i32 anim, dir, frame, x, y`, the position in pixels from the GOM's corner, 0..959 x 0..719), then `ENDX` |

The generator (`src/game/randommap.lua`) is documented in `docs/implemented.md` "Random maps". Verified with the binary: the
random numbers (`last = (0x6255 * last + 0x3619) & 0xFFFF`, a die is `rand * sides / 0xFFFF + 1`, `FUN_00582130` /
`FUN_005820b0`), the start piece rules, the matching of the edges, the 30 cells per piece, and the feature test
(`x / 10 + piece offset < map width` with pixels against cells).

## Custom AI scripts (`CustomAI/*.ai`, read by `src/game/aiparams.lua`)

Loose files in `<gamedir>/CustomAI/`, written by the original's AI editor (read back by `FUN_004f76d0` in the 1.04
binary, see below). Little-endian, 6416 bytes as shipped: a 56-byte header, then one block per struct whose
size the header declares. Header: `i32` 6360 (params block), `i32` 48 (group properties), `i32` 4 (defence), `i32` 4
(main), `i32` 6292 (race data); `char magic[10]` = `AIED_V1.0` at 20; `char description[20]` at 30; `i32 race` at 50
whose high 16 bits are the race the script was written for (-1 = any race, the generic `G_*` files).

The 6360-byte params block at 56: `i16 race` (race or -1) at +0, 2 bytes of padding, `i16 race` again at +4,
`{ u32 fourcc; u8 used; u8 priority; 2 pad } army[20]` at +8 (priority 0..100, `used` 1 marks a live slot),
the same shape `powerup[40]` at +168, `{ u32 fourcc; u8 priority; 3 pad } building[30]` at +488, `u8
customGroups` at +728 and 10 groups of 556 bytes at +732, `u8 numberOfGroups` at +6292, `u8 main[4]`
(army-upgrade / power-up-upgrade / army-production / tower priorities) at +6294, `u8 flags[7]` (heroBoldness,
armiesInTowers, buildersInMines, randomness, baseRelocation, heroRetreat, toughUnitsInTowers) at +6298, `u8
defense[4]` (mines / keeps / army-production buildings / power-up buildings) at +6308 and `i32 groupMin[6],
groupMax[6]` at +6312.

Custom group record (556 bytes; bytes and booleans are 1 byte and the records are 2-byte aligned, which gives exactly
the 6360 / 6292 the header announces):

    sub group[5], 104 bytes each
      u32 armies[20] @0 (fourccs; 0xFFFFFFFF or NULs for empty slots), char name[20] @80 (an unused sub group is named
      by its index: "2", "3", "4"), u8 min @100, u8 max @101, u8 used @102, 1 pad
    char groupName[30] @520, u8 used @550, u8 attackPriority[5] @551 (army production, power-up production, keeps,
    mines, towers; 0..100)

Only `A_Bomber.ai` has custom groups (`customGroups` 1, five used groups: "Small Bomb Group" 3..8 `AASX` + 0..1 `AAIX`,
"Large Bomb Group" 10..18 `AASX`, "Tower Bombers" with towers priority 100, "Long Range Guys" 8..12 of `AAFB` `AAWY`
`AADR`, "Keep Killer" 15..20 `AASX` with keeps priority 100); its `numberOfGroups` is 0 although five groups are used,
so the count is not reliable. The other 13 files have the flag 0 and all-zero records. The files hold raw bytes (a 0x0A
min of 10 stays 0x0A, unlike the `.uai` files below). The layout was read off the files and checked on
A_Bomber: names, army codes and priorities come out as the editor wrote them.

The 1.04 binary reads the file in `FUN_004f76d0` (called through the per-side parameter getter `FUN_004f7460`, which ignores
the result): the header must say 0x20F8 (8440), 0x30, 4, 4 and 0x20B4 (8372) - the layout with 30 army slots, 40
power-ups, 30 buildings and groups of 756 bytes (`0x2F4`, 5 sub groups of 144 bytes with 30 army codes each; the
custom group flag is at `+0x328`, the group sizes at `+0x20C8` / `+0x20E0`) - and the magic `AIED_V1.0`; otherwise the
defaults of `FUN_004f7560` stay. All 14 shipped files declare 6360 / 6292, so the 1.04 game itself cannot use any of
them (openwbc3 reads them anyway). The custom groups are dead data in the original: the group type 8 (custom) is never
assigned (the group type update `FUN_004f6d90` only writes 0 .. 7 and 9), the sub group names, sizes and army lists
have no reader at all, and the only readers of a group record are the attack priorities in the target priority
`FUN_004f66f0` (reached only for a group of type 8). `src/game/aiparams.lua` reads the records for completeness
(`custom`, `customGroups`, `numberOfGroups`); nothing uses them (`docs/todo/not-in-original.md`).

The display name is `Names.cfg [CAI_<ROOT>]` (the file's root upper-cased) or the header description. The shipped
files were written with 20 army slots, fewer than the 30 of the 1.04 loader, so it rejects them;
openwbc3 reads them as they are. Unused slots are `0xFFFFFFFF` fourccs in the race-specific files and four NULs in
the generic ones. All values were read off the 14 shipped files.

## Custom unit attitudes (`CustomUnitAI/*.uai`, read by `src/formats/uai.lua`)

Read by `FUN_00506c90` in the 1.04 binary (the `*.uai` scan is `FUN_00505ad0`). Booleans are 1 byte and words 2 bytes;
with 2-byte alignment of the records the sizes come out as the header announces (checked on all four shipped files: Fallback25, MagicAttacker, MagicDefender, RoamingGuardian). All
values little endian.

    header, 254 bytes
      char name[40]  @0          char description[200] @40   both padded with 0xCD after the terminator
      u16 version    @240 = 1    char fileType[10] @242 = "UnitAIV1"      u16 bodySize @252 = 1204 = the body's size
    body, 1204 bytes at 254
      u16 activeAreaCentre @0 (always 0xCDCD in the files, unused), u16 activeAreaSize @2 (cells; 20 or 30 in the files),
      u16 numberOfRules @4 (0 in every file; the original ignores it), rule[10] @6, idleAction @1186,
      u16 icon @1200 (the attitude icon, 0..11), u8 designatedUnitUsed @1202, u8 autoSpellCasting @1203
    rule, 118 bytes
      condition[5] @0 (16 each), action @80 (14), u16 priority @94, u8 used @96, char name[20] @97, u8 overridesPlayer @117
      unused rules have used = 0 (priority 50, the rest 0xCD); a rule without a used condition never holds
    condition, 16 bytes
      u16 code @0, u16 unitType @2 (0 me, 1 my hero, 2 designated unit), u8 activeAreaUsed @4, u16 extra[3] @6
      (extra[0] = threshold or distance), u8 used @12, u16 expectedResult @14 (1 = TRUE)
    action, 14 bytes
      u8 used @0, u16 code @2, u8 activeAreaUsed @4, u16 unitType @6 (-1 = none), u16 extra[3] @8

The files were written through a text mode `fwrite`, so every data byte 0x0A is stored as 0x0D 0x0A (Fallback25.uai has
1459 bytes: its icon 10 = "question" became `0D 0A`), and the original reads them in text mode (`"r"`), which turns
them back. A reader must replace CR LF by LF first. Condition codes: 0 has immediate threats, 1 has guard threats,
2 is alive, 3 attacking enemy building, 4 attacking enemy army, 5 damaged below threshold (percent), 6 under attack,
7 threats in attack range, 8 within distance of me. Action codes: 0 return to base, 1 follow unit, 2 protect unit,
3 stand ground, 4 run from attackers, 5 handle immediate threats, 6 handle guard threats, 7 random movement,
8 scout perimeter of area, 9 move to centre of active area, 10 run from threats; what each does is in the header
comment of `src/game/attitude.lua`. The list name and description are replaced by Names.cfg `[CUAI_NAME_<ROOT>]` /
`[CUAI_DESC_<ROOT>]` (root = file name without extension, upper case); the attitude list shows the file's own name
only when Names.cfg has no entry. The shipped rules: Fallback25 (rule "Look after myself" 63: immediate threats -> handle
them; "Run Away" 100: damaged below 25 % -> return to base), MagicAttacker (82: threats -> handle, auto spells),
MagicDefender (69: threats inside the active area -> handle, idle: move to the area centre, auto spells),
RoamingGuardian (designated unit; 69 own threats, 90 the hero's threats, 100 overriding the player: more than 25 cells
from the hero -> follow it; idle: random movement over the whole map).

## Quest data (`Quest.xcr/Bmsh.dat`, `Bzma.dat`)

One file per quest site type (`BMSH` shrine, `BZMA` mausoleum), read by `FUN_0052edb0` in the 1.04 binary. A 208-byte
header: `char id[5]` at 0, padding, `u16 count` at 6, then `u8 used[200]` from 8 (one byte per quest, so the records
start at 208). Records are 102 bytes at `208 + id * 102`, 2-byte aligned: `u16 timeLimit` (s) at +0, `u16 idleTime`
(s) at +2, `char picture[5]` at +4 (a sprite code with a digit last, the BMP of `Quest.xcr`), `u8 namingSet` at +9,
`u16 type` at +10, `u16 amount` at +12, `char data[16]` at +14 (a resource letter for type 0, else a unit / building
code), the five reward flags (resource / character / armies / power-up / item) one byte each at +30..+34,
`u16 gold, metal, crystal, stone` at +36..+42, `char characterId[5]` at +44 and `u16 characterXp` at +50,
`u16 armyCount` at +52, `char armyId[5]` at +54 and `u16 armyXp` at +60, `u8 armyNames` at +62 and `u8 armyNamingSet`
at +63, `char powerupId[5]` at +64, `u16 itemType` at +70, `u16 itemEffect[3]` at +72, `u16 itemEffectData[3]` at +78
(the item index first) and `u16 chances[3][3]` at +84.

Quest types (not all traced in the 1.04 binary yet): 0 pay a resource, 1 kill N armies, 2 raze N buildings, 3 convert N buildings, 4 give an
answer, 5 kill an enemy hero, 6 kill N units of a type, 7 raze N buildings of a type, 8 build a building type, 9
own a building type. The shipped sets use 0..3, 5, 6, 7 and 9 (42 of 43 shrine quests and 44 of 45 mausoleum
quests are marked used; the unused ones are kind 0 too, so kinds 4 and 8 are in no record at all). Texts are not in the data: they are
`<Lang>/Quest.cfg` keys `BMSH_000_NAME / NEWQ / CONT / CMPL / INST / REPT` (455 keys, no failure or refusal text). The 1.04 binary also
reads `<set>_<nnn>_ANSW` into the 16 byte `data` (the answer of a kind 4 quest, so it can be localised); the shipped files have none.
The quest dialog's sprites are effect sheets in `Assets/Effects/Effects1.xcr`: `EMDQ` (the 430x417 background), `EMDC` (30x120: the
30x30 cancel button in four rows, normal / hover / pressed) and `EMDE` (180x144: the 180x36 button in four rows); the portrait is
the 128x160 `<picture>.bmp` of `Quest.xcr`. The layout is in `docs/implemented.md` "Quest dialog".

## Naming sets (`<gamedir>/NamingSets/*.nam`)

Loose text files, one per set, in the order of the 1.04 binary's file name table at `0x006085d8` (`FUN_00434e90`): Standard, GenericEvil, KnightlyMale,
KnightlyFemale, HumanMale, HumanFemale, ElvenMale, ElvenFemale, DwarvenMale, DwarvenFemale, WizardMale, WizardFemale,
BarbarianMale, BarbarianFemale, Draconic, Fey. Windows-1252, an INI-ish shape: a `[RULES]` section of
`<chance> [SECTION] [SECTION2] ...` recipes, then one `[SECTION]` block per word list. The original forces the last
recipe's chance to 100, rolls 0..99 and takes the first recipe whose chance is above the roll, then concatenates one
random entry of every section the recipe names. For every language but English the original first remaps the set
index (a table of 16 `u16` at 0x608618 in the 1.04 binary): sets 1, 12 and 13 give GenericEvil, 14 stays Draconic and the
rest give Standard; openwbc3 does the same (`quests.nameSetIndex`). A file that cannot be read gives the name "Sirian".

## In-battle info area pages (info area at 304,456 342x144)

The info area pages through screens cycled by right-clicking inside it: page `(page + 1) % count`
with count 4 for a hero (stats, overview, skills, resistances), 2 for a plain unit (stats,
resistances) and 1 for a building; selecting another unit resets to page 0. The shipped binary is
stripped, so the page list and the cycle are openwbc3's reading of the reference screenshots
(`docs/todo/unit-hud-*.png`); the texts and icons below are as verified.

- Overview (positions and fonts verified in `FUN_004d7710`, see `docs/implemented.md`): the hero's name, then the
  labels of XCI text resource 6 sub-strings 3 / 4 / 5 ("Race:", "Class:", "Level:", each followed by a space and the
  value; race text 15 / 104, class texts 8..11) and the regeneration lines of `<Lang>/Game.txt` keys `0661` / `0662`
  ("Life/Mana Regeneration: 1 point per %0.2f seconds"), printed with `1 / rate` seconds of the hero's effective
  per-second regen; an undead hero also shows key `0663` ("(only at night)") under the life line.
- Skills: heading is XCI text resource 18 sub-string 2 ("Skills"), entries are `<Lang>/Game.txt`
  keys `0759 + skill id` printed as "<name> +<level>" (format `" +%d"`) in FO_MEDIUM, two per
  row (140 apart), only skills above level 0.
- Resistances: seven `SkillIcons.bmp` frames from the row at y=108 in bordered boxes with a
  signed value - sword 44, bow 92, mace 68, fire 116, lightning 140, ice crystal 215, scroll 164
  - then the strong / weak lines of `<Lang>/Game.txt` keys `0910 + type` ("Resistant (-50%) to
  ... Damage") and `0921 + type` ("Vulnerable (+50%) to ... Damage"). The damage-type order was
  read off the file: 0 piercing, 1 cold, 2 electrical, 3 fire, 4 magic, 5 crushing, 6 slashing,
  7 all physical, 8 piercing + slashing, 9 all elemental, 10 all damage. The `.ARM` record has a
  single `combat`, `resistance` and `armour` field, which is why the reference repeats one value
  per icon of a row (every unit whose strong class is fire and weak class cold has resistance 20,
  the value the reference shows); openwbc3 puts the hero's per-element item resistances
  (`h.mod.resist`) under the elemental icons, which is what `soften()` applies to elemental
  damage, and uses the sheet's ice crystal because the snowflake symbol of this sheet only exists
  inside the boxed armour-type frames.

## Campaign battle maps (`Campaign.xcr/MAP_*.map`, read by `src/game/campaigndata.lua`)
XML: `<Name file="...">` (a scenario in `CampaignScenario/`, or `random`), `<Battle victory points hidden fog level quests>`, `<Side id race
resources team ai relativeai nohero noretinue>` per side (0 = the hero), `<Hero ...>`, `<RandomData size terrain>`. `ai` (0 Passive or 7
Rampant in the shipped maps) replaces the side's AI level; `relativeai` (-1 / 0 / 1) moves it from the scenario's own level (file maps) or
from the hero's campaign AI level + 1 (random maps); a side without either keeps the scenario's level. Both attributes are optional: the
binary keeps a "used" flag for each (the campaign battle start `FUN_005a1880`, the record's +0x6a / +0x6e). How the levels come out:
`docs/implemented.md` "Campaign: extra army points, mercenary selection, options".

## Other files of the install

Inventory of what the GOG 1.04 install holds (112 archives with 10811 entries are mounted by `src/vfs/vfs.lua`), by file kind and
where it is described. A probe over every archive entry and every loose file found no kind that is not listed here or in the
sections above.

| kind | where | described in |
|---|---|---|
| `.xcr` | the archives | "Archives" |
| `.ani` + `.rle` / `.bmp` | sprite sheets | "Sprites" |
| `.ARM` / `.BUI` / `.FEA` / `.ter` | unit, building, feature and terrain records | "Unit and building types", "Terrain" |
| `.SCN`, `.evt`, `.lst` | scenarios (`Scenario/`, `CampaignScenario/`, `Tutorial/`), events (`Events/`) | "Scenarios", "Events" |
| `.GOM` | random map pieces (`RandomData.xcr`) | "Random map pieces" |
| `.ai`, `.uai`, `.nam` | `CustomAI/`, `CustomUnitAI/`, `NamingSets/` | "Custom AI scripts", "Custom unit attitudes", "Naming sets" |
| `.dat` | `Quest.xcr` (`Bmsh.dat`, `Bzma.dat`), `Data.xcr` (`data.dat`) | "Quest data", "Hero directory" |
| `.cfg` | `System.xcr` (`Army.cfg`, `Building.cfg`, `Item.cfg`), `<Lang>/*.cfg` | "Race columns", "Set items", "Text files" |
| `.act` `.amb` `.loc` `.map` `.var` `.bon` `.hnt` `.nis` `.txt` | `<Lang>/Campaign.xcr` | "Campaign definition", "Campaign battle maps" |
| `.xml` | `<Lang>/Items.xcr`, `Mercenaries.xcr`, the cut scenes, credits, history, journal, tips; `Assets/Particles` | "Item and mercenary catalogues", "Small XML files", "Particle definitions" |
| `.en` / `.ge` | `Assets/Terrain`, `Features`, `Sides`, `Effects`, `Particles` catalogues | "Asset catalogues" |
| `.xci` / `.xcg` | `War4Int.xci`, `War4Gfx.xcg` | "Interface" |
| `.txt`, `.ini` | `<Lang>/*.txt`, `Font.ini`, `Music/*.ini` | "Text files" |
| `.wav`, `.mp3`, `.bik` | sound effects and speech, music, videos (read through `src/audio/*`, converted by `--convert`) | no layout of the game's own |
| `.fnt` | TrueType faces of `Fonts/` | "Interface" |
| `.cur` / `.ani` (cursors), `.dll`, `.exe`, `.m3d`, `.asi`, `.pdb`, `.ico`, `.lnk`, `.pdf`, `.hashdb`, `.sdb`, `.script`, `.info`, `.msg`, `.log` | standard Windows cursor files in `Assets/Cursors`, the Miles sound system, the executables and their debug databases, the GOG installer and launcher files, the manuals | nothing game specific, see "Files the 1.04 binary does not name" |

There is no `Formations/` directory in the install and no archive entry of that name: the formations are compiled into the
executable ("Formation slot tables"). No `.WRM` file is shipped, and no `.GOM` exists outside `RandomData.xcr`.

### Campaign definition (`<Lang>/Campaign.xcr`, read by `src/game/campaigndata.lua`)

All files are Windows-1252 XML (`src/core/xml.lua`); the code of a file is its name without the prefix. What follows is field names
and the vocabulary of the format, the texts are the install's. The element and attribute lists were taken by parsing every file of
the install.

- `LOC_<code>.loc`, root `<Location code>`: a place on the world map (41). `<Name>`, `<Description>` with `<Paragraph>`s,
  `<Position x y>` (map pixels of the marker) and `<Text x y>` (of its label), `<Diplomacy owner hate>` (the race / side that
  holds the place; `hate` is 0 everywhere), `<Links>` with `<Link code traveltime type>` (a road to the place `code`, in days,
  `Land` or `Sea`, the label as text), `<Actions>` with `<Action code>` (the `ACT_<code>.act` offered there), `<Ambushes>` with
  `<Ambush code type>` (`AMB_<code>.amb`, `enter` or `leave`: when the road is taken), `<Variables>` with `<Variable id index
  value>` (initial campaign variables, index 0..5) and `<Conditions>` (the place is shown when they hold).
- `ACT_<code>.act`, root `<Action code type [replayable="1"]>`: something to do at a place (177); `type` is `battle`, `choice`,
  `item`, `mercenary`, `message`, `retinue` or `xp`. Children, each when needed: `<Name>`, `<Help>`, `<Description>`, `<Message>`,
  `<Heading>`, `<Option choice>` (the text of an answer), `<Cost data>` (gold; the text is the label), `<Map code>` (the battle:
  `MAP_<code>.map`), `<Reward type data shorttext>` (`bonus`, `crowns`, `item`, `video` or `xp`; the text is the line shown; the new-battle dialog prints only the first reward's `shorttext`),
  `<Diplomacy side modification min max choice>` (what an answer does to the rating with a side), `<Journal type choice important>`
  with `<Paragraph>`s or `<Video data>` (the journal entry written on `victory` or `defeat`), `<Data cost race image>` (retinue
  offers), `<Unit code level name nameset>` (a unit given; `name` is `fixed` or `random`), `<Mercenaries>` with `<Mercenary type
  index side minquality maxquality chance>`, `<Items price>` with `<Item type index minquality maxquality chance>` (`type` is
  `fixed` or `random`, `index` an entry of `Mercenaries.xml` / `Items.xml`), `<Sell price>` and `<Conditions>`.
- `AMB_<code>.amb`, root `<Ambush code [type]>`: an ambush on a road (13). `<Chances ally friend neutral enemy>` (percent, by the
  relation to the owner of the place the road leads to), `<Map code>`, `<Reward>`, `<Journal>`, `<Conditions>`, `<Name>`,
  `<Description>`, `<Help>`.
- `<Condition type id action value rating side>` (in all of the above): `check` compares the campaign variable `id` with `value`
  using `action` (`eq ne lt le gt ge`), `diplomacy` compares the rating with `side` against `rating`; `victory` and `defeat` are
  not tests but effects applied when the battle of the action is won or lost, with `action` `assign` or `add` (`sub` is read as
  well) on the variable (`src/game/campaignstate.lua` `conditionsMet` / `applyEffects`). Variable ids are lower-cased.
- `Global.var` (`<Globals><Variable id index value>`, five variables, all 0), `Global.bon` (`<Bonuses><Bonus index>` with `<Name>`,
  `<Description>` and `<Data type data [level]>`: the 14 hero bonuses a campaign grants; `type` is one of `hero skill`,
  `immunity disease`, `vision`, `speed`, `speed attack`, `mana regen`, `cold resistance`, `combat`, `morale`, `armor` or `none`;
  applied in `src/game/campaignrun.lua` and `hero.lua`) and `Global.hnt` (`<Hints><Hint levels>` with a `<Condition>` and
  `<Text level>`s, one per level of the hint: the help lines of the campaign map).
- `C_<name>.nis`, a scenario conversation (62; started by the `ENIS` event effect): `<NIS>` with `<Character id portrait>name`
  (id 0 is the player's hero, the others name a portrait index), `<Message character [condition]>text` shown one after another
  and an optional `<Flag id>` set when the conversation ends. A condition is words joined by `and` / `or` / `not`, evaluated left
  to right: `evil`, `good`, `mortal`, `immortal`, `wizard`, `rogue`, a race word or a hero class (`src/game/conversation.lua`).
- `<scenario>.txt` (only the German archive of this install has them, eight): the mission text of the information dialog, one
  line per row, at most 20 rows (`src/game/scenarioinfo.lua`).
- `MAP_<code>.map`: "Campaign battle maps" below.

### Item and mercenary catalogues

`<Lang>/Items.xcr/Items.xml` (read by `src/import/wbc3/items.lua`): `<Items>` of `<Item id>` with `<Name>`, `<Description>`,
`<Image iconrow iconcol>` (the row of `Items.bmp` is also the equipment slot, `docs/hero.md` "Items"), `<Data value level rarity>`
(`level` is `minor`, `lesser`, `greater`, `artifact` or `set`) and up to three `<Power id type data [chance level]>text`
(`id` 0..2; `type` is a name such as `combat` or `cast spell`, `data` a number whose meaning depends on the type, `chance` and
`level` only for item spells; the text is the line the tooltip shows).

`<Lang>/Mercenaries.xcr/Mercenaries.xml` (read by `campaigndata.lua`): `<Mercenaries>` of `<Mercenary id cost quality race
rarity>` (`quality` 0..2, `race` a race slot, `rarity` 1..9) with `<Name>` and `<Unit id number level name>text` (unit code,
how many, their level, the name shown).

### Set items (`System.xcr/Item.cfg`)

Read by the original at start-up (`FUN_00589170`, called from `FUN_0041a650`; it looks for the lines `[TREASURES]` and `[SETS]`),
not read by openwbc3 (the set pieces come from `Items.xml`, `level="set"`). Lines starting with `//` are comments. `[TREASURES]`
has 72 fixed-column rows `NNN T F PP V name`: characters 0..2 are the row number, 4 the item type (0 sword, 1 staff, 2 armour,
3 necklace, 4 shield, 5 ring, 6 crown, 7 helm, 8 banner, 9 boots), 6 the picture frame, 8..9 the power (the file's header comment
lists 01 combat, 02 health, 03 training, 04 conversion, 05 speed, 06 resistance, 07 morale, 08 magery, 10 command, 11 merchant),
11 the value and 13.. the name. Three consecutive rows make a set (the binary stores 74 bytes per row and numbers the set
`row / 3`). `[SETS]` holds the text lines of each set as `SSS k text`: set number, line number 0..5 (0 the heading, 1..3 the pieces,
4..5 the bonus lines).

### Text files

- `[KEY]<tab>text` files: `Help.cfg`, `Game.txt`, `Spells.txt`, `Quest.cfg`, `Names.cfg`, `Victory.cfg`, `Tutorial.cfg` (and
  `ScreenHelp.txt`); CRLF lines, `//` starts a comment line, keys are compared case-insensitively (`src/game/strings.lua` upper-cases
  them). `Game.txt` starts with a line holding the number of keys (1152) and uses four-digit keys `[0000]`. `Help.cfg` has per code
  `<CODE>_Name`, `_Desc`, `_Requ`, `_HKey` and (for 441 of the 656 codes) `_Lin1` .. `_Lin3`, a few `_Requ_<x>` variants.
  `Spells.txt`: `SPELL_NAME_nn`, `SPELL_DESC_nn`, `SPELL_NAME_PLURAL_n` / `_SINGULAR_n` (spheres), `SPELL_DLG_TEXT_n`,
  `SPELL_HOTKEY_TEXT_n`. `Victory.cfg`: `[VictoryNN_TextMM]` (victory rule `NN`, line `MM`; `src/game/scenarioinfo.lua`).
  `Tutorial.cfg`: `[NewTutN_TEXT]` with letter variants (`NewTutNa_TEXT` ...) for the tutorial popups (`events.lua`, effects 21 / 22).
  `Names.cfg` and `Quest.cfg` are described with the data that uses them ("Custom AI scripts", "Naming sets", "Quest data").
- `XCIStrings.txt` and `ScreenHelp.txt`: "Interface", "Screen help".
- `KeyMap.txt` (`src/ui/keymap.lua`): one shortcut per line, `//` comments; a single character (an upper-case letter means Shift +
  letter), `CTRL x`, `ALT x`, `F11`, `F12`, `SPACE`, `PAGEUP`, or `+ - .` for the keypad. The first 61 lines are the battle shortcut
  table in the order of the binary's `SH_*` list (`keymap.NAMES`; `FUN_00426060` reads it, `FUN_00427fb0` dispatches, see
  `docs/implemented.md` "Hot keys"); the remaining 48 lines are single-letter spell hotkeys, which openwbc3 does not read.
- `Font.ini` (`src/ui/fonts.lua`): `[FONTSYSTEM] NumFonts=45`, then `[FONT.n]` with `Name` (`FO_*`), `File` (a TrueType `.fnt` of
  `Fonts/`), `PointSize`, `Baseline`, `ColorRed` / `ColorGreen` / `ColorBlue`, `KeyRed` / `KeyGreen` / `KeyBlue` (the outline colour of
  the 21 `KeyLine` fonts) and `Style` (`Normal`, `DropShadow`, `DropShadowLeft`, `KeyLine`).
- `Music/*.ini` (`src/audio/music.lua`; `docs/implemented.md` "Scroll rate, volume levels, music sets"): `[SOUNDTRACK]` with
  `Title`, `File`, `Tracks`, `Ambient0` .. `Ambient6`, `Intro`, `Victory`, `Defeat`; `//` comments.

### Small XML files

In the language folder: `Campaign/Episode1..8.xml` and `Intro.xml` (`<CutScene voice voicedelay>` with `<Text time>` lines: the
subtitles of the campaign videos, `time` in milliseconds from the start; `src/game/campaign.lua`), `Credits.xml` (`<Credits>` of
`<Line type>`, `blank` / `heading` / `normal`; `screens/credits.lua`), `TipOfTheDay.xml` (`<Tips number>` of `<Tip id>`;
`screens/tip.lua`), `History.xml` (`<History number>` of `<Entry id>` with `<Title>` and `<Paragraph>`s) and `Journal.xml`
(`<Journal>` of `<Entry important video>` with `<Heading>` and `<Paragraph>`s: the opening journal entry); the last two are not
read by openwbc3.

### Asset catalogues (`Assets/Terrain|Features|Sides|Effects|Particles/*.en` and `.ge`)

XML lists chosen by the language abbreviation (`en`, `ge`; the original globs `Assets\Terrain\*.%s`). `Terrain/<pack>.<abbr>`:
`<Terrain>` with `<Group name type default>`, `<SubGroup name type>` and `<Tile id name big edge palette smooth useinsmooth>`
(`big`, `smooth` and `useinsmooth` are `yes` / `no`, `edge` the tile id it blends with); it is the editor's tile list and the
random map's tile source (`game/editorlib.lua` `tileCatalog`, `game/randommap.lua`). `Features/*`: see "Unit and building types"
(`.FEA`). `Sides/<race>.en`: `<Side name>` with `<Army id name>` and `<Building id name>` (display names by code; not read, the
names come from `Names.cfg` / `Help.cfg`). `Effects/Effects1.en`: `<Effects>` with `<Effect id name>` and `<Missile id name>`
(editor object names; not read).

### Particle definitions (`Assets/Particles/*.xml`)

The original globs `Assets\Particles\*.xml` and `*.<abbr>` (the localised copies change `name` only); openwbc3 does not read them
(its particles are the presets of `src/gfx/particles.lua` and `emitters.lua`). A file is one `<Particle id name graphic temporary
size [lifetime]>` (`graphic` a picture code such as `EPF0`) with the children `<Emitter x y varx vary circle perimeter>`,
`<Force x y>`, `<Velocity x y varx vary>`, `<Graphics red green blue alpha frame>`, `<Number max interval life release>` and the
animated twins `<AnimEmitter>`, `<AnimForce>`, `<AnimPForce>`, `<AnimVelocity>`, `<AnimGraphics>` (the same fields plus `start` and
`end`, the millisecond range of the change). Five files are shipped (a volcano, an evil brew, glows and sparkles).

### Hero directory (`Data.xcr/data.dat`)

The original keeps the player's heroes in a writable archive `HeroData.xcr` (the strings `%s\HeroData.xcr` and
`\HERODATA\data.dat`; `FUN_005549f0` loads it, `FUN_00554f90` / `FUN_00555550` write it) whose directory entry `data.dat` has
65540 bytes: `i32 count`, then 256 slots of `char name[256]`, each naming another entry of the archive. A named entry is a hero
record of 0x10E8 (4328) bytes read whole; it is dropped when its first dword is not 2, or when the dword at +0x54 is 1 and
`FUN_00452db0` (given the bytes at +0x1C and +0x181..+0x184) returns true (not traced further, nor are the other fields). The empty template
shipped in `Data.xcr` has count 0 and leftover bytes of a developer's list in the slots (a first name `asdf.hro`). openwbc3 keeps
its heroes in its own format (`src/game/profile.lua`, `%APPDATA%\LOVE\openwbc3`).

### Files the 1.04 binary does not name

No string of these names is in the executable's string table, so it does not read them under these names (leftovers of earlier
versions): `Data/Game.ini` (`[HelpScreens]`, `[GameService]`; the help level is a registry value, see "Options"),
`HeroData/Dir.dat` (a text file of `Name = value` lines such as the options of an older version), `lobby.ini` and
`Assets/Cursors/*` (standard Windows `.cur` / animated `.ani` cursors; the game draws the cursors of `War4Gfx.xcg`).

## Power-up data of the binary

The power-up records (`game/content/base/powerups.lua`: cost, research time, army statistic bonuses; `game/content/base/races.lua`:
`powerupOrder`, the picture order of each race's list in `Powerups<Race>.bmp`) are numbers the install's data files do not hold: the
original compiles them into `Battlecry III.exe` (1.04, md5 d8d6debd538857fec26a133f483342da; on disk `Battlecry III-orig.exe`). They
were first written to `src/game/powerupdata.lua` (commit 56da181, header "Generated"), which the content registry replaced in
c8d7e46 by the `powerup` records; the numbers did not change. **The generator was never committed**: it was a throw-away script of
the session that decompiled the functions below with the Ghidra MCP tools and interpreted the pseudo-C. What is in the repository
is `tools/dev/checkpowerups.lua`, a reference implementation of that interpretation that checks the records against the binary:

```
pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/checkpowerups.lua "<Battlecry III-orig.exe>" <FUN_004391c0.c>
```

(`FUN_004391c0.c` is the decompiler's text for that function: `decompile_function_by_address 0x004391c0`, whose result is too big
for the conversation and is saved by the tool as JSON `{function, code, truncated}`; `jq -r .code <file> > FUN_004391c0.c`.) It reads the
16 race lists straight out of the exe and compares them with the races' `powerupOrder`, interprets `FUN_004391c0` for every `P` / `R`
record and compares cost and time. Result for the shipped records: all 16 lists identical, all 258 records identical (one, `PGLA`,
has no case of its own and gets the function's default of 100 gold, 100 metal, 60 s).

### Where the data is in the binary (1.04, VA)

| what | where | layout |
|---|---|---|
| base cost and research time of a `P` / `R` code | `FUN_004391c0(code, out)` | a ladder of `if (code == K)` / `if (code < K)` tests (a compiled `switch` on the 32-bit code, 1869 lines of pseudo-C) with shared tails (`goto LAB_...`); writes `out[0..3]` int16 = gold, metal, crystal, stone and the int32 at byte 8 = seconds; unknown codes fall to a default (100 / 100 / 0 / 0, 60 s) |
| the wrapper that every cost question goes through | `FUN_0040b6b0(code, extra, side, out)` | branches on the first letter: `A` (army: the cost fields of the type record, `FUN_0040a850`), `B` (building: `FUN_0040aa50`, construction time scaled by the builder's skill), `P` / `R` -> `FUN_004391c0`; then the side's rule overrides (`FUN_00587aa0`, the `Building.cfg [RULES]` numbers), the Fame percentage (`FUN_0040c350`), the rune research cuts of the hero skills 0x3d..0x41 and a percentage from the hero skill 0x25 (capped at 75 %); see `docs/hero.md`, `docs/implemented.md` |
| picture order of a race's list | `FUN_00439050(code)` | a `switch` on the race of the local side (`DAT_00708f96 + side * 0x2c`, race slot 0..15) that picks one of 16 tables of 4-character codes in `.data` (start addresses 0x006089dc, 0x00608a74, 0x00608ae0, 0x00608b50, 0x00608bec, 0x00608c64, 0x00608cc0, 0x00608d48, 0x00608dd0, 0x00608f44, 0x00608e54, 0x00608ecc, 0x00608fdc, 0x006090f8, 0x00609174, 0x00609070 for the slots 0..15); an int32 holding the length follows each table (slot 0: 37 codes); the result is the index of the code in the table |
| what a finished power-up does | `FUN_00436500(side, code, ...)` (the power-up routine, 6766 bytes) | appends the code to the side's list (`code[50]` per side from 0x0070ae40, count int16 at 0x0070ae30 + 2 * side; `FUN_00437f70(side, code)` is the lookup: 1 / 0 for a code the side owns or not; for a code of the form `P` a b `X` it returns the level, the highest owned `Pab0` .. `Pab8` plus one, or 0), then a long chain of `if (code == K)` blocks calling `FUN_00438760` for the statistic bonuses, setting flag bytes (`(&DAT_0070d57d)[side] = 1` ...) or calling the special handlers (`FUN_00438180` research, `FUN_004382d0` mercenaries, `FUN_00438de0` knight's quest) |
| one statistic bonus | `FUN_00438760(side, mode, stat, amount, key, byMask, invert)` | for every army type of the type table (0x006e3f18, the 332-byte `.ARM` records, code first) whose code equals `key` (or all when `key` is -1) adds `amount` to byte `stat` of the side's per-type bonus record at `0x0070b3b8 + (type + side * 200) * 6`: bytes combat, speed, armour, damage, range, resistance; the `stat` argument is 0 combat, 2 speed, 3 damage, 4 range, 5 resistance (the records' `stat`; 1 is the armour byte by elimination, no power-up uses it). With `byMask` the test is `key & flags(type)` (`FUN_0040b120`: the type flags of the `Army.cfg` status string) instead of a code, `invert` turns it into "types without any of these flags" (`flags`, `without` of a record). `mode` is 0 (add) in every call of `FUN_00436500` |

How the shipped records read: `PAC0` is `FUN_00438760(side, 0, 3, 5, 'AGSL', 0, 0)`, i.e. `{ stat = "damage", amount = 5, units =
{ "AGSL" } }`; `PWE0` is `(side, 0, 3, 5, 0x240000, 1, 1)`, i.e. `{ stat = "damage", amount = 5, flags = 0x240000, without = true }`;
a call per unit code gives the `units` list of the record. The cost tuple order is the one stated above (checked on all 258 records),
the picture order is the table order. The bonus part was extracted by the same method (and spot-checked again against `PAC0`,
`PWE0`, `PBOW`, `PODR` while writing this); `checkpowerups.lua` does not interpret `FUN_00436500` yet (that needs `||` conditions and call
statements, and its text on disk, see step 2).

### The method

1. Find the function. The binary has no symbols: every function is `FUN_<address>`, data `DAT_<address>` and strings
   `s_<text>_<address>`. Start from something the program contains: a string (`list_strings`, then `get_xrefs_to` its address, which names the
   functions that use it) or a constant. The 4-character codes are 32-bit immediates in little-endian order (`'PAC0'` is 0x30434150,
   `'AGSL'` 0x4c534741), and the MCP has no immediate or byte search, so scan the exe file on disk for the four bytes (a few lines of
   Python or Lua; map the file offset to a VA with the PE section table as `tools/dev/genformations.lua` does) and give the hits to
   `get_function_by_address`. That is how `FUN_00436500` was located from `PAC0` / `AGSL`. A function that calls a known helper (`FUN_00437f70`, the power-up level lookup) is found with `get_xrefs_to` on the helper.
2. Decompile it (`decompile_function_by_address`). Output above the tool's size limit is saved as a JSON file; read it with `jq` or
   Python, never page it by hand. Output below the limit exists only in the conversation, so to feed a program it has to be written out
   again (or the function re-run through the tool that saves results).
3. Interpret the pseudo-C instead of reading it. The functions of this method contain a handful of statement forms: `if (x == K) {`,
   `if (x < K) {`, `else if`, `else {`, `}`, `if (x == K) goto LAB_...;`, `goto LAB_...;`, `LAB_...:`, `*param_2 = n;`,
   `param_2[i] = n;`, `*(undefined4 *)(param_2 + 4) = n;`, `uVarN = n;`, `bVarN = x == K;`, `return;` and calls with constant
   arguments. `checkpowerups.lua` flattens them into one statement list and runs it with a program counter, once per code.
   Points that went wrong before they were handled:
   - a `}` followed by `else` is a part boundary, not the end of the chain; a false condition continues at the next part of its own
     chain, a part reached from above leaves the chain;
   - `else if (x == K) goto LAB_...;` without braces closes its chain;
   - a false condition may jump to the header of an enclosing chain's `else`; the part header must only be accepted when the jump came
     from its own chain (track the chain, not the address);
   - `goto` lands inside nested blocks, so a tree walk does not work, a flat list does;
   - constants may stand on the left (`0x304f4d50 < param_1`), values are signed 16-bit in places (`param_2[i]` is an `int16`, the
     listing orders `[3]` before `[2]`), and the default path at the end (`LAB_0043b477`) is part of the function's behaviour.
4. Compare with the records and keep the check (`checkpowerups.lua`). A record equal to the default result proves nothing, so the
   script lists the codes that have no case of their own.

### Tooling quirks (Ghidra MCP, project `Battlecry III.exe`, image base 0x00400000, 4874 functions)

- **Functions Ghidra has not created.** Auto-analysis missed code: `get_function_by_address` / `decompile` / `disassemble_function` answer
  `FUNCTION_NOT_FOUND` and `get_xrefs_to` shows `from_function: null` for calls out of it. Example: nothing is defined between
  `FUN_00525960` (ends 0x00525a67) and `FUN_005266c0`, yet code that tests power-ups lives there (the call sites 0x00525c31,
  0x00526007, 0x00526169 ... call `FUN_00437f70`; the code of one starts at 0x00525a70 with `83 ec 14` after `0x90` padding). Spot gaps by
  `list_functions` with a filter such as `FUN_0052` (a name substring: it lists a 64 KB window in address order) and looking for
  jumps in the addresses, or by `null` callers in `get_xrefs_to`. There is no tool to create a function; use `read_memory` (at most
  4096 bytes, hex plus ASCII, `??` for uninitialised bytes) and decode the x86 by hand: `68 imm32` pushes a code, `3d imm32` is
  `cmp eax, imm32`, `e8 rel32` a call (target = address of the next instruction + rel32), `66 8b` / `0f bf` load an int16. Parts of
  the 1.04 editor code have no functions either (the menu handler at `0x004bf3c0`, the message box callbacks).
- **Raw tables** are read with `read_memory` or straight from the exe (`.data` is mapped from the file by the PE section table, the
  tail of `.data` is zero-initialised and not in the file). Ghidra names some code tables as strings (`s_BKK1BKK2..._006089dc`) and others
  `DAT_<address>`; both are the same kind of table.
- **Decompiler artefacts**: `undefined2` / `undefined4` for `int16` / `int32` fields, `CONCAT22(...)` and `(short)` casts for packed pairs,
  calling conventions guessed (`__fastcall`, `__thiscall` with `this` in `ecx` shown as `param_1` or missing, `in_EAX` / `extraout_var`
  for half-registers), `switch` statements compiled to `if (x < K)` binary-search ladders, constants of 4-character codes printed
  as hex (a code's text is the little-endian byte order), and `WARNING: Globals starting with '_' overlap smaller symbols` (harmless).
- **No scripting and no emulation** (as found in the earlier session): Ghidra scripts are disabled and emulation returns register
  values only; everything has to come out of `decompile`, `disassemble`, `read_memory` and `get_xrefs_*`.
- **The file on disk differs from the one in Ghidra's path**: Ghidra shows `Battlecry III.exe` (md5 above); the same bytes are
  `Battlecry III-orig.exe` in the install (the other exes there, the German builds and the rebuilt `-` / `-dbg` ones, have other
  addresses and must not be used for them).
