# Stage 5 - assets: sprites, sounds, portraits, icons, music, terrain, text

Goal: content records refer to art, sound and text through **references**, a layered **asset resolver** finds them (the
player's WBC3 install, then mod folders), and a mod ships only its own files. The repository still contains no
original asset. Prerequisite: stage 1 only; can run in parallel with stages 2-4 (each later stage adopts the
reference types as it lands). Overview: `README.md`.

## 5.1 Today

| asset | lookup today | problem for mods |
|---|---|---|
| sprite sets | `anims.get(code)` -> `vfs.find(code .. ".ani")`, sheet `code .. suffix .. ".rle"/".bmp"`; 9 animation slots (stand, walk, fight, die, ambient, special, convert, spell, interface); team colour via palette indices 224..238 and `RAMPS` | only original archives are searched; the format is the original's palette-indexed RLE; no way to say "this unit uses these PNGs" |
| voices | `voices.lua`: `<CODE>Select<n>.wav` in `<Pack>Voices<Lang>.xcr`, pack derived from the sprite's archive | location derived from the sprite archive; no per-unit override |
| sound effects | `sound.lua`: `vfs.read(arch, name)` / `vfs.find`, optional converted `.ogg` | names are literals scattered in code (`MISSILE_SOUND`, `moveSound` ids ...) |
| portraits | `portraits.lua`: `Portrait%02d.bmp` in `Assets/Heroes/Portraits.xcr` | by number; `herocustom.PORTRAITS` |
| icons | `Panel_Icons`, `SkillIcons.bmp`, `BM_DAMAGEICONS`, item sheet `Items.bmp` rows: atlas indices hard-coded in `hud.lua` (`CPI`), `armyabilities`, `items` | atlas index only |
| interface | `xci.lua` from `War4Int.xci` / `War4Gfx.xcg`; `interface.lua` | engine UI chrome: not content, not patchable in this plan |
| music | `music.lua`: converted `.ogg` / sets | |
| terrain | `.ter` + `.bmp` by id (`terrain.lua`), features `.fea` | tile atlas in original format |
| text | `strings.lua`: `[KEY]<tab>text` files per language; items / spells from `Items.xml`, `Spells.txt` | text keys are file + key; `text` conversions are CP1252 |

## 5.2 Asset references

A reference is a plain Lua value, resolved lazily at first use (never at `define`):

```lua
sprite = "AHBX"                              -- shorthand: original sprite set by code
sprite = { orig = "AHBX" }                   -- same, explicit
sprite = { orig = "AHBX", pal = "AHBX", ... }-- original frames, with overrides (e.g. other palette set)
sprite = { png = "gfx/orc_shaman/", ... }    -- mod-provided, relative to the mod folder (see 5.4)
sound  = { orig = "Assets/SoundFX.xcr/Whip.wav" } | { file = "sfx/boom.ogg" }
text   = { orig = "Game.txt#0105" } | { key = "mymod:shaman.name" } | "plain literal"   -- literal = not localised
icon   = { atlas = "panel", index = 46 } | { file = "gfx/icons/foo.png" }
```

`textref` shorthand in the other stage docs = the `text` forms. Records never contain original text, only keys into
the install's files; the resolver returns UTF-8 strings (the CP1252 conversion stays in `core/text.lua`).

## 5.3 The resolver (`src/assets/`)

```
assets.sprite(ref)  -> AnimSet            (replaces anims.get; the AnimSet API stays: has/frames/draw/pickRect/effectCentre ...)
assets.sound(ref)   -> SoundData | nil    assets.music(ref) assets.icon(ref) assets.portrait(ref) assets.text(ref)
assets.provider(name, p)                  -- register a provider; built-ins below
```

Providers, searched in this order for any reference without an explicit source:

1. mod folders in reverse load order (a later mod's file wins) - `file` / `png` / `ogg` / `wav`;
2. `orig` = the install through `vfs` (unchanged `PatchData` first order);
3. `converted/` (existing, for the Vorbis / Theora conversions).

Rules:

- `vfs` stays the reader for the original archives. A thin `assets.vfsOverlay` lets a mod **replace an original entry**
  by dropping a same-named file in `override/` (`override/AHBX.ani`, `override/Whip.wav`) - the simplest "re-skin"
  route; precedence documented.
- Caches keyed by reference identity + side colour + palette (what `AnimSet.images` is today). `assets.clear()` on mod
  change / language change (the options screen already calls `anims.clear`).
- Headless runs (`--selftest`) still must not touch `love.graphics`: providers are inert until asked for an image.
- Every reference that fails to resolve logs once (`asset <ref> missing (from <record> <mod>)`) and returns the
  engine's **placeholder** (a magenta-checker sprite / silent sound). A missing asset never crashes a battle.

## 5.4 Mod sprites

The original format is a palette-indexed RLE with 8 side-colour ramps and "effect" ranges. Mods need a format they can
author with common tools. Proposal (decision needed at the start of the stage, recommended: option A):

- **A. PNG strips + Lua descriptor.** `sprite = { png = "gfx/shaman", ... }` points at a folder with
  `stand.png`, `walk.png`, `fight.png`, `die.png`, `cast.png` ..., each a sheet laid out like the original (frame `f`,
  direction `d` at `(f * w, d * h)`; `dirs = 8` default, 5 or 1 allowed and mirrored) plus `anim.lua`:
  `return { size = {w=64,h=64}, origin = {32,56}, frames = { stand = 1, walk = 8, fight = 6, die = 8 },
  speed = ..., effect = {...}, selection = {...}, dirs = 8 }`. The descriptor corresponds 1:1 to the nine `.ani`
  records, so everything that reads `AnimSet.info` keeps working. Team colour: an optional `<anim>_team.png` mask
  (white = full team colour, grey = shade) tinted with the same ramps the original palette uses; without a mask the
  sprite is not recoloured.
- **B. Author tool.** `tools/spritepack` (separate, later) to convert existing sets to PNG for editing. Because it
  would output original art, the tool is a local helper only, output gitignored, and it is **not** a way to distribute
  assets.

`AnimSet` becomes an interface with two implementations (`WbcAnimSet`, `PngAnimSet`); `draw`, `drawCell`,
`drawInterface`, `pickRect`, `effectCentre`, `image` stay the contract, so `battle.lua`, `hud.lua`, `armysetup.lua` do
not care. Shadows: `shadow = "auto"|"none"|png` (the original uses `RS` shadow runs).

Sounds: `.ogg` / `.wav` from the mod folder, loaded by `sound.lua`'s existing path (`newFileData` from bytes read through
`core/fs.lua`, because mod folders are outside LÖVE's save directory).

## 5.5 Voices, speech and music

- `unit.speech = { select = {refs}, order = {refs}, ready = ref, attack = ..., die = ... }`; the importer fills the
  original unit's list from the file-name patterns `voices.lua` already uses (`<CODE>Select<n>.wav`), so that code
  moves into the importer and `voices.lua` plays the list. `race.voiceSet` / `herocustom.VOICES` become `voiceset`
  records (stage 4 reference).
- `music`: `content.musicset` (`id`, tracks, `mode = battle|menu`), default = what `music.lua` does today.
- `systemSpeech` (the 29 system speech lines, `docs/implemented.md` "System speech") become `setting "speech.system"` with sound
  references, so the missing lines can be added as data when the work in that guide is done.

## 5.6 Terrain, features, minimap colours

`terrain` kind: `id, type (TYPE enum), move legality (LEGAL), tile art (bmp ref), minimap colour (TERRAIN_RGB), editor
tree path`. The `.ter` importer builds the 669 records. A mod tile set is `terrain` records whose `tile` reference is a
PNG atlas; `fea` features similar. Pathing reads `terrain.type` classes, so new tiles must pick an existing type (no
new movement types in this plan).

## 5.7 Strings and localisation

- `content.text` kind: `id = "mymod:shaman.name"`, `en = "...", de = "..."` or `{ lang = "..." }`; the resolver picks
  `config.language`, then English, then the key. Mod folders may also carry `lang/<Language>.lua` files (flat
  `key = text`) so translators do not edit the content.
- Original text stays external: `orig = "Game.txt#0105"` reads `strings.get("Game.txt", "0105")`. `Help.cfg` (unit /
  building / power-up help) keys are produced by `strings.help(code)`; a unit record may carry its own `help =
  { name, desc, req }` which wins over the lookup.
- `text.fromCP1252` stays an importer concern; mod text is UTF-8.
- Formatting placeholders: the original strings use `%d`-style formats (`text(679):format(b.combat)`); mod text uses
  the same, verified by a `finalise` check when the record declares `args = n`.
- `docs/localization.md` gets a section for mod text.

## 5.8 Work breakdown

1. `assets/` module with resolver, provider list, placeholder, cache; `anims.get` / `sound.*` become calls into it.
   Behaviour unchanged for `orig` references.
2. Reference parsing for the shorthand forms; unit tests (resolution order, override folder, placeholder).
3. `PngAnimSet` + descriptor loader + team-colour mask; selftest with a procedurally generated test sheet (no
   original art in tests).
4. Move literal sound names (`MISSILE_SOUND`, `moveSound`, `combatSound`, `deathScream` ids) into the `missile` and
   `unit` records as references; voices into `unit.speech`.
5. Icons: `iconref` for ability / skill / spell / item / powerup / resource; `hud.CPI` indices remain as the `panel` atlas
   names.
6. Terrain / feature records + PNG atlas.
7. Text kind + localisation files.
8. Docs: `docs/modding/assets.md` with the PNG layout, a worked example mod.

## 5.9 Acceptance

- A mod defines a unit with its own PNG sprite set (generated by a script in the mod's `tools`, trivial shapes),
  its own `.ogg` select sound and its own name text in two languages; it walks, fights, dies, is selectable, and is
  drawn with the owning side's colour; removing the PNG falls back to the placeholder and logs once.
- The same mod works with the original install absent for its own assets (no crash; original references use
  placeholders), proving there is no hidden dependency on original files for mod-owned content.
- Re-skin by `override/` works for one unit and one sound.
