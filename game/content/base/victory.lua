-- The victory conditions of a battle (the scenario's victory condition number 0..12), docs/data-driven/04-heroes-abilities-rules.md 4.4. Record:
--   id        the rule name the setup screens, scenarios and the engine use ("standard", "raze all" ...), slot its number
--   alias     other names campaign data uses ("kill armies")
--   timer     seconds of the countdown / game length of a timed mode;  running  the side totals are shown at the right edge
--   defeat    what keeps a side alive: { units = true | "heroes", buildings = "stopDefeat" | "notMines" } (a side with none of it is out)
--   alive     function(world, side) -> true | false | nil: replaces `defeat` (a mod rule)
--   setup     function(world, startSides): at the start of the battle (titans, flags)
--   total     function(world, side) -> number: the running total of a side (razed buildings, kills, keep level ...)
--   decidedAtEnd  nobody is defeated before the end of the game (razefest / slugfest);  flagGame  the flag buildings matter and cannot be hurt
--   pitched   no building or production, tech level 0;  computerHeroLevel  the level of the computer heroes;  noComputerPack  no backpack
--             items for computer heroes
--   winners   function(world, ctx) -> { sides } | nil: the sides that win right now; ctx = { alive = { sides }, withAllies(side),
--             timerDone(), extend(seconds) }. Every other side is defeated by the caller.
-- Sources: texts and rules shown by the original (XCIStrings.txt 172 / 173 / 196 / 197, Victory.cfg) and the victory setup of the
-- 1.04 binary (FUN_0041c7d0: the 300 s countdown of 1 / 2 / 6, the 1800 s games of 4 / 5, 2500 of each resource for 8, nothing for
-- 9). The +5 minutes on a draw and the level 5 keep are checked by the event conditions (not traced in the 1.04 binary yet).
--   1 raze all   a 5 minute countdown, afterwards a side without buildings is defeated
--   2 kill all   the same for units;  6 fortress: for keeps (the countdown is also shown for it)
--   3 assassins  a side without a hero is defeated
--   4 razefest / 5 slugfest  after 30 minutes the side with most razed buildings / killed armies wins; a draw extends the game by 5 minutes
--   7 king of the castle  the first level 5 keep wins;  8 rich get richer  2500 of each resource wins
--   9 against the horde  standard rule (the original forces no teams for it)
--  10 battle of titans  every side gets a titan, computer heroes are level 50 (the text says 50; the 1.04 computer hero routine FUN_0042a0d0 makes them 100)
--  11 pitched battle  no building or production, 50 setup points, tech level 0
--  12 capture the flag  one flag (BMFL, cannot be hurt) per side near its start; owning every flag wins
-- Own choice (the original has no defeat check in these modes): sides without anything left are out in king of the castle, rich get
-- richer and capture the flag as in the standard rule.
return {
    ---@param content Content
    define = function(content)
        local gamedata = require("src.game.gamedata")
        local V = content.victory
        local function add(rec) V:add(rec) end

        local UNITS_AND_HOLDS = { units = true, buildings = "stopDefeat" }

        add({ id = "standard", slot = 0, defeat = UNITS_AND_HOLDS })
        add({ id = "raze all", slot = 1, timer = 300, defeat = { buildings = "notMines" } })
        add({ id = "kill all", slot = 2, alias = { "kill armies" }, timer = 300, defeat = { units = true } })
        add({ id = "assassins", slot = 3, noComputerPack = true, defeat = { units = "heroes" } })

        -- razefest / slugfest: at the end of the game the side with the most razed buildings / killed armies wins; a draw adds five minutes
        local function mostOf(counter)
            return function(world, ctx)
                if not ctx.timerDone() then return nil end
                local st = world.events.stats
                local tbl = counter == "razed" and st.razed or st.kills
                local best, bestN, draw = nil, -1, false
                for _, i in ipairs(ctx.alive) do
                    local n = tbl[i .. ":*"] or 0
                    if n > bestN then best, bestN, draw = i, n, false
                    elseif n == bestN then draw = true end
                end
                if draw then
                    ctx.extend(300)
                    return nil
                end
                if best then return { best } end
            end
        end
        local function stat(counter)
            return function(world, i)
                local st = world.events and world.events.stats
                return st and (counter == "razed" and st.razed or st.kills)[i .. ":*"] or 0
            end
        end
        add({ id = "razefest", slot = 4, timer = 1800, running = true, decidedAtEnd = true, defeat = { units = true }, total = stat("razed"),
              winners = mostOf("razed") })
        add({ id = "slugfest", slot = 5, timer = 1800, running = true, decidedAtEnd = true, defeat = { units = true }, total = stat("kills"),
              winners = mostOf("kills") })
        add({ id = "fortress", slot = 6, timer = 300, defeat = { buildings = "stopDefeat" } })
        add({ id = "king of the castle", slot = 7, running = true, defeat = UNITS_AND_HOLDS,
              total = function(world, i) return world.eco:keepLevel(i) end,
              winners = function(world, ctx)
                  for _, i in ipairs(ctx.alive) do
                      if world.eco:keepLevel(i) >= 5 then return { i } end
                  end
              end })
        add({ id = "rich get richer", slot = 8, running = true, defeat = UNITS_AND_HOLDS,
              total = function(world, i)
                  local s = world.sides[i]
                  return math.min(s.gold, s.metal, s.crystal, s.stone)
              end,
              winners = function(world, ctx)
                  for _, i in ipairs(ctx.alive) do
                      local s = world.sides[i]
                      if math.min(s.gold, s.metal, s.crystal, s.stone) >= 2500 then return { i } end
                  end
              end })
        add({ id = "against the horde", slot = 9, defeat = UNITS_AND_HOLDS })
        add({ id = "battle of titans", slot = 10, computerHeroLevel = 50, defeat = UNITS_AND_HOLDS,
              setup = function(world, startSides)
                  for _, i in ipairs(startSides) do
                      local s = world.sides[i]
                      local code = content.race:bySlot(s.race) and content.race:bySlot(s.race).units.titan
                      if code then
                          local x, y = world:nearestFree(s.startX + 1, s.startY + 2, 0, 8)
                          if x and world:addUnit(code, i, x, y) then s.producedTitan = true end
                      end
                  end
              end })
        add({ id = "pitched battle", slot = 11, pitched = true, defeat = { units = true } })
        add({ id = "capture the flag", slot = 12, running = true, flagGame = true, defeat = UNITS_AND_HOLDS,
              setup = function(world, startSides)
                  local n = 0
                  for _, i in ipairs(startSides) do
                      local s = world.sides[i]
                      local x, y = world:nearestFree(s.startX + 3, s.startY + 3, 0, 10)
                      if x then
                          n = n + 1
                          local b = world:addBuilding({ code = "BMFL", side = i, x = x * 32 + 16, y = y * 24 + 12 })
                          world.eco:initBuilding(b)
                          b.flagNumber = n
                          b.name = "Flag " .. n
                      end
                  end
                  world.flagCount = n
              end,
              total = function(world, i)
                  local n = 0
                  for _, b in ipairs(world.buildings) do
                      if b.side == i and b.hp > 0 and gamedata.hasTag(b.code, "flag") then n = n + 1 end
                  end
                  return n
              end,
              winners = function(world, ctx)
                  local owner, total = {}, 0
                  for _, b in ipairs(world.buildings) do
                      if gamedata.hasTag(b.code, "flag") and b.hp > 0 then
                          total = total + 1
                          owner[b.side] = (owner[b.side] or 0) + 1
                      end
                  end
                  if total > 0 then
                      for _, i in ipairs(ctx.alive) do
                          local mine = 0
                          for _, j in ipairs(ctx.alive) do
                              if j == i or not world:enemies(i, j) then mine = mine + (owner[j] or 0) end
                          end
                          if mine >= total then return ctx.withAllies(i) end
                      end
                  end
              end })
    end,
}
