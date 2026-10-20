-- Presentation effects of the battle view, gathered in one object that the battle screen drives with three calls
-- (update, drawGround, drawOver) and one world listener: ground decals (src/gfx/decals.lua), particles
-- (particles.lua), light flashes (lighting.lua), floating text (floattext.lua) and the footstep sounds
-- (src/audio/footsteps.lua). Each is gated by its option of the options screen (src/core/gameopts.lua).
--
-- Where the original starts them (1.04 binary):
--   * gore decals: the army death routine FUN_005374a0 - three decals (the cell, one beside it, one below it) unless the
--     army's blood effect type is 1 (white) or 3 (brown); green for type 2, else red;
--   * footprints: the army walking step FUN_005377a0 - an army whose move sound is walk, stomp, trot, wagon, pad or
--     skeleton leaves a footprint on sand and snow cells, one for a 1x1 army and two for a 2x2 one, picked by
--     the direction of the step;
--   * base decals: the building placement FUN_0053bca0 - dirt, snow or standard base under a building's base cells;
--   * blood: army damage FUN_00522d20 / building damage FUN_0052bf20 - 8 + damage / 8 points of blood (10 + damage / 4 for a
--     building) when the "blood" option is on;
--   * scorch marks and flashes: dragon breath on arrival, Titan balls, critical freezing / burning hits, spells;
--   * particle emitters (emitters.lua): the chimneys and vents of buildings at the points of their .BUI file, the smoke of a
--     razed building, the sparks and lights along a missile's flight, and the sprays of effects such as the soul sparkle.
--
-- It only reads the simulation and listens to its events; it never changes simulation state and never calls
-- math.random (every peer of a network game draws from the same events). Must not touch love.graphics at require time.
local bit = require("bit")
local gameopts = require("src.core.gameopts")
local decals = require("src.gfx.decals")
local particles = require("src.gfx.particles")
local lighting = require("src.gfx.lighting")
local floattext = require("src.gfx.floattext")
local emitters = require("src.gfx.emitters")
local frameload = require("src.gfx.frameload")
local sound = require("src.audio.sound")
local fidget = require("src.gfx.fidget")
local effectitems = require("src.gfx.effectitems")
local spellfx = require("src.gfx.spellfx")
local A = require("src.formats.sprite").ANIM

-- An effect emitter frame waiting for its time (M:emit, M:ruinSmoke).
---@class PendingEmit
---@field t number
---@field x number
---@field y number
---@field gx integer
---@field gy integer
---@field em Emitter

---@class BattleFx
---@field screen BattleScreen
---@field world World
---@field decals DecalList
---@field particles ParticleList
---@field lights LightList
---@field text FloatTextList
---@field items EffectItems
---@field fidget FidgetList
---@field lastCell table<Unit, { [1]: integer, [2]: integer }>   unit -> its cell at the last update (weak)
---@field dead table<Unit, boolean>            units whose death was shown (weak)
---@field baseDone table<Building, boolean>    building -> base decals made (false: removed again) (weak)
---@field missiles table<Missile, boolean>     missile -> impact shown (weak)
---@field pending PendingEmit[]
---@field bstate table<Building, table>        building -> its emitter counter (weak)
---@field mstate table<Missile, { frame: integer, counter: integer }>   missile -> its emitter counter and last frame (weak)
---@field recov table<Unit, boolean>           own army -> true while its spell recovery runs (weak)
---@field statusPics table<Unit, table>        army -> its stun and burn pictures (weak)
---@field cast SpellSnap?                      the world before the running cast's effect
---@field lastTick integer?
---@field crystalAt number?                    world time the next Crystallize.wav may play
---@field assassinAt number?
local M = {}
M.__index = M

local FOOTPRINT_SOUNDS = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true, [11] = true }
local TERRAIN = { SAND = 2, WATER = 3, LAVA = 5, MARSH = 6, FORD = 7, SNOW = 8, DIRT = 1, VOID = 9 }
-- footprint kinds by direction 0..7 (0 / 4 vertical, 1 / 5 diagonal up, 2 / 6 horizontal, 3 / 7 diagonal down)
local SMALL = { [0] = "footSmallV", "footSmallU", "footSmallH", "footSmallD", "footSmallV", "footSmallU", "footSmallH", "footSmallD" }
local LARGE = { [0] = "footLargeV", "footLargeU", "footLargeH", "footLargeD", "footLargeV", "footLargeU", "footLargeH", "footLargeD" }
-- the second decal of a 2x2 army's footprint per direction: offsets of both decals from the cell it left
local LARGE_CELLS = {
    [0] = { { 0, 0 }, { 1, 0 } }, [1] = { { 0, -1 }, { 1, 0 } }, [2] = { { 0, 0 }, { 0, -1 } }, [3] = { { 0, 0 }, { 1, -1 } },
    [4] = { { 0, -1 }, { 1, -1 } }, [5] = { { 0, -1 }, { 1, 0 } }, [6] = { { 1, 0 }, { 1, -1 } }, [7] = { { 0, 0 }, { 1, -1 } },
}
-- colour of the light at a spell cast per magic sphere (spell id / 10, 10 and above as 10): the table at 0x0060e5e0 of the 1.04
-- binary read by the spell effect function (`FUN_004ac0e0`, at its end the light routine `FUN_0044edb0` with the caster cell,
-- table[spell / 10], large, long): white purple red green purple yellow blue white blue red green; the light is made for every cast whose caster is on
-- the map, with or without a casting effect
local SPHERE_LIGHT = { [0] = lighting.WHITE, lighting.PURPLE, lighting.RED, lighting.GREEN, lighting.PURPLE, lighting.YELLOW,
                       lighting.BLUE, lighting.WHITE, lighting.BLUE, lighting.RED, lighting.GREEN }
