-- The idle fidgets of standing armies (the original's idle-fidget roll, 1.04 0x00539a90): now and then a unit that stands about plays
-- its ambient animation or turns on the spot. It is a thing of the display layer, as in the original: it is not simulation state,
-- every machine rolls its own dice (here a hash of the unit and the tick), and with the "ambient animations" option off nothing
-- happens.
--
-- Verified in the 1.04 binary (the fidget roll, read from the bytes at 0x00539a90: it is no Ghidra function): a unit fidgets only
-- while its animation is the stand animation and no animation sequence runs; with the option on it rolls d100 and compares with the
-- unit type's fidget rate (.ARM offset 204) when the type's flags have the ambient animation bit (0x04), else 0;
-- the turn bands follow at +2 / +4 / +5 / +6 when the flags have the ambient rotation bit (0x08): a roll up to the rate is the
-- ambient animation, up to rate + 2 a narrow turn to the left, up to rate + 4 a narrow turn to the right, up to rate + 5 a wide
-- turn to the left, up to rate + 6 a wide turn to the right (without the rotation bit all four bands are empty). The walk and the
-- animations (the main loop FUN_0041e320, the walk over the screen FUN_005471c0, ambient FUN_00536b40, turn FUN_00536590, wide
-- turn FUN_005367f0; anchors checked, the frame details below not all compared): the game checks every fifth tick (25 ms) of
-- the main loop, walking the display items of the rows from two above the view to six below it, each row from the left, items within six cells of the view sideways, and the walk ends at the first unit
-- that fidgets - so units near the top left of the screen fidget more often than the rest; the ambient animation shows the
-- frames of the ambient sheet at 100 ms each; a turn shows the stand frame 1 for 100 ms with the facing one step on (narrow) or
-- two steps on (wide), then the stand frame 0, and the unit keeps the new facing; a unit whose type has the complex rotation bit
-- (0x10) walks the turn on its walk frame 1 at the turning steps instead (the sequences below).
--
-- Presentation only: no math.random, no simulation state; must not touch love.graphics at require time.
local bit = require("bit")
local M = {}

M.AMBIENT_BIT, M.ROTATION_BIT, M.COMPLEX_BIT = 0x04, 0x08, 0x10
M.PASS_TICKS, M.TICK_MS = 5, 25
M.NONE, M.AMBIENT, M.TURN_LEFT, M.TURN_RIGHT, M.WIDE_LEFT, M.WIDE_RIGHT = 0, 1, 2, 3, 4, 5

-- The four bands as upper limits of the roll: { ambient, narrow left, narrow right, wide left, wide right }.
---@param rate integer
---@param flags integer
---@return integer[]
function M.bands(rate, flags)
    local r0 = bit.band(flags, M.AMBIENT_BIT) ~= 0 and rate or 0
    if bit.band(flags, M.ROTATION_BIT) ~= 0 then return { r0, r0 + 2, r0 + 4, r0 + 5, r0 + 6 } end
    return { r0, r0, r0, r0, r0 }
end

-- What a roll of 1..100 starts.
---@param bands integer[]
---@param roll integer
---@return integer
function M.pick(bands, roll)
    if roll <= bands[1] then return M.AMBIENT end
    if roll <= bands[2] then return M.TURN_LEFT end
    if roll <= bands[3] then return M.TURN_RIGHT end
    if roll <= bands[4] then return M.WIDE_LEFT end
    if roll <= bands[5] then return M.WIDE_RIGHT end
    return M.NONE
end

-- The frames of a sequence: { ms, direction, animation ("stand" | "walk" | "ambient"), frame }. The last one marks the end (the unit
-- is back to its normal stand animation facing `dir`).
---@alias FidgetStep { [1]: integer, [2]: integer, [3]: string, [4]: integer }   ms, dir, anim name, frame

---@param kind integer
---@param dir integer
---@param complex boolean
---@param ambientFrames integer
---@return FidgetStep[]
function M.sequence(kind, dir, complex, ambientFrames)
    local seq = {}
    local function add(t, d, anim, frame) seq[#seq + 1] = { t, d % 8, anim, frame } end
    if kind == M.AMBIENT then
        for i = 0, ambientFrames do add(i * 100, dir, "ambient", i == ambientFrames and 0 or i) end
        return seq
    end
    local sign = (kind == M.TURN_RIGHT or kind == M.WIDE_RIGHT) and 1 or -1
    local add1 = sign < 0 and 7 or 1
    local first = sign > 0 and dir or dir + add1
    if kind == M.TURN_LEFT or kind == M.TURN_RIGHT then
        if complex then
            add(0, dir, "walk", 1); add(100, first, "stand", 1); add(200, dir + add1, "walk", 1)
            add(300, dir + add1, "stand", 0); add(400, dir + add1, "stand", 0)
        else
            add(0, first, "stand", 1); add(100, dir + add1, "stand", 0); add(200, dir + add1, "stand", 0)
        end
    else
        local second = sign > 0 and dir + add1 or dir + 2 * add1
        local last = dir + 2 * add1
        if complex then
            add(0, dir, "walk", 1); add(100, first, "stand", 1); add(200, dir + add1, "walk", 1)
            add(300, second, "stand", 1); add(400, last, "walk", 1); add(500, last, "stand", 0); add(600, last, "stand", 0)
        else
            add(0, first, "stand", 1); add(100, second, "stand", 1); add(200, last, "stand", 0); add(300, last, "stand", 0)
        end
    end
    return seq
end

-- The state of the fidgets of one battle: unit -> { seq, t0, facing, base }.
---@class FidgetState
---@field seq FidgetStep[]?  the running sequence
---@field t0 number
---@field keep boolean       keep the last direction afterwards
---@field base integer       the unit's own direction when it started
---@field facing integer?    the direction it is shown facing

---@class FidgetList
---@field units table<Unit, FidgetState>   weak keys
---@field tick integer?
local List = {}
List.__index = List

---@return FidgetList
function M.new() return setmetatable({ units = setmetatable({}, { __mode = "k" }), tick = nil }, List) end

local function hash(a, b, c) return (a * 73856093 + b * 19349663 + c * 83492791) % 2147483647 end

-- The view a unit is drawn with at `now` (nil: the normal one): { dir, anim, frame } while a sequence runs, { dir } after it;
-- `idle` says whether the unit still stands about (an order, a fight or a death ends the sequence and the new facing).
---@param u Unit
---@param now number
---@param idle boolean
---@return { dir: integer, anim: string?, frame: integer? }?
function List:view(u, now, idle)
    local st = self.units[u]
    if not st then return nil end
    if not idle then
        self.units[u] = nil
        return nil
    end
    if st.seq then
        local elapsed, cur = now - st.t0, st.seq[1]
        for _, e in ipairs(st.seq) do if e[1] <= elapsed then cur = e end end
        if cur == st.seq[#st.seq] then
            st.seq = nil
            if st.keep then st.facing = cur[2] end
        else
            return { dir = cur[2], anim = cur[3], frame = cur[4] }
        end
    end
    if st.facing and st.base == u.dir then return { dir = st.facing } end
    self.units[u] = nil
    return nil
end

-- Called every frame with the world clock (ms), `ordered()` (the units to consider in the original's walking order, asked for only
-- when a pass is due), the on / off option, `canStand(u)` (whether the unit stands about with the stand animation) and
-- `ambientFrames(u)`. Returns nothing; read the result with :view().
---@param now number
---@param ordered fun(): Unit[]
---@param enabled boolean
---@param canStand fun(u: Unit): boolean
---@param ambientFrames fun(u: Unit): integer
function List:update(now, ordered, enabled, canStand, ambientFrames)
    local tick = math.floor(now / M.TICK_MS)
    local last = self.tick or tick
    self.tick = tick
    for t = math.max(last + 1, tick - 8), tick do
        if t % M.PASS_TICKS == 0 and enabled then
            for _, u in ipairs(ordered()) do
                local st = self.units[u]
                if canStand(u) and not (st and st.seq) then
                    local rec = u.type or {}
                    local roll = hash(u.id or 0, t, 3) % 100 + 1
                    local bands = M.bands(rec.fidget or 0, rec.flags or 0)
                    local kind = M.pick(bands, roll)
                    if kind ~= M.NONE then
                        local complex = bit.band(rec.flags or 0, M.COMPLEX_BIT) ~= 0
                        local dir = st and st.facing and st.base == u.dir and st.facing or u.dir
                        ---@cast dir integer
                        self.units[u] = { seq = M.sequence(kind, dir, complex, ambientFrames(u)), t0 = now,
                                          keep = kind ~= M.AMBIENT, base = u.dir,
                                          facing = (st and st.base == u.dir) and st.facing or nil }
                        break                       -- the walk (FUN_005471c0) ends at the first unit that fidgets
                    end
                end
            end
        end
    end
end

return M
