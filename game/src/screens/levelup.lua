-- Level-up dialogs (PNL_HEROLEVELUP_STATS and PNL_HEROLEVELUP_SKILLS): spend
-- the attribute points, then the skill points, gained with new levels.
-- enter(battle): the local hero of a battle (points are spent through commands). enter(battle, own) / enter(nil, own): a hero
-- that is changed directly, own = { hero = Hero, name, avatar = unit code, onDone, beforePop, always }:
--  * the Tournament hero before the battle (screens/tournamenthero.lua, no battle): its two screens always follow each other
--    (`always`; FUN_00553320 also tests the temporary-hero flag), nothing is saved and the extra line says "Temporary hero" (text 234 / 7);
--  * the hero after a battle (battle.lua `openLevelUps`, binary 0x004546F0): the stat screen while attribute points are
--    left, the skill screen when skill points are left; `beforePop` runs before the screen closes (saves the hero).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local heroMod = require("src.game.hero")
local music = require("src.audio.music")

-- The hero the dialog works on: the battle's hero unit, or a stand-in for a hero outside a battle.
---@class LevelUpHero
---@field h Hero
---@field name string?
---@field set table?                 the sprite set drawn on the panel (gfx/anims.lua)

-- What a hero outside a battle comes with (enter's `own`).
---@class LevelUpOwn
---@field hero Hero
---@field name string?
---@field avatar string?             unit code of the picture
---@field onDone fun()?
---@field beforePop fun()?           runs before the screen closes
---@field always boolean?            the skill screen always follows the stat screen

---@class LevelUpScreen: Screen
---@field battle BattleScreen?
---@field own LevelUpOwn?
---@field world World?
---@field hero LevelUpHero
---@field session { attr: table<string, integer>, skill: table<integer, integer> }   the points spent here, for refunds
---@field mode "stats"|"skills"
---@field panel Panel
---@field hint string?               the skill under the mouse (skill screen)
local S = { overlay = true }

-- row positions within the original panels
local STAT_ROWS = { 263, 300, 337, 374 }
local SKILL_ROWS = { 248, 285, 322, 359, 396 }

---@param battle BattleScreen?
---@param own LevelUpOwn?
function S:enter(battle, own)
    self.battle, self.own = battle, own
    if own then
        self.world = battle and battle.world
        self.hero = { h = own.hero, name = own.name, set = require("src.gfx.anims").get(own.avatar or "AHHX") }
    else
        ---@cast battle -nil
        self.world = battle.world
        self.hero = self.world.eco:heroAlive(self.world.player) --[[@as LevelUpHero]]   -- the dialog opens for a living hero
    end
    self.session = { attr = {}, skill = {} }
    if self.hero.h.points.attr > 0 or self.hero.h.points.skill == 0 then self:openStats() else self:openSkills() end
end

function S:leave() end

---@param name string
---@return Panel
function S:buildPanel(name)
    local p = UI.panel(name, { onButton = function(btn, it) self:button(btn, it) end })
    ---@cast p -nil
    self.panel = p
    p:hide("IM_HEROLEVELUP_STATSPOPUP")
    p:hide("IM_HEROLEVELUP_SKILLSPOPUP")
    for _, it in ipairs(p.items) do
        if it.ob.type == 4 then p.itemStrings[it] = "" end
    end
    return p
end

function S:openStats()
    self.mode = "stats"
    self:buildPanel("PNL_HEROLEVELUP_STATS")
    self:refresh()
end

function S:openSkills()
    self.mode = "skills"
    self:buildPanel("PNL_HEROLEVELUP_SKILLS")
    self:refresh()
end

function S:refresh()
    local p, h = self.panel, self.hero.h
    local ups, downs = p:all("BUTT_LEVELUP"), p:all("BUTT_LEVELDOWN")
    if self.mode == "stats" then
        p:setTextAt("STR_LARGE400", 374, 129, self.hero.name or "Hero")
        p:setTextAt("STR_SMALL_450", 378, 175, UI.text(5, 5) or "Improve Your Stats")
        p:setTextAt("STR_SMALL_450", 378, 190, (UI.text(5, 4) or "Level: %d"):format(h.level))
        p:setTextAt("STR_SMALL_450", 378, 205, (UI.text(5, 7) or "Points Left: %d"):format(h.points.attr))
        if h.tournament then p:setTextAt("STR_SMALL_450", 378, 220, UI.text(234, 7) or "Temporary hero") end
        for i, a in ipairs(heroMod.ATTRS) do
            local y = STAT_ROWS[i]
            p:setTextAt("STR_MEDIUM265", 336, y + 8, ("%s: %d"):format(a.name, h.attr[a.key]))
            p:setItemDisabled(ups[i], h.points.attr <= 0)
            p:setItemDisabled(downs[i], (self.session.attr[a.key] or 0) <= 0)
        end
    else
        p:setTextAt("STR_LARGE400", 279, 118, self.hero.name or "Hero")
        p:setTextAt("STR_SMALL_450", 283, 162, UI.text(5, 6) or "Improve Your Skills")
        p:setTextAt("STR_SMALL_450", 283, 177, (UI.text(5, 4) or "Level: %d"):format(h.level))
        p:setTextAt("STR_SMALL_450", 283, 192, (UI.text(5, 7) or "Points Left: %d"):format(h.points.skill))
        if self.hint then p:setTextAt("STR_SMALL_450", 283, 207, self.hint)
        elseif h.tournament then p:setTextAt("STR_SMALL_450", 283, 207, UI.text(234, 7) or "Temporary hero") end
        for i, e in ipairs(h.skillList) do
            local row, col = math.floor((i - 1) / 2), (i - 1) % 2
            local y = SKILL_ROWS[row + 1] + 8
            local vx, nx = col == 0 and 235 or 472, col == 0 and 272 or 509
            p:setTextAt("STR_MEDIUM200", vx, y, tostring(h.skill[e[1]]))
            p:setTextAt("STR_MEDIUM332", nx, y, heroMod.skillName(e[1]))
            local k = row * 2 + col + 1
            p:setItemDisabled(ups[k], not h:canRaise(e[1]))
            p:setItemDisabled(downs[k], (self.session.skill[e[1]] or 0) <= 0)
        end
    end
end

-- In a battle the hero changes through a command (so that every peer agrees); the temporary hero is not in a battle yet.
---@param op string a Hero method: spendAttr, refundAttr, spendSkill, refundSkill
---@param key string|integer the attribute or skill
function S:heroOp(op, key)
    if self.own then self.own.hero[op](self.own.hero, key) else assert(self.battle):heroOp(op, key) end
end

---@param name string
---@param it PanelItem?
function S:button(name, it)
    local h = self.hero.h
    local p = self.panel
    if name == "BUTT_OKAY_180" then
        if self.mode == "stats" and (h.points.skill > 0 or (self.own and self.own.always)) then self:openSkills()
        else
            if self.own and self.own.beforePop then self.own.beforePop() end
            if not self.own then assert(self.battle):heroOp("levelDone") end      -- no points left: the next level may come
            screens.pop()
            if self.own and self.own.onDone then self.own.onDone() end
        end
        return
    end
    if name ~= "BUTT_LEVELUP" and name ~= "BUTT_LEVELDOWN" then return end
    local list = p:all(name)
    local index
    for i, b in ipairs(list) do if b == it then index = i end end
    if not index then return end
    local key
    if self.mode == "stats" then key = heroMod.ATTRS[index] and heroMod.ATTRS[index].key
    else key = h.skillList[index] and h.skillList[index][1] end
    if not key then return end
    local kind = self.mode == "stats" and "attr" or "skill"
    if name == "BUTT_LEVELUP" then
        local ok = (kind == "attr" and h.points.attr > 0 and h.attr[key] ~= nil)
            or (kind == "skill" and h:canRaise(key --[[@as integer]]))
        if ok then
            self:heroOp(kind == "attr" and "spendAttr" or "spendSkill", key)
            self.session[kind][key] = (self.session[kind][key] or 0) + 1
        end
    elseif (self.session[kind][key] or 0) > 0 then
        self:heroOp(kind == "attr" and "refundAttr" or "refundSkill", key)
        self.session[kind][key] = self.session[kind][key] - 1
    end
    self:refresh()
end

function S:update()
    music.update()
end

function S:draw()
    UI.begin()
    self.panel:draw()
    if self.hero and self.hero.set then
        local team = self.battle and self.battle:teamColor(self.world.player) or 1
        local x, y = 257, 141
        if self.mode == "skills" then x, y = 167, 128 end
        self.hero.set:drawInterface(3, x, y, team)
    end
    UI.finish()
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousemoved(vx, vy)
    if self.mode == "skills" then
        -- describe the skill under the cursor
        local hint
        for i, e in ipairs(self.hero.h.skillList) do
            local row, col = math.floor((i - 1) / 2), (i - 1) % 2
            local sx = col == 0 and 165 or 402
            local sy = SKILL_ROWS[row + 1]
            if vx >= sx and vx < sx + 300 and vy >= sy and vy < sy + 32 then
                hint = heroMod.skillDesc(e[1], self.hero.h:lvl(e[1])) .. (e[2] > 1 and (" - from level %d"):format(e[2]) or "")
            end
        end
        if hint ~= self.hint then
            self.hint = hint
            self:refresh()
        end
    end
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if key == "return" or key == "escape" then self:button("BUTT_OKAY_180") end
end

return S
