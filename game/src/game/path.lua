-- A* path finding on the cell grid (8 directions, octile distance).
local ffi = require("ffi")

local M = {}

-- Direction index (0 = north, clockwise) -> delta.
M.DX = { [0] = 0, 1, 1, 1, 0, -1, -1, -1 }
M.DY = { [0] = -1, -1, 0, 1, 1, 1, 0, -1 }

-- A reusable search state for one grid size (one per world).
---@class Finder
---@field w integer grid width in cells
---@field h integer grid height in cells
---@field g ffi.cdata* float[w*h]: cost from the start
---@field parent ffi.cdata* int32_t[w*h]: previous node (-1 at the start)
---@field stamp ffi.cdata* uint32_t[w*h]: generation in which g / parent were set
---@field closed ffi.cdata* uint32_t[w*h]: generation in which the node was expanded
---@field gen integer current search generation
---@field heap integer[] open list nodes (binary heap)
---@field heapF number[] f values parallel to heap
local Finder = {}
Finder.__index = Finder

---@param w integer
---@param h integer
---@return Finder
function M.new(w, h)
    local n = w * h
    return setmetatable({
        w = w, h = h,
        g = ffi.new("float[?]", n),
        parent = ffi.new("int32_t[?]", n),
        stamp = ffi.new("uint32_t[?]", n),     -- generation marks avoid clearing arrays
        closed = ffi.new("uint32_t[?]", n),
        gen = 0,
        heap = {}, heapF = {},
    }, Finder)
end

-- binary heap of (f, node)
local function push(self, node, f)
    local heap, hf = self.heap, self.heapF
    local i = #heap + 1
    heap[i], hf[i] = node, f
    while i > 1 do
        local p = math.floor(i / 2)
        if hf[p] <= f then break end
        heap[i], hf[i] = heap[p], hf[p]
        i = p
    end
    heap[i], hf[i] = node, f
end

local function pop(self)
    local heap, hf = self.heap, self.heapF
    local n = #heap
    if n == 0 then return nil end
    local top = heap[1]
    local lastN, lastF = heap[n], hf[n]
    heap[n], hf[n] = nil, nil
    n = n - 1
    if n > 0 then
        local i = 1
        while true do
            local l = i * 2
            if l > n then break end
            local r = l + 1
            local c = (r <= n and hf[r] < hf[l]) and r or l
            if hf[c] >= lastF then break end
            heap[i], hf[i] = heap[c], hf[c]
            i = c
        end
        heap[i], hf[i] = lastN, lastF
    end
    return top
end

local SQRT2 = math.sqrt(2)

local function heuristic(x, y, tx, ty)
    local dx, dy = math.abs(x - tx), math.abs(y - ty)
    return (dx > dy) and (dx + (SQRT2 - 1) * dy) or (dy + (SQRT2 - 1) * dx)
end

-- passable(x, y) -> bool, cost(x, y) -> extra cost (optional).
-- Returns a list of {x, y} cells from the step after start to goal, or the
-- path to the closest reachable cell when the goal can't be reached.
---@param sx integer
---@param sy integer
---@param tx integer
---@param ty integer
---@param passable fun(x: integer, y: integer): boolean
---@param maxNodes? integer expansions before giving up (default 20000)
---@param cost? fun(x: integer, y: integer): number extra cost of entering a cell
---@return integer[][] path { {x, y}, ... }
---@return boolean reached true when the path ends at the goal
function Finder:find(sx, sy, tx, ty, passable, maxNodes, cost)
    maxNodes = maxNodes or 20000
    self.gen = self.gen + 1
    local gen = self.gen
    local w = self.w
    local g, parent, stamp, closed = self.g, self.parent, self.stamp, self.closed
    self.heap, self.heapF = {}, {}
    local start = sy * w + sx
    g[start], parent[start], stamp[start] = 0, -1, gen
    push(self, start, heuristic(sx, sy, tx, ty))
    local best, bestH = start, heuristic(sx, sy, tx, ty)
    local goal = ty * w + tx
    local expanded = 0
    while true do
        local node = pop(self)
        if not node then break end
        if closed[node] ~= gen then
            closed[node] = gen
            if node == goal then best = node break end
            local x, y = node % w, math.floor(node / w)
            local h = heuristic(x, y, tx, ty)
            if h < bestH then best, bestH = node, h end
            expanded = expanded + 1
            if expanded > maxNodes then break end
            for d = 0, 7 do
                local nx, ny = x + M.DX[d], y + M.DY[d]
                if nx >= 0 and ny >= 0 and nx < w and ny < self.h and passable(nx, ny) then
                    -- no corner cutting
                    if d % 2 == 0 or (passable(x + M.DX[d], y) and passable(x, y + M.DY[d])) then
                        local n = ny * w + nx
                        if closed[n] ~= gen then
                            local ng = g[node] + ((d % 2 == 1) and SQRT2 or 1) + (cost and cost(nx, ny) or 0)
                            if stamp[n] ~= gen or ng < g[n] then
                                stamp[n], g[n], parent[n] = gen, ng, node
                                push(self, n, ng + heuristic(nx, ny, tx, ty))
                            end
                        end
                    end
                end
            end
        end
    end
    local path = {}
    local node = best
    while node ~= start and node >= 0 do
        table.insert(path, 1, { node % w, math.floor(node / w) })
        node = parent[node]
    end
    return path, best == goal
end

return M
