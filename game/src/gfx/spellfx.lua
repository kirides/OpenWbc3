-- Which armies and buildings a cast touched, for the effect pictures of the spell records (`pictures`, content/base/spells.lua).
--
-- The original's spell message lists the targets and every spell function marks the ones it changed (a per-target flag, the
-- switch of FUN_004ac0e0 on the message's effect kind); its casting effect plays on the caster, its target effect on every marked
-- target and its persistent effect on every marked target for as long as the cast's statuses last (FUN_004ac0e0 end, FUN_00577320
-- makes the timed spell effect record). openwbc3's spells change the world through many helpers, so the view compares the world before and after the
-- effect function runs ("spellbegin" / "spellcast" events of game/spells.lua) and takes as touched:
--   * an army whose hit points, chaos morphs or mana changed, or that has a timed effect (`u.fx`) added, extended or removed, or that was made;
--   * a building whose hit points or chaos morphs changed or that was made;
--   * the target of a missile the cast launched.
-- A persistent picture goes on the armies that got a new or longer timed effect, else on the caster, and lasts as long as the
-- cast's duration (`c.durMs`, what the effect function asked of fx.dur) or, for a unit's own effect kinds, while one of them is on
-- it. This is openwbc3's reading: the original's lists come from the spell functions, which the simulation does not mirror.
-- Presentation only: reads the world, changes nothing. Must not touch love.graphics at require time.
local M = {}

local MAX_TARGETS = 24                -- the original's message holds at most 24 armies (FUN_004ac0e0's target arrays of 24)

-- The "before" picture of a cast.
---@class SpellSnap
---@field caster Unit?
---@field pics table           the spell's `pictures` record
---@field ctx table?           its cast context (durMs)
---@field units table<Unit, { stats: string, fx: table<any, number> }>
---@field buildings table<Building, string>
---@field nbuildings integer
---@field nmissiles integer
---@field t number

-- What a cast touched (M.finish).
---@class SpellTouched
---@field touched (Unit|Building)[]   row by row, at most 24
---@field persistent { owner: Unit, kinds: table<any, boolean>? }[]
---@field untilMs number

-- What a spell can change on an army or building besides its timed effects: hit points, the chaos morphs, mana.
---@param o Unit|Building
---@return string
local function stats(o)
    local morph = 0
    if o.morphMod then for _, v in pairs(o.morphMod) do morph = morph + v end end
    local mana = (o.mana or 0) + (o.h and o.h.mana or 0)
    return ("%s:%s:%s"):format(o.hp, morph, mana)
end

-- Takes the "before" picture of the world for a cast of `caster` (`pics` is the spell's `pictures` record, `ctx` its cast context).
---@param world World
---@param caster Unit?
---@param pics table
---@param ctx table?
---@return SpellSnap
function M.begin(world, caster, pics, ctx)
    local snap = { caster = caster, pics = pics, ctx = ctx, units = {}, buildings = {}, nbuildings = #world.buildings,
                   nmissiles = #world.missiles, t = world.time }
    for _, u in ipairs(world.units) do
        local fx = {}
        if u.fx then for kind, f in pairs(u.fx) do fx[kind] = f.t1 or 0 end end
        snap.units[u] = { stats = stats(u), fx = fx }
    end
    for _, b in ipairs(world.buildings) do snap.buildings[b] = stats(b) end
    return snap
end

local function byPlace(a, b)
    if a.gy ~= b.gy then return a.gy < b.gy end
    if a.gx ~= b.gx then return a.gx < b.gx end
    return (a.id or 0) < (b.id or 0)
end

-- Compares with the world after the cast: returns { touched = { army or building ... } (row by row, at most 24), persistent = {
-- { owner, kinds = { effect kind = true } | nil } ... }, untilMs = the time the persistent pictures end }.
---@param world World
---@param snap SpellSnap
---@return SpellTouched
function M.finish(world, snap)
    local now = world.time
    local touched, persistent, seen = {}, {}, {}
    local function touch(o)
        if o and not seen[o] and not o.remove then
            seen[o] = true
            touched[#touched + 1] = o
        end
    end
    for _, u in ipairs(world.units) do
        local before = snap.units[u]
        if not before then
            touch(u)
        else
            local changed, kinds = stats(u) ~= before.stats, nil
            if u.fx then
                for kind, f in pairs(u.fx) do
                    local t1 = f.t1 or 0
                    if before.fx[kind] ~= t1 then
                        changed = true
                        if t1 > now then kinds = kinds or {} kinds[kind] = true end
                    end
                end
            end
            for kind in pairs(before.fx) do
                if not (u.fx and u.fx[kind]) then changed = true end
            end
            if changed then touch(u) end
            if kinds then persistent[#persistent + 1] = { owner = u, kinds = kinds } end
        end
    end
    for i, b in ipairs(world.buildings) do
        local before = snap.buildings[b]
        if before == nil and i > snap.nbuildings or before ~= nil and stats(b) ~= before then touch(b) end
    end
    for i = snap.nmissiles + 1, #world.missiles do
        local m = world.missiles[i]
        -- the effect function marks every target it sends a missile to (FUN_004ac0e0 case 0x10 sets the target's flag before
        -- FUN_0058bdd0), so the target picture plays on it at the cast, not when the missile lands
        if m and m.shooter == snap.caster and m.target then touch(m.target) end
    end
    table.sort(touched, byPlace)
    while #touched > MAX_TARGETS do touched[#touched] = nil end
    local dur = snap.ctx and snap.ctx.durMs or 0
    if #persistent == 0 and dur > 0 and snap.caster then persistent[1] = { owner = snap.caster } end
    return { touched = touched, persistent = persistent, untilMs = now + dur }
end

return M
