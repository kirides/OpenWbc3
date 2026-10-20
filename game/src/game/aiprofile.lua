-- The computer player's level tables (`aiprofile` records, content/base/aiprofiles.lua): a field of a level, or the default of the caller.
local content = require("src.content")

local M = {}

-- The record of a level, or nil.
---@param level integer
---@return table?
function M.of(level) return content.aiprofile:bySlot(level) end

-- Field `field` of the level's profile, `default` when the level has none.
---@generic T
---@param level integer
---@param field string
---@param default T
---@return T
function M.get(level, field, default)
    local rec = content.aiprofile:bySlot(level)
    local v = rec and rec[field]
    if v == nil then return default end
    return v
end

-- A share of `rates` (army, powerup ...) of the level.
---@param level integer
---@param key string
---@param default number
---@return number
function M.rate(level, key, default)
    local rec = content.aiprofile:bySlot(level)
    local v = rec and rec.rates and rec.rates[key]
    if v == nil then return default end
    return v
end

return M
