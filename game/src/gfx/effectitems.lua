-- The effect pictures of the battle view: what the original makes with its effect routine (binary FUN_0044e8f0, an effect display
-- item made by FUN_0058bf70 and set up by FUN_0053c870) over an army or building, for spells, critical hits, level gains, potions and stuns.
--
-- Verified in the 1.04 binary:
--   * FUN_0044e8f0 takes the owner, the code, a feet flag, a keep-looping flag, a row adjustment, an on-screen-only flag and the
--     sound arguments: `feet` puts the picture at the army's position (+0x4c / +0x4e) instead of its effect point (that less the
--     sprite's effect origin, +0x96 / +0x98); on-screen-only, it is not made when the army is more than four cells off the view
--     (the gate of `Fx:onScreen`); the row adjustment re-files the item in the display list at the army's row plus the adjustment
--     (FUN_00535150 sets the grid cell +0x48 / +0x4a
--     and FUN_005473b0 inserts it in the row's list), which is the draw order: the lists are drawn row by row, so +1 puts a picture
--     in front of the army and the units of the next row, -1 and -2 behind it. The item's sort value is the bottom of its row, (row +
--     1) * 24 (the effect's draw-order routine at 0x0053ca40); without an adjustment the row comes from the picture's own pixel position;
--   * the picture comes from the effect emitter table (FUN_0040ebd0): an effect with an emitter is the invisible dummy EDUM, 16 frames
--     (EBLS and a few others keep a picture of their own, see emitters.lua), any other code is its own picture; a frame is 50 ms, 120
--     ms for EX01 .. EX04 and 40 + 3d10 ms for EZ09 (lightning), EZ11 (healing) and EZ32 (pillar of fire) (FUN_0053c870);
--   * the effect frame step (FUN_0053cc20, once a frame): the emitter counter starts at 1000, goes up before the test, fires the emitter at
--     its emit limit (`every`) and restarts at 0; the picture then moves to the next frame, and a one-shot picture ends when it has shown its
--     last frame. A persistent one (keep-looping flag set) loops until its timed spell effect record (FUN_00577320) is destroyed,
--     and moves with its army (the army's display item keeps it in its effect list at +0xa0, filled by FUN_00535460).
-- Openwbc3's own: the dice of the frame time are hashes of the place and time (the view must not call math.random), the
-- visibility of a picture is the visibility of its army, a one-shot picture is not kept when the view is left far behind (at most 16
-- missed frames are caught up for a persistent one).
-- Presentation only; must not touch love.graphics at require time.
local emitters = require("src.gfx.emitters")
local A = require("src.formats.sprite").ANIM

-- One effect picture.
---@class EffectItem
---@field id integer
---@field code string
---@field set AnimSet?        its picture (nil: an emitter only)
---@field frames integer
---@field em Emitter?
---@field owner (Unit|Building)?
---@field feet boolean?
---@field adjust integer      row adjustment
---@field persistent boolean?
---@field alive (fun(it: EffectItem, now: number): boolean)?
---@field x number
---@field y number
---@field gx integer
---@field gy integer
---@field t0 number
---@field ms number           ms per frame
---@field ticks integer
---@field counter integer     emitter counter
---@field dead boolean?
---@field untilMs number?     a persistent picture's end (gfx/battlefx.lua)
---@field kinds table<any, boolean>?   the timed effects a persistent picture lasts for (gfx/battlefx.lua)

---@class EffectItemOpts
---@field feet boolean?
---@field adjust integer?
---@field persistent boolean?
---@field alive (fun(it: EffectItem, now: number): boolean)?
---@field onScreen boolean?
---@field x number?
---@field y number?
---@field gx integer?
---@field gy integer?

---@class EffectItems
---@field fx BattleFx
---@field items EffectItem[]
---@field serial integer
local M = {}
M.__index = M

local CH = 24
local DICE = { EZ09 = true, EZ11 = true, EZ32 = true }
local SLOW = { EX01 = true, EX02 = true, EX03 = true, EX04 = true }

local function hash(a, b, c) return (a * 73856093 + b * 19349663 + c * 83492791) % 2147483647 end

-- The milliseconds a frame of an effect code lasts.
---@param code string
---@param gx integer?
---@param gy integer?
---@param now number?
---@return number
function M.frameMs(code, gx, gy, now)
    if SLOW[code] then return 120 end
    if DICE[code] then
        local h = hash(gx or 0, gy or 0, math.floor((now or 0) / 50))
        return 40 + 3 + h % 10 + math.floor(h / 10) % 10 + math.floor(h / 100) % 10
    end
    return 50
end

-- The target effects a spell puts at the army's feet, behind it (feet, row adjustment -1; FUN_004ac0e0's target loop tests EZ18, EZ14, EZ08,
-- EZ35, EZ34 and EZ40); every other target effect stands on the army, in front of it (+1).
M.AT_BASE = { EZ18 = true, EZ14 = true, EZ08 = true, EZ35 = true, EZ34 = true, EZ40 = true }

-- `fx` is the battle view's effect object (gfx/battlefx.lua): it supplies the effect point, the screen gates, the particle list
-- and the lights.
---@param fx BattleFx
---@return EffectItems
function M.new(fx)
    return setmetatable({ fx = fx, items = {}, serial = 0 }, M)
end

-- Makes the picture of `code` over `owner` (an army or building; or at opts.x / opts.y, cell opts.gx / opts.gy without one).
--   opts.feet        at the owner's position instead of its effect point
--   opts.adjust      the row adjustment of FUN_0044e8f0 (rows in front of (+) or behind (-) the owner's row; 0 = the picture's own row)
--   opts.persistent  loops until opts.alive(item, now) answers false, follows the owner
--   opts.onScreen    false for the persistent ones (they are made wherever the army is)
-- Returns the item, or nil when nothing is made (a gate failed, or the code has neither a picture nor an emitter).
---@param owner (Unit|Building)?
---@param code string
---@param opts EffectItemOpts?
---@return EffectItem?
function M:add(owner, code, opts)
    opts = opts or {}
    local fx = self.fx
    local now = fx.world.time
    local em, override = emitters.effect(code)
    ---@type string?
    local pic = code
    if em then
        if override == true then pic = code elseif type(override) == "string" then pic = override else pic = nil end
    end
    local set
    if pic then
        set = require("src.gfx.anims").get(pic)
        if not (set and set:has(A.STAND)) then set = nil end
    end
    if not set and not em then return nil end
    local x, y, gx, gy = opts.x, opts.y, opts.gx, opts.gy
    if owner then
        if owner.hidden or not owner.x then return nil end
        gx, gy = owner.gx, owner.gy
        if opts.feet then x, y = owner.x, owner.y else x, y = fx.effectPoint(owner) end
    end
    -- without an owner the caller gives the cell
    ---@cast gx integer
    ---@cast gy integer
    if opts.onScreen ~= false and (not fx:onScreen(gx, gy, 4) or owner and not fx.screen:shown(owner)) then return nil end
    self.serial = self.serial + 1
    local frames = set and set:frames(A.STAND) or emitters.DUMMY_FRAMES
    local it = { id = self.serial, code = code, set = set, frames = math.max(1, frames), em = em, owner = owner, feet = opts.feet,
                 adjust = opts.adjust or 0, persistent = opts.persistent, alive = opts.alive, x = x, y = y, gx = gx, gy = gy, t0 = now,
                 ms = M.frameMs(pic or code, gx, gy, now), ticks = 0, counter = 1000 }
    self.items[#self.items + 1] = it
    return it
end

-- Follows the owner of a persistent picture.
---@param self EffectItems
---@param it EffectItem
local function follow(self, it)
    local o = it.owner
    if o and it.persistent then
        if it.feet then it.x, it.y = o.x, o.y else it.x, it.y = self.fx.effectPoint(o) end
        it.gx, it.gy = o.gx, o.gy
    end
end

-- One frame of the view: the emitters and the ends of the pictures.
---@param now number
function M:update(now)
    local items, fx = self.items, self.fx
    for i = #items, 1, -1 do
        local it = items[i]
        follow(self, it)
        local alive = true
        if it.persistent then
            local o = it.owner
            alive = o ~= nil and not o.remove and (o.kind ~= "unit" and o.hp > 0 or o.kind == "unit" and o:alive()) and it.alive(it, now)
        end
        if alive then
            local n = math.floor((now - it.t0) / it.ms)
            if it.persistent then n = math.min(n, it.ticks + 16) else n = math.min(n, it.frames) end
            local visible = not it.owner or (not it.owner.hidden and fx.screen:shown(it.owner))
            while it.ticks < n do
                it.ticks = it.ticks + 1
                if it.em then
                    it.counter = it.counter + 1
                    if it.counter >= it.em.every then
                        it.counter = 0
                        if visible then fx:fireEmitter(it.em, it.x, it.y, it.gx, it.gy, now) end
                    end
                end
                if not it.persistent and it.ticks >= it.frames then alive = false break end
            end
        end
        if not alive then
            it.dead = true
            table.remove(items, i)
        end
    end
end

-- Adds the pictures in view to the battle screen's draw list as entries { kind = "fxpic", item, id, x, y, sortY } among its armies
-- and buildings (`shown(owner)` is the screen's fog test; the bounds are the list's own).
---@param list table[]
---@param shown fun(o: Unit|Building): boolean
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
function M:collect(list, shown, x0, y0, x1, y1)
    for _, it in ipairs(self.items) do
        if it.set and it.x >= x0 and it.x <= x1 and it.y >= y0 and it.y <= y1 then
            local o = it.owner
            if not it.persistent or not o or (not o.hidden and shown(o)) then
                local row = it.adjust ~= 0 and (it.gy + it.adjust) or math.floor(it.y / CH)
                list[#list + 1] = { kind = "fxpic", item = it, id = it.id, x = it.x, y = it.y, sortY = (row + 1) * CH }
            end
        end
    end
end

-- Draws one item at the world time `now`.
---@param it EffectItem
---@param now number
function M.draw(it, now)
    local f = math.floor((now - it.t0) / it.ms)
    if it.persistent then f = f % it.frames else f = math.min(it.frames - 1, f) end
    it.set:draw(A.STAND, 0, f, it.x, it.y)
end

return M
