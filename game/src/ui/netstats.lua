-- The network statistics dialog of the battle (Ctrl+N; the dialog constructor is `FUN_00566760`). Layout as in the
-- original: 400 pixels wide, players * 25 + 45 high, centred; a black translucent panel with a dark red frame, the
-- headings "Reliability" (Game.txt 0405) at x + 200 and "Ping" (0406) at x + 280 (FO_MEDIUM, centred), then one row per
-- player every 25 pixels from y + 35: the name right-aligned at x + 120 (FO_SMALL), the side's shield (ESHD) at
-- x + 126, the reliability as "%3.2f %%" centred at x + 200, the ping as "%ld ms" centred at x + 280 and a colour bar
-- of 5..65 pixels at x + 320 that is green when both are good and red when they are bad (the scale for other values is
-- openwbc3's own: the 1.04 draw routine FUN_00566860 only ever draws its one value, 1000 ms / 100 % as a 40 pixel bar
-- in colour 255,200,0). The dialog closes with Esc or a click.
-- What the original shows is a stub: the numbers are the constants 100.00 % and 1000 ms (FUN_00566860 formats the
-- constant 1000 and the double 100.0 for every player). openwbc3 shows real figures instead
-- (its own choice): the smoothed round trip time of the udp peer and the share of the reliable packets that did not
-- have to be sent again, i.e. every player's link to the host (the host is the hub of the lockstep). The host measures
-- every client and sends the table to the clients once a second (`Session:sendStats`, outside the simulation), so
-- every machine shows every player; a player that has dropped out shows "-".
local M = {}

---@class NetStatsRow
---@field side integer
---@field name string
---@field ping number?         ms; nil: the player dropped out
---@field reliability number?  %

M.WIDTH = 400

-- Length of the colour bar (5..65): 65 minus a penalty for loss and one for the ping.
---@param reliability number
---@param ping number
---@return integer
function M.barValue(reliability, ping)
    local v = 65
    local r = math.floor(reliability)
    if r <= 90 then v = v - 30 elseif r <= 92 then v = v - 25 elseif r <= 94 then v = v - 20
    elseif r <= 96 then v = v - 15 elseif r <= 98 then v = v - 10 elseif r <= 99 then v = v - 5 end
    if ping >= 1200 then v = v - 30 elseif ping >= 1000 then v = v - 25 elseif ping >= 800 then v = v - 20
    elseif ping >= 600 then v = v - 15 elseif ping >= 400 then v = v - 10 elseif ping >= 200 then v = v - 5 end
    return v
end

-- Bar colour (0..255 each) for a bar value, from green (65) through yellow (45) and red (20) to dark red (5).
local COLOURS = { { 65, 0, 255, 0 }, { 60, 100, 255, 0 }, { 55, 150, 255, 0 }, { 50, 200, 255, 0 }, { 45, 255, 255, 0 },
                  { 40, 255, 200, 0 }, { 35, 255, 150, 0 }, { 30, 255, 100, 0 }, { 25, 255, 50, 0 }, { 20, 255, 0, 0 },
                  { 15, 200, 0, 0 }, { 10, 150, 0, 0 }, { 5, 100, 0, 0 } }
---@param value number
---@return integer r
---@return integer g
---@return integer b
function M.barColour(value)
    for _, c in ipairs(COLOURS) do
        if value >= c[1] then return c[2], c[3], c[4] end
    end
    return 0, 255, 0           -- below 5 the original keeps its initial green
end

-- One entry per player: { side, name, ping (ms) or nil, reliability (%) or nil } (`net:statsOf`). A single player game
-- (net == nil) has the one local row.
---@param net Session?
---@param world World
---@return NetStatsRow[]
---@overload fun(net: Session, world: World?): NetStatsRow[] the world is only read without a session
function M.rows(net, world)
    local rows = {}
    if not net then
        return { { side = world.player, name = world:sideName(world.player), ping = 0, reliability = 100 } }
    end
    for _, side in ipairs(net.sides) do
        local r = { side = side, name = net.names[side] or ("Player " .. (side + 1)) }
        if not net.dropped[side] then r.ping, r.reliability = net:statsOf(side) end
        rows[#rows + 1] = r
    end
    return rows
end

-- Draws the dialog in the 800 x 600 interface space (the caller scales). `rows` as from M.rows (a single player game
-- has the one local row).
---@param rows NetStatsRow[]
---@param W number
---@param H number
---@param sideColour fun(side: integer): integer  the side's colour index (shield frame)
function M.draw(rows, W, H, sideColour)
    local g = love.graphics
    local fonts = require("src.ui.fonts")
    local strings = require("src.game.strings")
    local h = #rows * 25 + 45
    local x, y = math.floor((W - M.WIDTH) / 2), math.floor((H - h) / 2)
    g.setColor(0, 0, 0, 0.7)
    g.rectangle("fill", x, y, M.WIDTH, h)
    g.setColor(0, 0, 0)
    g.rectangle("line", x + 0.5, y + 0.5, M.WIDTH - 1, h - 1)
    g.setColor(128 / 255, 0, 0)
    g.rectangle("line", x + 1.5, y + 1.5, M.WIDTH - 3, h - 3)
    g.setColor(1, 1, 1)
    fonts.print(5, strings.get("Game.txt", "0405") or "Reliability", x + 200 - 80, y + 5, "center", 160)
    fonts.print(5, strings.get("Game.txt", "0406") or "Ping", x + 280 - 40, y + 5, "center", 80)
    local shields = require("src.gfx.anims").get("ESHD")
    local ry = y + 35
    for _, r in ipairs(rows) do
        fonts.print(2, r.name, x, ry + 2, "right", 120)
        if shields then shields:drawCell(0, 0, sideColour(r.side), x + 126, ry - 2) end
        if r.ping then
            fonts.print(5, ("%3.2f %%"):format(r.reliability), x + 200 - 50, ry, "center", 100)
            fonts.print(5, ("%d ms"):format(r.ping), x + 280 - 40, ry, "center", 80)
            local v = M.barValue(r.reliability, r.ping)
            local cr, cg, cb = M.barColour(v)
            g.setColor(cr / 255, cg / 255, cb / 255)
            g.rectangle("fill", x + 320, ry + 3, v, 14)
            g.setColor(1, 1, 1)
        else
            fonts.print(5, "-", x + 200 - 50, ry, "center", 100)
            fonts.print(5, "-", x + 280 - 40, ry, "center", 80)
        end
        ry = ry + 25
    end
end

return M