-- the dragon breath missiles (EMF1..EMF6) and the light they leave: fire yellow, ice white, acid green, evil blue,
-- good yellow, lightning blue
local BREATH_LIGHT = { EMF1 = lighting.YELLOW, EMF2 = lighting.WHITE, EMF3 = lighting.GREEN, EMF4 = lighting.BLUE,
                       EMF5 = lighting.YELLOW, EMF6 = lighting.BLUE }

-- The pictures and sounds of the special attacks that go with the floating lines (the original's freeze / stun / cleave / burn /
-- drain mana routines `FUN_00527b30`, `FUN_00527d10`, `FUN_005278a0`, `FUN_00527720`, `FUN_00527a00`, the piercing hit in the
-- missile hit `FUN_005427e0` / the melee strike at 0x0051b100, the spell effect function `FUN_004ac0e0` for the cleave,
-- `FUN_00527ed0` / `FUN_00527ff0` for the drain of experience and the reduced armour): key = the line of Game.txt, `code` the
-- effect picture (made by the effect routine FUN_0044e8f0, 50 ms a frame), `feet` whether it stands at the army's position rather
-- than its effect point, `sound` the wav of SoundFX.xcr played when the army is within the view, `onInflictor` for the cleave whose
-- picture and sound are the attacker's. `adjust` is the row adjustment passed to FUN_0044e8f0 (binary: the missile hit, the
-- freeze, stun, burn and electricity routines: +1 piercing, burning and electricity, +2 crushing and freezing; the cleave is the spell message's casting effect, +1: see
-- gfx/effectitems.lua). The persistent pictures (EF04 on a burning army, EZ10 on a stunned one) are made by `statusPictures`.
local CRIT = {
    [1113] = { code = "EZ60", adjust = 1, sound = "PiercingCrit.wav" },
    [1114] = { code = "EZ62", adjust = 1, sound = "SlashCrit.wav", onInflictor = true },
    [1115] = { code = "EZ63", feet = true, adjust = 2, sound = "CrushCrit.wav" },
    [1116] = { code = "EZ64", feet = true, adjust = 2, sound = "IceCrit.wav" },
    [1117] = { code = "EZ50", feet = true, adjust = 1 },
    [1118] = { code = "EZ61", feet = true, adjust = 1, sound = "ElectricCrit.wav" },
    [863] = { code = "EZ15", feet = true, adjust = 2 },    -- reduced armour (the acid breath; EZ15 at the army's position, +2)
    [864] = { code = "EZ15", feet = true, adjust = 2 },    -- drained experience (the evil breath)
}

local function hash(a, b, c) return (a * 73856093 + b * 19349663 + c * 83492791) % 2147483647 end

---@param screen BattleScreen
---@return BattleFx
function M.new(screen)
    local world = screen.world
    local self = setmetatable({ screen = screen, world = world }, M)
    self.decals = decals.new(world.terrain, {
        decals = function() return gameopts.on("decals") end,
        blood = function() return gameopts.on("blood") end,
    })
    self.particles = particles.new()
    self.lights = lighting.new()
    self.text = floattext.new()
    self.lastCell = setmetatable({}, { __mode = "k" })       -- unit -> its cell at the last update
    self.dead = setmetatable({}, { __mode = "k" })
    self.baseDone = setmetatable({}, { __mode = "k" })
    self.missiles = setmetatable({}, { __mode = "k" })
    self.pending = {}                                          -- effect emitters waiting for their animation frame
    self.bstate = setmetatable({}, { __mode = "k" })           -- building -> its emitter counter
    self.mstate = setmetatable({}, { __mode = "k" })           -- missile -> its emitter counter and last frame
    self.recov = setmetatable({}, { __mode = "k" })            -- own army -> true while its spell recovery runs
    self.items = effectitems.new(self)                         -- effect pictures (FUN_0044e8f0), gfx/effectitems.lua
    self.statusPics = setmetatable({}, { __mode = "k" })       -- army -> its stun and burn pictures
    self.fidget = fidget.new()
    world:listen(function(kind, a, b, c, d) self:onEvent(kind, a, b, c, d) end)
    return self
end

-- Whether the player sees a cell (decals are only drawn on seen cells, the fog visibility test FUN_0047f560).
---@param gx integer
---@param gy integer
---@return boolean
function M:visibleCell(gx, gy)
    local fog = self.screen.fog
    if not fog or not fog.enabled then return true end
    if fog.hiddenOnly then return fog:isExplored(gx, gy) end
    return fog:isVisible(gx, gy)
end

-- The point effects hang from: the position less the sprite's effect origin (as the 1.04 binary computes it, e.g. FUN_0044e8f0 and
-- the status icons; the same point is what the missiles aim at, checked: it lies on a solid pixel of every building sprite).
---@param e Unit|Building
---@return number x
---@return number y
local function effectPoint(e)
    if e.set and e.set.effectCentre then
        local ex, ey = e.set:effectCentre()
        return e.x - ex, e.y - ey
    end
    return e.x, e.y
end

---@param self BattleFx
---@param gx integer
---@param gy integer
---@param margin integer?
---@return boolean
local function onScreen(self, gx, gy, margin)
    local s = self.screen
    local left, top, w, h = s:viewCells()
    margin = margin or 0
    return gx >= left - margin and gx <= left + w + margin and gy >= top - margin and gy <= top + h + margin
