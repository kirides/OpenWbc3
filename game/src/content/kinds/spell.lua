-- Content kind `spell` (stage 3, docs/data-driven/03-spells-effects.md 3.2): hero and troop spells. Key: "<sphere>.<index>" for the original
-- spells, "troop.<n>" for the troops' own, "modid:name" for mods.
--   slot      sphere * 10 + index (the number heroes, saves and the spell book store); the troops' spells have negative slots
--   sphere    the sphere id (a `sphere` record), index the place in it;  cost  mana;  name  Game.txt key (troop spells; hero spell names
--             come from <Lang>/Spells.txt by slot)
--   ai        "heal" | "attack" | "summon" | "buff": when computer heroes cast it
--   target    "none" (default) | "ground" (a placed building) | "enemy" | "ally" | "choice" (one of four in a dialog; "weather" is
--             the same with Change Weather's four when it has no `choices`)
--   choices   for "choice": the dialog's four entries { picture = anim code, frame = n (the picture is frame n of the code's
--             first animation) or unit = true (the army's 90x90 interface picture), text = <Lang>/Spells.txt key }; the effect
--             reads the pick as c.target.choice (0..3)
--   portal    the building whose presence near the hero adds a casting level (Black Portal / Circle of Power)
--   effect    function(c) or a recipe table (content/recipes.lua): what the spell does; `c` is the cast context (see src/game/fx.lua)
-- The cast context an effect gets (fx.ctx, src/game/fx.lua): the caster, the world and the numbers of this cast.
---@class SpellCast
---@field u Unit                        the caster
---@field w World
---@field h Hero                        the caster's hero record (troop casts: the unit's casting stand-in)
---@field id integer                    the spell slot
---@field target table?                 the clicked unit, building or cell ({ gx, gy }), or { choice = 0..3 }
---@field side integer
---@field t number                      world time of the cast (ms)
---@field lvl integer                   the success level (the original's "result", 1 = marginal)
---@field base integer                  the command radius before the Command spell
---@field r integer                     the area radius (command radius, Command spell included)
---@field rm integer                    the mastery radius
---@field empPct number                 the side's Empower percentage (0 without)
---@field ext number                    duration factor: 2 under Extend, else 1
---@field durMs number?                 the longest duration the cast asked for (ms): how long the view keeps its picture
---@field mroll integer?                the cast's d100 for its missiles
---@field portal (Unit|Building)?       where summons appear instead of around the caster

-- One entry of a "choice" spell's dialog (screens/spellchoice.lua).
---@class SpellChoice
---@field picture string               anim code
---@field frame integer?                frame of the first animation (else the 90x90 interface picture of an army)
---@field unit boolean?                 the picture is an army's interface picture
---@field text string?                  <Lang>/Spells.txt key of its name

-- The pictures and the sound of a cast (content/base/spells.lua PICTURES).
---@class SpellPictures
---@field cast string?
---@field target string?
---@field persistent string?
---@field base boolean?
---@field sound integer?

---@class SpellRecord
---@field id string
---@field slot integer                  sphere * 10 + index; the troops' spells are negative
---@field sphere string?                a `sphere` record id
---@field index integer?
---@field cost integer?                 mana
---@field name string?                  Game.txt key (troop spells)
---@field ai "heal"|"attack"|"summon"|"buff"|nil
---@field target string?                "none" | "ground" | "enemy" | "ally" | "choice" ("weather")
---@field choices SpellChoice[]?        the four entries of a "choice" spell's dialog
---@field portal string?                the building whose presence near the hero adds a casting level
---@field effect (fun(c: SpellCast))|table   the effect function or a recipe (content/recipes.lua)
---@field pictures SpellPictures?
---@field run fun(c: SpellCast)          derived: what the engine calls

return {
    name = "spell",
    doc = "spells",
    slotted = true,
    -- a mod spell names its sphere and its place in it and gets sphere slot * 10 + index
    ---@param rec SpellRecord
    ---@param kind ContentKind<SpellRecord>
    slotOf = function(rec, kind)
        local sphere = kind._R.sphere[rec.sphere]
        assert(sphere and type(rec.index) == "number", "needs a `slot`, or a `sphere` and an `index`")
        return sphere.slot * 10 + rec.index
    end,
    derived = { "run" },
    ---@param rec SpellRecord
    derive = function(rec)
        -- `run` is what the engine calls: the function itself, or the compiled recipe
        local effect = rec.effect
        local run = type(effect) == "table" and require("src.content.recipes").compile(effect) or effect
        rec.run = run --[[@as fun(c: SpellCast)]]
    end,
    refs = { { field = "sphere", target = "sphere", mode = "id", hard = true } },
    ---@param rec SpellRecord
    validate = function(rec)
        if type(rec.slot) ~= "number" then return "needs a slot" end
        if type(rec.effect) ~= "function" and type(rec.effect) ~= "table" then return "needs an effect (a function or a recipe)" end
        if rec.target == "choice" or rec.choices ~= nil then
            if type(rec.choices) ~= "table" or #rec.choices ~= 4 then return "a choice spell needs four `choices`" end
            for _, ch in ipairs(rec.choices) do
                if type(ch) ~= "table" or type(ch.picture) ~= "string" then return "every choice needs a `picture`" end
            end
        end
    end,
}
