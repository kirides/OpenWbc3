-- The content registry core: kinds of records, the patch API, phases, provenance, finalisation, hash
-- (docs/data-driven/01-content-registry.md). `registry.new()` builds an independent registry (the tests use it);
-- `src/content/init.lua` holds the one the game uses.
--
-- A registry holds *kinds* (`unit`, `race`, `spell` ...). A kind holds records: plain tables with a string `id`.
-- Kind handles are reachable as `R.<kind>` and `R.kind(name)`; `R.unit["AHBX"]` is the record, `R.unit:all()` the
-- ordered array. Reading is always allowed; writing only in the define / patch / final phases (`R.begin()` ..
-- `R.finalise()`). Provenance (layer, file, line) and the patch trail are kept beside the records, not in them.
local patch = require("src.content.patch")
local hashlib = require("src.content.hash")
local dump = require("src.content.dump")

---@alias ContentId string|number    a record id: a string (a 4-letter code, "modid:name"), a number for the numbered items

-- A reference spec of a kind (`def.refs`, see `cascade`).
---@class ContentRef
---@field field string                  dotted path; "*" visits every value of a table
---@field target string                 the kind the ids name
---@field mode "id"|"list"|"keys"
---@field key string?                   "list" of records: the field that holds the id (default "id")
---@field hard boolean?                 removing the target is an error instead of clearing the field

-- The definition of a kind (the table a `src/content/kinds/*.lua` file returns).
---@class ContentKindDef
---@field name string
---@field doc string?
---@field fields table<string, string>?             documentation map
---@field refs ContentRef[]?
---@field validate (fun(rec: table, kind: ContentKind<table>): string?)?   nil when the record is fine, else the message
---@field derive (fun(rec: table, kind: ContentKind<table>))?             derived fields of one record at finalise
---@field finalise (fun(kind: ContentKind<table>, R: ContentRegistry))?   after every record was derived
---@field derived string[]?                          derived field names (left out of hash and dump)
---@field sortBy string?                             records are stable-sorted by this field at finalise
---@field slotted boolean?                           records carry a numeric `slot` (indexed at finalise)
---@field slotOf (fun(rec: table, kind: ContentKind<table>): integer)?    the slot of a record that gives none
---@field [string] any                               extras of the kind module (unit: STATUS, FLAG, composeStatus ...)

-- Where a record came from.
---@class ContentOrigin
---@field layer string                  "base", "wbc3", "mod:<id>"
---@field file string?
---@field line integer?

---@class ContentMessage
---@field layer string
---@field msg string
---@field text string                   "[layer] msg"

---@class ContentReport
---@field errors ContentMessage[]
---@field warnings ContentMessage[]

---@class ContentSnapshot
---@field kinds table<string, { recs: table, list: table[], removed: table, src: table, patched: table }>
---@field phase string

local M = {}

local PHASES = { define = 1, patch = 2, final = 3 }

