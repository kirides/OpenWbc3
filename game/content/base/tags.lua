-- Traits of units and buildings (docs/data-driven/02-entities.md "Tags"): the code sets that were scattered through the
-- engine (unit.lua DRAGON / CRITTER / NO_MINE, powerups.lua DAEMONS / INSECTS / TREANTS / KNIGHTS ..., economy.lua NO_DRAGONS /
-- NO_FLIERS ...) as `tag` records plus the codes that carry them, and the named per-type behaviours (`unit.behaviour`).
-- Tags implied by the typed Army.cfg columns (`from`) need no list. The numbers and code lists are the original game's rules as
-- the engine had them; a comment names the 1.04 binary routine of the rule where it was checked.
local function codes(text)
    local out = {}
    for c in text:gmatch("%S+") do out[#out + 1] = c end
    return out
end

-- Tags implied by typed fields.
local DERIVED = {
    { "evil", { alignment = "evil" }, "evil-aligned units (the Army.cfg alignment column)" },
    { "good", { alignment = "good" }, "good-aligned units" },
    { "planar", { planar = true }, "extra-planar units (the X of the status column)" },
    { "titan", { titan = true }, "titans (the T of the status column)" },
    { "cavalry", { cavalry = true }, "cavalry (the C of the status column)" },
    { "infantry", { infantry = true }, "infantry (the I of the status column)" },
    { "flyer", { moveClass = "air" }, "flying units (the flyer flag of the unit type)" },
    { "undead", { raceClass = "U" }, "undead (race letter U)" },
    { "daemonClass", { raceClass = "V" }, "the Daemon race's units (race letter V)" },
    { "mechanical", { raceClass = "C" }, "mechanical units (race letter C)" },
}

-- Explicit tags: id, doc, unit codes, building codes.
local EXPLICIT = {
    { "dragon", "the six dragons: idle frames 160 ms instead of 100, taken away by the No Dragons game mod (FUN_0040c990)",
      "AADR AADU AADB AADC AADW AADG" },
    { "critter", "neutral animals: no garrison, no value, ignored by the attitudes, immune to psychic effects",
      "ACSH ACCO ACGO ACPE ACCA ACSO ACTU ACSE" },
    { "noMine", "builders that cannot work a mine (FUN_00523e70): wisps, treants, the eagle and the elven general",
      "AEBX AEAX AWJX AWKX AEGX" },
    { "noGarrison", "units that never garrison besides critters and illusions (the Eye, FUN_0051c240)", "AAEY" },
    { "knight", "the knights AHFX AHDX AHEX: Knight's Quest, Full Plate Armor, the retinue naming set", "AHFX AHDX AHEX" },
    { "daemon", "the summoned daemons that the Summon Daemon power-ups speed up", "AADE AAIM AVBX AVIX AVCX AVDX" },
    { "insect", "the Swarm's insect troops (Insect Brood production bonus)", "ARBX ARMX ARIX ARCX ARGX" },
    { "treant", "treants: no walls, Iron Bark", "AWJX AWKX" },
    { "slayerKnight", "Slayer Knight and Doom Knight", "AULX AUAX" },
    { "noFlame", "units flame arrows do not set alight: Ballista, Barbarian, Sprite, Scorpion", "ADNX ABIX AASP ASSC" },
    { "resistant", "units with the Resistance power-up bonus", "ADGX ADSX AUIX ARJX AUCX AADU" },
    { "assassin", "assassins (Assassin skill)", "AKJX AMJX AAWA" },
    { "undeadMorph", "the units of the Undead morph chain (built by the Graveyard)", "AUJX AUKX AUXX AUMX AULX AUAX" },
    { "aiDragon", "dragons and titans, which the computer players' army planner counts separately (aiplan.lua)",
      "AADR AADL AADF AADS AADW AADC AADU AADB AADG ATHX ATDX ATEX ATKX ATWX ATAX ATOX ATBX ATMX ATFX ATVX ATUX" },
    { "flag", "the capture-the-flag flag: cannot be hurt in that game", nil, "BMFL" },
    { "temple", "the four temples (FUN_0052fc50): never destroyed for good", nil, "BTCE BTIN BTDR BTEL" },
    { "crystalTower", "the Crystal Tower: its shot crystallizes the army it kills (the tower shot FUN_0052d2f0 gives this code's"
      .. " missile the special attack 5, the impact FUN_005427e0 sends the crystallize message 0x214)", nil, "BWTF" },
    { "noFliers", "buildings the No Fliers game mod takes away (FUN_0040c990)", nil, "BAE0 BAE1 BAE2 BAV0 BAV1 BAV2 BAN0 BAN1 BAN2" },
}

-- Named behaviours of single unit types: unit code -> behaviour fields (kinds/unit.lua documents them).
local BEHAVIOUR = {
    AWGX = { conversion = { num = 3, den = 4 } },                           -- Dryad general: conversion at three quarters of the time
    AAGX = { conversion = { num = 3, den = 4, powerup = "PBRO" } },         -- Bronze golem general with Bronze General
    ADBX = { mineSkill = 2 }, AABX = { mineSkill = 2 },                     -- Dwarf Smith and Engineer (FUN_00523e70)
    AOCX = { psychWith = { powerup = "PRAB", type = 6, strength = 5 } },    -- Rabies gives the Wolf Rider's attack a disease of strength 5
    AOMX = { regenMultiplier = 4 },                                          -- regenerates four times as fast
    -- The critters' threat reaction (FUN_0051a230): the animals (the Souls are not among them) rest unless a roll of 1..100 is above
    -- this: sheep 79, camels 86, cows / turtles / seals 99, geese / penguins 9 (attitude.lua critterRest)
    ACSH = { critterRest = 79 }, ACCA = { critterRest = 86 }, ACCO = { critterRest = 99 }, ACTU = { critterRest = 99 },
    ACSE = { critterRest = 99 }, ACGO = { critterRest = 9 }, ACPE = { critterRest = 9 },
}

-- The animals the hunters of the target search (the 1.04 binary's FUN_005334f0, its critter branch, the 11 codes below) go after:
-- `behaviour.hunts` = { prey = codes, wounded = only while hurt (priority 1 + a quarter of the missing hits, 201 at most),
-- mana = the daemons: only below that mana level (priority 1 + (mana - level) * 4), heroRace = only a hero of that race }; a
-- hunt without the two is worth priority 1. The prey lists are the binary's: the Catapult does not hunt camels, nor the Troll
-- turtles, penguins or seals.
local PREY_MINOTAUR = "ACSH ACCO ACCA ACPE ACSE ACTU"
local PREY_MINOTAUR_KING = PREY_MINOTAUR .. " ACGO"
local HUNTS = {
    AMIX = { prey = PREY_MINOTAUR, wounded = true },
    AMNX = { prey = PREY_MINOTAUR_KING, wounded = true }, AMGX = { prey = PREY_MINOTAUR_KING, wounded = true },
    AMMX = { prey = PREY_MINOTAUR_KING, wounded = true },
    ABHX = { prey = PREY_MINOTAUR_KING, wounded = true, heroRace = "minotaur" },
    ASCA = { prey = "ACCO" },
    AOMX = { prey = "ACSH" },
    AADE = { prey = "ACSO", mana = 7 }, AVGX = { prey = "ACSO", mana = 7 }, AVHX = { prey = "ACSO", mana = 7 },
    AVJX = { prey = "ACSO", mana = 7 },
}

-- The retinue naming set of single unit types (the retinue list routine, binary FUN_0043f3e0).
local NAME_SET = { [15] = "AWGX AEXX AASP AFJX", [11] = "AAHA AVIX AFGX", [1] = "AAIM AADE", [2] = "AHFX AHEX AHDX" }

return {
    ---@param content Content
    define = function(content)
        for _, t in ipairs(DERIVED) do content.tag:add({ id = t[1], from = t[2], doc = t[3] }) end
        for _, t in ipairs(EXPLICIT) do content.tag:add({ id = t[1], doc = t[2] }) end
    end,
    ---@param content Content
    patch = function(content)
        local function record(code)
            local rec = content.unit[code] or content.building[code]
            if not rec then content.warn("tag data names %s, which has no record", code) end
            return rec
        end
        for _, t in ipairs(EXPLICIT) do
            for _, list in ipairs({ t[3] or "", t[4] or "" }) do
                for _, code in ipairs(codes(list)) do
                    local rec = record(code)
                    if rec then
                        rec.tags = rec.tags or {}
                        rec.tags[#rec.tags + 1] = t[1]
                    end
                end
            end
        end
        local codesInOrder = {}
        for code in pairs(BEHAVIOUR) do codesInOrder[#codesInOrder + 1] = code end
        table.sort(codesInOrder)
        for _, code in ipairs(codesInOrder) do
            local rec = record(code)
            if rec then
                rec.behaviour = rec.behaviour or {}
                for k, v in pairs(BEHAVIOUR[code]) do rec.behaviour[k] = v end
            end
        end
        local hunters = {}
        for code in pairs(HUNTS) do hunters[#hunters + 1] = code end
        table.sort(hunters)
        for _, code in ipairs(hunters) do
            local rec = record(code)
            if rec then
                local h = HUNTS[code]
                rec.behaviour = rec.behaviour or {}
                rec.behaviour.hunts = { prey = codes(h.prey), wounded = h.wounded, mana = h.mana, heroRace = h.heroRace }
            end
        end
        for set, list in pairs(NAME_SET) do
            for _, code in ipairs(codes(list)) do
                local rec = record(code)
                if rec then
                    rec.behaviour = rec.behaviour or {}
                    rec.behaviour.nameSet = set
                end
            end
        end
    end,
}
