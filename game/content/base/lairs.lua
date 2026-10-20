-- The lairs (docs/data-driven/04-heroes-abilities-rules.md 4.5): what a neutral nest breeds, how often, and which boss it leaves behind. The
-- original's lair table (0x94-byte records from 0x005fb338 of the 1.04 binary, read by the spawner FUN_00404e10): the intervals, the spawn groups,
-- the troop levels and the boss levels are the original's numbers. A spawn group is { troops, troop, level, leaders, leader, leaderLevel };
-- the breeding rules (group sizes growing with the elapsed time ...) are in src/game/sites.lua.
-- The production list of an owned lair is everything its spawn table can make: derived in the patch phase from the records of every layer.
local function spawn(troops, troop, level, leaders, leader, leaderLevel)
    return { troops = troops, troop = troop, level = level, leaders = leaders, leader = leader, leaderLevel = leaderLevel }
end

return {
    ---@param content Content
    define = function(content)
        local function lair(id, min, max, boss, spawns)
            content.lair:add{ id = id, min = min, max = max, boss = { unit = boss[1], level = boss[2] }, spawns = spawns }
        end
        lair("BLBM", 100000, 150000, { "AUAX", 12 },
             { spawn(3, "AUIX", 1), spawn(4, "AUIX", 1), spawn(4, "AUIX", 1, 1, "AUKX", 4),
               spawn(4, "AUIX", 1, 1, "AULX", 3), spawn(5, "AUIX", 1, 1, "AUJX", 6), spawn(5, "AUIX", 1, 1, "AUJX", 8) })
        lair("BLGH", 70000, 110000, { "AONX", 18 },
             { spawn(3, "AOSX", 1), spawn(4, "AOSX", 1), spawn(5, "AOSX", 1),
               spawn(3, "AOSX", 1, 1, "AOKX", 3), spawn(3, "AOSX", 1, 1, "AONX", 5), spawn(2, "ASGS", 1, 1, "AOKX", 4) })
        lair("BLGL", 80000, 120000, { "AMJX", 18 }, { spawn(2, "AMJX", 1), spawn(3, "AMJX", 1), spawn(4, "AMJX", 1) })
        lair("BLHN", 80000, 120000, { "AAHA", 16 }, { spawn(2, "AAHA", 1), spawn(3, "AAHA", 1) })
        lair("BSAL", 70000, 110000, { "AKJX", 19 },
             { spawn(3, "AKJX", 1, 1, "AKJX", 3), spawn(3, "AKJX", 1, 1, "AKJX", 5), spawn(2, "AKJX", 1, 1, "AKJX", 4) })
        lair("BSBS", 90000, 120000, { "AKOX", 15 },
             { spawn(5, "AKKX", 1), spawn(5, "AKKX", 1, 1, "AKKX", 5), spawn(4, "AKKX", 1, 1, "AKLX", 3),
               spawn(4, "AKLX", 1), spawn(3, "AKLX", 1, 1, "AKOX", 4), spawn(4, "AKKX", 1, 1, "AKNX", 4) })
    end,
    ---@param content Content
    patch = function(content)
        local codes = {}
        for _, rec in ipairs(content.lair:all()) do codes[#codes + 1] = rec.id end
        table.sort(codes)
        for _, code in ipairs(codes) do
            local entries, seen = {}, {}
            for _, sp in ipairs(content.lair[code].spawns) do
                for _, c in ipairs({ sp.troop, sp.leader }) do
                    if c and not seen[c] then
                        seen[c] = true
                        entries[#entries + 1] = { id = c, level = "0" }
                    end
                end
            end
            if content.building[code] then
                content.building:patch(code, { produces = { ["*"] = content.value(entries) } })
            end
        end
    end,
}
