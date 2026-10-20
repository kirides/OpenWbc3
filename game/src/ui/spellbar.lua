-- Spell bar above the control panel: the hero's learned spells (openwbc3's own, the original has none), the
-- mouse wheel pages through more of them. A spell shows the key (F1..F8) it was given in the spell book.
-- Off unless the player switches it on (Options, Game: "Spell bar", `[options] spellbar` in openwbc3.ini), as the
-- original has no such bar; with it off nothing is drawn and the strip above the panel is the map.
local spells = require("src.game.spells")
local fonts = require("src.ui.fonts")
local gameopts = require("src.core.gameopts")

local M = { PER_PAGE = 8, SLOT_W = 94, SLOT_H = 26, GAP = 3 }

---@return boolean
function M.enabled() return gameopts.get("spellbar") == true end

local function getFont()
    return fonts.plain(11)
end

local SPHERE_COL = require("src.content").sphere:view("colour")      -- the `colour` of the sphere records (content/base/spheres.lua)
M.SPHERE_COL = SPHERE_COL

---@param hud HUD
---@param list integer[]
---@return integer page
---@return integer pages
function M.page(hud, list)
    local pages = math.max(1, math.ceil(#list / M.PER_PAGE))
    hud.spellPage = math.max(0, math.min(pages - 1, hud.spellPage or 0))
    return hud.spellPage, pages
end

-- Spell ids on the current page.
---@param hud HUD
---@return table<integer, integer> ids  slot (1..PER_PAGE) -> spell id
---@return integer pages
function M.current(hud)
    local hero = hud:hero()
    if not hero or not hero.h then return {}, 0 end
    local list = spells.list(hero.h)
    local page, pages = M.page(hud, list)
    local out = {}
    for i = 1, M.PER_PAGE do out[i] = list[page * M.PER_PAGE + i] end
    return out, pages
end

---@param hud HUD
---@return number x
---@return number y
function M.origin(hud)
    return 8, (hud.mapBottom or love.graphics.getHeight()) - M.SLOT_H - 6
end

-- Slot index (1..PER_PAGE) at window position and its spell id, or nil.
---@param hud HUD
---@return integer? slot
---@return integer? id
function M.at(hud, x, y)
    if not M.enabled() then return nil end
    local ids = M.current(hud)
    if #ids == 0 and not next(ids) then return nil end
    local ox, oy = M.origin(hud)
    if y < oy or y >= oy + M.SLOT_H then return nil end
    local i = math.floor((x - ox) / (M.SLOT_W + M.GAP)) + 1
    if i < 1 or i > M.PER_PAGE or (x - ox) % (M.SLOT_W + M.GAP) >= M.SLOT_W then return nil end
    if ids[i] then return i, ids[i] end
end

---@param hud HUD
function M.draw(hud)
    if not M.enabled() then return end
    local hero = hud:hero()
    if not hero or not hero.h then return end
    local ids, pages = M.current(hud)
    if not next(ids) then return end
    local g = love.graphics
    local ox, oy = M.origin(hud)
    local old = g.getFont()
    g.setFont(getFont())
    local mx, my = love.mouse.getPosition()
    for i = 1, M.PER_PAGE do
        local id = ids[i]
        if id then
            local x = ox + (i - 1) * (M.SLOT_W + M.GAP)
            local ok = spells.canCast(hero, id)
            local col = SPHERE_COL[spells.sphere(id)]
            local hover = mx >= x and mx < x + M.SLOT_W and my >= oy and my < oy + M.SLOT_H
            local active = hud.mode == "spell" and hud.spellId == id
            g.setColor(0, 0, 0, 0.7)
            g.rectangle("fill", x, oy, M.SLOT_W, M.SLOT_H)
            g.setColor(col[1], col[2], col[3], ok and 1 or 0.4)
            g.rectangle("line", x + 0.5, oy + 0.5, M.SLOT_W - 1, M.SLOT_H - 1)
            if hover or active then
                g.setColor(col[1], col[2], col[3], 0.25)
                g.rectangle("fill", x + 1, oy + 1, M.SLOT_W - 2, M.SLOT_H - 2)
            end
            g.setColor(1, 1, 1, ok and 1 or 0.45)
            local key = hero.h:shortcutOf(id)
            if key then g.print(("F%d"):format(key), x + 4, oy + 2) end
            g.printf(spells.name(id), x + 4, oy + 13, M.SLOT_W - 8, "left")
            g.setColor(0.6, 0.8, 1, ok and 1 or 0.45)
            g.printf(tostring(spells.cost(hero, id)), x, oy + 2, M.SLOT_W - 4, "right")
        end
    end
    if pages > 1 then
        g.setColor(1, 1, 1, 0.8)
        g.print(("%d/%d"):format((hud.spellPage or 0) + 1, pages), ox + 8 * (M.SLOT_W + M.GAP) + 2, oy + 6)
    end
    g.setFont(old)
    g.setColor(1, 1, 1)
end

---@param hud HUD
---@param id integer
---@return string[]
function M.tooltipLines(hud, id)
    local hero = hud:hero()
    ---@cast hero -nil           a spell on the bar is the hero's
    local sphere = spells.SPHERE_NAMES[spells.sphere(id)]
    return {
        spells.name(id),
        ("%s, level %d"):format(sphere, spells.level(id) + 1),
        spells.desc(id),
        ("%d mana, %d%% chance"):format(spells.cost(hero, id), spells.chance(hero, id)),
    }
end

return M
