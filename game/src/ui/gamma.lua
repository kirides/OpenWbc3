-- Screen gamma (the "gamma" option, registry GammaCorrection 0..4): drawn over the finished frame as the original
-- sets its gamma ramp.
--
-- Verified in the 1.04 binary (the gamma ramp setter FUN_00468cf0) and the options code: the option value g
-- gives the level 0xffff - g * 0x1fff and each colour channel is scaled linearly by level / 0xffff (the identity at g = 0,
-- 87.5 / 75 / 62.5 % at g = 1..3); the one special case is the level of g = 4 (0x8003) when set at once, which
-- becomes a ramp of 0x3fff + 3/4 of the identity, i.e. 25 % grey lifted into the blacks. (The option screen's labels
-- are "One" .. "Five".)
--
-- A multiply and an add of a flat colour reproduce both ramps. Must not touch love.graphics at require time.
local gameopts = require("src.core.gameopts")

local M = {}

-- Multiplier and offset (0..1) of the ramp of option value g.
---@param g integer
---@return number mul
---@return number add
function M.ramp(g)
    if g <= 0 then return 1, 0 end
    if g >= 4 then return 0.75, 0x3fff / 0xffff end
    return (0xffff - g * 0x1fff) / 0xffff, 0
end

function M.apply()
    local mul, add = M.ramp(gameopts.level("gamma"))
    if mul == 1 and add == 0 then return end
    local g = love.graphics
    local w, h = g.getDimensions()
    g.push("all")
    g.origin()
    g.setScissor()
    g.setColor(mul, mul, mul, 1)
    g.setBlendMode("multiply", "premultiplied")
    g.rectangle("fill", 0, 0, w, h)
    if add > 0 then
        g.setColor(add, add, add, 0)
        g.setBlendMode("add", "premultiplied")
        g.rectangle("fill", 0, 0, w, h)
    end
    g.pop()
end

return M
