---@meta
-- Definitions for the Lua language server (LuaLS): the globals a mod file sees in its sandbox (game/src/content/sandbox.lua) -
-- `content`, `fx`, `mod`, `include`, `asset` - for completion and checks in an editor. Nothing here runs. Add this file to the
-- language server's `workspace.library` together with openwbc3's `game/src` folder (the record classes `UnitRecord`, `SpellRecord`
-- ... and `ContentKind` live there: game/src/content/kinds/*.lua, game/src/content/registry.lua).

-- The registry API a mod gets: the kinds (`content.unit`, `content.spell` ...) and the patch helpers (docs/modding/registry.md).
---@class ModContent: ContentKinds
---@field REMOVE table                   assign it in a patch to delete a field
local ModContent = {}

-- A patch value that is assigned as it is (a function or table that must not be merged or called).
---@param v any
---@return table
function ModContent.value(v) end

-- Appends a copy of `v` (an element, a keyed record or an array of them) to `list`.
---@param list any[]
---@param v any
---@return any[]
function ModContent.append(list, v) end

---@param list any[]
---@param v any
---@return any[]
function ModContent.prepend(list, v) end

-- Inserts `v` before the element `match` addresses (an id, the element itself or a predicate).
---@param list any[]
---@param match any
---@param v any
---@return any[]
function ModContent.insertBefore(list, match, v) end

---@param list any[]
---@param match any
---@param v any
---@return any[]
function ModContent.insertAfter(list, match, v) end

-- Removes every element accepted by `pred` (a predicate, an id / value, or an array of those); returns how many.
---@param list any[]
---@param pred any
---@return integer
function ModContent.removeWhere(list, pred) end

-- A deep copy (functions are shared): start a new record from an existing one.
---@generic T
---@param v T
---@return T
function ModContent.clone(v) end

-- Ordered iteration over a table with mixed keys (use it instead of `pairs` where the order matters).
---@generic K, V
---@param t table<K, V>
---@return fun(): K, V
function ModContent.pairs(t) end

-- The unit, building or power-up record of a code, and the kind it came from.
---@param id string
---@return (UnitRecord|BuildingRecord|PowerupRecord)? rec
---@return string? kind
function ModContent.thing(id) end

---@param layer string
---@return boolean
function ModContent.isModLayer(layer) end

-- What a mod file knows about its own mod (from mod.lua).
---@class ModIdentity
---@field id string
---@field name string
---@field version string
---@field author string?
---@field scope "gameplay"|"cosmetic"

-- A reference to art or sound (docs/modding/assets.md).
---@class ModAssetRef
---@field png string?                    a PNG sprite set of the mod
---@field file string?                   a sound or icon file of the mod
---@field mod string?                    the mod that ships the file
---@field orig string?                   an original asset by code

---@class ModAssetBuilders
---@field sprite fun(path: string): ModAssetRef   a PNG sprite set of the mod
---@field sound fun(path: string): ModAssetRef
---@field icon fun(path: string): ModAssetRef
---@field orig fun(code: string): ModAssetRef     an original asset by code

-- The effect library spell effects are written against (game/src/game/fx.lua, docs/modding/effects.md). Every helper takes the
-- cast context `c` first.
---@class FxLibrary
---@field CW integer                     cell width in pixels
---@field CH integer                     cell height in pixels
---@field COL table<string, number[]>    ring colours by key ("fire", "ice", "magic", "heal", "poison", "earth", "light", "dark", "elec")
---@field ARMOUR_TYPE table<integer, integer>   the spells' damage types -> the armour table's
local FxLibrary = {}

-- Cells between two map objects (the larger of the two axis distances).
---@param a Unit|Building
---@param b Unit|Building
---@return integer
function FxLibrary.dist(a, b) end

-- Runs `fn` on the units within `radius` cells around `from` (the caster by default) that are `who` ("enemy", "ally", "other" =
-- not the caster, anything else = all) and pass `pred`: at most 24, row by row from the top. Returns how many.
---@param c SpellCast
---@param who "enemy"|"ally"|"other"|"all"
---@param radius number
---@param fn fun(o: Unit)
---@param from (Unit|Building|{ gx: integer, gy: integer })?
---@param pred (fun(o: Unit): boolean?)?
---@return integer
function FxLibrary.each(c, who, radius, fn, from, pred) end

-- The `n` nearest enemies within `radius`.
---@param c SpellCast
---@param n integer
---@param radius number
---@return Unit[]
function FxLibrary.nearestEnemies(c, n, radius) end

-- A ring of `cells` radius at pixel (x, y) (display only).
---@param c SpellCast
---@param x number
---@param y number
---@param cells number
---@param r number
---@param g number
---@param b number
function FxLibrary.ring(c, x, y, cells, r, g, b) end

-- A lightning bolt between two pixel positions (display only).
---@param c SpellCast
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param r number
---@param g number
---@param b number
function FxLibrary.bolt(c, x0, y0, x1, y1, r, g, b) end

-- A ring of the colour `key` around the caster (radius: the command radius).
---@param c SpellCast
---@param key string
---@param radius number?
function FxLibrary.aura(c, key, radius) end

-- `amount` raised by the side's Empower percentage.
---@param c SpellCast
---@param amount number
---@return integer
function FxLibrary.emp(c, amount) end

-- Seconds of a duration class of the `spell.duration` setting at mastery `m` (default: success level - 1).
---@param c SpellCast
---@param kind string
---@param m integer?
---@return number
function FxLibrary.dur(c, kind, m) end

-- Spell damage (dtype 1 fire, 2 ice, 3 electricity, 4 magic, 0 physical); hero resistances apply.
---@param c SpellCast
---@param target Unit|Building
---@param amount number
---@param dtype integer
function FxLibrary.hurt(c, target, amount, dtype) end

---@param c SpellCast
---@param target Unit|Building
---@param amount number
function FxLibrary.heal(c, target, amount) end

-- A timed status (a `status` record id) on `o` for `secs` seconds (Extend applies).
---@param c SpellCast
---@param o Unit
---@param kind string
---@param secs number
---@param value number?
---@param extra table?
function FxLibrary.buff(c, o, kind, secs, value, extra) end

-- The status on every ally in the command radius that passes `filter`, and a light ring. Returns how many.
---@param c SpellCast
---@param kind string
---@param secs number
---@param value number?
---@param filter (fun(o: Unit): boolean?)?
---@return integer
function FxLibrary.buffGroup(c, kind, secs, value, filter) end

-- The status on every enemy in the radius that is not under Ward.
---@param c SpellCast
---@param kind string
---@param secs number
---@param value number?
---@param radius number?
function FxLibrary.debuffEnemies(c, kind, secs, value, radius) end

-- `n` units of `code` for the caster's side around `near` (the caster, or the portal); they vanish after `secs` (nil: permanent).
---@param c SpellCast
---@param code string
---@param n integer
---@param secs number?
---@param near (Unit|Building)?
---@param illusion boolean?
---@return Unit[]
function FxLibrary.summon(c, code, n, secs, near, illusion) end

-- `summon` with the starting experience of the Gate power-up plus `per` for every spell level above the first.
---@param c SpellCast
---@param per number
---@param code string
---@param n integer
---@param secs number?
---@param extra number?
---@return Unit[]
function FxLibrary.summonXp(c, per, code, n, secs, extra) end

-- Runs `fn` on the corpses within `radius` cells of the caster.
---@param c SpellCast
---@param radius number
---@param fn fun(o: Unit)
function FxLibrary.corpses(c, radius, fn) end

-- A random item of `tier` for the hero (dropped on the ground when the pack is full).
---@param c SpellCast
---@param tier integer
function FxLibrary.giveItem(c, tier) end

---@param o Unit|Building
---@return boolean
function FxLibrary.isEvil(o) end
---@param o Unit|Building
---@return boolean
function FxLibrary.isPlanar(o) end
---@param o Unit|Building
---@return boolean
function FxLibrary.isCavalry(o) end
---@param o Unit|Building
---@return boolean
function FxLibrary.isInfantry(o) end
---@param o Unit|Building
---@return boolean
function FxLibrary.isUndead(o) end
-- Always false: the army records carry no mechanical flag.
---@param o (Unit|Building)?
---@return boolean
function FxLibrary.isMech(o) end
---@param o Unit
---@return boolean
function FxLibrary.isFlyer(o) end
-- A hero's level is its side's hero level, any other army's its own level.
---@param o Unit
---@return integer
function FxLibrary.levelOf(o) end
---@param o Unit|Building
---@param tag string
---@return boolean
function FxLibrary.hasTag(o, tag) end

-- Sets the side timer `key` (a side field holding an end time) to now + `secs` (Extend applies).
---@param c SpellCast
---@param key string
---@param secs number
function FxLibrary.sideTimer(c, key, secs) end

-- Whether the side buff `key` of `side` is running.
---@param w World
---@param side integer
---@param key string
---@return boolean
function FxLibrary.sideBuff(w, side, key) end

-- Sends the damage as a missile of picture `code` from the caster to `o` (it lands like an arrow).
---@param c SpellCast
---@param o Unit|Building
---@param amount number
---@param dtype integer
---@param code string
function FxLibrary.fire(c, o, amount, dtype, code) end

-- Damage to the `n` nearest enemies (bolts, or missiles of picture `missile`). Returns how many.
---@param c SpellCast
---@param n integer
---@param amount number
---@param dtype integer
---@param key string?
---@param radius number?
---@param missile string?
---@return integer
function FxLibrary.hitMany(c, n, amount, dtype, key, radius, missile) end

-- Area damage around the caster; `buildings` hurts buildings too, `friends` every other army, `missile` sends it as missiles.
---@param c SpellCast
---@param amount number
---@param dtype integer
---@param key string?
---@param radius number?
---@param buildings boolean?
---@param friends boolean?
---@param missile string?
function FxLibrary.areaHurt(c, amount, dtype, key, radius, buildings, friends, missile) end

-- Brings a dead unit back with `frac` of its hit points; returns 1, or 0 when there is no room.
---@param c SpellCast
---@param o Unit
---@param frac number
---@return integer
function FxLibrary.revive(c, o, frac) end

-- Replaces a unit by a new one of type `code` for `side`.
---@param c SpellCast
---@param o Unit
---@param code string
---@param side integer
---@return Unit?
function FxLibrary.replace(c, o, code, side) end

-- Places a building of `code` at the clicked cell for `secs` seconds (walls, portals, circles).
---@param c SpellCast
---@param code string
---@param secs number
---@return Building?
function FxLibrary.place(c, code, secs) end

-- Whether the caster's side has room for one more army of `code`.
---@param c SpellCast
---@param code string
---@return boolean
function FxLibrary.roomFor(c, code) end

-- What the other sides' spells do to an army `casterSide` has just summoned (Poison Gate, Corruption).
---@param w World
---@param s Unit
---@param casterSide integer
function FxLibrary.summonedFor(w, s, casterSide) end

-- The cast context of a unit casting spell `id` at success level `lvl`.
---@param u Unit
---@param id integer
---@param target table?
---@param lvl integer?
---@return SpellCast
function FxLibrary.ctx(u, id, target, lvl) end

-- The sandbox globals --------------------------------------------------------------------------------------------------------

-- The content registry: `content.unit["AHBX"]`, `content.unit:patch(...)`, `content.clone(rec)` ...
---@type ModContent
content = nil

-- The effect library for spell effects written as functions.
---@type FxLibrary
fx = nil

-- The mod's own manifest (id, name, version, author, scope).
---@type ModIdentity
mod = nil

-- Builders for references to the mod's art and sound (docs/modding/assets.md).
---@type ModAssetBuilders
asset = nil

-- Runs another Lua file of the mod (a path relative to the mod folder) in the same environment and returns what it returns.
---@param rel string
---@return any ...
function include(rel) end
