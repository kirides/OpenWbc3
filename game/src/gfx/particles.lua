-- Particle effects of the battle view (the original's particle display item): a burst of small points or sprite blobs
-- that fly along one of 400 pre-computed paths (8 groups of 50: radial / fountain, with gravity / without / against
-- it, splash, bounce) for at most 42 steps of 25 ms. Used for blood, sparks and the "fizz" of spells.
--
-- Presentation only: nothing here touches the simulation or math.random (network games); the paths come from a
-- private generator with a fixed seed. Must not touch love.graphics at require time.
--
-- As the original does it (1.04: path tables FUN_00544670 / FUN_00544b50, set-up FUN_005434a0, step FUN_00543a00, pool
-- FUN_0058c0d0; the level option, the pool and the throttle checked there, the rest not all compared): the path
-- construction (slope table, how gravity turns the slope, bounce), the step timing (a frame every 25 ms, two path
-- steps per frame for points, one for sprites), the five-step translucent trail of a point (weights 13/16 ... 7/16),
-- the colours of the points, the sprite sheets EPA0..EPA6 per colour (row = particle type), the fade / animation
-- tables per path step, and the particle level option (0 none, 1 half the count and no respawn, 2 three quarters
-- and half the respawns, 3 as given). openwbc3's own: the respawn count is kept per burst as in the original, but
-- the graded translucency of a faded sprite is the sheet's own gradient times (16 - level) / 16. At most 400 bursts live
-- at a time (the original's pool, FUN_0058c0d0) and the frame-rate throttle (frameload.lua) applies to every new one.
local M = {}

M.POINT, M.LENS, M.GLOW, M.STAR, M.CLOUD, M.SPECIAL = -1, 0, 1, 2, 3, 4
M.COLOR = { white = 1, red = 2, green = 4, blue = 8, cyan = 16, yellow = 32, brown = 64 }
M.GRAVITY, M.NOGRAVITY, M.ANTIGRAVITY = 1, 2, 4
M.RADIAL, M.FOUNTAIN, M.SPLASH, M.BOUNCE = 1, 2, 4, 8
M.SLOW, M.MEDIUM, M.FAST = 0, 1, 2
M.SMALL, M.LARGE, M.HUGE, M.MASSIVE = 0, 1, 2, 3
-- animation types and fade types
M.NOANIMATE, M.LOOP, M.ONESHOT, M.REVERSELOOP, M.REVERSEONESHOT, M.FORWARDBACK = 0, 1, 2, 3, 4, 5
M.FRAME1, M.FRAME2, M.FRAME3, M.FRAME4, M.FRAMERANDOM = 6, 7, 8, 9, 10
M.NOFADE, M.FADEOUT, M.GRADUALFADE, M.FADEIN, M.FADEINANDOUT = 0, 1, 2, 3, 4

local frameload = require("src.gfx.frameload")
local STEPS, GROUP, PAST_END = 42, 50, 666
local LIMIT = 240                       -- |x| or |y| of the largest area
local MAX_BURSTS = 400                  -- the original's pool of particle display items (FUN_0058c0d0: 400)

-- RGB of a point per colour bit (the original converts these to 565)
local RGB = {
    [1] = { 220, 210, 200 }, [2] = { 180, 0, 0 }, [4] = { 0, 180, 0 }, [8] = { 0, 0, 150 },
    [16] = { 0, 200, 200 }, [32] = { 200, 200, 0 }, [64] = { 180, 120, 80 },
}
-- sprite sheet per first colour bit (white, red, green, blue, cyan, yellow, brown)
local SHEET = { [1] = "EPA0", [2] = "EPA1", [4] = "EPA2", [8] = "EPA3", [16] = "EPA4", [32] = "EPA5", [64] = "EPA6" }
-- translucency of the point at trail level 0..4
local TRAIL = { 1, 13 / 16, 11 / 16, 9 / 16, 7 / 16 }

-- Own generator for the path table (xorshift), fixed seed.
local seed = 0x2545F491
local function rnd(n)
    seed = bit.bxor(seed, bit.lshift(seed, 13))
    seed = bit.bxor(seed, bit.rshift(seed, 17))
    seed = bit.bxor(seed, bit.lshift(seed, 5))
    return (bit.band(seed, 0x7fffffff) % n) + 1
end
local function dice(n, off) return rnd(n) + off end

-- slope s: -11..12; the unit vector of |s| in 20ths and the signs of the step
local VEC = { [0] = { 0, 20 }, { 5, 19 }, { 10, 17 }, { 14, 14 }, { 17, 10 }, { 19, 5 }, { 20, 0 },
              { 19, 5 }, { 17, 10 }, { 14, 14 }, { 10, 17 }, { 5, 19 }, { 0, 20 } }
local function dirOf(s)
    local a = math.abs(s)
    local xd = (a == 0 or a == 12) and 0 or (s > 0 and 1 or -1)
    local yd = a <= 5 and -1 or (a == 6 and 0 or 1)
    return VEC[a][1], VEC[a][2], xd, yd
end
local BOUNCE_Y = { 8, 5, 4, 3, 2, 0, -2, -3, -4, -5, -8, -10, -8, -5, -4, -3, -2, 0, 2, 3, 4, 5, 8, 10 }
local BOUNCE_DIR = { -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, 0, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }

local function idiv(a, b)         -- C division (truncates towards zero)
    local q = a / b
    return q >= 0 and math.floor(q) or math.ceil(q)
end

-- One path: steps[0..41] = { x, y, gradual, fadeOut, fadeIn, loop, reverseLoop, oneShot, reverseOneShot,
-- forwardBack }; x == PAST_END past its end.
local function makePath(first, last, length, check, slope, speed, bounce)
    local path = {}
    for i = 0, STEPS - 1 do
        path[i] = { x = 0, y = 0, gradual = 0, fadeOut = 0, fadeIn = 0, loop = 0, reverseLoop = 0, oneShot = 0,
                    reverseOneShot = 0, forwardBack = 0 }
    end
    local reverse = false
    if check < 0 then check, reverse = -check, true end
    local bounceY, sinceBounce = 0, 0
    if bounce then bounceY = BOUNCE_Y[slope + 12] end
    local xacc, yacc = 0, 0
    for i = 1, STEPS - 1 do
        local p, prev = path[i], path[i - 1]
        if i < first then
            p.x, p.y = 0, 0
        elseif i > last then
            p.x, p.y = PAST_END, PAST_END
        else
            local fx, fy, xd, yd = dirOf(slope)
            xacc = xacc + idiv(fx * speed * 100, 20)
            yacc = yacc + idiv(fy * speed * 100, 20)
            p.x, p.y = prev.x, prev.y
            while xacc > 100 do p.x = p.x + xd; xacc = xacc - 100 end
            while yacc > 100 do p.y = p.y + yd; yacc = yacc - 100 end
            if p.x <= -LIMIT or p.x >= LIMIT or p.y <= -LIMIT or p.y >= LIMIT then
                p.x, p.y = PAST_END, PAST_END
                last = i
            end
            -- gravity turns the direction after every `check` steps; how soon depends on the slope
            local c = check
            if c < length then
                local a = math.abs(slope)
                if reverse then
                    if a >= 1 and a <= 2 then c = c + 1
                    elseif a >= 6 then c = c - (a - 5) end                   -- 6: -1 ... 11: -6, 12: -7
                else
                    if a == 10 or a == 11 then c = c + 1
                    elseif a <= 6 then c = c - (7 - a) end                   -- 6: -1, 5: -2 ... 0: -7
                end
            end
            c = math.max(2, c)
            if (i + 1) % c == 0 and rnd(100) < 100 then
                if reverse then
                    if slope == 12 then slope = rnd(100) < 50 and 11 or -11
                    elseif slope > 0 and slope < 12 then slope = slope - 1
                    elseif slope < 0 and slope > -12 then slope = slope + 1 end
                else
                    if slope == 0 then slope = rnd(100) < 50 and 1 or -1
                    elseif slope > 0 and slope < 12 then slope = slope + 1
                    elseif slope < 0 and slope > -12 then
                        slope = slope - 1
                        if slope == -12 then slope = 12 end
                    end
                end
            end
            if bounce and p.y > bounceY and sinceBounce > 4 and math.abs(slope) > 6 then
                slope = BOUNCE_DIR[slope + 12]
                bounceY = bounceY + idiv(bounceY, 2)
                sinceBounce = 0
            else
                sinceBounce = sinceBounce + 1
            end
        end
    end
    -- fade and sprite frame tables
    local forward = true
    for i = 0, STEPS - 1 do
        if i >= first and i <= last then
            local p = path[i]
            p.gradual = math.floor(12 * (i - first) / length)
            p.fadeOut = math.max(12 - math.floor((last - i) / 2), 0)
            p.fadeIn = math.max(12 - 2 * (i - first), 0)
            p.loop = math.floor(i / 2) % 4
            p.reverseLoop = 3 - p.loop
            p.oneShot = math.min(math.floor(4 * (i - first) / length), 3)
            p.reverseOneShot = 3 - p.oneShot
            if i == first then
                p.forwardBack = 0
            elseif forward then
                p.forwardBack = path[i - 1].forwardBack + 1
                if p.forwardBack == 3 then forward = false end
            else
                p.forwardBack = path[i - 1].forwardBack - 1
                if p.forwardBack == 0 then forward = true end
            end
        end
    end
    return path
end

local paths
local function buildPaths()
    paths = {}
    for speedIdx = 0, 2 do
        local list = {}
        local function add(endSides, checkFn, slopeRange, bounce)
            for _ = 1, GROUP do
                local first = dice(4, 0)
                local last = dice(endSides[1], endSides[2])
                local len = last - first + 1
                local slope = slopeRange == 24 and dice(24, -12) or dice(11, -6)
                list[#list + 1] = makePath(first, last, len, checkFn(len), slope, speedIdx + 1, bounce)
            end
        end
        local function gravity(len) return math.max(3, dice(math.max(1, math.floor(len / (2 * speedIdx + 3))), -1)) end
        local function none(len) return len + 2 end
        local function anti(len) return math.min(-3, -dice(math.max(1, math.floor(len / (2 * speedIdx + 3))), -1)) end
        add({ 21, 20 }, gravity, 24)              -- radial with gravity
        add({ 21, 20 }, none, 24)                 -- radial without
        add({ 21, 20 }, gravity, 11)              -- fountain with gravity
        add({ 21, 20 }, none, 11)                 -- fountain without
        add({ 21, 20 }, anti, 24)                 -- radial against gravity
        add({ 21, 20 }, anti, 11)                 -- fountain against gravity
        add({ 21, 13 }, function() return math.max(3, dice(4, 0)) end, 11)       -- splash
        add({ 21, 20 }, function(len) return math.max(3, dice(math.max(1, math.floor(len / (2 * speedIdx + 4))), -1)) end, 11, true)
        paths[speedIdx] = list
    end
end

local function groupOffset(gravity, direction)
    if direction == M.SPLASH then return 6 * GROUP end
    if direction == M.BOUNCE then return 7 * GROUP end
    if gravity == M.GRAVITY and direction == M.RADIAL then return 0 end
    if gravity == M.NOGRAVITY and direction == M.RADIAL then return GROUP end
    if gravity == M.GRAVITY and direction == M.FOUNTAIN then return 2 * GROUP end
    if gravity == M.NOGRAVITY and direction == M.FOUNTAIN then return 3 * GROUP end
    if gravity == M.ANTIGRAVITY and direction == M.RADIAL then return 4 * GROUP end
    if gravity == M.ANTIGRAVITY and direction == M.FOUNTAIN then return 5 * GROUP end
    return 0
end

-- Bursts -----------------------------------------------------------------------------

---@class Particle
---@field frame integer
---@field done boolean
---@field path integer     index into the speed's path group (0-based)
---@field color integer    COLOR bit
---@field rframe integer   frame when the burst's animation gives none

---@class ParticleBurst
---@field x number
---@field y number
---@field t0 number
---@field nextTick number
---@field type integer
---@field speed integer
---@field fade integer
---@field anim integer
---@field respawn integer
---@field parts Particle[]
---@field frameFixed integer?   fixed frame (-1 = random per particle)
---@field sheet string          sprite set of the first colour
---@field row integer

-- Options of List:add (an emitter's numbers, see emitters.lua).
---@class ParticleOpts
---@field size integer?
---@field colors integer?
---@field gravity integer?
---@field direction integer?
---@field type integer?
---@field speed integer?
---@field animation integer?
---@field fade integer?
---@field respawn integer?
---@field area integer?
---@field level integer?   the particles option 0..3

---@class ParticleList
---@field bursts ParticleBurst[]
---@field counter integer
local List = {}
List.__index = List

---@return ParticleList
function M.new() return setmetatable({ bursts = {}, counter = 0 }, List) end

-- Starts a burst at world pixel (x, y). `o` fields (all optional): size (1..32), colors (bit mask), gravity,
-- direction, type, speed, animation, fade, respawn, area; `level` is the particle option (0..3).
---@param x number
---@param y number
---@param now number
---@param o ParticleOpts
function List:add(x, y, now, o)
    local level = o.level or 3
    local size, respawn = math.min(o.size or 16, 32), o.respawn or 0
    if level <= 0 then return end
    if level == 1 then size, respawn = math.floor(size / 2), 0
    elseif level == 2 then size, respawn = size - math.floor(size / 4), math.floor(respawn / 2) end
    if size <= 0 then return end
    -- the frame-rate throttle (FUN_0058c0d0): nothing from 12 on, a quarter from 8, a half from 4, and no respawns
    local fp = frameload.problems
    if fp >= frameload.BAD then return end
    if fp >= frameload.MODERATE then size, respawn = math.floor(size / 4), 0
    elseif fp >= frameload.SOME then size, respawn = math.floor(size / 2), 0 end
    if size <= 0 or #self.bursts >= MAX_BURSTS then return end
    if not paths then buildPaths() end
    local colors = o.colors or M.COLOR.white
    local list, bits = {}, {}
    for _, bitv in ipairs({ 1, 2, 4, 8, 16, 32, 64 }) do
        if bit.band(colors, bitv) ~= 0 then bits[#bits + 1] = bitv end
    end
    if #bits == 0 then bits[1] = 1 end
    local b = {
        x = x, y = y, t0 = now, nextTick = now + 50, type = o.type or M.POINT, speed = o.speed or M.FAST,
        fade = o.fade or M.NOFADE, anim = o.animation or M.NOANIMATE, respawn = respawn, parts = {}, frameFixed = nil,
        sheet = SHEET[bits[1]], row = o.type or 0,
    }
    local anim = b.anim
    if anim >= M.FRAME1 and anim <= M.FRAME4 then b.frameFixed, b.anim = anim - M.FRAME1, M.NOANIMATE
    elseif anim == M.FRAMERANDOM then b.frameFixed, b.anim = -1, M.NOANIMATE end
    local offset = groupOffset(o.gravity or M.GRAVITY, o.direction or M.RADIAL)
    for i = 1, size do
        b.parts[i] = { frame = 0, done = false, path = offset + self.counter, color = bits[(i - 1) % #bits + 1],
                       rframe = (i - 1) % 4 }
        self.counter = (self.counter + 1) % GROUP
    end
    self.bursts[#self.bursts + 1] = b
end

---@param now number
function List:update(now)
    for i = #self.bursts, 1, -1 do
        local b = self.bursts[i]
        local step = b.type == M.POINT and 2 or 1
        local alive, ticks = false, 0
        while now >= b.nextTick and ticks < 8 do
            b.nextTick = b.nextTick + 25
            ticks = ticks + 1
            for _, p in ipairs(b.parts) do p.frame = p.frame + step end
        end
        for _, p in ipairs(b.parts) do
            if p.frame < STEPS then alive = true end
        end
        if not alive then table.remove(self.bursts, i) end
    end
end

-- Draws the bursts in world coordinates; `visible(x, y)` says whether the place is in sight.
---@param anims AnimsModule
---@param visible (fun(x: number, y: number): boolean)?
function List:draw(anims, visible)
    if not paths then return end
    local g = love.graphics
    for _, b in ipairs(self.bursts) do
        if not visible or visible(b.x, b.y) then
            local set = b.type ~= M.POINT and anims.get(b.sheet) or nil
            local group = paths[b.speed]
            for _, p in ipairs(b.parts) do
                if not p.done then
                    local path = group[p.path + 1]
                    if b.type == M.POINT then
                        -- the current step and the four before it, fading out behind
                        local level = 0
                        local f = p.frame
                        while f > 0 and f >= p.frame - 4 do
                            local pt = path[math.min(f, STEPS - 1)]
                            if pt.x == PAST_END then
                                if level >= 4 then p.done = true end
                            else
                                local c = RGB[p.color]
                                g.setColor(c[1] / 255, c[2] / 255, c[3] / 255, TRAIL[level + 1])
                                g.rectangle("fill", b.x + pt.x, b.y + pt.y, 1, 1)
                            end
                            f = f - 1
                            level = level + 1
                        end
                    elseif set then
                        local pt = path[math.min(p.frame, STEPS - 1)]
                        if pt.x == PAST_END then
                            p.done = true
                            if b.respawn > 0 then
                                p.done, p.frame, p.path = false, 0, groupOffset(M.GRAVITY, M.RADIAL) + (p.path % GROUP)
                                b.respawn = b.respawn - 1
                            end
                        else
                            local fade = 0
                            if b.fade == M.FADEOUT then fade = pt.fadeOut
                            elseif b.fade == M.GRADUALFADE then fade = pt.gradual
                            elseif b.fade == M.FADEIN then fade = pt.fadeIn
                            elseif b.fade == M.FADEINANDOUT then fade = pt.fadeOut + pt.fadeIn end
                            local col = b.frameFixed
                            if b.anim == M.LOOP then col = pt.loop
                            elseif b.anim == M.ONESHOT then col = pt.oneShot
                            elseif b.anim == M.REVERSELOOP then col = pt.reverseLoop
                            elseif b.anim == M.REVERSEONESHOT then col = pt.reverseOneShot
                            elseif b.anim == M.FORWARDBACK then col = pt.forwardBack end
                            if col == nil or col < 0 then col = p.rframe end
                            g.setColor(1, 1, 1, math.max(0, (16 - fade) / 16))
                            set:draw(0, b.row, col, b.x + pt.x, b.y + pt.y)
                        end
                    end
                end
            end
        end
    end
    g.setColor(1, 1, 1)
end

return M