end
M.onScreen = onScreen                  -- fx:onScreen(gx, gy, margin)
M.effectPoint = effectPoint            -- fx.effectPoint(army or building)

---@param side integer
---@return boolean
function M:isMineOrAlly(side)
    local w = self.world
    return side == w.player or (self.screen.isAlly and self.screen:isAlly(side)) or false
end

-- A "tiny message" over an army: `key` is the number of the line in Game.txt (the tiny message lines), `arg` its %d.
---@param u Unit
---@param key integer
---@param kind integer floattext kind
---@param arg any?
function M:message(u, key, kind, arg)
    if not gameopts.on("floattext") then return end
    if not u or not u.x or u.hidden or not onScreen(self, u.gx, u.gy) or not self.screen:shown(u) then return end
    local strings = require("src.game.strings")
    local fmt = strings.get("Game.txt", ("%04d"):format(key))
    if not fmt then return end
    local text = arg and fmt:format(arg) or fmt
    local x, y = effectPoint(u)
    self.text:add(u, text, kind, self:isMineOrAlly(u.side), x, y, self.world.time)
end

-- An army the good dragon's breath crystallized (FUN_00528190, from the network handler FUN_004a9d90): eight blue particles (small special sprites that
-- fall away and fade, as the blood does) at its effect point and Crystallize.wav, the sound only for the side of the army or of the
-- shooter and at most once a second.
---@param victim Unit
---@param shooter Unit?
function M:crystallize(victim, shooter)
    if not victim or not victim.x or victim.hidden or not self.screen:shown(victim) or not onScreen(self, victim.gx, victim.gy, 2) then return end
    local x, y = effectPoint(victim)
    self.particles:add(x, y, self.world.time, { size = 8, colors = particles.COLOR.blue, gravity = particles.GRAVITY,
        direction = particles.RADIAL, type = particles.SPECIAL, speed = particles.MEDIUM, animation = particles.FRAMERANDOM,
        fade = particles.FADEOUT, area = particles.LARGE, level = gameopts.level("particles") })
    local me = self.world.player
    local now = self.world.time
    if (victim.side == me or (shooter and shooter.side == me)) and (not self.crystalAt or now >= self.crystalAt) then
        self.crystalAt = now + 1000
        sound.playAt("Assets/SoundFX.xcr", "Crystallize.wav", victim.gx, victim.gy)
    end
end

-- Blood of a hit (army damage FUN_00522d20, building damage FUN_0052bf20).
---@param e Unit|Building
---@param dmg number
function M:blood(e, dmg)
    if not gameopts.on("blood") or not dmg or dmg <= 0 then return end
    if not self.screen:shown(e) or not onScreen(self, e.gx, e.gy, 2) then return end
    local x, y = effectPoint(e)
    local etype = e.set and e.set.info[0] and e.set.info[0].effectType or 0
    local C = particles.COLOR
    local level = gameopts.level("particles")
    if e.kind == "building" then
        self.particles:add(x, y, self.world.time, { size = 10 + math.floor(dmg / 4),
            colors = etype == 1 and C.white or (etype == 2 and C.green or C.brown), level = level })
    else
        self.particles:add(x, y, self.world.time, { size = 8 + math.floor(dmg / 8),
            colors = etype == 1 and C.brown or (etype == 2 and C.green or C.red), gravity = particles.GRAVITY,
            direction = particles.RADIAL, type = particles.SPECIAL, speed = particles.MEDIUM,
            animation = particles.FRAMERANDOM, fade = particles.FADEOUT, area = particles.LARGE, level = level })
    end
end

