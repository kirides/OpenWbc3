-- Mod discovery, manifests, load order and the loader entries (docs/data-driven/06-mod-runtime.md 6.1 / 6.2).
--
-- A mod is a folder with a manifest `mod.lua` and Lua files in `data/` (define phase), `patch/` and `final/`; art, sound, text and
-- override files belong to the asset layer (stage 5). Mods live in <save directory>/mods/<folder>, or anywhere through `--mod <dir>` and
-- `[mods] path=<dir>` of openwbc3.ini. Which mods are enabled and in what order is <save directory>/mods/enabled.lua (`return { "id", ... }`),
-- edited by the mod manager (screens/mods.lua).
--
-- mod.lua (a plain table, evaluated in an empty environment: no code runs at this point):
--   id = "orc_tweaks"                     [a-z][a-z0-9_]*, unique; the namespace of every id the mod adds ("orc_tweaks:shaman")
--   name, version, author, description    shown in the manager
--   api = 1                               the content API version the mod was written for
--   requires = { "openwbc3 >= 0.1" }      engine version range
--   depends = { "base_pack >= 2.0" }      hard: must be enabled, is loaded earlier
--   after = { "balance_mod" }             soft: only affects the order when present
--   conflicts = { "other_mod" }
--   scope = "gameplay" | "cosmetic"       cosmetic mods carry no data / patch / final files (art, text and sound only) and stay out of the
--                                         multiplayer content check
--   files = { data = {...}, patch = {...}, final = {...} }   optional explicit file order (default: sorted names)
local config = require("src.core.config")
local log = require("src.core.log")
local hashlib = require("src.content.hash")
local modfs = require("src.content.modfs")
local sandbox = require("src.content.sandbox")

local M = {}

-- A checked mod.lua (readManifest fills the defaults).
---@class ModManifest
---@field id string
---@field name string
---@field version string
---@field author string?
---@field description string?
---@field api integer
---@field requires string[]
---@field depends string[]
---@field after string[]
---@field conflicts string[]
---@field scope "gameplay"|"cosmetic"
---@field files { data: string[]?, patch: string[]?, final: string[]? }?
---@field _text string                  the source text (hashed)

-- A mod folder that was found.
---@class ModFound
---@field id string                     the manifest id, else the folder name
---@field folder string
---@field dir ModDir
---@field manifest ModManifest?         nil when it could not be read
---@field source "save"|"cli"|"ini"
---@field error string?

-- A loader entry (src/content/loader.lua `M.mods`): the phase functions of one mod.
---@class ModEntry
---@field id string
---@field define fun(content: Content)?
---@field patch fun(content: Content)?
---@field final fun(content: Content)?

-- A loaded mod as `loaded()` / `describe()` report it.
---@class ModLoaded
---@field id string
---@field name string
---@field version string
---@field scope string
---@field folder string
---@field chunks table<string, string>  chunk name -> hash of its text
---@field manifestHash string

-- The mod set of a session, for saves and the lobby (`describe`).
---@class ModSetDescription
---@field hash string                   the registry hash
---@field version string                the engine version
---@field mods { id: string, name: string, version: string, scope: string, hash: string }[]

M.ENGINE_VERSION = "0.1"
M.API = 1
M.PHASES = { "data", "patch", "final" }         -- the folders, in the order of the load phases: define, patch, final
---@type table<string, "define"|"patch"|"final">
local PHASE_OF = { data = "define", patch = "patch", final = "final" }

-- The folder below the save directory that holds the mods, the list of enabled ones and the slot table (the tests use their own).
M.root = "mods"

---@type { cli: string[], noMods: boolean, only: boolean, found: ModFound[]?, errors: string[], loaded: ModLoaded[], order: any }
local state = { cli = {}, noMods = false, only = false, found = nil, errors = {}, loaded = {}, order = nil }

