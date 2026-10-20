# Spells: records, the effect library `fx` and recipes

Spells are `spell` records in the content registry; their effects are written against the effect library (`game/src/game/fx.lua`)
or composed as *recipes* (`game/src/content/recipes.lua`). The 130 hero spells and the troops' own spells of the original are in
`game/content/base/spells.lua` (ids `<sphere>.<index>`, `troop.<n>`), the spheres in `base/spheres.lua`.

```lua
content.sphere:add{ id = "mymod:chrono", slot = 13, skill = 150, name = "Chronomancy", researchName = "Chronomancy Spell",
                    colour = { 1, 1, 1 }, icon = 12 }
content.spell:add{ id = "mymod:haste", slot = 130, sphere = "mymod:chrono", index = 0, cost = 5, ai = "buff", name = "Hasten",
                   effect = { { status = { id = "speed", who = "self", seconds = { duration = "normal" },
                                           value = { base = 2, perLevel = 1 } } } } }
content.spell:patch("healing.4", { cost = 7 })       -- retune
content.spell:remove("healing.9")                     -- heroes lose it from the book
```

* `slot` is the number heroes, saves and the spell book store: `sphere.slot * 10 + index`. Sphere slots are contiguous from 0
  (a mod sphere takes the next free ones); a hero knows the spells of a sphere according to its casting skill, the hero skill
  `sphere.skill` (10 + slot for the original spheres).
* `target`: `"none"` (default), `"ground"` (a building the spell places), `"choice"` (the four-picture dialog of Change Weather, Elementalism and Raise Champion: `choices` lists the four entries `{ picture = <anim code>, frame = n | unit = true, text = <Spells.txt key> }`, the effect reads the pick as `c.target.choice`, 0..3; `"weather"` without `choices` shows Change Weather's four); `ai`: `"heal"`,
  `"attack"`, `"summon"`, `"buff"` is when computer heroes cast it; `portal`: a building near the hero that adds a casting level.
* `effect` is a function `function(c)` or a recipe.
* `pictures` (optional): the effect pictures of a cast, `{ cast = code, target = code, persistent = code, base = true }` - `cast` plays on
  the caster, `target` on every army or building the cast changed, `persistent` loops on them while the spell's timed effects last (`base`:
  at the feet, behind the army). A code is an `EZnn` / `EFnn` / `EXnn` picture of the install or one of the emitter codes of
  `gfx/emitters.lua`. The original spells carry the table read from the game (`docs/spells.md` "Effect pictures"). Presentation only.

## The cast context `c`

`c.u` (the casting unit), `c.h` (its hero), `c.w` (the world), `c.side`, `c.target`, `c.lvl` (the success level, 1 = marginal),
`c.r` / `c.rm` (radius in cells and mastery radius), `c.base` (the command radius), `c.empPct` (the side's Empower), `c.ext`
(Extend: 2 or 1), `c.portal`. Spell effects must only read the context and call `fx`; they must be deterministic (all peers run
them): use `math.random` (reseeded per tick in network games), never the clock.

## `fx` (all take the context first)

| group | helpers |
|---|---|
| targeting | `each(c, who, radius, fn [, from])` (`"enemy"`, `"ally"`, `"other"`, `"all"`; at most 24 units, row by row), `nearestEnemies(c, n, radius)`, `corpses(c, radius, fn)` |
| damage, healing | `hurt(c, target, amount, damageType)`, `heal(c, target, amount)`, `areaHurt(c, amount, damageType, colourKey, radius, buildings, friends, missile)`, `hitMany(...)`, `fire(c, target, amount, damageType, missile)`, `emp(c, n)` (apply Empower) |
| status | `buff(c, unit, kind, seconds, value, extra)`, `buffGroup(c, kind, seconds, value, filter)`, `debuffEnemies(c, kind, seconds, value, radius)`, `sideTimer(c, key, seconds)`, `dur(c, class [, mastery])` |
| creation | `summon(c, code, n, seconds, near, illusion)`, `summonXp(c, xpPerLevel, code, n, seconds)` (both make nothing and say "too many men" when one army of `code` does not fit under the side's army limit; `roomFor(c, code)` is that check, code `nil` = a unit value of 1), `place(c, building, seconds)`, `replace(c, unit, code, side)`, `revive(c, unit, fraction)`, `giveItem(c, tier)` |
| looks | `ring(c, x, y, cells, r, g, b)`, `bolt(...)`, `aura(c, key, radius)` |
| queries | `hasTag(unit, tag)`, `isEvil / isUndead / isPlanar / isCavalry / isInfantry / isFlyer(unit)`, `dist(a, b)`, `levelOf(unit)` |

## Recipes

A recipe is an array of steps; every step has one action key:

| step | meaning |
|---|---|
| `{ heal = { target = "self"\|"allies", amount, empower, cure, radius, aura, auraRadius } }` | heal the caster or the allies in the radius |
| `{ status = { id, who = "self"\|"allies"\|"enemies", seconds, value, radius, filter, effect } }` | a timed status; `"allies"` is the group buff (with a light ring) |
| `{ damage = { amount, empower, damageType, key, radius, buildings, friends, missile } }` | area damage around the caster |
| `{ summon = { unit, count, seconds, xp } }` | troops of the caster's side |
| `{ aura = "heal" }` or `{ aura = { key = "light", radius = 2 } }` | a ring around the caster |

Amounts are `n` or `{ base, perLevel, perLevelSq }` (of the success level), durations `n` seconds or `{ duration = "normal" }`
(a class of the `spell.duration` setting: `veryShort short normal medium long longPlus building tower wall arcane slowArmy
spellCastingArmy`), radii `"r"`, `"rm"` or cells, filters `{ tag = "cavalry", without = "evil", notSelf = true }`.
About forty of the original spells are recipes; the rest keep a function because they need arithmetic the steps do not offer.
An unknown step is an error of the spell at load time.

## Verifying a port

`pwsh tools/dev/golden.ps1 -Baseline <commit> -Spells` casts every spell at every success level in a seeded world at the baseline
commit and at the working tree and compares the resulting state of the world (units, statuses, buildings, side timers, hero).
