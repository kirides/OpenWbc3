-- The thirteen spell spheres of the original game and the duration classes of the spells (docs/data-driven/03-spells-effects.md).
-- The sphere order and the skill ids (10 + slot) are the original's (hero skills 10..22); the colours are the spell bar's.
-- The durations are the original's spell duration rule (the eight classes of FUN_005199e0, called with success level - 1):
-- seconds = base + mastery * step with mastery = success level - 1. normal = class 0, veryShort 1, building and arcane 2 / 5,
-- tower 3, wall 4, short 6, long 7; the army version 0x00529f30 adds the Extend percentage.
-- The names the research messages use (the binary's own English table at 0x006156a8, the one the research routine FUN_00438180 prints into
-- game string 0x81; it is the same in every language).
local RESEARCH = { "Healing Spell", "Summoning Spell", "Nature Spell", "Illusion Spell", "Necromancy Spell", "Pyromancy Spell",
               "Alchemy Spell", "Rune Spell", "Ice Spell", "Chaos Spell", "Poison Spell", "Divination Spell", "Arcane Spell" }

return {
    ---@param content Content
    define = function(content)
        local list = {
            { "healing", "Healing", { 0.4, 0.9, 0.5 } }, { "summoning", "Summoning", { 0.8, 0.5, 1 } },
            { "nature", "Nature", { 0.5, 0.8, 0.3 } }, { "illusion", "Illusion", { 0.7, 0.7, 1 } },
            { "necromancy", "Necromancy", { 0.6, 0.4, 0.7 } }, { "pyromancy", "Pyromancy", { 1, 0.5, 0.2 } },
            { "alchemy", "Alchemy", { 0.9, 0.8, 0.4 } }, { "runes", "Runes", { 0.7, 0.6, 0.4 } },
            { "ice", "Ice", { 0.5, 0.8, 1 } }, { "chaos", "Chaos", { 0.9, 0.3, 0.6 } },
            { "poison", "Poison", { 0.6, 0.9, 0.2 } }, { "divination", "Divination", { 1, 1, 0.7 } },
            { "arcane", "Arcane", { 0.8, 0.8, 0.9 } },
        }
        for i, s in ipairs(list) do
            content.sphere:add({ id = s[1], slot = i - 1, skill = 10 + i - 1, name = s[2], colour = s[3], researchName = RESEARCH[i], icon = i - 1 })
        end
        content.setting:add({ id = "spell.duration", doc = "spell duration classes in seconds: { base, step per mastery level }",
            value = { normal = { 60, 60 }, veryShort = { 5, 5 }, building = { 120, 60 }, tower = { 600, 120 }, wall = { 600, 600 },
                      arcane = { 120, 60 }, short = { 30, 30 }, long = { 120, 120 } } })
    end,
}