local function split(path)
    local parts = {}
    for p in path:gmatch("[^%.]+") do parts[#parts + 1] = p end
    return parts
end

---@return ContentRegistry
function M.new()
    -- the kind methods close over this registry's state, so every registry has its own set

    -- A kind handle: `kind[id]` is the record (methods win over ids), the methods below read and write. The game's kinds are the
    -- fields of `Content` (src/content/init.lua) with their record classes (src/content/kinds/*.lua).
    ---@class ContentKind<T>
    ---@field name string
    ---@field def ContentKindDef
    ---@field _R Content                          the registry the kind belongs to
    ---@field _recs table<ContentId, T>           by id (aliases too)
    ---@field _list T[]                           in registry order
    ---@field _removed table<ContentId, string>   removed ids -> the layer that removed them
    ---@field _src table<ContentId, ContentOrigin>
    ---@field _patched table<ContentId, string[]> the layers that patched a record
    ---@field derivedSet table<string, true>
    ---@field cache table<string, any>            lookups built at finalise (`slot`, race `letter`, `playable`)
    ---@field [string|number] T
    local Kind = {}
    local kindMeta = {
        __index = function(self, id)
            local m = Kind[id]
            if m ~= nil then return m end
            return rawget(self, "_recs")[id]
        end,
    }
    -- The registry API (the game's registry adds the kinds: `Content`, src/content/init.lua).
    ---@class ContentRegistry
    ---@field sources table<string, string>       chunk name -> source text of mod chunks
    ---@field [string] ContentKind<table>        the kinds by name (`R.unit`), added by `defineKind`
    local R = { REMOVE = patch.REMOVE, value = patch.value, append = patch.append, prepend = patch.prepend,
                insertBefore = patch.insertBefore, insertAfter = patch.insertAfter, removeWhere = patch.removeWhere,
                clone = patch.copy }
    ---@type table<string, ContentKind<table>>, ContentKind<table>[]
    local kinds, kindList = {}, {}
    local S = { phase = "closed", layer = "base", track = false, errors = {}, warnings = {}, hooks = {},
                sources = {}, hash = nil, frozenHash = nil }
    R.sources = S.sources          -- chunk name -> source text of mod chunks (function hashing)

    -- reporting ---------------------------------------------------------------------------------------------------
    ---@param layer string
    ---@return boolean
    local function isModLayer(layer) return layer:sub(1, 4) == "mod:" end
    R.isModLayer = isModLayer

    local function report(list, layer, fmt, ...)
        local msg = select("#", ...) > 0 and fmt:format(...) or fmt
        list[#list + 1] = { layer = layer, msg = msg, text = ("[%s] %s"):format(layer, msg) }
    end
    ---@param fmt string
    ---@param ... any
    function R.error(fmt, ...) report(S.errors, S.layer, fmt, ...) end
    ---@param fmt string
    ---@param ... any
    function R.warn(fmt, ...) report(S.warnings, S.layer, fmt, ...) end

    -- Errors and warnings of the last load: { errors = { {layer, msg, text} }, warnings = {...} }.
    ---@return ContentReport
    function R.report() return { errors = S.errors, warnings = S.warnings } end

    ---@param name string
    function R.setLayer(name) S.layer = name end
    ---@return string
    function R.layer() return S.layer end
    ---@return string
    function R.phaseName() return S.phase end

    -- Whether source locations are recorded for new records (always for mods, optional for the engine layers).
    ---@param on boolean
    function R.trackSource(on) S.track = on end

    -- kinds -------------------------------------------------------------------------------------------------------
    -- Defines a kind. `def`: name, doc, fields (documentation map), refs (reference specs, see `cascade` below),
    -- validate(rec) -> nil | message, derive(rec), finalise(kind), derived (array of derived field names, left out of
    -- hash and dump), sortBy (field name: records are stable-sorted by it at finalise).
    ---@param def ContentKindDef
    ---@return ContentKind<table>
    function R.defineKind(def)
        assert(type(def) == "table" and type(def.name) == "string", "kind needs a name")
        if kinds[def.name] then error(("kind '%s' is already defined"):format(def.name), 2) end
        if Kind[def.name] ~= nil or R[def.name] ~= nil then
            error(("kind name '%s' collides with the registry API"):format(def.name), 2)
        end
        ---@type ContentKind<table>
        local k = setmetatable({ name = def.name, def = def, _R = R, _recs = {}, _list = {}, _removed = {}, _src = {},
                                 _patched = {}, derivedSet = {}, cache = {} }, kindMeta)
        for _, f in ipairs(def.derived or {}) do k.derivedSet[f] = true end
        kinds[def.name] = k
        kindList[#kindList + 1] = k
        R[def.name] = k
        return k
    end

    -- The kind handle (error when unknown).
    ---@param name string
    ---@return ContentKind<table>
    function R.kind(name)
        local k = kinds[name]
        if not k then error(("unknown content kind '%s'"):format(tostring(name)), 2) end
        return k
    end
    ---@return ContentKind<table>[]
    function R.kinds() return kindList end
    ---@param name string
    ---@return boolean
    function R.hasKind(name) return kinds[name] ~= nil end

    -- Runs `fn()` every time the registry has been finalised (and at once when it is): engine modules that keep values of the registry
    -- (settings, tables) in locals re-read them here, so mods that patch them are seen whenever the module was loaded.
    ---@type fun()[]
    local readyFns = {}
    ---@param fn fun()
    function R.onReady(fn)
        readyFns[#readyFns + 1] = fn
        if S.phase == "frozen" then fn() end
    end

    -- Runs `fn(R)` after the per-kind steps of finalise (derived data across kinds); lower `order` runs first.
    ---@param fn fun(R: ContentRegistry)
    ---@param order number?
    function R.onFinalise(fn, order)
        S.hooks[#S.hooks + 1] = { fn = fn, order = order or 100, n = #S.hooks }
    end

    -- lifecycle ---------------------------------------------------------------------------------------------------
    -- Empties every kind and opens the define phase (the loader calls it before each pass).
    function R.begin()
        for _, k in ipairs(kindList) do
            k._recs, k._list, k._removed, k._src, k._patched, k.cache = {}, {}, {}, {}, {}, {}
        end
        S.errors, S.warnings = {}, {}
        S.phase, S.layer, S.hash, S.frozenHash = "define", "base", nil, nil
    end

    -- Enters the phase `name` ("define", "patch", "final"; only forwards), or returns the current one when `name` is nil.
    ---@param name string?
    ---@return string?
    function R.phase(name)
        if name == nil then return S.phase end
        if not PHASES[name] then error(("unknown phase '%s'"):format(tostring(name)), 2) end
        if not PHASES[S.phase] then
            error(("cannot enter phase '%s': the registry is %s"):format(name, S.phase), 2)
        end
        if PHASES[name] < PHASES[S.phase] then
            error(("cannot go back from phase '%s' to '%s'"):format(S.phase, name), 2)
        end
        S.phase = name
    end

    local function writable(kind, what)
        if not PHASES[S.phase] then
            error(("cannot %s %s records: the registry is %s (writes are allowed between begin() and finalise())")
                :format(what, kind.name, S.phase), 3)
        end
    end

    ---@return ContentOrigin
    local function origin(level)
        local entry = { layer = S.layer }
        if S.track or isModLayer(S.layer) then
            local info = debug.getinfo(level, "Sl")
            if info then entry.file, entry.line = info.short_src, info.currentline end
        end
        return entry
    end

    -- Where a record came from, for messages: "mod:orc data/x.lua:12" / "base".
    ---@param kind string|ContentKind<table>
    ---@param id ContentId
    ---@return string
    function R.where(kind, id)
        local k = type(kind) == "string" and R.kind(kind) or kind
        local s = k._src[id]
        if not s then return "unknown origin" end
        local text = s.layer
        if s.file then text = text .. " " .. s.file .. ":" .. tostring(s.line) end
        local trail = k._patched[id]
        if trail and #trail > 0 then text = text .. ", patched by " .. table.concat(trail, ", ") end
        return text
    end

    -- Slots of kinds that have them: `slot = "auto"` is given by the allocator (src/content/slots.lua, persisted), no `slot` at all by the
    -- kind's own rule (`def.slotOf(rec, kind)`: a spell's slot is its sphere's times ten plus its index).
    ---@param fn fun(kind: ContentKind<table>, id: ContentId): integer
    function R.setSlotAllocator(fn) S.allocator = fn end
    local function resolveSlot(kind, rec)
        if rec.slot == "auto" then
            if not S.allocator then error(("%s '%s': slot = \"auto\" needs the slot allocator"):format(kind.name, tostring(rec.id)), 3) end
            rec.slot = S.allocator(kind, rec.id)
        elseif rec.slot == nil and kind.def.slotOf then
            local ok, slot = pcall(kind.def.slotOf, rec, kind)
            if not ok then error(("%s '%s': %s"):format(kind.name, tostring(rec.id), tostring(slot)), 3) end
            rec.slot = slot
        end
    end

    -- Kind methods ------------------------------------------------------------------------------------------------
    -- reading
    ---@generic T
    ---@param self ContentKind<T>
    ---@param id ContentId
    ---@return T?
    function Kind:get(id) return self._recs[id] end
    -- The record of `id`; an error naming `who` when there is none.
    ---@generic T
    ---@param self ContentKind<T>
    ---@param id ContentId
    ---@param who string?
    ---@return T
    function Kind:require(id, who)
        local rec = self._recs[id]
        if not rec then
            error(("%s '%s' is not defined%s"):format(self.name, tostring(id), who and (" (needed by " .. who .. ")") or ""), 2)
        end
        return rec
    end
    ---@param id ContentId
    ---@return boolean
    function Kind:has(id) return self._recs[id] ~= nil end
    -- The records in registry order (the kind's own array: do not change it).
    ---@generic T
    ---@param self ContentKind<T>
    ---@return T[]
    function Kind:all() return self._list end
    ---@return integer
    function Kind:count() return #self._list end
    -- The ids in registry order (strings: the item kind, the one keyed by numbers, is read through `all()`).
    ---@return string[]
    function Kind:ids()
        local out = {}
        for i, rec in ipairs(self._list) do out[i] = rec.id end
        return out
    end
    -- Iterator over the records accepted by `pred` (all when nil), in registry order: `for _, rec in kind:each(pred)`.
    ---@generic T
    ---@param self ContentKind<T>
    ---@param pred (fun(rec: T): any)?
    ---@return fun(): integer, T
    function Kind:each(pred)
        local i = 0
        local list = self._list
        return function()
            while true do
                i = i + 1
                local rec = list[i]
                if rec == nil then return nil end
                if not pred or pred(rec) then return i, rec end
            end
        end
    end

    -- Kinds whose records carry a numeric `slot` (races, spheres, spells ...: the number saves and scenarios store) are indexed at
    -- finalise (`def.slotted`); before that, and for lookups while the registry is filled, this scans.
    ---@generic T
    ---@param self ContentKind<T>
    ---@param n integer
    ---@return T?
    function Kind:bySlot(n)
        local idx = self.cache.slot
        if idx then return idx[n] end
        for _, rec in ipairs(self._list) do
            if rec.slot == n then return rec end
        end
    end

    -- A read-only table indexed by slot whose values are the records' field `path` ("units.hero", "name" ...): the engine's replacement
    -- for arrays indexed by slot.
    ---@param path string
    ---@return table<integer, any>
    function Kind:view(path)
        local parts = split(path)
        local kind = self
        return setmetatable({}, { __index = function(_, slot)
            local node = kind:bySlot(slot)
            for i = 1, #parts do
                if type(node) ~= "table" then return nil end
                node = node[parts[i]]
            end
            return node
        end })
    end

    -- The same keyed by id: a read-only table whose values are the records' field `path` (`missile:idView("flags")["EMA0"]`).
    ---@param path string
    ---@return table<ContentId, any>
    function Kind:idView(path)
        local parts = split(path)
        local kind = self
        return setmetatable({}, { __index = function(_, id)
            local node = kind._recs[id]
            for i = 1, #parts do
                if type(node) ~= "table" then return nil end
                node = node[parts[i]]
            end
            return node
        end })
    end

    -- writing
    -- Adds a new record (an error when the id exists: use `replace` or `patch`). Returns it.
    ---@generic T
    ---@param self ContentKind<T>
    ---@param rec T
    ---@return T
    function Kind:add(rec)
        writable(self, "add")
        if type(rec) ~= "table" then error(("%s:add needs a record table"):format(self.name), 2) end
        local id = rec.id
        if not (type(id) == "number" or (type(id) == "string" and id ~= "")) then
            error(("%s:add: the record has no id (a string, or a number for kinds like items that the files number)"):format(self.name), 2)
        end
        if Kind[id] ~= nil then error(("%s:add: id '%s' is reserved"):format(self.name, id), 2) end
        if self._recs[id] then
            error(("%s '%s' already exists (%s); use :replace or :patch"):format(self.name, id, R.where(self, id)), 2)
        end
        if self.def.slotted then resolveSlot(self, rec) end
        self._recs[id] = rec
        self._list[#self._list + 1] = rec
        self._removed[id] = nil
        self._src[id] = origin(3)
        self._patched[id] = nil
        S.hash = nil
        return rec
    end

    -- Puts `rec` in the place of the record with its id (and the aliases of that one). Returns it.
    ---@generic T
    ---@param self ContentKind<T>
    ---@param rec T
    ---@return T
    function Kind:replace(rec)
        writable(self, "replace")
        local id = type(rec) == "table" and rec.id
        local old = id and self._recs[id]
        if not old then error(("%s:replace: '%s' is not defined"):format(self.name, tostring(id)), 2) end
        ---@cast id -false
        for i, r in ipairs(self._list) do
            if r == old then self._list[i] = rec break end
        end
        for key, r in pairs(self._recs) do
            if r == old then self._recs[key] = rec end
        end
        self._src[id] = origin(3)
        self._patched[id] = nil
        S.hash = nil
        return rec
    end

    local function patchOne(self, rec, p, level)
        if type(p) == "function" then
            p(rec)
        elseif type(p) == "table" then
            if p.id ~= nil and p.id ~= rec.id then
                error(("%s '%s': a patch cannot change the id"):format(self.name, rec.id), level)
            end
            local ok, err = pcall(patch.apply, rec, p, ("%s '%s'"):format(self.name, rec.id))
            if not ok then error(tostring(err), level) end
        else
            error(("%s:patch needs a table or a function"):format(self.name), level)
        end
        local trail = self._patched[rec.id] or {}
        if trail[#trail] ~= S.layer then trail[#trail + 1] = S.layer end
        self._patched[rec.id] = trail
    end

    -- patch(id, tableOrFn) or patch(pred, tableOrFn): see patch.lua for the merge rules. Returns the record (by id) or the number
    -- of records patched (by predicate).
    ---@generic T
    ---@param self ContentKind<T>
    ---@param target ContentId|fun(rec: T): any
    ---@param p table|fun(rec: T)
    ---@return T|integer
    function Kind:patch(target, p)
        writable(self, "patch")
        S.hash = nil
        if type(target) == "function" then
            local list = {}
            for i, rec in ipairs(self._list) do list[i] = rec end    -- the patch may not change the list while visiting
            local n = 0
            for _, rec in ipairs(list) do
                if target(rec) then patchOne(self, rec, p, 3) n = n + 1 end
            end
            return n
        end
        local rec = self._recs[target]
        if not rec then
            error(("%s:patch: '%s' is not defined (%s)"):format(self.name, tostring(target), S.layer), 2)
        end
        patchOne(self, rec, p, 3)
        return rec
    end

    -- Removes a record (and its aliases); references to it are cleaned up at finalise. `ifExists` silences the error
    -- for an id that is not there.
    ---@param id ContentId
    ---@param ifExists boolean?
    ---@return boolean
    function Kind:remove(id, ifExists)
        writable(self, "remove")
        local rec = self._recs[id]
        if not rec then
            if ifExists then return false end
            error(("%s:remove: '%s' is not defined"):format(self.name, tostring(id)), 2)
        end
        for key, r in pairs(self._recs) do
            if r == rec then
                self._recs[key] = nil
                self._removed[key] = S.layer
            end
        end
        for i, r in ipairs(self._list) do
            if r == rec then table.remove(self._list, i) break end
        end
        S.hash = nil
        return true
    end

    -- A second id for the same record (a rename that keeps old references working).
    ---@param newId ContentId
    ---@param existing ContentId
    function Kind:alias(newId, existing)
        writable(self, "alias")
        local rec = self._recs[existing]
        if not rec then error(("%s:alias: '%s' is not defined"):format(self.name, tostring(existing)), 2) end
        if self._recs[newId] and self._recs[newId] ~= rec then
            error(("%s:alias: '%s' already names another record"):format(self.name, newId), 2)
        end
        self._recs[newId] = rec
        self._removed[newId] = nil
        S.hash = nil
    end

    -- finalise: removal cascade, validation, derived data -----------------------------------------------------------
    -- Reference specs of a kind: { field = "path", target = "kind", mode = "id"|"list"|"keys", key = "id", hard = bool }.
    -- A path is dotted; "*" visits every value of a table in sorted key order. mode "id": the field is an id;
    -- "list": an array of ids or of records holding the id under `key`; "keys": a map keyed by ids.
    local function visit(node, parts, i, fn)
        for j = i, #parts do
            local p = parts[j]
            if type(node) ~= "table" then return end
            if p == "*" then
                local keys = {}
                for k in pairs(node) do keys[#keys + 1] = k end
                table.sort(keys, hashlib.keyLess)
                for _, k in ipairs(keys) do
                    if j == #parts then fn(node, k) else visit(node[k], parts, j + 1, fn) end
                end
                return
            end
            if j == #parts then fn(node, p) return end
            node = node[p]
        end
    end

    -- The layer a record's problems are blamed on: the last mod that patched it, else the layer that defined it (a mod that
    -- breaks a record of the install must see an error, not the importer's warning).
    local function layerOf(kind, id)
        local trail = kind._patched[id]
        local last = trail and trail[#trail]
        if last and isModLayer(last) then return last end
        return (kind._src[id] and kind._src[id].layer) or "base"
    end

    -- mods and the base ruleset must be consistent (errors); the importers only warn (a missing install file is no error)
    local function sink(layer, strict)
        return (strict or isModLayer(layer) or layer == "base") and S.errors or S.warnings
    end

    local function cascade(kind, spec)
        local target = kinds[spec.target]
        if not target then
            report(S.errors, "base", "kind %s: reference %s points at unknown kind '%s'", kind.name, spec.field,
                tostring(spec.target))
            return
        end
        local parts = split(spec.field)
        local key = spec.key or "id"
        local function dead(id) return target._removed[id] ~= nil and target._recs[id] == nil end
        local function missing(id) return target._recs[id] == nil and target._removed[id] == nil end
        local function idOf(el) return type(el) == "table" and el[key] or el end
        for _, rec in ipairs(kind._list) do
            local layer = layerOf(kind, rec.id)
            local where = R.where(kind, rec.id)
            visit(rec, parts, 1, function(node, field)
                local value = node[field]
                if value == nil then return end
                if spec.mode == "id" then
                    if dead(value) then
                        if spec.hard then
                            report(sink(layer, true), layer, "%s '%s' (%s): %s refers to %s '%s', which was removed by %s",
                                kind.name, rec.id, where, spec.field, spec.target, tostring(value), target._removed[value])
                        else
                            node[field] = nil
                            report(S.warnings, layer, "%s '%s': %s cleared, %s '%s' was removed by %s", kind.name, rec.id,
                                spec.field, spec.target, tostring(value), target._removed[value])
                        end
                    elseif missing(value) then
                        report(sink(layer), layer, "%s '%s' (%s): %s refers to unknown %s '%s'", kind.name, rec.id, where,
                            spec.field, spec.target, tostring(value))
                    end
                elseif spec.mode == "list" and type(value) == "table" then
                    local keep = {}
                    for _, el in ipairs(value) do
                        local id = idOf(el)
                        if dead(id) then
                            report(S.warnings, layer, "%s '%s': %s loses '%s', removed by %s", kind.name, rec.id,
                                spec.field, tostring(id), target._removed[id])
                        else
                            if missing(id) then
                                report(sink(layer), layer, "%s '%s' (%s): %s refers to unknown %s '%s'", kind.name, rec.id,
                                    where, spec.field, spec.target, tostring(id))
                            end
                            keep[#keep + 1] = el
                        end
                    end
                    if #keep ~= #value then
                        for i = #value, 1, -1 do value[i] = nil end
                        for i, el in ipairs(keep) do value[i] = el end
                    end
                elseif spec.mode == "keys" and type(value) == "table" then
                    local ks = {}
                    for k in pairs(value) do ks[#ks + 1] = k end
                    table.sort(ks, hashlib.keyLess)
                    for _, id in ipairs(ks) do
                        if dead(id) then
                            value[id] = nil
                            report(S.warnings, layer, "%s '%s': %s loses '%s', removed by %s", kind.name, rec.id, spec.field,
                                tostring(id), target._removed[id])
                        elseif missing(id) then
                            report(sink(layer), layer, "%s '%s' (%s): %s refers to unknown %s '%s'", kind.name, rec.id, where,
                                spec.field, spec.target, tostring(id))
                        end
                    end
                end
            end)
        end
    end

    local function stableSort(list, field)
        local idx = {}
        for i, rec in ipairs(list) do idx[rec] = i end
        table.sort(list, function(a, b)
            local x, y = a[field], b[field]
            if x == y then return idx[a] < idx[b] end
            if x == nil then return false elseif y == nil then return true end
            return x < y
        end)
    end

    -- Resolves, derives, validates and freezes. Returns the report. Errors do not stop it: all are collected.
    ---@return ContentReport
    function R.finalise()
        if not PHASES[S.phase] then error(("finalise: the registry is %s"):format(S.phase), 2) end
        S.phase = "finalising"
        for _, kind in ipairs(kindList) do
            if kind.def.sortBy then stableSort(kind._list, kind.def.sortBy) end
        end
        for _, kind in ipairs(kindList) do
            for _, spec in ipairs(kind.def.refs or {}) do cascade(kind, spec) end
            if kind.def.slotted then
                local slots = {}
                for _, rec in ipairs(kind._list) do
                    if slots[rec.slot] then
                        report(S.errors, layerOf(kind, rec.id), "%s '%s' (%s) uses slot %s of '%s'", kind.name, rec.id,
                            R.where(kind, rec.id), tostring(rec.slot), slots[rec.slot].id)
                    elseif rec.slot ~= nil then
                        slots[rec.slot] = rec
                    end
                end
                kind.cache.slot = slots
            end
        end
        for _, kind in ipairs(kindList) do
            local validate = kind.def.validate
            if validate then
                for _, rec in ipairs(kind._list) do
                    local layer = layerOf(kind, rec.id)
                    local ok, msg = pcall(validate, rec, kind)
                    if not ok then msg = "validator failed: " .. tostring(msg) end
                    if msg then
                        report(sink(layer), layer, "%s '%s' (%s): %s", kind.name, rec.id, R.where(kind, rec.id), tostring(msg))
                    end
                end
            end
        end
        for _, kind in ipairs(kindList) do
            local derive = kind.def.derive
            if derive then
                for _, rec in ipairs(kind._list) do
                    local ok, err = pcall(derive, rec, kind)
                    if not ok then
                        report(S.errors, layerOf(kind, rec.id), "%s '%s': derive failed: %s", kind.name, rec.id, tostring(err))
                    end
                end
            end
            if kind.def.finalise then
                local ok, err = pcall(kind.def.finalise, kind, R)
                if not ok then report(S.errors, "base", "kind %s: finalise failed: %s", kind.name, tostring(err)) end
            end
        end
        table.sort(S.hooks, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.n < b.n end)
        for _, h in ipairs(S.hooks) do
            local ok, err = pcall(h.fn, R)
            if not ok then report(S.errors, "base", "finalise hook failed: %s", tostring(err)) end
        end
        S.phase = "frozen"
        S.hash, S.frozenHash = nil, nil
        for _, fn in ipairs(readyFns) do
            local ok, err = pcall(fn)
            if not ok then report(S.errors, "base", "onReady callback failed: %s", tostring(err)) end
        end
        return R.report()
    end

    ---@return boolean
    function R.frozen() return S.phase == "frozen" end

    -- Hash of the registry (computed on first use, then cached). `R.verify()` recomputes it and tells whether the
    -- records of a frozen registry were mutated behind the API's back since (dev check).
    ---@return string
    function R.hash()
        if not S.hash then
            S.hash = hashlib.registry(kindList, S.sources, S.meta)
            if S.phase == "frozen" then S.frozenHash = S.hash end
        end
        return S.hash
    end
    -- Text mixed into the registry hash besides the records: the engine version and the mod set (manifests and file hashes).
    ---@param text string?
    function R.setMeta(text)
        S.meta = text
        S.hash, S.frozenHash = nil, nil
    end
    ---@return boolean
    function R.verify()
        if not S.frozenHash then R.hash() return true end
        return hashlib.registry(kindList, S.sources, S.meta) == S.frozenHash
    end

    -- rollback of failed mods --------------------------------------------------------------------------------------
    -- A snapshot is a deep copy of every kind's state (shared sub-tables stay shared); `restore` puts it back. Records
    -- are replaced by their copies, so nothing may hold record references across a rollback (true while loading).
    ---@return ContentSnapshot
    function R.snapshot()
        local memo = {}
        local snap = { kinds = {}, phase = S.phase }
        for _, k in ipairs(kindList) do
            snap.kinds[k.name] = { recs = patch.copy(k._recs, memo), list = patch.copy(k._list, memo),
                                   removed = patch.copy(k._removed, memo), src = patch.copy(k._src, memo),
                                   patched = patch.copy(k._patched, memo) }
        end
        return snap
    end
    ---@param snap ContentSnapshot
    function R.restore(snap)
        for _, k in ipairs(kindList) do
            local s = snap.kinds[k.name]
            k._recs, k._list, k._removed, k._src, k._patched = s.recs, s.list, s.removed, s.src, s.patched
            k.cache = {}
        end
        S.phase = snap.phase
        S.hash = nil
    end

    -- Ordered iteration over a table with mixed keys: the replacement for `pairs` where order matters (determinism).
    ---@generic K, V
    ---@param t table<K, V>
    ---@return fun(): K, V
    function R.pairs(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, hashlib.keyLess)
        local i = 0
        return function()
            i = i + 1
            local k = keys[i]
            if k ~= nil then return k, t[k] end
        end
    end

    -- The records of a kind as Lua source (src/content/dump.lua).
    ---@param kind string|ContentKind<table>
    ---@return string
    function R.dump(kind) return dump.kind(type(kind) == "string" and R.kind(kind) or kind) end
    -- The canonical text of a record that the hash is computed over.
    ---@param rec table
    ---@param kind ContentKind<table>?
    ---@return string
    function R.canonical(rec, kind)
        return hashlib.canonical(rec, kind and kind.derivedSet, S.sources)
    end

    return R
end

return M