-- A particle emitter of an effect (src/gfx/emitters.lua: soul sparkle, mana leech, chaos effects, Explode ...) at an army or
-- building, started by the simulation's "emit" event; the original makes it for armies on screen only (the effect routine
-- FUN_0044e8f0 tests the cell against the view with a margin of 4). The effect is a dummy picture of 16 frames of 50 ms (or the 8 of EZ21 for the good breath's sparkles)
-- that fires its emitter on every `every`-th frame, the first frame included: `pending` holds those frames.
---@param e Unit|Building
---@param code string
function M:emit(e, code)
    if not e or not e.x or e.hidden or not onScreen(self, e.gx, e.gy, 4) then return end
    if e.kind == "unit" and not self.screen:shown(e) then return end
    local x, y = effectPoint(e)
    local now = self.world.time
    local level = gameopts.level("particles")
    if emitters.EXTRA[code] then
        emitters.emit(self.particles, code, x, y, now, level)
        return
    end
    local em, picture = emitters.effect(code)
    if not em then return end
    local frames = emitters.DUMMY_FRAMES
    if type(picture) == "string" then
        local set = require("src.gfx.anims").get(picture)
        frames = set and set:has(0) and set:frames(0) or 1
    end
    for _, step in ipairs(emitters.steps(em.every, frames)) do
        if #self.pending < 400 then
            self.pending[#self.pending + 1] = { t = now + emitters.EFFECT_MS * step, x = x, y = y, gx = e.gx, gy = e.gy, em = em }
        end
    end
end

-- One burst (and light) of an effect emitter at (x, y), cell (gx, gy), when the cell is within four cells of the view.
---@param em Emitter
---@param x number
---@param y number
---@param gx integer
---@param gy integer
---@param now number
function M:fireEmitter(em, x, y, gx, gy, now)
    if not onScreen(self, gx, gy, 4) then return end
    emitters.burst(self.particles, em, x, y, now, gameopts.level("particles"))
    local lt = em.light
    if lt then self:light(gx, gy + em.gy, lt[1], lt[2], lt[3]) end
end

-- Fires the effect emitters whose animation frame has come (the effect frame step FUN_0053cc20): the burst, and the light of
-- the effects that flash one (the cell is the effect's own plus the grid offset).
---@param now number
function M:firePending(now)
    local list = self.pending
    local i = 1
    while i <= #list do
        local p = list[i]
        if now >= p.t then
            table.remove(list, i)
            self:fireEmitter(p.em, p.x, p.y, p.gx, p.gy, now)
        else
            i = i + 1
        end
    end
end

-- The idle fidgets of standing armies (gfx/fidget.lua): a pass every fifth 25 ms tick over the units on and round the screen in the
-- original's order (rows from the top, each from the left); the units carry the result in `u.view`, which `Unit:draw` reads.
local ANIM_NAME = { stand = A.STAND, walk = A.WALK, ambient = A.AMBIENT }
local function standing(u) return u.state == "idle" and u.anim == A.STAND and not u.pendingCast and not u.hidden end
---@param now number
function M:updateFidgets(now)
    local world, f = self.world, self.fidget
    local on = gameopts.on("ambient")
    f:update(now, function()
        local left, top, w, h = self.screen:viewCells()
        local list = {}
        for _, u in ipairs(world.units) do
            if u.state ~= "dead" and not u.hidden and u.gx >= left - 6 and u.gx <= left + w + 6
                and u.gy >= top - 2 and u.gy <= top + h + 6 then
                list[#list + 1] = u
            end
        end
        table.sort(list, function(a, b)
            if a.gy ~= b.gy then return a.gy < b.gy end
            if a.gx ~= b.gx then return a.gx < b.gx end
            return a.id < b.id
        end)
        return list
    end, on, standing, function(u) return u.set:has(A.AMBIENT) and u.set:frames(A.AMBIENT) or 0 end)
    for u in pairs(f.units) do
        local v = on and f:view(u, now, standing(u)) or nil
        if v and v.anim then
            local anim = ANIM_NAME[v.anim]
            local n = u.set:frames(anim)
            if not u.set:has(anim) or n < 1 then v.anim, v.frame = nil, nil
            else v.anim, v.frame = anim, math.min(v.frame, n - 1) end
        end
        u.view = v
        if not on then f.units[u] = nil end
    end
end

-- The emitters of the buildings (the building emitter table FUN_0040e930 + the points of the .BUI file): every 25 ms tick of the main loop a
-- building that stands finished, is not hidden by the fog and is within 8 cells of the view counts up and, at the table's
-- emit limit (9 or 10), makes a burst at each of its up to three points. The first count is random (`FUN_0053a8a0`: a number
-- below the limit), here a hash of the building's place. An emitter is gated like the building's own ambient animation
-- (the original's tick only runs while the picture is the stand one: not under construction, not destroyed).
local TICK_MS = 25
---@param now number
function M:tickBuildings(now)
    local tick = math.floor(now / TICK_MS)
    local last = self.lastTick or tick
    self.lastTick = tick
    local n = math.min(tick - last, 8)
    if n <= 0 then return end
    local screen, level = self.screen, gameopts.level("particles")
    for _, b in ipairs(self.world.buildings) do
        local pts = b.type and b.type.emitter
        if pts and pts[1][1] ~= 0 and b.hp > 0 and not b.destroyed and b.complete ~= false and b.set
            and onScreen(self, b.gx, b.gy, 8) and screen:shown(b) then
            local st = self.bstate[b]
            if not st then
                st = { counter = hash(b.gx, b.gy, 17) % emitters.building(b.code, function() return 1 end).every }
                self.bstate[b] = st
            end
            for k = 1, n do
                local seed = hash(b.gx, b.gy, tick - n + k)
                local em = emitters.building(b.code, function(sides) return 1 + seed % sides end)
                st.counter = st.counter + 1
                if st.counter >= em.every then
                    st.counter = 0
                    local ox, oy = b.set:pickRect(0)
                    ox, oy = ox or 0, oy or 0
                    for _, p in ipairs(pts) do
                        if p[1] ~= 0 then
                            emitters.burst(self.particles, em, b.x - ox + p[1], b.y - oy + p[2], now, level)
                        end
                    end
                end
            end
        else
            self.bstate[b] = nil
        end
    end
end

-- The smoke of a razed building (the building destruction routine, 1.04 `FUN_0052b3e0` after the removal): with n = the smaller of
-- width and height less one, a first roll of 2..4 decides: when it is at most n a second roll of 2..4 is the number of smoke
-- effects (it can exceed n), else n of them; each is an ESMR effect (a 16 frame dummy that sprays one cloud) at the cell
-- (x + d(1, n) - n / 2, y + d(1, n) - 1) round the building's.
---@param b Building
---@param now number
function M:ruinSmoke(b, now)
    local shape = (b.type and b.type.shape) or b.shape
    if not shape then return end
    local n = math.min((shape.h or 1) - 1, (shape.w or 1) - 1)
    if n < 1 then return end
    local seed = hash(b.gx, b.gy, 71)
    local function dice(i, sides, off) return 1 + hash(seed, i, 5) % sides + off end
    local count = n
    if dice(1, 3, 1) <= n then count = dice(2, 3, 1) end
    local em = emitters.EFFECTS.ESMR[1]
    for i = 1, count do
        local gx = b.gx + dice(10 + i, n, -math.floor(n / 2))
        local gy = b.gy + dice(20 + i, n, -1)
        if onScreen(self, gx, gy, 4) then
            self.pending[#self.pending + 1] = { t = now + emitters.EFFECT_MS, x = gx * 32 + 16, y = gy * 24 + 12, gx = gx, gy = gy, em = em }
        end
    end
end

-- The emitter of a missile (the missile emitter table FUN_0040f620): it counts the flight frames (25 or 50 ms each), the first of them fires at once
-- (the counter starts at 1000), and fires at the position of the previous frame; the lights of the lightning and fire balls
-- are made at the cell of the new frame (the lightning's at its first step, one row down).
---@param m Missile
---@param now number
function M:missileEmitter(m, now)
    local em = emitters.missile(m.code)
    if not em then return end
    local st = self.mstate[m]
    if not st then st = { frame = 0, counter = 1000 }; self.mstate[m] = st end
    local frame = m.frame or 0
    local missiles = require("src.game.missiles")
    local level = gameopts.level("particles")
    while st.frame < frame do
        st.frame = st.frame + 1
        st.counter = st.counter + 1
        if st.counter >= em.every then
            st.counter = 0
            local prev = m.steps and m.steps[math.max(st.frame - 1, 0)]
            local x, y = prev and prev.px or m.x0, prev and prev.py or m.y0
            local gx, gy = math.floor(x / 32), math.floor(y / 24)
            if onScreen(self, gx, gy, 4) and self:visibleCell(gx, gy) then
                emitters.burst(self.particles, em, x, y, now, level)
                local lt = em.light
                if lt and st.frame < (m.maxSteps or m.n or 0) then
                    local lx, ly
                    if m.instant or require("bit").band(m.flags or 0, missiles.F.LIGHTNING) ~= 0 then
                        lx, ly = m.gx0, m.gy0 + 1
                    else
                        local step = m.steps and m.steps[st.frame]
                        if step then lx, ly = step.gx, step.gy end
                    end
                    if lx then self:light(lx, ly + em.gy, lt[1], lt[2], lt[3]) end
                end
            end
        end
    end
end

-- The picture and sound of a special attack (see CRIT); `victim` is the hit army, `inflictor` the attacker.
---@param victim Unit
---@param key integer
---@param inflictor Unit?
function M:critFx(victim, key, inflictor)
    local def = CRIT[key]
    local e = def and (def.onInflictor and inflictor or victim)
    if not e or not e.x or e.hidden or not onScreen(self, e.gx, e.gy, 4) then return end
    if e.kind == "unit" and not self.screen:shown(e) then return end
    self.items:add(e, def.code, { feet = def.feet, adjust = def.adjust })
    if def.sound and onScreen(self, e.gx, e.gy, 0) then sound.playAt("Assets/SoundFX.xcr", def.sound, e.gx, e.gy) end
end

-- A hero's spell recovery has ended (the army update FUN_0051c7d0): "Recovered" and a white spray over the army, for the local side.
---@param u Unit
function M:recovered(u)
    if not self.screen:shown(u) or not onScreen(self, u.gx, u.gy, 4) then return end
    self:message(u, 1151, floattext.GOOD)
    local x, y = effectPoint(u)
    emitters.burst(self.particles, emitters.EXTRA.recovered[1], x, y - 20, self.world.time, gameopts.level("particles"))
end

-- A cast's effect pictures (FUN_004ac0e0, the spell effect function; the table is the spell record's `pictures`, see
-- content/base/spells.lua): the casting effect on the caster, the target effect on each army or building the cast touched, one in
-- front of the army (row adjustment +1) or, for the codes in effectitems.AT_BASE, at its feet behind it (-1), but not on the caster when it
-- is the casting effect's code too; the persistent one on the armies that got a timed effect, for as long as it lasts. "spellbegin"
-- takes the picture of the world before the effect function runs, "spellcast" compares (gfx/spellfx.lua).
---@param u Unit
---@param id integer
---@param ctx table?
function M:spellBegin(u, id, ctx)
    self.cast = nil
    if not u or u.kind ~= "unit" then return end
    local def = require("src.game.spells").defs[id]
    local pics = def and def.pictures
    if pics and (pics.cast or pics.target or pics.persistent) then self.cast = spellfx.begin(self.world, u, pics, ctx) end
end

-- The sound of a cast (the end of the spell effect function FUN_004ac0e0): when the spell message carries a sound number (the
-- spell record's `pictures.sound`, content/base/spells.lua) the receiver plays `STEZ<nn>.wav` of SoundFX.xcr at the caster's cell
-- with FUN_0050f0a0, the helper of every positional sound: within 24 cells of the view centre, and only when the cell of the sound or
-- the centre of the view is visible (the fog test FUN_0047f560); the volume falls with the distance and the pan follows the
-- horizontal offset (sound.playAt). It plays on every machine, for a successful cast of a hero, an item spell or a troop's spell (a
-- fizzle sends no message). The spells that have no number (Create Item, Transmute, Rune Item, Morph Resources open a dialog and
-- send no message: silent) - except the troops' own spells (negative slots, whose functions were not traced), which keep
-- openwbc3's own Statpop.wav, an unverified choice.
---@param u Unit
---@param id integer
function M:spellSound(u, id)
    local def = require("src.game.spells").defs[id]
    local n = def and def.pictures and def.pictures.sound
    if not u or u.kind ~= "unit" or not u.gx then return end
    local wav = n and n ~= 0 and ("STEZ%02d.wav"):format(n) or (id < 0 and "Statpop.wav") or nil
    if not wav then return end
    local fog = self.screen.fog
    if fog and fog.enabled then
        local function seen(gx, gy) return fog.hiddenOnly and fog:isExplored(gx, gy) or (not fog.hiddenOnly and fog:isVisible(gx, gy)) end
        if not (seen(u.gx, u.gy) or seen(math.floor(sound.listenerX), math.floor(sound.listenerY))) then return end
    end
    sound.playAt("Assets/SoundFX.xcr", wav, u.gx, u.gy, wav == "Statpop.wav" and { volume = 0.5 } or nil)
end

---@param u Unit
function M:spellEnd(u)
    local snap = self.cast
    self.cast = nil
    if not snap or snap.caster ~= u then return end
    local pics, items = snap.pics, self.items
    if pics.cast then items:add(u, pics.cast, { adjust = 1 }) end
    if not (pics.target or pics.persistent) then return end
    local res = spellfx.finish(self.world, snap)
    if pics.target then
        local base = effectitems.AT_BASE[pics.target]
        for _, o in ipairs(res.touched) do
            if not (o == u and pics.target == pics.cast) then
                items:add(o, pics.target, { feet = base, adjust = base and -1 or 1 })
            end
        end
    end
    if pics.persistent then
        for _, p in ipairs(res.persistent) do self:persistent(p.owner, pics.persistent, pics.base, p.kinds, res.untilMs) end
    end
end

-- A persistent picture on an army (the FUN_0044e8f0 call of the persistent loop: made wherever the army is, never removed by itself,
-- feet and row adjustment -2 for an effect "at the base" (special effect type 100), else effect point and +1). It ends with the timed
-- effects the cast added (`kinds`), or at `untilMs`. A second cast of the same spell extends the first picture.
---@param o Unit
---@param code string
---@param base boolean?
---@param kinds table<any, boolean>?
---@param untilMs number
function M:persistent(o, code, base, kinds, untilMs)
    if o.kind ~= "unit" then return end
    for _, f in pairs(o.fx or {}) do
        if f.effect == code then return end            -- the battle screen's aura of the status already shows it
    end
    for _, it in ipairs(self.items.items) do
        if it.persistent and it.owner == o and it.code == code then
            it.untilMs = math.max(it.untilMs or 0, untilMs)
            if kinds then it.kinds = it.kinds or {} for k in pairs(kinds) do it.kinds[k] = true end end
            return
        end
    end
    local it = self.items:add(o, code, { feet = base, adjust = base and -2 or 1, persistent = true, onScreen = false,
        alive = function(item, now)
            if item.kinds then
                for kind in pairs(item.kinds) do
                    local f = item.owner.fx and item.owner.fx[kind]
                    if f and (f.t1 or 0) > now then return true end
                end
                return false
            end
            return now < (item.untilMs or 0)
        end })
    if it then
        if kinds then
            it.kinds = {}
            for k in pairs(kinds) do it.kinds[k] = true end
        end
        it.untilMs = untilMs
    end
end

-- The persistent pictures of a stun (EZ10, the stun routine FUN_00527d10) and of a burning army (EF04, the burn routine FUN_00527720):
-- FUN_0044e8f0 at the effect point, row adjustment +1, until the status ends; made when the view first sees the status.
local STATUS_PICS = { { key = "stun", code = "EZ10", test = function(f) return f.stun end },
                      { key = "burn", code = "EF04", test = function(f) return f.immol or f.fanatic end } }
function M:statusPictures()
    for _, u in ipairs(self.world.units) do
        local f = u.fx
        if f then
            for _, sp in ipairs(STATUS_PICS) do
                if sp.test(f) then
                    local mine = self.statusPics[u]
                    local it = mine and mine[sp.key]
                    if not it or it.dead then
                        it = self.items:add(u, sp.code, { adjust = 1, persistent = true, onScreen = false,
                            alive = function(item) local g = item.owner.fx return g ~= nil and sp.test(g) end })
                        if it then
                            mine = mine or {}
                            self.statusPics[u] = mine
                            mine[sp.key] = it
                        end
                    end
                end
            end
        end
    end
end

-- The local player asked a hero to cast while it was still recovering from the last spell (the original's cast function says
-- "Recovering" over the hero and does nothing).
---@param u Unit
function M:recovering(u)
    self:message(u, 1150, floattext.GOOD)
end

---@param gx integer
---@param gy integer
---@param colour integer
---@param size integer
---@param duration integer
function M:light(gx, gy, colour, size, duration)
    if not onScreen(self, gx, gy, 4) then return end
    self.lights:add(gx, gy, colour, size, duration, self.world.time, gameopts.level("lighting"))
end

-- The world listener (world:listen).
---@param kind string
function M:onEvent(kind, a, b, c, d)
    if kind == "attacked" then
        if a and (a.kind == "unit" or a.kind == "building") then self:blood(a, c) end
    elseif kind == "emit" then
        self:emit(a, b)
    elseif kind == "crystallize" then
        self:crystallize(a, b)
    elseif kind == "critfx" then
        self:critFx(a, b, c)
    elseif kind == "manapotion" then
        -- the mana potion (FUN_00561c30): the sparkle picture EZ00 at the hero's effect point with Sparkles.wav, "Mana potion: +n" in the magic colour
        if a and a.x and not a.hidden and onScreen(self, a.gx, a.gy, 4) and self.screen:shown(a) then
            self.items:add(a, "EZ00", { adjust = 1 })
            if onScreen(self, a.gx, a.gy, 0) then sound.playAt("Assets/SoundFX.xcr", "Sparkles.wav", a.gx, a.gy) end
            self:message(a, 1119, floattext.MAGIC, b)
        end
    elseif kind == "assassinate" then
        -- the assassination handler FUN_004a9e90: EZ43 at the victim's effect point (the sound at most once a second), "Assassinate" over a killer that is no hero
        if a and a.x and onScreen(self, a.gx, a.gy, 4) and self.screen:shown(a) then
            self.items:add(a, "EZ43", { adjust = 2 })
            local now = self.world.time
            if not self.assassinAt or now >= self.assassinAt then
                self.assassinAt = now + 1000
                sound.playAt("Assets/SoundFX.xcr", "Assassination.wav", a.gx, a.gy)
            end
        end
        if b and b.kind == "unit" and not b.h then self:message(b, 1146, floattext.GOOD) end
    elseif kind == "tinymsg" then
        -- a critical freeze flashes blue, a critical burn yellow (the freeze / burn routines FUN_00527b30 / FUN_00527720: medium, long)
        if a and (b == 1116 or b == 1117) then
            self:light(a.gx, a.gy, b == 1116 and lighting.BLUE or lighting.YELLOW, lighting.MEDIUM, lighting.LONG)
        end
        self:message(a, b, c, d)
    elseif kind == "gainedlevel" then
        if a and a.kind == "unit" then self:message(a, 1109, floattext.LEVEL, (a.level or 0) + 1) end
        -- the level gain routine FUN_00527100, for the local player's armies: EZ12 behind the army (row adjustment -1) and EZ57 in
        -- front of it (+1), both at its feet
        if a and a.kind == "unit" and a.side == self.world.player then
            self.items:add(a, "EZ12", { feet = true, adjust = -1 })
            self.items:add(a, "EZ57", { feet = true, adjust = 1 })
        end
    elseif kind == "resisted" then
        -- "Spell Resisted" (Game.txt 1112) over an army that a Banish, Mutate, Strip Flesh or Rot did not take (FUN_004afa00 ->
        -- FUN_00539fb0: the line of the level colour, 1000 ms)
        self:message(a, 1112, floattext.LEVEL)
    elseif kind == "healthpotion" then
        -- the healing potion (FUN_00561d80): a Cure and Heal spell message of the hero with the casting effect EZ53 (in front of
        -- the hero, row adjustment +1), sound number 11 and the sphere 0 light; the "Healing" line comes with the heal itself
        if a and a.x and not a.hidden and onScreen(self, a.gx, a.gy, 4) and self.screen:shown(a) then
            self.items:add(a, "EZ53", { adjust = 1 })
            self:light(a.gx, a.gy, SPHERE_LIGHT[0], lighting.LARGE, lighting.LONG)
            if onScreen(self, a.gx, a.gy, 0) then sound.playAt("Assets/SoundFX.xcr", "STEZ11.wav", a.gx, a.gy) end
        end
    elseif kind == "spellbegin" then
        self:spellBegin(a, b, c)
    elseif kind == "levelup" then
        if a and a.kind == "unit" and a.h then self:message(a, 1109, floattext.LEVEL, a.h.level) end
    elseif kind == "spellcast" or kind == "itemspell" then
        if a and a.kind == "unit" then
            if c then
                self:spellEnd(a)
                self:spellSound(a, b)
                self:message(a, 1111, floattext.MAGIC, d or 1)
                self:light(a.gx, a.gy, SPHERE_LIGHT[math.max(0, math.min(10, math.floor((b or 0) / 10)))] or lighting.WHITE,
                    lighting.LARGE, lighting.LONG)
            else
                self:message(a, 1110, floattext.BAD)
                -- a failed cast: yellow stars fall away from the caster (FUN_005777a0, the particle call before the line)
                if self.screen:shown(a) and onScreen(self, a.gx, a.gy, 4) then
                    local x, y = effectPoint(a)
                    emitters.burst(self.particles, emitters.EXTRA.fizz[1], x, y, self.world.time, gameopts.level("particles"))
                end
            end
        end
    end
end

-- Decals and effects that follow what the units, buildings and missiles do; called every frame.
---@param dt number
function M:update(dt)
    local world, s = self.world, self.screen
    local now = world.time
    frameload.frame(love.timer.getTime() * 1000)
    local tr = world.terrain
    local dd = self.decals
    for _, u in ipairs(world.units) do
        if u.state == "dead" then
            if not self.dead[u] then
                self.dead[u] = true
                -- an army that has just died (not one loaded as a corpse): gore around the cell
                local etype = u.set and u.set.info[0] and u.set.info[0].effectType or 0
                if now - (u.deadSince or now) < 1500 and etype ~= 1 and etype ~= 3 then
                    local kind = etype == 2 and "goreGreen" or "goreRed"
                    local h1, h2 = hash(u.gx, u.gy, math.floor(now)), hash(u.gy, u.gx, u.id or 0)
                    dd:create(kind, u.gx, u.gy, now)
                    dd:create(kind, u.gx + (h1 % 3) - 1, u.gy, now)
                    dd:create(kind, u.gx, u.gy + (h2 % 3) - 1, now)
                end
            end
        elseif u.state == "step" or u.state == "move" then
            local last = self.lastCell[u]
            if last and (last[1] ~= u.gx or last[2] ~= u.gy) then self:footprint(u, last[1], last[2], now) end
            if not last then self.lastCell[u] = { u.gx, u.gy } else last[1], last[2] = u.gx, u.gy end
        else
            self.lastCell[u] = nil
        end
    end
    for _, u in ipairs(world.units) do
        if u.side == world.player then
            if u.recoverUntil and now < u.recoverUntil then
                self.recov[u] = true
            elseif self.recov[u] then
                self.recov[u] = nil
                if u.state ~= "dead" then self:recovered(u) end
            end
        end
    end
    for _, b in ipairs(world.buildings) do
        if not self.baseDone[b] and b.type and b.type.base and b.shape then
            self.baseDone[b] = true
            local base = b.type.base
            local x0 = b.gx - math.floor((math.max(1, base.w) - 1) / 2)
            for ey = 0, math.max(1, base.h) - 1 do
                for ex = 0, math.max(1, base.w) - 1 do
                    if bit.band(base.exclusion[ey] or 0, bit.lshift(1, ex)) ~= 0 then
                        local t = tr:typeAt(x0 + ex, b.gy + ey)
                        dd:create(t == TERRAIN.SNOW and "baseSnow" or (t == TERRAIN.DIRT and "baseDirt" or "baseStandard"),
                            x0 + ex, b.gy + ey, now, b)
                    end
                end
            end
        elseif self.baseDone[b] == true and (b.hp <= 0 or b.destroyed) then
            self.baseDone[b] = false
            dd:removeLinked(b)
            -- a building that has just been razed (not one loaded as a ruin) smokes
            if b.destroyed and now - (b.rubbleSince or now) < 2000 then self:ruinSmoke(b, now) end
        end
    end
    -- missiles that arrived since the last frame (the after-images may live on a few frames longer)
    local live = {}
    for _, m in ipairs(world.missiles) do
        live[m] = true
        self:missileEmitter(m, now)
        self.missiles[m] = self.missiles[m] or false
        if m.landed and not self.missiles[m] then
            self.missiles[m] = true
            self:impact(m, now)
        end
    end
    for m, impacted in pairs(self.missiles) do
        if not live[m] then
            self.missiles[m] = nil
            if not impacted then self:impact(m, now) end
        end
    end
    self:updateFidgets(now)
    self:tickBuildings(now)
    self:firePending(now)
    self:statusPictures()
    self.items:update(now)
    dd:update(now)
    self.particles:update(now)
    self.lights:update(now)
    self.text:update(now)
    local footsteps = require("src.audio.footsteps")
    if s.paused or s.result then footsteps.stop() else footsteps.update(world, function(u) return s:shown(u) end) end
    require("src.audio.ambience").update(world, gameopts.on("envsound"), function(f) return s:shown(f) end)
    require("src.audio.heartbeat").update(not s.result and not s.paused and world.eco:heroAlive(world.player) or nil, love.timer.getTime(),
        gameopts.on("heartbeat"))
end

---@param u Unit
---@param gx integer
---@param gy integer
---@param now number
function M:footprint(u, gx, gy, now)
    if u.illusion or (u.type and u.type.moveType == 1) then return end
    local sound = u.h and 0 or (u.type and u.type.moveSound) or 0
    if not FOOTPRINT_SOUNDS[sound] then return end
    local t = self.world.terrain:typeAt(gx, gy)
    if t ~= TERRAIN.SAND and t ~= TERRAIN.SNOW then return end
    local dir = u.dir or 0
    if u.type and u.type.shape and u.type.shape.w == 2 then
        for _, c in ipairs(LARGE_CELLS[dir]) do self.decals:create(LARGE[dir], gx + c[1], gy + c[2], now) end
    else
        self.decals:create(SMALL[dir], gx, gy, now)
    end
end

-- The effects of a missile that reached its target: dragon breath scorches the ground and glows, the Titan's balls
-- explode in light and bouncing sparks.
---@param m Missile
---@param now number
function M:impact(m, now)
    local code = m.code
    if not code then return end
    local x, y = m.ix or m.x1, m.iy or m.y1
    local gx, gy = math.floor(x / 32), math.floor((y + 16) / 24)
    if BREATH_LIGHT[code] then
        local t = self.world.terrain:typeAt(gx, gy)
        if t ~= TERRAIN.WATER and t ~= TERRAIN.LAVA and t ~= TERRAIN.FORD and t ~= TERRAIN.MARSH and t ~= TERRAIN.VOID
            and self:visibleCell(gx, gy) then
            self.decals:create("scorch", gx, gy, now)
        end
        self:light(gx, gy, BREATH_LIGHT[code], lighting.MEDIUM, lighting.SHORT)
    elseif code == "EMTF" or code == "EMTM" then
        local fire = code == "EMTF"
        self:light(gx, gy, fire and lighting.RED or lighting.WHITE, lighting.LARGE, lighting.LONG)
        self.particles:add(gx * 32 + 16, gy * 24 + 12, now, { size = 5, colors = fire and particles.COLOR.red or particles.COLOR.cyan,
            gravity = particles.GRAVITY, direction = particles.BOUNCE, type = particles.LENS, speed = particles.MEDIUM,
            animation = particles.REVERSEONESHOT, fade = particles.FADEOUT, level = gameopts.level("particles") })
    end
end

---@param anims AnimsModule
function M:drawGround(anims)
    local s = self.screen
    local left, top, w, h = s:viewCells()
    self.decals:draw(anims, left - 1, top - 1, left + w + 1, top + h + 1, function(gx, gy) return self:visibleCell(gx, gy) end)
    love.graphics.setColor(1, 1, 1)
end

---@param anims AnimsModule
---@param fonts table src.ui.fonts
function M:drawOver(anims, fonts)
    local s, now = self.screen, self.world.time
    self.lights:draw(anims, now)
    self.particles:draw(anims, function(x, y) return self:visibleCell(math.floor(x / 32), math.floor(y / 24)) end)
    self.text:draw(fonts, now)
    love.graphics.setColor(1, 1, 1)
end

return M
