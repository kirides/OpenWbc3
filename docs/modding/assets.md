# Assets in mods

A record refers to art by **reference**; a mod ships only files it made itself (the repository and mods contain no original art).
Nothing is read when the records load: a reference is resolved the first time something is drawn.

## Sprite references (`sprite` of a unit or building record)

```lua
u.sprite = "AHBX"                          -- the install's sprite set by code (what every original record has)
u.sprite = { orig = "AHBX" }               -- the same, explicit
u.sprite = asset.sprite("gfx/shaman")      -- a PNG sprite set in this mod's folder (asset.sprite adds { mod = <your id> })
u.sprite = { png = "gfx/shaman" }          -- the same, searched in every mod, the latest first
```

An original unit has no `sprite` field: its set is the one named by its code. A **mod unit without a sprite, or whose sprite cannot be
found, is drawn as a magenta checker and the problem is logged once** (`asset: ...`); it still plays. A mod unit that should look like an
original one just names that set (`sprite = "AHFX"`).

## PNG sprite sets

A folder `gfx/<name>/` of the mod:

```
anim.lua       return { size = { w = 64, h = 64 }, origin = { 32, 56 }, dirs = 8,
                        frames = { stand = 1, walk = 8, fight = 6, die = 8 },
                        hit = 3, effectOrigin = { 32, 10 }, selection = { 32, 56, 1 } }
stand.png walk.png fight.png die.png ambient.png special.png convert.png spell.png
stand_team.png ...                    optional team colour masks
```

* One sheet per animation. Frame `f` of direction `d` is the cell at `(f * w, d * h)`. Directions run clockwise from north.
* `dirs = 8` (default): all eight rows. `dirs = 5`: north, north-east, east, south-east, south; the west half is the mirror image.
  `dirs = 1`: one row, the same picture in every direction.
* `size` is the cell size, `origin` the point of the cell that sits on the unit's position (its feet). `frames` lists the animations the
  set has (a missing one is simply not played); `hit` is the frame of `fight` in which the blow lands; `effectOrigin` is where status
  icons and effects hang; `selection` is `{ x, y, size }` of a building's selection ring: the ring's top left corner sits `x, y`
  pixels left of and above the position, `size` is its size class 0 .. 6 (the rings of `SelectionRings.BMP`; a unit's ring does not use
  it). `anims = { walk = { size = ..., origin = ... } }` overrides size and origin for one animation.
* **Team colour**: a `<anim>_team.png` of the same size marks the pixels that take the side's colour: the mask's brightness picks the
  shade of the side's colour ramp (white = lightest). Without a mask the sheet is not recoloured.
* `anim.lua` runs without any environment: it is data, not code.

## Replacing an original file: `override/`

A file `override/<entry name>` in a mod replaces the install's entry of that name for the whole game (`override/AHBX.ani`,
`override/Whip.wav`, `override/Portrait05.bmp` ...). Names are matched without regard to case. Later mods win over earlier ones and over
the install. This is the simplest way to re-skin one thing; the replacement must be in the original's own format.

## Remaining references

Sounds, icons, portraits, terrain and text are still looked up by the engine's own names (`docs/data-driven/05-assets.md` 5.5-5.7 are the
plan for references to them); a mod can already replace them through `override/`.
