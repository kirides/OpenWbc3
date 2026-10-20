-- The resources and the numeric rules of the economy and the battle field (docs/data-driven/04-heroes-abilities-rules.md 4.6): `resource`
-- records and `setting` records. The numbers are the original game's rules (unless a record says
-- `own`); the comment of a setting names what it is.
return {
    ---@param content Content
    define = function(content)
        -- The four resources in the order the engine lists them. `letter` is the resource column of Building.cfg (the mine types
        -- BRG.. / BRM.. / BRC.. / BRS.. end in it), `colour` the minimap / HUD colour.
        for _, r in ipairs({ { "gold", "G", { 193, 193, 44 } }, { "metal", "M", { 192, 201, 255 } },
                             { "crystal", "C", { 39, 178, 165 } }, { "stone", "S", { 139, 139, 139 } } }) do
            content.resource:add({ id = r[1], letter = r[2], colour = r[3] })
        end

        local function setting(id, value, doc, own)
            content.setting:add({ id = id, value = value, doc = doc, own = own })
        end
        -- economy
        setting("eco.startAmount", { [0] = 20, 100, 300, 600, 1000 }, "starting amount of each resource by the resources setting (Very Low .. Very High)")
        setting("eco.mineProduce", { [0] = 1, 2, 4 }, "produce of a mine by its level")
        setting("eco.mineReserve", { [0] = 3000, 8000, 15000 }, "reserve of a mine by its level")
        setting("eco.keepAmount", { [0] = 2, 5, 10, 15, 20, 30 }, "army limit a keep gives by its level")
        setting("eco.incomeTime", 4000, "ms between two incomes of the mines")
        setting("eco.hordeAmount", { [0] = 0, 5, 10, 15, 20, 25, 30, 35, 40, 50 }, "army limit the Slave Horde / Brood power-ups give by level")
        setting("eco.incomeAmount", { [0] = 0, 1, 2, 4, 6, 8, 10, 12 }, "Income / Hard Labor power-ups: extra produce per mine by level")
        setting("eco.convertTime", 39000, "ms a hero needs to convert a building at conversion rating 8")
        setting("eco.convertRange", 4, "cells from which a hero converts")
        setting("eco.giftAmounts", { 50, 100, 200, 300, 400, 500 }, "the amounts of the resource gift dialog")
        setting("eco.giftResources", { [0] = "gold", "metal", "stone", "crystal" },
            "the resource order of the gift dialog's buttons (the gift routine FUN_00559690 of the alliance dialog)")
        setting("eco.repairSeconds", { [0] = 90, 45 }, "seconds to repair a building by the repair setting")
        setting("eco.attackInterval", { [0] = 6000, 3000, 2400, 1900, 1600, 1400, 1200, 1000, 900, 800, 700, 600, 500, 450, 400, 350, 300 },
            "the computer's attack pacing by level")
        setting("eco.keepConvert", { range = 28, seconds = 150, aiRange = 32, aiSeconds = 120 }, "keep conversion: cells and seconds")
        setting("eco.conversionListMax", 8, "at most eight buildings in one conversion (FUN_005489e0 / FUN_00532640)")

        -- the battle field
        setting("unit.troopManaLeech", { AHGB = 5 }, "mana a kill gives a troop that is not a hero (the Black Mage; the mana leech routine FUN_00526de0)")
        setting("unit.stepTime", { [0] = 1200, 900, 800, 700, 600, 550, 525, 500, 475, 450, 430, 410, 390, 370, 350, 340, 330, 320,
                                   310, 300, 290, 280, 275, 270, 265, 260, 255, 250, 245, 240, 235 },
            "ms for one walk step (one cell) by speed value 0..30 (the table at 0x0061178c of the binary)")
        setting("fog.viewRadius", { [0] = 4, 4, 7, 7, 7, 10, 10, 10, 10, 13, 13, 13, 13, 16, 16, 16, 19, 19, 19,
                                    13, 13, 13, 16, 16, 16, 13, 13, 13, 16, 16 }, "vision radius in cells by the unit type's view index")
    end,
}
