-- Combat results after a battle (the original's opener FUN_00449ce0): PNL_RESULTS_MAIN with the tabs Hero, Resource,
-- Units and Buildings; every tab is a panel (PNL_RESULTS_HERO ...) whose progress bars (PB_ONE..PB_SIX, one per
-- player, bitmap in the player's colour) show a value as a percentage of the best player's value and print the
-- value on top. The local player is the first row, the other players follow in side order. Bars fill up in steps
-- after a tab is opened, like the original's timer.
--
-- enter(battle): the finished battle screen. dev(): a sample result for --show results.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local xci = require("src.ui.xci")
local gamedata = require("src.game.gamedata")
local classes = require("src.game.classes")

-- One player's row of the statistics (collect / sample).
---@class ResultRow
---@field side integer
---@field name string
---@field color integer
---@field level integer
---@field xp number
---@field dead boolean               the hero fell
---@field levelled boolean?          the hero gained a level
---@field kills integer
---@field spells integer
---@field games integer
---@field produced integer
---@field lost integer
---@field killed integer
---@field killedOf integer           units of this side the player killed
---@field built integer
---@field buildingsLost integer
---@field razed integer
---@field converted integer
---@field razedOf integer            buildings of this side the player razed
---@field res table<string, { [1]: integer, [2]: integer }>   gold, metal, stone, crystal, total: obtained, spent
---@field obtained table<string, integer>?
---@field spent table<string, integer>?
---@field st table?                  the side's battle statistics (battlestats.lua)

-- A tab's panel with its bars.
---@class ResultTab
---@field panel Panel
---@field bars table<integer, { x: number, y: number, w: number, h: number }[]>   per player row
---@field values number[][]          per player, per statistic
---@field pct integer[][]            per statistic, per player
---@field status PanelItem[]?        hero tab: the fallen-hero icons
---@field level PanelItem[]?         hero tab: the level-up icons

---@class ResultsScreen: Screen
---@field battle BattleScreen?
---@field players ResultRow[]
---@field won boolean?
---@field panel Panel                PNL_RESULTS_MAIN
---@field subs table<string, ResultTab>   the tabs opened so far
---@field tab integer
---@field t0 number                  when the tab was opened (the bars fill up)
local S = {}
S.helpId = 13          -- screen help (src/screens/screenhelp.lua)

local TABS = { "hero", "resources", "units", "buildings" }
local PANELS = { hero = "PNL_RESULTS_HERO", resources = "PNL_RESULTS_RESOURCES", units = "PNL_RESULTS_UNITS",
                 buildings = "PNL_RESULTS_BUILDINGS" }
local TAB_BUTTONS = { BUTT_RESULTS_HERO = 1, BUTT_RESULTS_RESOURCES = 2, BUTT_RESULTS_UNITS = 3, BUTT_RESULTS_BUILDINGS = 4 }
-- tab -> index into STR_RESULTS_HELP (text id 271)
local HELP = { BUTT_RESULTS_HERO = 2, BUTT_RESULTS_RESOURCES = 5, BUTT_RESULTS_UNITS = 4, BUTT_RESULTS_BUILDINGS = 3 }
local PB = { PB_ONE = 1, PB_TWO = 2, PB_THREE = 3, PB_FOUR = 4, PB_FIVE = 5, PB_SIX = 6 }
-- side colour -> ResultsBar bitmap (red, blue, green, purple, black, yellow)
local BAR = { [0] = 583, 580, 581, 582, 579, 584 }
local BAR_FRAME_MS = 1200
local TABBAR_ROW_H = 70
local sample

-- Rows of the table: one per used side, the player first.
local function collect(world, extra)
    local me = world.player
    local order = { me }
    for i = 0, 5 do
        if i ~= me and world.sides[i].used then order[#order + 1] = i end
    end
    local stats = world:battleStats()
    local players = {}
    for k, i in ipairs(order) do
        local sd, st = world.sides[i], stats.sides[i]
        local hero = world.eco:heroAlive(i)
        local level, xp, dead = 0, 0, false
        if hero and hero.h then level, xp = hero.h.level, hero.h.xp
        elseif sd.fallenHero then level, xp, dead = sd.fallenHero.level or 1, sd.fallenHero.xp or 0, true end
        local name = hero and hero.name
        if not name or name == "" then name = classes.RACE_NAMES[sd.race] or gamedata.RACES[sd.race] or "?" end
        local p = { side = i, name = name, color = sd.color, level = level, xp = xp, dead = dead, levelled = st.levelled,
                    kills = st.heroKills, spells = st.spells, games = (i == me and extra.games) or 0,
                    produced = st.unitsProduced, lost = st.unitsLost, killed = st.unitsKilled,
                    built = st.built - st.converted, buildingsLost = st.lost, razed = st.razed, converted = st.converted,
                    obtained = st.obtained, spent = st.spent, st = st }
        -- the original never shows more spent than produced: it fakes spent as 95-99 % of produced
        p.res = {}
        local tp, ts = 0, 0
        for _, r in ipairs({ "gold", "metal", "stone", "crystal" }) do
            local got, out = p.obtained[r], p.spent[r]
            if got < out then out = got - math.floor(got / 100) * (1 + (i * 7 + got) % 5) end
            p.res[r] = { got, out }
            tp, ts = tp + got, ts + out
        end
        p.res.total = { tp, ts }
        players[k] = p
    end
    -- per-side columns are relative to the player (row 1)
    for k, p in ipairs(players) do
        p.killedOf = players[1].st.killedBySide[p.side] or 0
        p.razedOf = players[1].st.razedBySide[p.side] or 0
    end
    return players
end

-- stat values of a player for a tab, in the order of the bars (see the PB layout of the panels)
local function values(tab, p)
    if tab == "hero" then return { p.kills, p.spells, p.games, p.xp }
    elseif tab == "resources" then
        local r = p.res
        return { r.gold[1], r.metal[1], r.stone[1], r.crystal[1], r.total[1],
                 r.gold[2], r.metal[2], r.stone[2], r.crystal[2], r.total[2] }
    elseif tab == "units" then return { p.produced, p.lost, p.killed, p.killedOf }
    end
    return { p.built, p.buildingsLost, p.razed, p.converted, p.razedOf }
end

---@param battle BattleScreen?
---@param players ResultRow[]? (no battle) the rows to show, else a sample
function S:enter(battle, players)
    -- a menu-like screen: the original's pointer hand (core/screens.lua), and scaled to the window
    -- height regardless of the battle's UI scale
    UI.inGame = false
    self.battle = battle
    if not battle then
        self.players = players or sample()
        self.won = true
    else
        local world = battle.world
        self.players = collect(world, { games = battle.result and battle.result.games or 0 })
        self.won = battle.result and battle.result.won
    end
    self.panel = UI.panel("PNL_RESULTS_MAIN", { x = 0, y = 0, onButton = function(name) self:button(name) end }) --[[@as Panel]]
    -- the tab buttons and the full-screen catcher are hit areas only; their bitmap must not be drawn
    for _, it in ipairs(self.panel.items) do
        if TAB_BUTTONS[it.name] or it.name == "BUTT_SS_FULLSCREEN" then
            it.ob = setmetatable({ source = -1 }, { __index = it.ob })
        end
    end
    self.panel:setString("STR_PARCHLARGE_L500", UI.text(281, 1))
    self.panel.align = self.panel.align or {}
    for _, it in ipairs(self.panel:all("STR_PARCHLARGE_L500")) do self.panel.align[it] = "center" end
    for k, it in ipairs(self.panel:all("STR_PARCHSMALL_L150")) do
        local p = self.players[k]
        self.panel.itemStrings[it] = p and p.name or ""
        self.panel.align[it] = "right"
    end
    for _, it in ipairs(self.panel:all("STR_MEDIUM700")) do self.panel.align[it] = "center" end
    self.panel:setString("STR_MEDIUM700", "")
    self.subs = {}
    self:setTab(1)
end

function S:button(name)
    if name == "BUTT_DONE_180" then
        screens.pop()
    elseif TAB_BUTTONS[name] then
        self:setTab(TAB_BUTTONS[name])
    end
end

-- Builds the bar layout of a tab's panel from the original panel definition.
local function layout(panel, nPlayers)
    local per = {}
    for _, it in ipairs(panel.items) do
        local idx = it.ob.type == xci.TYPE.PROGRESS and PB[it.name]
        if idx then
            per[idx] = per[idx] or {}
            table.insert(per[idx], { x = it.e.x, y = it.e.y, w = it.ob.w, h = it.ob.h })
        end
    end
    for _, list in pairs(per) do
        table.sort(list, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
    end
    return per
end

---@param n integer 1..4
function S:setTab(n)
    self.tab = n
    self.t0 = love.timer.getTime()
    local name = TABS[n]
    local sub = self.subs[name]
    if not sub then
        local panel = UI.panel(PANELS[name], { x = 0, y = 0 }) --[[@as Panel]]
        sub = ({ panel = panel, bars = layout(panel, #self.players) }) --[[@as ResultTab]]   -- fillPanel adds the values
        self.subs[name] = sub
        self:fillPanel(name, sub)
    end
    -- the tab bar image has one 70 px row per tab
    local bar = self.panel:find("IM_RESULTS_TABBAR")
    local img = UI.bitmap(589)
    if bar and img then
        bar.quad = love.graphics.newQuad(0, (n - 1) * TABBAR_ROW_H, 600, TABBAR_ROW_H, img:getDimensions())
    end
end

-- Percentages relative to the best player of every statistic (the original's FUN_0044bfa0: 100 when the value is
-- the best or the best is 0).
local function percentages(all, k)
    local best = 0
    for _, v in ipairs(all) do best = math.max(best, v[k] or 0) end
    local out = {}
    for i, v in ipairs(all) do
        local x = v[k] or 0
        out[i] = (best == 0 or x == best) and 100 or math.max(0, math.min(100, math.floor(x * 100 / best)))
    end
    return out
end

---@param name string
---@param sub ResultTab
function S:fillPanel(name, sub)
    local panel = sub.panel
    local all = {}
    for i, p in ipairs(self.players) do all[i] = values(name, p) end
    local nStats = #all[1]
    sub.values, sub.pct = all, {}
    for k = 1, nStats do sub.pct[k] = percentages(all, k) end
    if name == "hero" then
        local lv = panel:all("STR_PARCHMED_L35")
        local status, level = panel:all("IM_RESULTS_STATUS"), panel:all("IM_RESULTS_LEVEL")
        for i, p in ipairs(self.players) do
            if lv[i] then
                panel.itemStrings[lv[i]] = tostring(p.level)
                panel.align[lv[i]] = "center"
            end
            -- the images are drawn by this screen (only the first icon of the sheet pair matters)
            if status[i] then panel.itemHidden[status[i]] = true end
            if level[i] then panel.itemHidden[level[i]] = true end
        end
        sub.status, sub.level = status, level
        for i = #self.players + 1, #lv do panel.itemStrings[lv[i]] = "" end
        for i = #self.players + 1, #status do
            panel.itemHidden[status[i]] = true
            panel.itemHidden[level[i]] = true
        end
    end
end

function S:update(dt) end

local quads = {}
function S:barQuad(img, fullW, h, sy, w)
    local key = tostring(img) .. ":" .. sy .. ":" .. w
    local q = quads[key]
    if not q then
        q = love.graphics.newQuad(0, sy, math.min(w, img:getWidth()), h, img:getDimensions())
        quads[key] = q
    end
    return q
end

function S:draw()
    UI.begin()
    self.panel:draw()
    local sub = self.subs[TABS[self.tab]]
    sub.panel:draw()
    local g = love.graphics
    local k = math.min(1, (love.timer.getTime() - self.t0) * 1000 / BAR_FRAME_MS)
    for i, p in ipairs(self.players) do
        local list = sub.bars[i]
        local img = UI.bitmap(BAR[p.color] or 583)
        for j, pos in ipairs(list or {}) do
            local pct = sub.pct[j] and sub.pct[j][i]
            local value = sub.values[i][j]
            if pct and value ~= nil and img then
                -- the per-side columns have no bar for the player's own row
                local own = (TABS[self.tab] == "units" and j == 4 or TABS[self.tab] == "buildings" and j == 5) and i == 1
                if not own then
                    -- the bar bitmap is two rows: the empty trough above, the filled bar below
                    local w = math.floor(pos.w * pct * k / 100 + 0.5)
                    g.draw(img, self:barQuad(img, pos.w, pos.h, 0, pos.w), pos.x, pos.y)
                    if w > 0 then g.draw(img, self:barQuad(img, pos.w, pos.h, pos.h, w), pos.x, pos.y) end
                    fonts.print(2, tostring(value), pos.x, pos.y + 1, "center", pos.w)
                end
            end
        end
    end
    if TABS[self.tab] == "hero" then
        local sheet = UI.bitmap(591)
        for i, p in ipairs(self.players) do
            local st, lv = sub.status[i], sub.level[i]
            if sheet and st and p.dead then
                g.draw(sheet, love.graphics.newQuad(0, 0, 24, 24, sheet:getDimensions()), st.e.x, st.e.y)
            end
            if sheet and lv and p.levelled then
                g.draw(sheet, love.graphics.newQuad(24, 0, 24, 24, sheet:getDimensions()), lv.e.x, lv.e.y)
            end
        end
    end
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousemoved(vx, vy)
    local it = self.panel.hover
    local help = it and HELP[it.name]
    if it and it.name == "BUTT_DONE_180" then help = self.won and 0 or 1 end
    self.panel:setString("STR_MEDIUM700", help and UI.text(271, help) or "")
end

function S:mousepressed(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, b)
end

function S:mousereleased(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, b)
end

function S:keypressed(key)
    if key == "escape" or key == "return" then screens.pop() end
end

-- A made-up three-player result (--show results)
function sample()
    local function res(a, b) return { gold = { a, b }, metal = { math.floor(a / 2), math.floor(b / 2) }, stone = { 10, 8 }, crystal = { 0, 0 },
                                      total = { a + math.floor(a / 2) + 10, b + math.floor(b / 2) + 8 } } end
    local players = {
        { side = 0, name = "Hero", color = 0, level = 7, xp = 5300, dead = false, levelled = true, kills = 42, spells = 18,
          games = 5, produced = 60, lost = 20, killed = 55, killedOf = 0, built = 14, buildingsLost = 2, razed = 6,
          converted = 3, razedOf = 0, res = res(5400, 5100) },
        { side = 1, name = "Computer", color = 1, level = 4, xp = 1200, dead = true, kills = 11, spells = 5, games = 0,
          produced = 80, lost = 55, killed = 20, killedOf = 40, built = 18, buildingsLost = 9, razed = 2, converted = 0,
          razedOf = 6, res = res(7200, 6900) },
        { side = 2, name = "Computer", color = 2, level = 1, xp = 0, kills = 2, spells = 0, games = 0, produced = 10,
          lost = 3, killed = 4, killedOf = 15, built = 4, buildingsLost = 0, razed = 0, converted = 1, razedOf = 0,
          res = res(900, 700) },
    }
    return players
end


-- --show results:<tab 1-4>
function S:dev(sub) self:setTab(tonumber(sub) or 1) end

return S
