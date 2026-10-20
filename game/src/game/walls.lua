-- Drag-built walls: the section list a player draws with the mouse while a wall piece is chosen for placement.
-- Pure data and rules, no world access, so it can be tested headless; the battle screen feeds it the cell under the
-- cursor and a legality callback, and sends the finished list as one build command (commands.lua, `sections`).
--
-- The rules are those of the original's wall drag (add a section FUN_00429820, re-pick the pieces FUN_004299b0 in the
-- 1.04 binary; the shortcut keys see docs/implemented.md):
--   * the first press starts the list with the chosen piece; every further cell the mouse passes is added (there is no
--     line fill between two mouse events);
--   * a new cell must be inside the map, is snapped to the 2-cell grid of the first section (the parity of the
--     first x / y is kept), must be a legal placement for the chosen piece, must not be in the list already and the
--     list holds at most 64 sections;
--   * after each addition every section is re-picked from its neighbours two cells away: only above and below ->
--     the vertical piece (..2, 1x2), only left and right -> the horizontal piece (..1, 2x1), anything else (also a
--     lone end with one neighbour) -> the square piece (..0, 2x2). The rampart keeps its code.
local M = {}

M.MAX = 64

---@class WallSection
---@field code string
---@field gx integer
---@field gy integer

-- A wall drag in progress (M.start).
---@class WallDrag
---@field code string            the chosen piece
---@field firstX integer         the first cell (its parity is kept)
---@field firstY integer
---@field w integer              map size in cells
---@field h integer
---@field sections WallSection[]

-- The wall families of the three alignments (good / neutral / evil) and the rampart: the original's wall codes.
local FAMILY = { BWG = true, BWN = true, BWE = true }

---@param code string
---@return boolean
function M.isWall(code)
    if code == "BWRA" then return true end
    local f, n = code:sub(1, 3), code:sub(4, 4)
    return FAMILY[f] == true and (n == "0" or n == "1" or n == "2") and #code == 4
end

-- Who may build walls: not heroes, not Treants / Ancient Treants (the special-ability buttons, FUN_004d3200).
---@param unit Unit
---@return boolean
function M.canBuild(unit)
    return not unit.hero and not require("src.game.gamedata").hasTag(unit.code, "treant")
end

-- Starts a drag with the chosen piece at the cell the button went down on; `w`, `h` is the map size in cells.
---@param code string
---@param gx integer
---@param gy integer
---@param w integer
---@param h integer
---@return WallDrag
function M.start(code, gx, gy, w, h)
    return { code = code, firstX = gx, firstY = gy, w = w, h = h, sections = { { code = code, gx = gx, gy = gy } } }
end

local function has(list, gx, gy)
    for _, s in ipairs(list) do
        if s.gx == gx and s.gy == gy then return true end
    end
    return false
end

-- Re-picks the piece of every section from the neighbours two cells away (FUN_004299b0).
---@param sections WallSection[]
function M.refine(sections)
    if #sections <= 1 then return end
    for _, s in ipairs(sections) do
        if s.code ~= "BWRA" then
            local top, bottom = has(sections, s.gx, s.gy - 2), has(sections, s.gx, s.gy + 2)
            local left, right = has(sections, s.gx - 2, s.gy), has(sections, s.gx + 2, s.gy)
            local n = 0
            if top and bottom and not left and not right then n = 2
            elseif left and right and not top and not bottom then n = 1 end
            s.code = s.code:sub(1, 3) .. n
        end
    end
end

-- Adds the cell (gx, gy) under the cursor. `legal(code, gx, gy)` says whether the chosen piece may be placed there.
-- Returns whether a section was added.
---@param drag WallDrag
---@param gx integer
---@param gy integer
---@param legal fun(code: string, gx: integer, gy: integer): boolean
---@return boolean
function M.add(drag, gx, gy, legal)
    if gx < 0 or gy < 0 or gx >= drag.w or gy >= drag.h then return false end
    local odd = { drag.firstX % 2 == 1, drag.firstY % 2 == 1 }
    if odd[1] and gx < 1 then return false end
    if odd[2] and gy < 1 then return false end
    if odd[1] then gx = math.floor((gx + 1) / 2) * 2 - 1 else gx = math.floor(gx / 2) * 2 end
    if odd[2] then gy = math.floor((gy + 1) / 2) * 2 - 1 else gy = math.floor(gy / 2) * 2 end
    if #drag.sections >= M.MAX then return false end
    if not legal(drag.code, gx, gy) then return false end
    if has(drag.sections, gx, gy) then return false end
    drag.sections[#drag.sections + 1] = { code = drag.code, gx = gx, gy = gy }
    M.refine(drag.sections)
    return true
end

-- The finished list as plain data for the command: { { code, gx, gy } ... }.
---@param drag WallDrag
---@return WallSection[]
function M.list(drag)
    local out = {}
    for i, s in ipairs(drag.sections) do out[i] = { code = s.code, gx = s.gx, gy = s.gy } end
    return out
end

return M
