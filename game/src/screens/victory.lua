-- Victory / defeat screen after a battle (1.04: FUN_00454b70, panel PNL_VICTORYDEFEAT_NEW): the
-- VictoryBG.bmp / DefeatBG.bmp backdrop (a parchment banner under the picture), the hero's name, "Victory" or
-- "Defeat", troops built / lost / killed and buildings built / lost / destroyed, the post-battle experience bonus
-- ("You have gained a N XP bonus", or the frozen-hero text, or the campaign form with the extra XP of the action), the
-- levels the hero gained, the "saved games deleted" line and the campaign's reward line, a button for the advanced
-- results (the statistics screen) and a continue button. The 1.04 binary plays no victory / defeat video (no Victory.bik
-- / Defeat.bik name in it), so there are none to play.
--
-- enter(battle, opts): the finished battle screen; dev(): a sample for --show victory.
-- The Continue button pops this screen (the battle screen then leaves). `Advanced results` pushes the statistics.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")
local music = require("src.audio.music")

---@class VictoryScreen: Screen
---@field battle BattleScreen?       the finished battle (nil: the --show sample)
---@field won boolean?
---@field bg love.Image?             VictoryBG.bmp / DefeatBG.bmp
---@field panel Panel                PNL_VICTORYDEFEAT_NEW
local S = {}
S.helpId = 14          -- screen help (src/screens/screenhelp.lua)

local backdrops = {}
local function backdrop(name)
    local b = backdrops[name]
    if b == nil then
        b = false
        local data = vfs.read("Assets/Graphics.xcr", name)
        if data then
            local ok, img = pcall(bmp.image, data, { key = true })
            if ok and img then b = img end
        end
        backdrops[name] = b
    end
    return b or nil
end

---@param battle BattleScreen?
function S:enter(battle)
    UI.inGame = false
    self.battle = battle
    local counts, won, name, levels, xp, extra, reward, frozen, deleted
    if battle and battle.world then
        local world = battle.world
        local st = world:battleStats().sides[world.player]
        counts = { st.unitsProduced, st.unitsLost, st.unitsKilled, st.built, st.lost, st.razed }
        won = battle.result and battle.result.won
        local hero = world.eco:heroAlive(world.player)
        local rec = world.opts.profile and require("src.game.profile").current()
        name = rec and rec.name or (hero and hero.name)
        local result = battle.result or {}
        levels = result.levelsGained or 0           -- points still to spend plus the levels the battle's experience owes
        xp = result.heroRemoved and 0 or result.xp
        frozen = hero and hero.h and hero.h.frozen
        if battle.victoryExtra then extra, reward = battle.victoryExtra(won) end
        -- the original deletes the hero's saved game when the battle gave it experience (NODELETE keeps it)
        if (xp or 0) > 0 and rec and require("src.core.config").get("game", "deletesaves", "1") ~= "0" then
            deleted = require("src.game.savegame").deleteForHero(rec.id) > 0
        end
    else
        counts, won, name, levels, xp = { 24, 6, 31, 7, 1, 4 }, true, "Sample Hero", 1, 76
    end
    self.won = won
    -- the screen's builder starts the music set's Victory / Defeat theme (FUN_00454560, see audio/music.lua); the
    -- --show sample has no battle behind it and keeps the menu theme
    if battle and battle.world then music.play(won and "victory" or "defeat") end
    self.bg = backdrop(won and "VictoryBG.bmp" or "DefeatBG.bmp")
    local p = UI.panel("PNL_VICTORYDEFEAT_NEW", { x = 0, y = 0, onButton = function(n) self:button(n) end })
    ---@cast p -nil
    self.panel = p
    p:hide("IM_VICTORYBACKGROUND")
    p:hide("BUTT_SS_FULLSCREEN")
    -- six values with their captions: the troops in the left column, the buildings in the right
    local function column(list)
        table.sort(list, function(a, b)
            if a.e.x ~= b.e.x then return a.e.x < b.e.x end
            return a.e.y < b.e.y
        end)
        return list
    end
    local values, captions = column(p:all("STR_PARCHSMALL_L150")), column(p:all("STR_PARCHSMALL_L250"))
    for i = 1, 6 do
        p.itemStrings[values[i]] = tostring(counts[i] or 0)
        p.align[values[i]] = "center"
        p.itemStrings[captions[i]] = UI.text(279, i - 1) or ""
        p.align[captions[i]] = "center"
    end
    local title = p:find("STR_PARCHLARGE_500") --[[@as PanelItem]]
    p.itemStrings[title] = UI.text(23, won and 4 or 5) or ""
    p.align[title] = "center"
    local hero = p:find("STR_PARCHLARGE_L500") --[[@as PanelItem]]
    p.itemStrings[hero] = name or ""
    p.align[hero] = "center"
    local med = p:all("STR_PARCHMED_L700")
    for _, it in ipairs(med) do p.itemStrings[it] = ""; p.align[it] = "center" end
    if frozen then
        p.itemStrings[med[1]] = UI.text(333, 1) or ""
    elseif xp then
        local line = (extra and extra > 0) and (UI.text(330, 5) or ""):format(xp, extra) or (UI.text(279, 6) or ""):format(xp)
        p.itemStrings[med[1]] = line
    end
    if levels and levels > 0 then
        local line = levels > 1 and (UI.text(330, 7) or ""):gsub("%%d", tostring(levels)) or UI.text(279, 7)
        p.itemStrings[med[#med]] = line   -- the lower of the two lines, as the original's index 1
    end
    local small = p:all("STR_SMALL700")
    for _, it in ipairs(small) do p.itemStrings[it] = ""; p.align[it] = "center" end
    if deleted and small[1] then p.itemStrings[small[1]] = require("src.game.strings").get("Game.txt", "0492") or "" end
    if reward and small[2] then p.itemStrings[small[2]] = reward end
    p.itemStrings[p:find("BUTT_OKAY_STARTUP")] = UI.text(23, 7) or "Continue"
end

function S:button(name)
    if name == "BUTT_OKAY_STARTUP" then
        screens.pop()
    elseif name == "BUTT_ADVANCEDRESULTS" then
        screens.push(require("src.screens.results"), self.battle)
    end
end

function S:draw()
    love.graphics.clear(0, 0, 0)
    UI.begin()
    if self.bg then love.graphics.draw(self.bg, 0, 0) end
    self.panel:draw()
    UI.finish()
end

function S:resume() UI.inGame = false end

function S:update() music.update() end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end

function S:mousepressed(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousepressed(vx, vy, b)
end

function S:mousereleased(x, y, b)
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, b)
end

function S:keypressed(key)
    if key == "escape" or key == "return" or key == "space" then screens.pop() end
end

function S:dev(sub)
    if sub == "defeat" then
        self.won = false
        self.bg = backdrop("DefeatBG.bmp")
        local t = self.panel:find("STR_PARCHLARGE_500") --[[@as PanelItem]]
        self.panel.itemStrings[t] = UI.text(23, 5) or ""
    end
end

return S
