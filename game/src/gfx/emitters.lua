-- Particle emitters of buildings, effects and missiles: what the original's three tables start for a code.
--   * the building table (binary FUN_0040e930): the chimneys, vents and fires of buildings; the points on the building come
--     from the .BUI file (`emitter` of the building record, offset 188, three x / y pairs);
--   * the effect table (FUN_0040ebd0): an effect picture (the effect routine FUN_0044e8f0) is swapped for the invisible dummy picture EDUM (16
--     frames of 50 ms) and carries an emitter; a few effects keep their own picture (EZ33, EZ93, EBLS' EZ21);
--   * the missile table (FUN_0040f620): the trails, sparks and lights along the flight of a missile, and the picture a missile
--     code is drawn with (EMAP as EMA0 ...).
-- An emitter fires when its counter reaches `every` (the table's emit limit): effects count their animation frames
-- (the effect frame step `FUN_0053cc20`: 50 ms a frame), missiles their flight frames (`0x0053fbc0`: 25 or
-- 50 ms), buildings the 25 ms ticks of the main loop (`0x0053b44a`: while the building is not fogged and within 8 cells of
-- the view). The counter starts at 1000 for effects and missiles, so the first frame always fires; a building's starts at a
-- random number below `every` (`FUN_0053a8a0`).
--
-- Verified in the 1.04 binary: every field of the three tables (read from the decompiled functions: size, colour mask,
-- gravity, direction, type, speed, animation, fade, respawn, area, emit limit, pixel offset y, grid offset y, the light
-- flag / colour / size / duration), the counters above and the position each uses (a building: the corner of its selection
-- rectangle plus the point; an effect and a missile: its pixel position plus the offsets; the missile's is the one of the
-- previous frame). The grid offset is a drawing order hint in the original (openwbc3 draws particles over the map) except
-- for lights, where it moves the cell the light is centred on. Not a Ghidra function: the frame functions above are read from
-- the bytes. The case of Mana Leech (EMLE) falls through into Venom Touch's block in the 1.04 table, so its emitter is Venom
-- Touch's; the earlier table here gave it a block of its own.
--
-- Presentation only (never touches the simulation or math.random: the dice of the original become hashes). Must not touch
-- love.graphics at require time.
local particles = require("src.gfx.particles")
local lighting = require("src.gfx.lighting")
local P, L = particles, lighting

local M = {}

-- One emitter: the particle burst `size` .. `area` (see gfx/particles.lua), `every` the counter limit, `py` / `gy` the pixel
-- and grid offsets (x offsets are 0 in every entry) and `light` { colour, size, duration } for the entries that flash a light.
-- A particle emitter (the numbers of particles.lua) with its firing rate and position.
---@class Emitter
---@field size integer        particles per burst (0: none, a light only)
---@field colors integer      particles.COLOR bits
---@field gravity integer
---@field direction integer
---@field type integer        particle picture (particles.LENS ...)
---@field speed integer
---@field animation integer
---@field fade integer
---@field respawn integer
---@field area integer
---@field every integer       ticks between two bursts
---@field py integer          pixel offset of the burst
---@field gy integer          row offset
---@field light integer[]?    { colour, size, duration } of a light flash (lighting.lua)

---@return Emitter
local function E(size, colors, gravity, direction, ptype, speed, anim, fade, respawn, area, every, py, gy, light)
    return { size = size, colors = colors, gravity = gravity, direction = direction, type = ptype, speed = speed,
             animation = anim, fade = fade, respawn = respawn, area = area, every = every, py = py or 0, gy = gy or 0, light = light }
end
local C = P.COLOR

-- The effect table (FUN_0040ebd0): code -> { picture (the code itself when the effect keeps its own sheet, nil for the dummy), emitter }.
-- The comments name the spell or event each is used by in the original.
M.EFFECTS = {
    EIMM = { E(7, C.white, P.GRAVITY, P.FOUNTAIN, P.STAR, P.MEDIUM, P.FORWARDBACK, P.GRADUALFADE, 0, P.LARGE, 5, -40, 2) },     -- immunity
    ERUC = { E(5, C.white, P.NOGRAVITY, P.FOUNTAIN, P.SPECIAL, P.MEDIUM, P.FRAMERANDOM, P.FADEOUT, 0, P.LARGE, 50, 0, 2) },      -- rune cast
    EPOC = { E(9, C.green, P.ANTIGRAVITY, P.RADIAL, P.GLOW, P.MEDIUM, P.REVERSEONESHOT, P.GRADUALFADE, 0, P.LARGE, 20, 0, 2,
               { L.GREEN, L.SMALL, L.SHORT }) },                                                                                -- poison cast
    ECHC = { E(9, C.red, P.ANTIGRAVITY, P.RADIAL, P.GLOW, P.MEDIUM, P.REVERSEONESHOT, P.GRADUALFADE, 0, P.LARGE, 20, 0, 2) },   -- chaos cast
    EARC = { E(7, C.brown, P.ANTIGRAVITY, P.RADIAL, P.CLOUD, P.MEDIUM, P.FRAME3, P.GRADUALFADE, 0, P.LARGE, 4, -30, 2) },       -- arcane cast
    ECOM = { E(7, C.brown, P.GRAVITY, P.RADIAL, P.CLOUD, P.SLOW, P.FRAME3, P.GRADUALFADE, 0, P.LARGE, 4, -30, 2) },             -- comprehension
    ESIV = { E(7, C.brown, P.ANTIGRAVITY, P.RADIAL, P.CLOUD, P.SLOW, P.FRAME1, P.GRADUALFADE, 0, P.LARGE, 10, -30, 2) },        -- see invisible
    EZ33 = { E(2, C.red, P.GRAVITY, P.RADIAL, P.GLOW, P.SLOW, P.FRAMERANDOM, P.FADEOUT, 0, P.LARGE, 4, -30, 0), sprite = true }, -- fire breath (own picture)
    EZ93 = { E(4, C.blue, P.GRAVITY, P.RADIAL, P.GLOW, P.SLOW, P.FRAMERANDOM, P.FADEOUT, 0, P.LARGE, 3, -30, 0), sprite = true }, -- (own picture)
    EPGA = { E(7, C.green, P.NOGRAVITY, P.SPLASH, P.LENS, P.SLOW, P.LOOP, P.GRADUALFADE, 0, P.LARGE, 5, -40, 2) },             -- poison gate, acid breath
    EMLE = { E(1, C.green, P.ANTIGRAVITY, P.RADIAL, P.GLOW, P.SLOW, P.FRAME1, P.FADEOUT, 0, P.SMALL, 1, 0, 0) },                -- mana leech (= venom touch)
    ESVT = { E(1, C.green, P.ANTIGRAVITY, P.RADIAL, P.GLOW, P.SLOW, P.FRAME1, P.FADEOUT, 0, P.SMALL, 1, 0, 0) },                -- venom touch
    EMIF = { E(6, C.cyan, P.NOGRAVITY, P.RADIAL, P.SPECIAL, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.LARGE, 5, 0, -2) },      -- ice floe
    EDVC = { E(12, C.yellow, P.ANTIGRAVITY, P.RADIAL, P.CLOUD, P.SLOW, P.FORWARDBACK, P.GRADUALFADE, 0, P.LARGE, 20, 0, 2) },   -- divination cast
    ECHE = { E(9, C.red, P.ANTIGRAVITY, P.RADIAL, P.LENS, P.MEDIUM, P.LOOP, P.FADEINANDOUT, 0, P.LARGE, 20, 0, 7) },            -- chaos effect
    EILE = { E(6, C.red, P.NOGRAVITY, P.RADIAL, P.LENS, P.MEDIUM, P.LOOP, P.GRADUALFADE, 0, P.LARGE, 100, 0, 4) },              -- evil illusion, evil breath
    EILU = { E(6, C.cyan, P.NOGRAVITY, P.RADIAL, P.LENS, P.MEDIUM, P.LOOP, P.GRADUALFADE, 0, P.LARGE, 100, 0, 4) },             -- illusion
    EIAR = { E(6, C.cyan, P.GRAVITY, P.RADIAL, P.GLOW, P.SLOW, P.REVERSEONESHOT, P.GRADUALFADE, 0, P.SMALL, 4, -36, 1) },       -- ice armour
    EISP = { E(12, C.cyan, P.NOGRAVITY, P.RADIAL, P.SPECIAL, P.MEDIUM, P.FRAMERANDOM, P.GRADUALFADE, 0, P.LARGE, 100, 0, 4) },  -- ice sparkle
    ESSP = { E(4, C.yellow, P.ANTIGRAVITY, P.FOUNTAIN, P.LENS, P.MEDIUM, P.LOOP, P.FADEOUT, 0, P.LARGE, 100, 0, 4) },           -- soul sparkle
    ESMR = { E(5, C.white, P.ANTIGRAVITY, P.FOUNTAIN, P.CLOUD, P.MEDIUM, P.FRAMERANDOM, P.GRADUALFADE, 3, P.LARGE, 100, 0, 0) }, -- smoking ruin
    ESMX = { E(5, C.white, P.ANTIGRAVITY, P.FOUNTAIN, P.CLOUD, P.MEDIUM, P.FRAMERANDOM, P.GRADUALFADE, 3, P.LARGE, 100, 0, 4) }, -- smoking resource
    ECHW = { E(9, C.red, P.ANTIGRAVITY, P.FOUNTAIN, P.GLOW, P.MEDIUM, P.REVERSEONESHOT, P.GRADUALFADE, 0, P.LARGE, 20, 0, 7) },  -- wildfire
    EIST = { E(12, C.cyan, P.NOGRAVITY, P.FOUNTAIN, P.GLOW, P.FAST, P.REVERSEONESHOT, P.FADEOUT, 4, P.HUGE, 20, -5, 6) },       -- ice storm
    EIFM = { E(4, C.cyan, P.ANTIGRAVITY, P.RADIAL, P.LENS, P.MEDIUM, P.LOOP, P.GRADUALFADE, 0, P.LARGE, 5, -35, 2) },           -- freeze magic
    -- the good dragon's breath and the bless spell: the picture EZ21 (8 frames) stays and sprays yellow sparks
    EBLS = { E(7, C.yellow, P.GRAVITY, P.FOUNTAIN, P.SPECIAL, P.MEDIUM, P.FORWARDBACK, P.GRADUALFADE, 0, P.LARGE, 5, -40, 2),
             sprite = "EZ21" },
}
-- the mana leech effect id is 'EMLE', the blessing sparkle 'EBLS', the poison gate 'EPGA'
M.DUMMY_FRAMES = 16         -- the dummy picture EDUM (16 frames: the effect set-up FUN_0053c870)
M.EFFECT_MS = 50            -- ms a frame of an effect (120 for the slow ones, which carry no emitter)

-- Other particle calls of the original that are not table entries: the Explode ability (FUN_00529a40, two bursts when no effect
-- picture is asked for), the Minotaur's meal (FUN_005210b0, next to Eating.wav) and the two below.
M.EXTRA = {
    explode = { E(8, C.red, P.GRAVITY, P.RADIAL, P.GLOW, P.MEDIUM, P.REVERSEONESHOT, P.FADEOUT, 0, P.SMALL, 1000),
                E(6, C.brown, P.GRAVITY, P.RADIAL, P.CLOUD, P.SLOW, P.LOOP, P.GRADUALFADE, 0, P.SMALL, 1000) },
    eat = { E(11, C.red, P.GRAVITY, P.RADIAL, P.SPECIAL, P.MEDIUM, P.FRAMERANDOM, P.FADEOUT, 0, P.SMALL, 1000) },
    -- a failed spell (FUN_005777a0, the call before the "Spell Failed" line) and the end of a hero's spell recovery (the army's
    -- Update, 0x0051c8f0, 20 pixels above the effect point)
    fizz = { E(12, C.yellow, P.ANTIGRAVITY, P.RADIAL, P.STAR, P.SLOW, P.LOOP, P.FADEINANDOUT, 4, P.LARGE, 1000) },
    recovered = { E(10, C.white, P.GRAVITY, P.RADIAL, P.STAR, P.MEDIUM, P.FRAMERANDOM, P.FADEOUT, 0, P.LARGE, 1000) },
}

-- The missile table (FUN_0040f620): missile code -> { sprite (the picture it is drawn with; "EDUM" is invisible), real (the code its damage,
-- flags and sounds use when it differs), emitter }. `size` 0 entries only flash lights.
M.MISSILES = {
    EMIF = { sprite = "EDUM", E(3, C.blue, P.NOGRAVITY, P.RADIAL, P.SPECIAL, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.SMALL, 1, 0, 0) },   -- ice floe
    EMIS = { sprite = "EDUM", E(4, C.cyan, P.GRAVITY, P.FOUNTAIN, P.SPECIAL, P.FAST, P.FRAMERANDOM, P.GRADUALFADE, 0, P.LARGE, 1, 0, 0) },   -- ice shards
    EMA1 = { E(2, C.white, P.GRAVITY, P.RADIAL, P.STAR, P.MEDIUM, P.LOOP, P.GRADUALFADE, 0, P.SMALL, 3, 0, 0) },                 -- silver arrow
    EMA2 = { E(1, C.red, P.NOGRAVITY, P.FOUNTAIN, P.SPECIAL, P.FAST, P.NOANIMATE, P.GRADUALFADE, 0, P.SMALL, 1000, 0, 0) },      -- flaming arrow
    EMAP = { sprite = "EMA0", E(1, C.green, P.GRAVITY, P.FOUNTAIN, P.GLOW, P.SLOW, P.FRAME1, P.FADEOUT, 0, P.SMALL, 1, 0, 0) },  -- poison arrow
    EMFP = { sprite = "EMA2", E(2, C.green, P.GRAVITY, P.FOUNTAIN, P.GLOW, P.FAST, P.FRAME1, P.GRADUALFADE, 0, P.SMALL, 5, 0, 0) }, -- fire poison arrow
    EMS0 = { sprite = "EMM3", E(1, C.red, P.GRAVITY, P.RADIAL, P.CLOUD, P.SLOW, P.FRAMERANDOM, P.FADEOUT, 0, P.SMALL, 1, 0, 0) },  -- Minotaur's axe
    EMF0 = { E(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, { L.RED, L.SMALL, L.SHORT }) },                                           -- fireball: a light only
    EMM0 = { E(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, { L.BLUE, L.SMALL, L.SHORT }) },                                          -- magic sphere: a light only
    EMM1 = { E(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, -2, { L.RED, L.MEDIUM, L.SHORT }) },                                       -- red lightning
    EMM2 = { E(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, -2, { L.BLUE, L.MEDIUM, L.SHORT }) },                                      -- blue lightning
    EMMF = { sprite = "EMC1", real = "EMC1", E(5, C.brown, P.ANTIGRAVITY, P.FOUNTAIN, P.CLOUD, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.LARGE, 1000, 0, 1) }, -- mortar fire
    EMTF = { sprite = "EMF0", E(15, C.red, P.NOGRAVITY, P.FOUNTAIN, P.GLOW, P.FAST, P.FRAMERANDOM, P.GRADUALFADE, 0, P.MASSIVE, 1000, 0, 1) },    -- the titan's fire ball
    EMTM = { sprite = "EMM0", E(15, C.cyan, P.NOGRAVITY, P.FOUNTAIN, P.GLOW, P.FAST, P.FRAMERANDOM, P.GRADUALFADE, 0, P.MASSIVE, 1000, 0, 1) },   -- the titan's magic ball
}

-- The building table (FUN_0040e930): the emitter of a building code. `roll(n)` answers 1..n (a hash in openwbc3, a dice roll in the
-- original).
local PLAGUE = { BKG0 = 1, BKG1 = 1, BKG2 = 1, BKG3 = 1, BKG4 = 1, BWTG = 1, BASM = 1, BACP = 1, BPPS = 1, BPLB = 1 }
local FURNACE = { BKA0 = 1, BKA1 = 1, BKA2 = 1, BKA3 = 1, BKA4 = 1 }
local CAVE = { BPFC = "fire", BPIC = "ice" }
---@param code string
---@param roll fun(n: integer): integer
---@return Emitter
function M.building(code, roll)
    if PLAGUE[code] then
        return E(3, C.green, P.ANTIGRAVITY, P.FOUNTAIN, P.GLOW, P.SLOW, P.ONESHOT, P.FADEOUT, 0, P.SMALL, 9, 0, 2)
    elseif CAVE[code] == "fire" then             -- fire cave: yellow, or red one time in two
        return E(3, roll(2) == 1 and C.red or C.yellow, P.ANTIGRAVITY, P.FOUNTAIN, P.STAR, P.SLOW, P.ONESHOT, P.FADEOUT, 0,
                 P.SMALL, 9, 0, 2)
    elseif CAVE[code] == "ice" then              -- ice cave
        return E(3, C.cyan, P.ANTIGRAVITY, P.FOUNTAIN, P.STAR, P.SLOW, P.ONESHOT, P.FADEOUT, 0, P.SMALL, 9, 0, 2)
    elseif FURNACE[code] then                    -- furnace: white smoke, red sparks one time in four
        if roll(4) == 1 then
            return E(5, C.red, P.GRAVITY, P.FOUNTAIN, P.GLOW, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.SMALL, 10, 0, 5)
        end
        return E(3, C.white, P.ANTIGRAVITY, P.FOUNTAIN, P.CLOUD, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.SMALL, 10, 0, 5)
    end
    return E(3, C.white, P.ANTIGRAVITY, P.FOUNTAIN, P.CLOUD, P.SLOW, P.FRAMERANDOM, P.GRADUALFADE, 0, P.SMALL, 10, 0, 2)
end

-- The animation steps (1-based, one every 50 ms) of an effect with `frames` frames at which an emitter fires: the counter starts
-- at 1000, goes up before the test and restarts at 0 when it has reached `every`.
---@param every integer
---@param frames integer
---@return integer[]
function M.steps(every, frames)
    local out, counter = {}, 1000
    for step = 1, frames do
        counter = counter + 1
        if counter >= every then
            counter = 0
            out[#out + 1] = step
        end
    end
    return out
end

-- Starts the particle burst of an emitter record at world pixel (x, y); `level` is the particle option (0..3).
---@param list ParticleList
---@param e Emitter
---@param x number
---@param y number
---@param now number
---@param level integer?
---@return boolean
function M.burst(list, e, x, y, now, level)
    if e.size <= 0 then return false end
    list:add(x, y + e.py, now, { size = e.size, colors = e.colors, gravity = e.gravity, direction = e.direction, type = e.type,
                                 speed = e.speed, animation = e.animation, fade = e.fade, respawn = e.respawn, area = e.area,
                                 level = level })
    return true
end

-- The emitter of an effect code ({ emitter, picture } or nil) and the animation frames the effect has (the dummy's 16, else
-- `frames` of its own picture).
---@param code string
---@return Emitter? emitter
---@return (string|boolean)? sprite the picture: true = the code's own, a code = another one, nil = the dummy
function M.effect(code)
    local rec = M.EFFECTS[code]
    if not rec then return nil end
    return rec[1], rec.sprite
end

-- The emitter and the picture override of a missile code.
---@param code string
---@return Emitter? emitter
---@return string? sprite
---@return string? real
function M.missile(code)
    local rec = M.MISSILES[code]
    if not rec then return nil end
    return rec[1], rec.sprite, rec.real
end

-- Compatibility: starts the bursts of an effect, extra or missile code once at world pixel (x, y) (the first frame of an effect
-- fires its emitter at once; `explode` and `eat` are the two other particle calls). Returns whether the code has an emitter.
---@param list ParticleList
---@param code string
---@param x number
---@param y number
---@param now number
---@param level integer?
---@return boolean
function M.emit(list, code, x, y, now, level)
    local def = M.EXTRA[code]
    local n = 0
    if def then
        for _, e in ipairs(def) do if M.burst(list, e, x, y, now, level) then n = n + 1 end end
        return n > 0
    end
    local e = M.effect(code) or M.missile(code)
    if not e then return false end
    return M.burst(list, e, x, y, now, level)
end

return M