-- Settings of this session from the command line: --mod <dir> (repeatable, enables that folder), --no-mods, --check-mod <dir> (only that
-- folder, whatever the player enabled).
---@param args string[]?
function M.configure(args)
    state.cli, state.noMods, state.only, state.found = {}, false, false, nil
    for i, a in ipairs(args or {}) do
        ---@cast args -nil
        if a == "--check-mod" and args[i + 1] then state.cli[#state.cli + 1] = args[i + 1]:gsub("\\", "/"):gsub("/$", "") state.only = true end
        if a == "--mod" and args[i + 1] then state.cli[#state.cli + 1] = args[i + 1]:gsub("\\", "/"):gsub("/$", "") end
        if a == "--no-mods" then state.noMods = true end
    end
end

-- Version strings: "1.2.3" > "1.2" > "1.1.9"; missing parts count as 0.
local function versionParts(v)
    local out = {}
    for n in tostring(v or "0"):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end
-- -1, 0 or 1.
---@param a string?
---@param b string?
---@return integer
function M.compareVersions(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

-- "name >= 1.2" -> name, op, version ("name" alone: any version)
local function parseRequirement(text)
    local name, op, version = tostring(text):match("^%s*([%w_]+)%s*([<>=]*)%s*([%d%.]*)%s*$")
    if not name then return nil end
    return name, op ~= "" and op or nil, version ~= "" and version or nil
end

local function satisfied(have, op, want)
    if not op or not want then return true end
    local c = M.compareVersions(have, want)
    if op == ">=" then return c >= 0 elseif op == ">" then return c > 0 elseif op == "<=" then return c <= 0
    elseif op == "<" then return c < 0 elseif op == "=" or op == "==" then return c == 0 end
    return true
end

-- Reads and checks a manifest; returns the table or nil, message.
---@param dir ModDir
---@param folder string
---@return ModManifest?, string?
local function readManifest(dir, folder)
    local text = dir:read("mod.lua")
    if not text then return nil, "no mod.lua" end
    local chunk, err = loadstring(text, "@" .. folder .. "/mod.lua")
    if not chunk then return nil, err end
    setfenv(chunk, {})
    local ok, m = pcall(chunk)
    if not ok or type(m) ~= "table" then return nil, ok and "mod.lua must return a table" or tostring(m) end
    if type(m.id) ~= "string" or not m.id:match("^[a-z][a-z0-9_]*$") then return nil, "id must match [a-z][a-z0-9_]*" end
    m.name = type(m.name) == "string" and m.name or m.id
    m.version = tostring(m.version or "0")
    m.api = tonumber(m.api) or 1
    m.scope = m.scope or "gameplay"
    if m.scope ~= "gameplay" and m.scope ~= "cosmetic" then return nil, "scope must be gameplay or cosmetic" end
    for _, field in ipairs({ "requires", "depends", "after", "conflicts" }) do
        if m[field] ~= nil and type(m[field]) ~= "table" then return nil, field .. " must be a list" end
        m[field] = m[field] or {}
    end
    if m.api > M.API then return nil, ("written for content API %d, this engine has %d"):format(m.api, M.API) end
    m._text = text
    return m
end

-- Every mod folder that can be found: { id, folder, dir, manifest, source = "save" | "cli" | "ini", error }. Cached until `configure`.
---@return ModFound[]
function M.discover()
    if state.found then return state.found end
    local found, seen = {}, {}
    local function add(dir, folder, source)
        local m, err = readManifest(dir, folder)
        local rec = { folder = folder, dir = dir, manifest = m, source = source, error = err, id = m and m.id or folder }
        if m and seen[m.id] then
            rec.manifest, rec.error = nil, ("id '%s' is already used by %s"):format(m.id, seen[m.id])
        elseif m then
            seen[m.id] = folder
        end
        found[#found + 1] = rec
    end
    for _, name in ipairs(modfs.folders(M.root, "save")) do add(modfs.open(M.root .. "/" .. name, "save"), name, "save") end
    local ini = config.get and config.get("mods", "path", nil)
    local paths = {}
    if ini and ini ~= "" then
        for p in tostring(ini):gmatch("[^;]+") do paths[#paths + 1] = p:gsub("\\", "/"):gsub("/$", "") end
    end
    for _, root in ipairs(paths) do
        for _, name in ipairs(modfs.folders(root, "real")) do add(modfs.open(root .. "/" .. name, "real"), name, "ini") end
    end
    for _, path in ipairs(state.cli) do
        local name = path:match("([^/]+)$") or path
        add(modfs.open(path, "real"), name, "cli")
    end
    state.found = found
    return found
end

-- The ids the player enabled, in his order (<save directory>/mods/enabled.lua).
---@return string[]
function M.enabledIds()
    local text = love.filesystem.getInfo(M.root .. "/enabled.lua") and love.filesystem.read(M.root .. "/enabled.lua")
    local list = {}
    if text then
        local chunk = loadstring(text, "@" .. M.root .. "/enabled.lua")
        if chunk then
            setfenv(chunk, {})
            local ok, t = pcall(chunk)
            if ok and type(t) == "table" then
                for _, id in ipairs(t) do if type(id) == "string" then list[#list + 1] = id end end
            end
        end
    end
    return list
end

---@param ids string[]
function M.saveEnabled(ids)
    love.filesystem.createDirectory(M.root)
    local lines = { "-- The mods the player enabled, in the order of his choice (edited by the mod manager)", "return {" }
    for _, id in ipairs(ids) do lines[#lines + 1] = ("    %q,"):format(id) end
    lines[#lines + 1] = "}"
    love.filesystem.write(M.root .. "/enabled.lua", table.concat(lines, "\n") .. "\n")
end

-- The mods of this session in load order: { { rec, ... } }, and a list of messages for the ones that were left out.
-- Order: a topological sort over `depends` / `after`, ties by the player's list, then by id (never by file system order).
---@return ModFound[] planned, string[] errors
function M.plan()
    local errors = {}
    local found = M.discover()
    local byId = {}
    for _, rec in ipairs(found) do
        if rec.manifest then byId[rec.manifest.id] = rec elseif rec.source ~= "save" then errors[#errors + 1] = ("%s: %s"):format(rec.folder, rec.error) end
    end
    local want, rank = {}, {}
    if not state.noMods then
        for _, id in ipairs(state.only and {} or M.enabledIds()) do
            if byId[id] and not rank[id] then want[#want + 1] = id rank[id] = #want
            elseif not byId[id] then errors[#errors + 1] = ("enabled mod '%s' was not found"):format(id) end
        end
        for _, rec in ipairs(found) do
            if rec.manifest and rec.source == "cli" and not rank[rec.manifest.id] then
                want[#want + 1] = rec.manifest.id
                rank[rec.manifest.id] = #want
            end
        end
    end
    -- requirements: drop what cannot be satisfied (repeat: dropping one can break its dependants)
    local active = {}
    for _, id in ipairs(want) do active[id] = true end
    local function drop(id, why)
        active[id] = nil
        errors[#errors + 1] = ("mod '%s' left out: %s"):format(id, why)
    end
    local changed = true
    while changed do
        changed = false
        for _, id in ipairs(want) do
            if active[id] then
                local m = byId[id].manifest
                for _, req in ipairs(m.requires) do
                    local name, op, version = parseRequirement(req)
                    if name == "openwbc3" and not satisfied(M.ENGINE_VERSION, op, version) then
                        drop(id, ("needs %s, this is %s"):format(req, M.ENGINE_VERSION)) changed = true break
                    end
                end
                if active[id] then
                    for _, dep in ipairs(m.depends) do
                        local name, op, version = parseRequirement(dep)
                        local other = name and byId[name]
                        if not (other and active[name] and satisfied(other.manifest.version, op, version)) then
                            drop(id, ("needs '%s'"):format(dep)) changed = true break
                        end
                    end
                end
            end
        end
    end
    -- the order
    local deps = {}
    for id in pairs(active) do
        local m = byId[id].manifest
        deps[id] = {}
        for _, list in ipairs({ m.depends, m.after }) do
            for _, req in ipairs(list) do
                local name = parseRequirement(req)
                if name and active[name] and name ~= id then deps[id][name] = true end
            end
        end
    end
    local ordered, done = {}, {}
    local function better(a, b)
        local ra, rb = rank[a] or math.huge, rank[b] or math.huge
        if ra ~= rb then return ra < rb end
        return a < b
    end
    local remaining = {}
    for id in pairs(active) do remaining[#remaining + 1] = id end
    table.sort(remaining, better)
    while #remaining > 0 do
        local pick
        for i, id in ipairs(remaining) do
            local ready = true
            for dep in pairs(deps[id]) do if not done[dep] then ready = false break end end
            if ready then pick = i break end
        end
        if not pick then
            errors[#errors + 1] = "the mods depend on each other in a circle: " .. table.concat(remaining, ", ")
            break
        end
        local id = table.remove(remaining, pick)
        done[id] = true
        ordered[#ordered + 1] = byId[id]
    end
    -- conflicts: the later mod goes
    local kept = {}
    for _, rec in ipairs(ordered) do
        local clash
        for _, c in ipairs(rec.manifest.conflicts) do
            if kept[c] then clash = c end
        end
        for id in pairs(kept) do
            for _, c in ipairs(byId[id].manifest.conflicts) do if c == rec.manifest.id then clash = id end end
        end
        if clash then
            errors[#errors + 1] = ("mod '%s' left out: it conflicts with '%s'"):format(rec.manifest.id, clash)
        else
            kept[rec.manifest.id] = true
        end
    end
    local result = {}
    for _, rec in ipairs(ordered) do if kept[rec.manifest.id] then result[#result + 1] = rec end end
    return result, errors
end

-- The loader entries (`content.loader.mods`) of the planned mods. Each runs the files of one phase folder in the mod's sandbox.
---@param content Content
---@return ModEntry[]
function M.entries(content)
    local planned, errors = M.plan()
    state.errors = errors
    state.loaded = {}
    local entries, mounts = {}, {}
    for _, rec in ipairs(planned) do
        local m, dir = rec.manifest, rec.dir
        ---@cast m -nil                  -- planned mods have a manifest
        mounts[#mounts + 1] = { id = m.id, dir = dir }
        local info = { id = m.id, name = m.name, version = m.version, scope = m.scope, folder = rec.folder, chunks = {}, manifestHash = hashlib.string(m._text) }
        state.loaded[#state.loaded + 1] = info
        local env, loading = nil, false
        local function runFile(rel)
            local text = dir:read(rel)
            if not text then error(("mod '%s': %s is missing"):format(m.id, rel), 0) end
            local chunkname = "@mod:" .. m.id .. "/" .. rel
            content.sources[chunkname] = text
            info.chunks[chunkname] = hashlib.string(text)
            local chunk, err = loadstring(text, chunkname)
            if not chunk then error(err, 0) end
            setfenv(chunk, env --[[@as table]])          -- set by the phase function before any file runs
            local was = loading
            loading = true
            local ok, a, b, c = pcall(sandbox.run, chunk)
            loading = was
            if not ok then error(a, 0) end
            return a, b, c
        end
        local function files(phase)
            local explicit = m.files and m.files[phase]
            if explicit then return explicit end
            local names = {}
            for _, name in ipairs(dir:lua(phase)) do names[#names + 1] = name end
            return names
        end
        ---@type ModEntry
        local entry = { id = m.id }
        local function phaseFunction(folder)
            return function(c)
                if not env then
                    env = sandbox.env({ content = c, manifest = { id = m.id, name = m.name, version = m.version, author = m.author,
                                                                  scope = m.scope },
                                        include = function(rel) return runFile(rel) end, loading = function() return loading end,
                                        asset = require("src.assets").builders(m.id),
                                        fx = function() return require("src.game.fx") end })
                end
                for _, name in ipairs(files(folder)) do runFile(folder .. "/" .. name) end
            end
        end
        for _, folder in ipairs(M.PHASES) do
            -- the key is "define" / "patch" / "final", not the entry's id
            ---@diagnostic disable-next-line: assign-type-mismatch
            if #files(folder) > 0 then entry[PHASE_OF[folder]] = phaseFunction(folder) end
        end
        if m.scope == "cosmetic" and (entry.define or entry.patch or entry.final) then
            errors[#errors + 1] = ("mod '%s' is cosmetic but has data / patch / final files"):format(m.id)
            state.loaded[#state.loaded] = nil
        else
            entries[#entries + 1] = entry
        end
    end
    require("src.assets").setMounts(mounts)
    return entries
end

-- Forgets the loaded mods (a caller that supplies its own mod list).
function M.reset()
    state.loaded, state.errors = {}, {}
    require("src.assets").setMounts({})
end

-- Errors of the last plan (mods left out).
---@return string[]
function M.errors() return state.errors end

-- The mods that were loaded: { { id, name, version, scope, chunks = { chunkname = hash } } }
---@return ModLoaded[]
function M.loaded() return state.loaded end

-- A compact description of the loaded mod set for saves and the multiplayer lobby: { hash, version, mods = { { id, version, hash } } }.
-- `hash` is the registry hash (records, functions, the mods' manifests and file hashes).
---@param content { hash: fun(): string }
---@return ModSetDescription
function M.describe(content)
    local mods = {}
    for _, info in ipairs(state.loaded) do
        local names = {}
        for chunk in pairs(info.chunks) do names[#names + 1] = chunk end
        table.sort(names)
        local parts = { info.manifestHash }
        for _, chunk in ipairs(names) do parts[#parts + 1] = chunk .. "=" .. info.chunks[chunk] end
        mods[#mods + 1] = { id = info.id, name = info.name, version = info.version, scope = info.scope,
                            hash = hashlib.string(table.concat(parts, ";")) }
    end
    return { hash = content.hash(), version = M.ENGINE_VERSION, mods = mods }
end

-- Tells whether a description of another machine / an earlier session (`describe`) matches the loaded content. Returns true, or false and
-- a sentence naming what differs ("saved with: orc_tweaks 1.2; now: none").
---@param theirs ModSetDescription?
---@param content { hash: fun(): string }
---@return boolean same, string? why
function M.compare(theirs, content)
    local mine = M.describe(content)
    if theirs and theirs.hash == mine.hash then return true end
    local function list(info)
        local out = {}
        for _, m in ipairs(info and info.mods or {}) do
            if m.scope ~= "cosmetic" then out[#out + 1] = m.id .. " " .. m.version end
        end
        return #out > 0 and table.concat(out, ", ") or "no mods"
    end
    local a, b = list(theirs), list(mine)
    if not theirs then return false, ("no content information (now: %s)"):format(b) end
    if a == b then return false, ("the same mods (%s) with different files or another game version"):format(a) end
    return false, ("the other side has: %s; here: %s"):format(a, b)
end

-- The text the registry hash mixes in: every gameplay mod with its version and file hashes, in load order.
---@return string
function M.metaText()
    local lines = { "engine " .. M.ENGINE_VERSION }
    for _, m in ipairs(M.describe({ hash = function() return "" end }).mods) do
        if m.scope ~= "cosmetic" then lines[#lines + 1] = ("mod %s %s %s"):format(m.id, m.version, m.hash) end
    end
    return table.concat(lines, "\n")
end

return M
