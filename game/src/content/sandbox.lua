-- The environment mod code runs in (docs/data-driven/06-mod-runtime.md 6.3). Mod chunks get `setfenv`'d to a table that holds only:
-- the safe parts of the standard library (copies, so a mod cannot change the engine's `string` or `table`), the content API (`content`,
-- the effect library `fx`), the mod's own manifest (`mod`), `include` for the mod's other files and `print` to the log. There is no
-- `io`, `os`, `package`, `require`, `debug`, `ffi`, `love`, `loadstring`, `_G`, `getmetatable`, `rawset`. `math.random` is there but refuses to
-- run while content loads (the content of two machines must not depend on a dice).
-- This prevents accidents and non-determinism; it is not a security boundary against hostile code (decision D3 of the plan): the mod
-- manager says which mods run code. Functions a mod stores in records are closures of its chunks and keep this environment, so a spell
-- effect cannot reach `io` later either.
local log = require("src.core.log")

local M = {}

M.BUDGET_SECONDS = 3          -- a chunk that runs longer while loading is stopped
M.HOOK_COUNT = 20000          -- the budget is checked every that many VM instructions

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- Names of the registry API a mod may use (the kinds are added by name).
local API = { "REMOVE", "value", "append", "prepend", "insertBefore", "insertAfter", "removeWhere", "clone", "pairs", "thing",
              "isModLayer" }

-- What `env` needs to know about one mod.
---@class SandboxContext
---@field content Content
---@field manifest ModIdentity          the parts of the manifest a mod sees as `mod`
---@field include fun(rel: string): ...
---@field loading fun(): boolean        whether a chunk of the mod is running right now (content loads)
---@field asset ModAssetBuilders?
---@field fx (fun(): FxLibrary)?        the effect library, required on first use

-- Builds the environment of one mod. `ctx`: { content, manifest, include(rel), loading = function() -> bool }. The globals it holds
-- are declared for editors in docs/modding/luals/openwbc3-mod.lua.
---@param ctx SandboxContext
---@return table
function M.env(ctx)
    local content = ctx.content
    local api = {}
    for _, name in ipairs(API) do api[name] = content[name] end
    for _, kind in ipairs(content.kinds()) do api[kind.name] = kind end
    api.setting = content.setting
    local math2 = copy(math)
    local realRandom = math.random
    math2.random = function(...)
        if ctx.loading() then error("math.random is not available while content loads: every machine must build the same content", 2) end
        return realRandom(...)
    end
    math2.randomseed = nil
    local mod = copy(ctx.manifest)
    local env = {
        content = api, mod = mod,
        math = math2, string = copy(string), table = copy(table), bit = copy(require("bit")),
        pairs = pairs, ipairs = ipairs, next = next, type = type, tostring = tostring, tonumber = tonumber, select = select,
        pcall = pcall, error = error, assert = assert, unpack = unpack, setmetatable = setmetatable,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            log.info("[mod %s] %s", ctx.manifest.id, table.concat(parts, " "))
        end,
        include = ctx.include,
        asset = ctx.asset,
    }
    env.string.dump = nil
    env.fx = ctx.fx and ctx.fx() or nil
    return env
end

-- Runs `fn()` with an instruction budget (a runaway loop in a mod chunk raises an error instead of hanging the start-up).
---@param fn function
---@param ... any
---@return any, any, any
function M.run(fn, ...)
    local deadline = os.clock() + M.BUDGET_SECONDS
    local jit = require("jit")
    jit.off()                      -- the compiled loops of LuaJIT ignore count hooks
    debug.sethook(function()
        if os.clock() > deadline then error("the mod chunk ran longer than " .. M.BUDGET_SECONDS .. " s while loading", 2) end
    end, "", M.HOOK_COUNT)
    local ok, a, b, c = xpcall(fn, function(e) return type(e) == "string" and e or debug.traceback(tostring(e), 2) end, ...)
    debug.sethook()
    jit.on()
    if not ok then error(a, 0) end
    return a, b, c
end

return M
