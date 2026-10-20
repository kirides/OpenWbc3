-- Loads the content registry (docs/data-driven/01-content-registry.md 1.7, 6.2): layers in order -- the engine-authored
-- base ruleset, importers of the player's install, mods -- then `finalise`. A layer is a function run with the layer
-- name set; an error inside a mod layer drops that mod (the registry is built again without it) and is reported, an error
-- in an engine layer is reported as an error of the load (the caller decides whether that is fatal).
--
-- Phases: `define` runs the base modules' `define`, then the importers (so importers can refer to records the base
-- defines, like the races); `patch` runs the base modules' `patch` (data that decorates imported records: tags ...);
-- `final` the base `final`. Mods join in the same phases (stage 6). A base module requires engine modules inside its phase functions,
-- never at the top of its file: engine modules read settings and records of the registry when they load.
local content = require("src.content")
local log = require("src.core.log")

---@class ContentLoader
---@field mods ModEntry[]?
---@field autoMods ModEntry[]?             the entries of the mod folders (when no caller set `mods`)
---@field failed table<string, string>?    mod id -> why it was dropped by the last `setup`
local M = {}

-- Base ruleset modules (game/content/base/*): each returns a function (define) or { define =, patch =, final = }.
M.base = { "content.base.races", "content.base.powerups", "content.base.tags", "content.base.items", "content.base.abilities", "content.base.skills", "content.base.classes", "content.base.hero", "content.base.rules", "content.base.damagetypes", "content.base.missiles", "content.base.statuses", "content.base.victory", "content.base.attitudes", "content.base.aiprofiles", "content.base.spheres", "content.base.spells",
                "content.base.lairs" }
-- Importers (install -> registry, src/import/wbc3/*): each returns function(content).
M.importers = { "src.import.wbc3.units", "src.import.wbc3.buildings", "src.import.wbc3.rules", "src.import.wbc3.items", "src.import.wbc3.attitudes" }

-- Mods: { id = "orc_tweaks", define = fn, patch = fn, final = fn } with functions taking `content`, in load order. They come from the
-- mod folders (src/content/mods.lua) unless a caller (the tests) sets `M.mods` itself before `setup`. A mod whose function fails is
-- dropped and the whole registry is built again without it (all mods' changes interleave across the phases, so only a rebuild is an
-- exact rollback); the error stays in the report.
M.mods = nil

local ready = false

-- Runs `fn(content)` as layer `name`. Returns ok, err.
---@param name string
---@param fn fun(content: Content)
---@return boolean ok, any err
function M.layer(name, fn)
    content.setLayer(name)
    local ok, err = xpcall(function() return fn(content) end, function(e)
        return type(e) == "string" and e or debug.traceback(tostring(e), 2)
    end)
    if not ok then content.error("layer failed: %s", tostring(err)) end
    content.setLayer("base")
    return ok, err
end

-- Requires the modules once; returns { { name, mod = { define, patch, final } } ... }.
local function load(names, layerName)
    local out = {}
    for _, name in ipairs(names) do
        local ok, mod = pcall(require, name)
        if not ok then
            content.setLayer(layerName)
            content.error("%s: %s", name, tostring(mod))
            content.setLayer("base")
        else
            if type(mod) == "function" then mod = { define = mod } end
            out[#out + 1] = { name = name, mod = mod }
        end
    end
    return out
end

local function run(list, phase, layerName)
    for _, m in ipairs(list) do
        if m.mod[phase] then
            local ok = M.layer(layerName, m.mod[phase])
            if not ok then log.error("content: %s (%s) failed", m.name, phase) end
        end
    end
end

-- One pass: begin, base, importers, mods, finalise. `failed` is the set of mods to leave out; mods failing in this pass are
-- added to it (id -> message). Returns whether a mod failed.
local function pass(base, importers, failed)
    local newFailure = false
    local function runMods(phase)
        for _, mod in ipairs(M.mods) do
            if mod[phase] and not failed[mod.id] then
                local ok, err = M.layer("mod:" .. mod.id, mod[phase])
                if not ok then
                    failed[mod.id] = tostring(err)
                    newFailure = true
                    log.error("content: mod %s failed in %s and is skipped", mod.id, phase)
                end
            end
        end
    end
    require("src.import.wbc3.cfg").clear()       -- the parsed files are shared into records: parse again for every pass
    content.begin()
    content.phase("define")
    run(base, "define", "base")
    run(importers, "define", "wbc3")
    runMods("define")
    content.phase("patch")
    run(base, "patch", "base")
    run(importers, "patch", "wbc3")
    runMods("patch")
    content.phase("final")
    run(base, "final", "base")
    run(importers, "final", "wbc3")
    runMods("final")
    return newFailure
end

-- Builds the registry: base, importers, mods, finalise. Idempotent unless `force`. Returns the report.
---@param force boolean?
---@return ContentReport
function M.setup(force)
    if ready and not force then return content.report() end
    local t0 = os.clock()
    local base, importers = load(M.base, "base"), load(M.importers, "wbc3")
    local mods = require("src.content.mods")
    local slots = require("src.content.slots")
    content.setSlotAllocator(slots.allocate)
    if M.mods == nil or M.mods == M.autoMods then        -- the mod folders, unless a caller set an explicit list
        M.autoMods = mods.entries(content)
        M.mods = M.autoMods
    else
        mods.reset()
    end
    local failed = {}
    while pass(base, importers, failed) do end
    local report = content.finalise()
    content.setMeta(mods.metaText())
    slots.save()
    if package.loaded["src.gfx.anims"] then package.loaded["src.gfx.anims"].forget() end
    for _, e in ipairs(mods.errors()) do content.warn("%s", e) end
    for _, mod in ipairs(M.mods) do
        if failed[mod.id] then
            content.setLayer("mod:" .. mod.id)
            content.error("mod disabled: %s", failed[mod.id])
        end
    end
    content.setLayer("base")
    M.failed = failed
    ready = true
    for _, e in ipairs(report.errors) do log.error("content: %s", e.text) end
    for _, w in ipairs(report.warnings) do log.debug("content: %s", w.text) end
    log.info("content: %d errors, %d warnings (%.3fs)", #report.errors, #report.warnings, os.clock() - t0)
    return report
end

---@return boolean
function M.isReady() return ready end

return M
