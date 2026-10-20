-- Self test of the random map generator (game/randommap.lua) and its piece reader (formats/gom.lua).
--   run(check)   the cheap checks of `--selftest`: every .GOM of RandomData.xcr reads, the counts of the terrain sets,
--                the original's generator numbers, and a few generated maps (invariants, same seed = same map)
--   seeds(n)     `--selftest --lua tools/dev/randomseeds.lua [n]`: n seeds over every terrain, size and side count
local M = {}

-- One side of the invariants of a generated scenario; returns a list of problems (empty = fine).
---@param scn table a generated scenario (formats/scn.lua layout)
---@return string[] problems
---@return World
function M.verify(scn)
    local worldMod = require("src.game.world")
    local gamedata = require("src.game.gamedata")
    local bad = {}
    local w = worldMod.new(scn, { player = 0, startForces = false, noAI = true })
    if #w.buildings ~= #scn.buildings then bad[#bad + 1] = "buildings lost" end
    local W, H = w.w, w.h
    -- the corners are joined
    local corners = { { 4, 4 }, { W - 4, 4 }, { W - 4, H - 4 }, { 4, H - 4 } }
    local seen
    local function flood(sx, sy)
        local mark, stack, top = {}, { sy * W + sx }, 1
        mark[sy * W + sx] = true
        while top > 0 do
            local i = stack[top]
            top = top - 1
            local x, y = i % W, math.floor(i / W)
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local nx, ny = x + dx, y + dy
                    if (dx ~= 0 or dy ~= 0) and nx >= 0 and ny >= 0 and nx < W and ny < H and not mark[ny * W + nx]
                        and w:free(nx, ny, 0) then
                        mark[ny * W + nx] = true
                        top = top + 1
                        stack[top] = ny * W + nx
                    end
                end
            end
        end
        return mark
    end
    for i, c in ipairs(corners) do
        local x, y = w:nearestFree(c[1], c[2], 0, 20)
        if not x then bad[#bad + 1] = "corner " .. i .. " has no free cell" break end
        if i == 1 then seen = flood(x, y) elseif not seen[y * W + x] then bad[#bad + 1] = "corner " .. i .. " is cut off" end
    end
    local starts = 0
    for i = 0, 5 do
        local sd = scn.sides[i]
        if sd.used then
            starts = starts + 1
            if sd.startX < 6 or sd.startY < 6 or sd.startX > W - 6 or sd.startY > H - 6 then
                bad[#bad + 1] = "start " .. i .. " too close to the edge"
            elseif not w:free(sd.startX, sd.startY, 0) then
                bad[#bad + 1] = "start " .. i .. " is blocked"
            elseif not seen or not seen[sd.startY * W + sd.startX] then
                bad[#bad + 1] = "start " .. i .. " is cut off"
            else
                -- room for the hero and the two builders
                local free = 0
                for dy = -2, 2 do for dx = -2, 2 do if w:free(sd.startX + dx, sd.startY + dy, 0) then free = free + 1 end end end
                if free < 9 then bad[#bad + 1] = "start " .. i .. " is crowded" end
                -- one tower trio per side
                local towers = 0
                for _, b in ipairs(scn.buildings) do if b.side == i and gamedata.isRaceTower(b.code) then towers = towers + 1 end end
                if towers == 0 and not scn.noTowers then bad[#bad + 1] = "start " .. i .. " has no tower" end
            end
        end
    end
    for _, b in ipairs(scn.buildings) do
        local gx, gy = math.floor(b.x / 32), math.floor(b.y / 24)
        if gx < 1 or gy < 1 or gx >= W - 1 or gy >= H - 1 then bad[#bad + 1] = "building " .. b.code .. " outside" end
    end
    for _, a in ipairs(scn.armies) do
        local gx, gy = math.floor(a.x / 32), math.floor(a.y / 24)
        if gx < 1 or gy < 1 or gx >= W - 1 or gy >= H - 1 then bad[#bad + 1] = "critter outside" end
    end
    return bad, w
end

-- A short digest of a scenario's map for "same seed, same map".
---@param scn table
---@return string
function M.digest(scn)
    local t = { scn.width }
    for i = 0, scn.tilesW * scn.tilesH - 1 do t[#t + 1] = scn.tiles[i].id .. scn.tiles[i].part end
    for _, f in ipairs(scn.features) do t[#t + 1] = f.code .. f.x .. "," .. f.y end
    for _, b in ipairs(scn.buildings) do t[#t + 1] = b.code .. b.side .. b.x .. "," .. b.y end
    for _, a in ipairs(scn.armies) do t[#t + 1] = a.code .. a.x .. "," .. a.y end
    for i = 0, 5 do t[#t + 1] = scn.sides[i].startX .. "," .. scn.sides[i].startY end
    return table.concat(t, ";")
end

-- Builds a map for `d` (see randommap.build) and returns it with its problems.
---@param d table
---@return table scn
---@return table info
---@return string[] problems
---@return World
function M.make(d)
    local rm = require("src.game.randommap")
    local scn, info = rm.build(d)
    local bad, w = M.verify(scn)
    return scn, info, bad, w
end

---@param n integer the number of used sides
---@return table<integer, {used: boolean, race: integer}>
local function sidesOf(n)
    local s = {}
    for i = 0, 5 do s[i] = { used = i < n, race = (i * 5 + 3) % 16 } end
    return s
end

---@param check fun(name: string, ok: any) the selftest's check: logs ok / FAIL and counts the failures
function M.run(check)
    local vfs = require("src.vfs.vfs")
    local gom = require("src.formats.gom")
    local rm = require("src.game.randommap")
    -- the pieces
    local files, broken, unknownTiles, perSet = 0, 0, 0, {}
    local cat = rm.tileCatalog()
    for _, path in ipairs(vfs.list("%.gom$", "RandomData.xcr")) do
        local name = path:match("([^/]+)$")
        local g = gom.parse(vfs.read("RandomData.xcr", name) or "")
        files = files + 1
        if not g or not g.complete then broken = broken + 1
        else
            for _, id in ipairs(g.tiles) do
                if not cat[id] and not id:match("^TDS") then unknownTiles = unknownTiles + 1 end
            end
        end
        local set = name:lower():gsub("%d+%.gom$", "")
        perSet[set] = (perSet[set] or 0) + 1
    end
    check("random map: all " .. files .. " .GOM files read (the .TDS dirt tiles of the unused desert set are the only unknown ones)",
        files >= 640 and broken == 0 and unknownTiles == 0)
    local counts = true
    for _, set in pairs(gom.TERRAINS) do
        if perSet[set.prefix:lower()] ~= set.count then counts = false end
    end
    check("random map: the pieces per terrain set equal the original's table", counts)
    -- the generator of the original: seed 1 gives 1 -> (25173 + 13849) % 65536 = 39022
    local r = rm.rng(1)
    check("random map: the original's random number generator", r:next() == 39022 and r:dice(2, 6, 3) >= 5)
    -- three small maps: invariants and determinism
    for k, d in ipairs({
        { seed = 7, size = 0, terrain = 0, temples = 2, critters = 2, resources = 1, sides = sidesOf(2) },
        { seed = 99, size = 1, terrain = 4, temples = 0, critters = 1, resources = 2, sides = sidesOf(4) },
        { seed = 4242, size = 1, terrain = 10, temples = 5, critters = 5, resources = 3, sides = sidesOf(3), quests = true },
    }) do
        local scn, info, bad, w = M.make(d)
        local again = require("src.game.randommap").build(d)
        local same = M.digest(scn) == M.digest(again)
        check(("random map %d: %dx%d terrain %d, %d features, %d buildings, %d critters: %s"):format(k, scn.width, scn.height,
            info.terrain, #scn.features, #scn.buildings, #scn.armies, table.concat(bad, ", ")), #bad == 0)
        check("random map " .. k .. ": the same seed gives the same map", same)
        local w2 = require("src.game.world").new(again, { player = 0, startForces = false, noAI = true })
        check("random map " .. k .. ": the same world hash", w:hash() == w2:hash())
    end
    -- the settings the dropdowns send
    local rr = rm.resolve(rm.rng(5), { size = 4, terrain = 10, temples = 5, critters = 5, resources = 3 })
    check("random map: random settings resolve to concrete values", rr.size <= 3 and rr.terrain <= 9 and rr.temples <= 4
        and rr.critters <= 4 and rr.resources <= 2)
end

-- Many seeds over all terrains / sizes / side counts; prints one line per map and returns the number of problems.
---@param n integer
---@return integer problems
function M.seeds(n)
    local rm = require("src.game.randommap")
    local log = require("src.core.log")
    local problems = 0
    local worst = 0
    for seed = 1, n do
        local d = { seed = seed * 7919 + 13, size = seed % 4, terrain = seed % 10, temples = seed % 5, critters = seed % 5,
                    resources = seed % 3, sides = sidesOf(2 + seed % 5), quests = seed % 2 == 0 }
        local t0 = os.clock()
        local ok, scn, info, bad = pcall(M.make, d)
        local dt = os.clock() - t0
        worst = math.max(worst, dt)
        if not ok then
            problems = problems + 1
            log.error("seed %d: %s", seed, tostring(scn))
        else
            problems = problems + #bad
            log.info("seed %2d terrain %d size %d sides %d: %d tries, %4d features %3d buildings %2d critters %.2fs %s", seed,
                info.terrain, info.size, 2 + seed % 5, info.attempts, #scn.features, #scn.buildings, #scn.armies, dt,
                #bad > 0 and ("PROBLEMS: " .. table.concat(bad, ", ")) or "ok")
        end
    end
    log.info("%d seeds, %d problems, slowest %.2fs", n, problems, worst)
    return problems
end

return M
