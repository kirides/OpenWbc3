-- Tiny logger: prints to stdout and keeps the last lines for an on-screen console.
---@class Log
---@field lines string[]   the last `max` lines, for an on-screen console
---@field max integer
---@field verbose boolean? debug lines are printed only when set (--verbose)
local M = { lines = {}, max = 200 }

local function push(level, fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
    local line = ("[%s] %s"):format(level, msg)
    print(line)
    local lines = M.lines
    lines[#lines + 1] = line
    if #lines > M.max then table.remove(lines, 1) end
end

-- `fmt` is a format string when arguments follow, else any value printed with tostring.
---@param fmt any
---@param ... any
function M.info(fmt, ...) push("info", fmt, ...) end
---@param fmt any
---@param ... any
function M.warn(fmt, ...) push("warn", fmt, ...) end
---@param fmt any
---@param ... any
function M.error(fmt, ...) push("error", fmt, ...) end
---@param fmt any
---@param ... any
function M.debug(fmt, ...) if M.verbose then push("debug", fmt, ...) end end

return M
