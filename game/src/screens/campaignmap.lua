-- The campaign world map: travel between locations, visit them for battles, shops, mercenaries and
-- news. Mirrors the original campaign (data from <Lang>/Campaign.xcr, see src/game/campaigndata.lua).
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local kit = require("src.ui.kit")
local fonts = require("src.ui.fonts")
local widgets = require("src.ui.widgets")
local config = require("src.core.config")
local data = require("src.game.campaigndata")
local cstate = require("src.game.campaignstate")
local run = require("src.game.campaignrun")
local profile = require("src.game.profile")
local heroMod = require("src.game.hero")
local retinueMod = require("src.game.retinue")
local items = require("src.game.items")
local gamedata = require("src.game.gamedata")
local classes = require("src.game.classes")
local spells = require("src.game.spells")
local music = require("src.audio.music")
local sound = require("src.audio.sound")
local dropdown = require("src.ui.dropdown")

-- The open dialog of the map (one table; which fields are set depends on `kind`).
---@class CampaignMapDialog
---@field kind string          location, moreinfo, action, result, ambush, journal, bonuses, diplomacy, hero, stash, hint, resign
---@field panel Panel?         the XCI panel of a panel dialog (moreinfo, action of a battle, ambush, diplomacy)
---@field act table?           the campaign action (campaigndata) of an action / result dialog
---@field amb table?           the ambush of the ambush dialog
---@field races integer[]?     the races the battle can be played with (new-battle / ambush drop-down)
---@field pick integer?        index into `races`
---@field canPay boolean?      the hero has the crowns for the action's entry fee
---@field note string?         a message line under the dialog
---@field offers table[]?      the mercenary companies on offer (campaignrun.offers)
---@field stock string[]?      the item ids for sale (campaignrun.shopItems)
---@field scroll integer?      journal: entries scrolled back
---@field won boolean?         result: the battle was won
---@field lines string[]?      result: the reward lines
---@field journal nil         result: no journal entry (always nil)
---@field camX number?         moreinfo: the camera to go back to
---@field camY number?

---@class CampaignMapTravel
---@field x0 number
---@field y0 number
---@field x1 number
---@field y1 number
---@field t number             0..1 along the route
---@field link table           the route (location link) travelled

-- A press on the map that may become a drag: where it began, the camera then, whether it moved.
---@class CampaignMapDrag
---@field x number
---@field y number
---@field camX number
---@field camY number
---@field moved boolean

---@class CampaignMapScreen: Screen
---@field D table              the campaign data (campaigndata.load)
---@field hero HeroProfile     the hero's profile record
---@field state CampaignState  the hero's campaign progress
---@field dialog CampaignMapDialog?
---@field menu boolean         the campaign menu is open
---@field help string          the help line at the bottom
---@field travel CampaignMapTravel? the hero's marker moving along a route
---@field camX number          map scroll position
---@field camY number
---@field pendingResult { act: table, won: boolean }? the battle that just ended, handled on resume
---@field markers { code: string, x: number, y: number }[]? the location markers drawn last frame
---@field hits table[]         kit hit boxes (kit.begin sets them at every draw)
---@field rowQuads table<integer, love.Quad>?
---@field iconQuads table<integer, love.Quad>?
---@field bigIcon love.Quad?
---@field actionList table[]?  the actions of the location popup, by row
---@field drag CampaignMapDrag? a map drag in progress
local S = {}

S.helpId = 7          -- screen help (src/screens/screenhelp.lua)

local BM = { MAP = 721, TOP = 725, BOTTOM = 722, LEFT = 723, RIGHT = 724, MARKER = 715, RING = 732, MENU = 714,
             DIALOG = 718, JOURNAL = 716, POPUP = 711, BIGBUTTON = 719, ICONS_SMALL = 737, ICONS_LARGE = 738 }
-- icons of ActionIcons{Small,Large}.bmp (11 of them: 22x15 and 36x30)
local ICON = { message = 0, xp = 1, retinue = 2, battle = 3, mercenary = 5, item = 6, info = 10 }
local REL_LABEL = { ally = "Ally", friend = "Friend", neutral = "Neutral", enemy = "Enemy" }
local VX, VY, VW, VH = 15, 42, 770, 516           -- map viewport
local MAP = 1200

local MENU_ITEMS = {
    { id = "bonuses", label = "View Bonuses", help = "View the bonuses you have collected." },
    { id = "journal", label = "View Journal", help = "Read the journal of your adventures." },
    { id = "diplomacy", label = "Diplomacy", help = "View information about your relationship with other races." },
    { id = "options", label = "Options", help = "Change sound and game options." },
    { id = "hero", label = "Hero Information", help = "Look at your hero." },
    { id = "stash", label = "Your Item Stash", help = "Look through the items you are carrying with you." },
    { id = "hint", label = "Hint", help = "Get a hint about what to do next." },
    { id = "exit", label = "Exit", help = "Return to the main menu." },
}

local function img(id) return UI.bitmap(id) end

-- Setup ---------------------------------------------------------------------------------------------

---@param heroRec HeroProfile? the hero's profile record (default: the current hero)
function S:enter(heroRec)
    heroRec = heroRec or profile.current()
    ---@cast heroRec -nil
    self.D = data.load()
    self.hero = heroRec
    local state = cstate.load(heroRec.id)
    local fresh = not state
    if not state then
        state = cstate.new(heroRec.id)
        state:save()
    end
    self.state = state
    self.dialog = nil
    self.menu = false
    self.help = ""
    self.travel = nil
    self:centreOn(self.D.locations[self.state.location])
    music.play("intro")
    if fresh or not self.state.introSeen then
        self.state.introSeen = true
        self.state:save()
        screens.push(require("src.screens.cutscene"), "Intro")
    end
end

-- developer aid: --show campaignmap:location / :action / :menu / :hint
---@param sub string
function S:dev(sub)
    if sub == "menu" then self.menu = true
    elseif sub == "location" then self.dialog = { kind = "location" }
    elseif sub == "moreinfo" then self:openMoreInfo()
    elseif sub == "action" then self:openAction(self.state:actions()[1])
    elseif sub == "fight" then
        local act = self.state:actions()[1]
        self:openAction(act)
        self:launch(act, act.map)
    elseif sub == "races" or sub == "racelist" then
        -- the new-battle dialog of a hero with allies (standings made up; the saved campaign is left alone): the drop-down
        -- list open with "racelist"
        self.state.save = function() end
        for _, race in ipairs({ 1, 6, 9 }) do self.state.diplomacy[race] = 15 end
        self:openAction(self.state:actions()[1])
        self:pickRace(2)
        if sub == "racelist" then self:openRaceList() end
    elseif sub == "fightrace" then
        -- the battle of the first action played with an allied race (the army setup lists that race's troops)
        self.state.save = function() end
        self.state.diplomacy[1] = 15
        local act = self.state:actions()[1]
        self:openAction(act)
        self:launch(act, act.map, 1)
    elseif sub == "options" then self:openOptions()
    elseif sub == "extra" or sub == "mercs" then
        -- the dialogs of the army setup of a battle: extra army points (crowns needed), the mercenary selection; the saved
        -- campaign is left alone
        self.state.save = function() end
        self.state.crowns = sub == "extra" and 45 or 5
        self.state.mercs = { 3, 12 }
        local act = self.state:actions()[1]
        self:openAction(act)
        self:launch(act, act.map)
    elseif sub == "hint" then self.dialog = { kind = "hint" }
    elseif sub == "diplomacy" then
        -- the standings of a hero with allies and enemies (made up; the saved campaign is left alone)
        self.state.save = function() end
        for _, race in ipairs({ 1, 6, 9 }) do self.state.diplomacy[race] = 15 end
        for _, race in ipairs({ 3, 10 }) do self.state.diplomacy[race] = 7 end
        self.state.diplomacy[self.hero.race] = 20
        self.state.diplomacy[4] = -8
        self:openDiplomacy()
    elseif sub == "ambush" then
        -- the ambush dialog of a hero with allies (the saved campaign is left alone)
        self.state.save = function() end
        for _, race in ipairs({ 1, 6, 9 }) do self.state.diplomacy[race] = 15 end
        local amb = self.D.ambushes.AMB_ARAMBUSH
        self:openAmbush(amb)
        self:pickRace(2)
    elseif sub == "reward" or sub == "replay" then
        -- the new-battle dialog of an action with two rewards (only the first one's text is shown) / a replayable one
        self:openAction(self.D.actions[sub == "reward" and "ACT_ENMOUTH" or "ACT_KBMEDIUM"])
    elseif sub == "resign" then self.dialog = { kind = "resign" } end
end

---@param loc table? a campaign location (nil: the map centre)
function S:centreOn(loc)
    self.camX = math.max(0, math.min(MAP - VW, (loc and loc.x or 600) - VW / 2))
    self.camY = math.max(0, math.min(MAP - VH, (loc and loc.y or 600) - VH / 2))
end

function S:resume()
    music.play("intro")
    self.hero = profile.get(self.hero.id) or self.hero
    local r = self.pendingResult
    if r then
        self.pendingResult = nil
        local lines = run.finishBattle(self.state, r.act, r.won)
        self.dialog = { kind = "result", act = r.act, won = r.won, lines = lines, journal = nil }
        -- back on the world map after a battle: the journal / hint hint (the original shows it once, on leaving
        -- the retinue screen in campaign mode)
        require("src.screens.screenhelp").open(4)
        self.hero = profile.get(self.hero.id) or self.hero
    end
end

-- Helpers ------------------------------------------------------------------------------------------------

---@return table loc the location the hero stands at
function S:location() return self.D.locations[self.state.location] end

---@return Hero
function S:heroObject()
    return heroMod.new(nil, self.hero.hero)
end

---@param h Hero
function S:saveHero(h)
    self.hero.hero = h:save()
    profile.update(self.hero)
end

local function line(self, text, x, y, w, font, color)
    local lines = widgets.wrap(font or 5, text or "", w)
    if color then love.graphics.setColor(color[1], color[2], color[3]) end
    for i, l in ipairs(lines) do fonts.print(font or 5, l, x, y + (i - 1) * ((font == 2) and 15 or 20)) end
    love.graphics.setColor(1, 1, 1)
    return #lines * ((font == 2) and 15 or 20)
end

-- Drawing ---------------------------------------------------------------------------------------------------

function S:drawMap()
    local g = love.graphics
    local map = img(BM.MAP)
    g.setColor(1, 1, 1)
    if map then
        local quad = love.graphics.newQuad(self.camX, self.camY, VW, VH, MAP, MAP)
        g.draw(map, quad, VX, VY)
    end
    local visible = self.state:visible()
    local marker = img(BM.MARKER)
    local ring = img(BM.RING)
    local t = love.timer.getTime()
    self.markers = {}
    -- routes of the current location
    local cur = self:location()
    for _, l in ipairs(cur.links) do
        local to = self.D.locations[l.to]
        if to and self.state:locationOpen(l.to) then
            local x0, y0 = cur.x - self.camX + VX, cur.y - self.camY + VY
            local x1, y1 = to.x - self.camX + VX, to.y - self.camY + VY
            g.setColor(1, 0.9, 0.5, 0.45)
            g.setLineWidth(2)
            local n = 28
            for i = 0, n - 1, 2 do
                local a, b = i / n, (i + 1) / n
                g.line(x0 + (x1 - x0) * a, y0 + (y1 - y0) * a, x0 + (x1 - x0) * b, y0 + (y1 - y0) * b)
            end
            g.setLineWidth(1)
        end
    end
    for code in pairs(visible) do
        local loc = self.D.locations[code]
        local x, y = loc.x - self.camX + VX, loc.y - self.camY + VY
        if x > VX - 20 and x < VX + VW + 20 and y > VY - 20 and y < VY + VH + 20 then
            local isCur = code == self.state.location
            local hover = kit.inside(self, x - 12, y - 12, 24, 24) and not self.dialog
            self.markers[#self.markers + 1] = { code = code, x = x, y = y }
            g.setColor(1, 1, 1)
            if marker then
                local state = isCur and 0 or (hover and 1 or (self.state.visited[code] and 0 or 2))
                g.draw(marker, love.graphics.newQuad(0, state * 22, 22, 22, 22, 66), x - 11, y - 11)
            end
            if isCur and ring then
                local f = math.floor(t * 4) % 5
                g.draw(ring, love.graphics.newQuad(0, f * 66, 66, 66, 66, 330), x - 33, y - 33)
            end
            if isCur or hover or self.state.visited[code] then
                local label = loc.name
                local w = fonts.width(5, label)
                fonts.print(5, label, loc.tx - self.camX + VX - w / 2, loc.ty - self.camY + VY - 8)
            end
            if hover then
                self.help = loc.name
                for _, l in ipairs(cur.links) do
                    if l.to == code then self.help = ("%s - %d days"):format(loc.name, l.days) end
                end
            end
        end
    end
end

function S:drawFrames()
    local g = love.graphics
    g.setColor(1, 1, 1)
    local top, bottom, left, right = img(BM.TOP), img(BM.BOTTOM), img(BM.LEFT), img(BM.RIGHT)
    if top then g.draw(top, 0, 0) end
    if bottom then g.draw(bottom, 0, 558) end
    if left then g.draw(left, 0, 42) end
    if right then g.draw(right, 785, 42) end
    -- top bar
    local st = self.state
    local menuHover = kit.inside(self, 93, 4, 158, 22)
    local hit = { id = "menu", x = 93, y = 4, w = 158, h = 22 }
    self.hits[#self.hits + 1] = hit
    love.graphics.setColor(menuHover and 0.5 or 0.38, 0.05, 0.05, 0.95)
    love.graphics.rectangle("fill", 93, 4, 158, 22)
    love.graphics.setColor(1, 1, 1)
    fonts.print(5, "Menu", 93, 4 + fonts.middleY(5, 22), "center", 158)
    fonts.print(5, ("%d Crowns"):format(st.crowns), 317, 4 + fonts.middleY(5, 22), "center", 159)
    fonts.print(5, ("Year %d   Day %d"):format(st.year, st.day), 551, 4 + fonts.middleY(5, 22), "center", 158)
    if menuHover then self.help = "Open the campaign menu." end
    fonts.print(5, self.help or "", 15, 578 + fonts.middleY(5, 20), "center", 770)
end

function S:drawMenu()
    if not self.menu then return end
    local g = love.graphics
    local bg = img(BM.MENU)
    if bg then g.draw(bg, 93, 27) end
    for i, item in ipairs(MENU_ITEMS) do
        local y = 40 + (i - 1) * 20 + (i == #MENU_ITEMS and 6 or 0)
        local hv = kit.inside(self, 100, y, 150, 20)
        self.hits[#self.hits + 1] = { id = "menu_" .. item.id, x = 100, y = y, w = 150, h = 20 }
        if hv then
            g.setColor(1, 0.95, 0.7)
            self.help = item.help
        else
            g.setColor(0.85, 0.8, 0.65)
        end
        fonts.print(5, item.label, 93, y + fonts.middleY(5, 20), "center", 165)
        g.setColor(1, 1, 1)
    end
    -- once the campaign can be finished, the menu offers to end it (the original's resign option)
    if self.state:finishable() then
        local y = 40 + #MENU_ITEMS * 20 + 6
        local hv = kit.inside(self, 100, y, 150, 20)
        self.hits[#self.hits + 1] = { id = "menu_resign", x = 100, y = y, w = 150, h = 20 }
        fonts.print(5, hv and "Finish Campaign" or "Finish Campaign", 93, y + fonts.middleY(5, 20), "center", 165)
        if hv then self.help = "End the campaign and see the credits." end
    end
end

-- Dialog frame: title + body area; returns x, y of the body.
---@param title string?
---@param w number?
---@param h number?
---@return integer x, integer y, number w, number h
function S:frame(title, w, h)
    local g = love.graphics
    w, h = w or 696, h or 484
    local x, y = math.floor((800 - w) / 2), math.floor((600 - h) / 2) - 6
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 0, 800, 600)
    g.setColor(1, 1, 1)
    local bg = img(BM.DIALOG)
    if bg and w == 696 then g.draw(bg, x, y)
    else
        kit.panel(x, y, w, h, 0.97)
    end
    fonts.print(1, title or "", x, y + 16, "center", w)
    return x, y, w, h
end

---@param id string
---@param label string
---@param x number
---@param y number
---@param w number
---@param h number?
---@param opts table?
---@param extra any       handed to `act` with the id
---@return table hit the kit hit box
function S:button(id, label, x, y, w, h, opts, extra)
    kit.button(self, id, label, x, y, w, h or 28, opts)
    if extra ~= nil then self.hits[#self.hits].extra = extra end
    return self.hits[#self.hits]
end

-- Dialogs ---------------------------------------------------------------------------------------------------

-- The reward line of the new-battle dialog: the short text of the action's FIRST reward only (`FUN_005a3450` pushes the one
-- string at action record + 0x746, the first reward's short text, no loop over the rewards); a first reward
-- without a short text leaves the line empty.
local function rewardText(act)
    local r = act.rewards and act.rewards[1]
    return r and r.short or ""
end

-- One 220x20 row of the location popup (CampaignBigButton.bmp: normal, hover, pressed) with an icon at each end.
---@param id string
---@param label string
---@param x number
---@param y number
---@param icon integer?
---@param extra any
---@param inactive boolean?
---@return boolean hovered
function S:popupRow(id, label, x, y, icon, extra, inactive)
    local g = love.graphics
    local hv = kit.inside(self, x, y, 220, 20)
    if not inactive then self.hits[#self.hits + 1] = { id = id, x = x, y = y, w = 220, h = 20, extra = extra } end
    local state = (hv and not inactive and love.mouse.isDown(1)) and 2 or (hv and not inactive and 1 or 0)
    if inactive then g.setColor(0.5, 0.5, 0.5) else g.setColor(1, 1, 1) end
    local bg = img(BM.BIGBUTTON)
    if bg then
        self.rowQuads = self.rowQuads or {}
        self.rowQuads[state] = self.rowQuads[state] or g.newQuad(0, state * 20, 220, 20, bg:getDimensions())
        g.draw(bg, self.rowQuads[state], x, y)
    end
    local icons = img(BM.ICONS_SMALL)
    if icons and icon then
        self.iconQuads = self.iconQuads or {}
        self.iconQuads[icon] = self.iconQuads[icon] or g.newQuad(icon * 22, 0, 22, 15, icons:getDimensions())
        g.draw(icons, self.iconQuads[icon], x + 2, y + 3)
        g.draw(icons, self.iconQuads[icon], x + 220 - 24, y + 3)
    end
    local ob = UI.ui.objByName.BUTT_CAMPAIGN_ACTION
    local fid = (ob and ob.fonts and ob.fonts[1]) or 5
    if hv and not inactive and ob and ob.fonts and ob.fonts[2] ~= 0 then fid = ob.fonts[2] end
    fonts.print(fid, label, x, y + fonts.middleY(fid, 20) + (state == 2 and 1 or 0), "center", 220)
    g.setColor(1, 1, 1)
    return hv and not inactive
end

-- Clicking the place the hero stands at: what can be done here, plus More Info.
function S:drawLocationDialog()
    local loc = self:location()
    local acts = self.state:actions()
    self.actionList = acts
    local shown = math.min(#acts, 8)
    local w = 235
    local cancelY = 36 + (shown + 2) * 20
    local h = cancelY + 24
    local x, y = math.floor((800 - w) / 2), math.floor((600 - h) / 2) + 30
    local g = love.graphics
    g.setColor(0.02, 0.01, 0.03, 1)
    g.rectangle("fill", x, y, w, h)
    g.setColor(0.3, 0.22, 0.3, 1)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    g.setColor(1, 1, 1)
    local head = img(BM.POPUP)
    if head then g.draw(head, x, y) end
    fonts.print(5, loc.name, x, y + 8 + fonts.middleY(5, 20), "center", w)
    for i = 1, shown do
        local act = acts[i]
        if self:popupRow("act", act.name, x + 7, y + 36 + (i - 1) * 20, ICON[act.type] or ICON.message, i) then
            self.help = act.help or ""
        end
    end
    if self:popupRow("moreinfo", "More Info...", x + 7, y + 36 + shown * 20, ICON.info) then
        self.help = "Read about this place."
    end
    self:popupRow("cancel", "Cancel", x + 7, y + cancelY)
end

local function paragraphLines(font, text, width)
    local out = {}
    for para in (text or ""):gmatch("[^\n]+") do
        if #out > 0 then out[#out + 1] = "" end
        for _, l in ipairs(widgets.wrap(font, para, width)) do out[#out + 1] = l end
    end
    return out
end

-- Scroll with the story of the place (the map moves so the place sits beside it).
function S:openMoreInfo()
    local loc = self:location()
    local p = UI.panel("PNL_CAMPAIGN_MOREINFO", { x = 200, y = 88, onButton = function() self:act("moreinfo_done") end })
    ---@cast p -nil
    p:hide("IM_CAMPAIGN_MOREINFO")                      -- the dimming layer; the map stays bright
    self.dialog = { kind = "moreinfo", panel = p, camX = self.camX, camY = self.camY }
    self.camX = math.max(0, math.min(MAP - VW, loc.x + VX - 137))
    self.camY = math.max(0, math.min(MAP - VH, loc.y + VY - 379))
end

function S:drawMoreInfo()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local loc = self:location()
    local p = d.panel --[[@as Panel]]
    p:draw()
    local x, y = p.x, p.y
    local title = UI.ui.objByName.STR_PARCHLARGEH_L400
    fonts.print(title and title.font or 1, loc.name, x, y + 22, "center", 400)
    local cy = y + 66
    for _, l in ipairs(paragraphLines(5, loc.description, 340)) do
        if l ~= "" then fonts.print(5, l, x + 30, cy, "center", 340) end
        cy = cy + 20
    end
    if loc.owner then
        local race = classes.RACE_NAMES[loc.owner]
        if race then
            fonts.print(5, "Race: " .. race, x, y + 271, "center", 400)
            fonts.print(5, "Diplomatic Rating: " .. (REL_LABEL[self.state:relation(loc.owner)] or "Neutral"), x, y + 291, "center", 400)
        end
    end
    local battle = false
    for _, a in ipairs(self.state:actions()) do if a.type == "battle" then battle = true end end
    local icons = img(BM.ICONS_LARGE)
    if battle and icons then
        self.bigIcon = self.bigIcon or love.graphics.newQuad(ICON.battle * 36, 0, 36, 30, icons:getDimensions())
        love.graphics.draw(icons, self.bigIcon, x + 182, y + 322)
    end
end

-- The rating of the battle map for the hero playing `race` (the campaign difficulty rating `FUN_005966a0`, built on
-- the AI level formula `FUN_005a1790`: campaignrun.mapDifficulty), printed as Game.txt [0700 + rating]: Easy,
-- Average, Hard, Very Hard, Insane, Suicidal (`FUN_005a3450` adds 0x2bc to it).
---@param act table
---@param race integer?
---@return string
function S:difficulty(act, race)
    local rating = act.map and require("src.game.campaignrun").mapDifficulty(self.state, act.map, race)
    return rating and require("src.game.strings").get("Game.txt", ("%04d"):format(700 + rating)) or "-"
end

-- The name a race has in the new-battle dialog's list (TXT_RACE_ABBREV_1 / _2 = texts 277 / 278, `FUN_005a3390`).
local function raceText(race)
    return race < 8 and UI.text(277, race) or UI.text(278, race - 8) or classes.RACE_NAMES[race] or ""
end

-- The text of the dialog's texts (TXT_CAMPAIGN_NEWBATTLE 316, TXT_CAMPAIGN_NEWBATTLE2 317) with an English fallback.
local function nbText(id, sub, fallback) return UI.text(id, sub) or fallback end

-- "A New Battle": the mission briefing shown before a battle action starts (`FUN_005a2fc0`). The
-- drop-down offers the hero's own race first and then every race that is his Ally (campaignrun.battleRaces); the pick is
-- the race he plays the battle with and the difficulty line follows it (`FUN_005a3390`).
---@param act table
function S:openBattle(act)
    -- a replayable battle gets its explanation (the original opens the help when the briefing is set up)
    if act.replayable then require("src.screens.screenhelp").open(5) end
    local p = UI.panel("PNL_CAMPAIGN_NEWBATTLE", { x = 52, y = 58, onButton = function(name, it)
        if name == "BUTT_OKAY_180" then self:act("fight")
        elseif name == "BUTT_CANCEL_180" then self:act("cancel")
        elseif name == "BUTT_DROPLIST170" then self:openRaceList() end
    end })
    ---@cast p -nil
    p:hide("IM_CAMPAIGN_NEWBATTLE")
    p:setString("STR_PARCHLARGEH_L400", nbText(316, 0, "A New Battle"))
    p.align[p:find("STR_PARCHLARGEH_L400")] = "center"
    p.align[p:find("BUTT_DROPLIST170")] = "left"
    local canPay = not act.cost or self.state.crowns >= act.cost
    if not canPay then p:setDisabled("BUTT_OKAY_180", true) end
    self.dialog = { kind = "action", act = act, panel = p, canPay = canPay, races = run.battleRaces(self.state), pick = 1 }
    self:pickRace(1)
end

-- Makes entry `i` of the race list the battle's race (`FUN_005a3390`: the button shows its name).
---@param i integer
function S:pickRace(i)
    local d = self.dialog --[[@as CampaignMapDialog]]
    d.pick = i
    local p = d.panel --[[@as Panel]]
    p:setString("BUTT_DROPLIST170", raceText(d.races[i]))
end

function S:openRaceList()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local names = {}
    for i, race in ipairs(d.races) do names[i] = raceText(race) end
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    dropdown.open(names, mx, my, function(index) self:pickRace(index) end)
end

function S:drawNewBattle()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local act = d.act --[[@as table]]
    local p = d.panel --[[@as Panel]]
    p:draw()
    local x, y = p.x, p.y
    local function row(label, value, ry)
        fonts.print(5, label, x, ry, "right", 173)
        fonts.print(5, value, x + 183, ry)
    end
    -- the cost line of `FUN_005a3450`: free = text 317/1, the action's own text, else "%d Crown(s)" (317/0, 316/7)
    local cost = nbText(317, 1, "-")
    if act.cost and act.cost > 0 then
        if act.costText and act.costText ~= "" then cost = act.costText
        elseif act.cost == 1 then cost = nbText(317, 0, "%d Crown"):format(act.cost)
        else cost = nbText(316, 7, "%d Crowns"):format(act.cost) end
    end
    -- the name of a replayable action carries Game.txt 716 ("   (Replayable)") (`FUN_005a3450`, flag at record + 0xd4); the
    -- strings loader trims the three leading spaces of the file's text, so one space is put back (own choice)
    local name = act.name or ""
    if act.replayable then name = name .. " " .. (require("src.game.strings").get("Game.txt", "0716") or "") end
    row(nbText(316, 1, "Mission Name:"), name, y + 98)
    row(nbText(316, 2, "Cost:"), cost, y + 132)
    row(nbText(316, 3, "Reward:"), rewardText(act), y + 153)
    row(nbText(316, 4, "Difficulty:"), self:difficulty(act, d.races[d.pick]), y + 173)
    fonts.print(5, nbText(316, 5, "Description:"), x, y + 203, "right", 173)
    local cy = y + 203
    for _, l in ipairs(paragraphLines(5, act.description or act.message or "", 390)) do
        fonts.print(5, l, x + 183, cy)
        cy = cy + 20
    end
    fonts.print(5, nbText(316, 6, "Race:"), x, y + 320, "right", 173)
    local note = d.note or (not d.canPay and "You cannot afford the entry fee.") or nil
    if note then fonts.print(2, note, x, y + 380, "center", 696) end
    dropdown.draw()
end

function S:drawActionDialog()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local act = d.act --[[@as table]]
    local st = self.state
    if d.panel then return self:drawNewBattle() end
    local x, y = self:frame(act.name)
    if act.type == "message" then
        line(self, act.message or act.description or "", x + 58, y + 70, 580, 5)
        self:button("cancel", "Close", x + 268, y + 440, 160, 30)
    elseif act.type == "choice" then
        line(self, act.message or "", x + 58, y + 70, 580, 5)
        for i, o in ipairs(act.options) do
            self:button("option", o.label, x + 100 + (i - 1) * 260, y + 440, 220, 30, nil, o.choice)
        end
    elseif act.type == "xp" or act.type == "retinue" then
        local h = line(self, act.message or act.description or "", x + 58, y + 70, 580, 5)
        local cost = act.data and act.data.cost or 0
        local ty = y + 90 + h
        if act.type == "retinue" and act.unit then
            local t = gamedata.army(act.unit.code)
            fonts.print(5, ("%s (level %d)"):format(t and t.name or act.unit.code, act.unit.level), x + 60, ty)
        end
        fonts.print(5, ("Cost: %d Crowns"):format(cost), x + 60, ty + 26)
        fonts.print(2, ("You have %d Crowns."):format(st.crowns), x + 60, ty + 54)
        self:button("buy", act.type == "xp" and "Train" or "Hire", x + 120, y + 440, 160, 30, { disabled = st.crowns < cost })
        self:button("cancel", "Leave", x + 416, y + 440, 160, 30)
        if d.note then fonts.print(2, d.note, x + 58, y + 410, "center", 580) end
    elseif act.type == "mercenary" then
        fonts.print(5, ("You have %d Crowns."):format(st.crowns), x + 58, y + 62)
        fonts.print(2, ("Companies waiting for the next battle: %d of %d"):format(#st.mercs, run.MERC_SLOTS), x + 360, y + 66)
        d.offers = d.offers or run.offers(st, act)
        if #d.offers == 0 then fonts.print(5, "Nobody is looking for work today.", x + 58, y + 100) end
        for i, m in ipairs(d.offers) do
            if i > 5 then break end
            local by = y + 96 + (i - 1) * 62
            love.graphics.setColor(0, 0, 0, 0.35)
            love.graphics.rectangle("fill", x + 58, by, 580, 56, 4, 4)
            love.graphics.setColor(1, 1, 1)
            fonts.print(5, m.name, x + 50, by + 2)
            local parts = {}
            for _, u in ipairs(m.units) do parts[#parts + 1] = u.text end
            fonts.print(2, table.concat(parts, "; "), x + 50, by + 28)
            self:button("hire", ("Hire (%d)"):format(m.cost), x + 530, by + 14, 108, 28,
                        { disabled = st.crowns < m.cost or #st.mercs >= run.MERC_SLOTS }, i)
        end
        self:button("cancel", "Leave", x + 268, y + 440, 160, 30)
    elseif act.type == "item" then
        self:drawShop(x, y)
    end
end

function S:drawShop(x, y)
    local d = self.dialog --[[@as CampaignMapDialog]]
    local act = d.act --[[@as table]]
    local st = self.state
    local h = self:heroObject()
    d.stock = d.stock or run.shopItems(st, act)
    fonts.print(5, ("You have %d Crowns."):format(st.crowns), x + 58, y + 56)
    fonts.print(5, "For sale", x + 58, y + 84)
    fonts.print(5, "Sell your items", x + 366, y + 84)
    local price = act.items and act.items.price or 100
    for i, id in ipairs(d.stock) do
        local it = items.get(id)
        if it then
            local by = y + 110 + (i - 1) * 34
            local hit = self:button("buy_item", ("%s  -  %d"):format(it.name, price), x + 58, by, 316, 30, { disabled = st.crowns < price }, i)
        end
    end
    local sell = act.sell or 40
    local k = 0
    local function sellRow(it, source, index)
        k = k + 1
        if k > 11 then return end
        self:button("sell_item", ("%s  +%d"):format(it.name, sell), x + 366, y + 110 + (k - 1) * 34, 268, 30, nil, { source, index })
    end
    for i, it in ipairs(h.pack) do sellRow(it, "pack", i) end
    for i, id in ipairs(st.stash) do
        local it = items.get(id)
        if it then sellRow(it, "stash", i) end
    end
    self:button("cancel", "Leave", x + 268, y + 440, 160, 30)
    if d.note then fonts.print(2, d.note, x + 58, y + 410, "center", 580) end
end

function S:drawResult()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local act = d.act --[[@as table]]
    local x, y = self:frame(d.won and "Victory!" or "Defeat")
    fonts.print(5, act.name, x, y + 56, "center", 696)
    local ty = y + 92
    local jtext
    for _, j in ipairs(act.journals or {}) do
        if j.type == (d.won and "victory" or "defeat") then jtext = j.text end
    end
    if jtext then ty = ty + line(self, jtext, x + 58, ty, 580, 5) + 10 end
    if d.won and #d.lines > 0 then
        fonts.print(5, "You receive:", x + 58, ty)
        for i, l in ipairs(d.lines) do fonts.print(5, l, x + 60, ty + 24 * i) end
    end
    self:button("resultok", "Continue", x + 268, y + 440, 160, 30)
end

-- The end-of-campaign offer (the original's resign panel, PNL_CAMP_RESIGN): finish now for a reward, or keep playing.
function S:drawResign()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local left = self.state:missionsLeft()
    local x, y = self:frame("Finish the Campaign?")
    local body = (left <= 0) and "You have completed every mission. Do you wish to finish the campaign now?"
        or ("You have finished all but %d of the campaign's missions. Do you wish to finish the campaign now?"):format(left)
    line(self, body, x + 58, y + 70, 580, 5)
    self:button("resign", "Finish", x + 120, y + 440, 160, 30)
    self:button("cancel", "Keep Playing", x + 416, y + 440, 160, 30)
end

-- The ambush dialog (rolled for by the travel start `FUN_0059d7d0`; the panel opens in its slide callback at
-- 0x0059d560, at (57, 35), modal): PNL_CAMPAIGN_AMBUSH with a race drop-down and the Fight button. The drop-down
-- lists the same races as the new-battle dialog (the hero's own first, then every race that is his ally: the loop at
-- 0x0059d607 fills the list at 0x060d79f8 with `FUN_00595470(race) == ally`), starts on the hero's own race, and the
-- picked race plays the battle (`FUN_0059dbf0` hands list[pick] to the battle start `FUN_005a1880`). Unlike the
-- new-battle dialog it has no difficulty line and no reward line.
---@param amb table
function S:openAmbush(amb)
    local p = UI.panel("PNL_CAMPAIGN_AMBUSH", { x = 57, y = 35, onButton = function(name)
        if name == "BUTT_CAMPAIGN_FIGHT" then self:act("fightambush")
        elseif name == "BUTT_DROPLIST170" then self:openRaceList() end
    end })
    ---@cast p -nil
    p:hide("IM_CAMPAIGN_AMBUSH")
    p.align[p:find("BUTT_DROPLIST170")] = "left"
    self.dialog = { kind = "ambush", amb = amb, panel = p, races = run.battleRaces(self.state), pick = 1 }
    self:pickRace(1)
end

-- The ambush dialog's drawing (`FUN_0059db00`; coordinates are screen positions): the ambush's name in
-- FO_LARGE_PARCHLARGEH (36) centred at (400, 180); its description wrapped to 300 px (font 23, FO_SMALL_PARCH, as the
-- original measures it), every line centred at x 400 from y 250, 20 apart, in FO_SMALL_PARCHLIGHT (27); then "Race:"
-- (text 316 / 6, font 34) right-aligned at (309, 359), left of the drop-down.
function S:drawAmbush()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local amb = d.amb --[[@as table]]
    local p = d.panel --[[@as Panel]]
    p:draw()
    fonts.print(36, amb.name or "", 0, 180 - 3, "center", 800)
    local cy = 250
    for _, l in ipairs(paragraphLines(23, amb.description or "", 300)) do
        fonts.print(27, l, 0, cy - 4, "center", 800)
        cy = cy + 20
    end
    fonts.print(34, nbText(316, 6, "Race:"), 0, 359 - 4, "right", 309)
    dropdown.draw()
end

-- Menu dialogs -----------------------------------------------------------------------------------------------

function S:drawJournal()
    local d = self.dialog --[[@as CampaignMapDialog]]
    local g = love.graphics
    local bg = img(BM.JOURNAL)
    local x, y = math.floor((800 - 557) / 2), 40
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 0, 800, 600)
    g.setColor(1, 1, 1)
    if bg then g.draw(bg, x, y) else kit.panel(x, y, 557, 399) end
    fonts.print(1, "Journal", x, y + 12, "center", 557)
    local entries = self.state.journal
    d.scroll = math.max(0, math.min(math.max(0, #entries - 4), d.scroll or 0))
    local cy = y + 60
    local shown = 0
    for i = #entries - (d.scroll or 0), 1, -1 do
        local e = entries[i]
        fonts.print(2, ("Year %d, day %d"):format(e.year, e.day), x + 58, cy)
        if e.video then self:button("journalvideo", "Play video", x + 430, cy - 2, 108, 20, nil, i) end
        cy = cy + 16
        cy = cy + line(self, e.text, x + 58, cy, 480, 2, e.important and { 1, 0.9, 0.6 } or nil) + 12
        shown = shown + 1
        if cy > y + 340 then break end
    end
    if #entries == 0 then fonts.print(5, "Nothing has been written yet.", x + 58, y + 80) end
    self:button("scroll_up", "Newer", x + 58, y + 355, 100, 26, nil, -1)
    self:button("scroll_down", "Older", x + 417, y + 355, 100, 26, nil, 1)
    self:button("cancel", "Close", x + 218, y + 355, 120, 26)
end

function S:drawBonuses()
    local x, y = self:frame("Bonuses")
    local n = 0
    for index = 0, 30 do
        local b = self.D.bonuses[index]
        if b and self.state.bonuses[index] then
            n = n + 1
            fonts.print(5, b.name, x + 50, y + 70 + (n - 1) * 44)
            fonts.print(2, b.description, x + 70, y + 70 + (n - 1) * 44 + 22)
        end
    end
    if n == 0 then fonts.print(5, "You have not collected any bonuses yet.", x + 50, y + 80) end
    self:button("cancel", "Close", x + 268, y + 440, 160, 30)
end

local COLUMNS = { "ally", "friend", "neutral", "enemy" }

-- The diplomacy dialog (`FUN_0059eaf0`: PNL_CAMPAIGN_DIPLOMACY at (52, 58), title text 314 / 2, the
-- Done button): it only lists the sixteen races in four columns by their relation to the hero.
function S:openDiplomacy()
    local p = UI.panel("PNL_CAMPAIGN_DIPLOMACY", { x = 52, y = 58, onButton = function() self:act("cancel") end })
    ---@cast p -nil
    p:hide("IM_CAMPAIGN_DIPLOMACY")
    p.align[p:find("STR_LARGE400")] = "center"
    p:setString("STR_LARGE400", nbText(314, 2, "Diplomacy"))
    self.dialog = { kind = "diplomacy", panel = p }
end

-- The diplomacy dialog's drawing (`FUN_0059ebf0`, screen coordinates): the four headings (texts 315 / 0..3: Ally,
-- Friend, Neutral, Enemy) in font 12 centred at x 155 + 150 x column, y 120; then the races 0..15 in order, each
-- centred in the column of its relation (`FUN_00595470`: 0 ally .. 3 enemy), 20 apart from y 160, in
-- FO_SMALL_PARCHLIGHT (27) with its short race name (texts 277 / 278). No standing numbers are shown.
function S:drawDiplomacy()
    local p = (self.dialog --[[@as CampaignMapDialog]]).panel --[[@as table]]
    p:draw()
    for c = 0, 3 do
        fonts.print(12, nbText(315, c, COLUMNS[c + 1]), 155 + 150 * c - 75, 120 - 4, "center", 150)
    end
    local count = { [0] = 0, 0, 0, 0 }
    for race = 0, 15 do
        local c = 0
        for i, rel in ipairs(COLUMNS) do if rel == self.state:relation(race) then c = i - 1 end end
        fonts.print(27, raceText(race), 155 + 150 * c - 75, 160 + 20 * count[c] - 4, "center", 150)
        count[c] = count[c] + 1
    end
end

function S:drawHero()
    local x, y = self:frame(self.hero.name)
    local h = self:heroObject()
    fonts.print(5, ("%s %s, level %d"):format(classes.RACE_NAMES[self.hero.race], self.hero.class, h.level), x, y + 56, "center", 696)
    local a = h.attr
    fonts.print(5, ("Strength %d    Dexterity %d    Intelligence %d    Charisma %d"):format(a.str, a.dex, a.int, a.cha), x, y + 90, "center", 696)
    fonts.print(2, ("Experience %d / %s"):format(h.xp, h:nextLevelXp() and tostring(h:nextLevelXp()) or "-"), x, y + 118, "center", 696)
    fonts.print(2, ("Unspent points: attributes %d, skills %d"):format(h.points.attr, h.points.skill), x, y + 136, "center", 696)
    fonts.print(5, "Retinue", x + 50, y + 170)
    local row = 0
    for slot = 1, retinueMod.SLOTS do
        local r = self.hero.retinue and self.hero.retinue[slot]
        if r then
            local t = gamedata.army(r.code)
            local name = (r.name and r.name ~= "") and r.name or (t and t.name or r.code)
            fonts.print(2, ("%s, %s (level %d)"):format(name, t and t.name or r.code, (r.level or 0) + 1), x + 70, y + 196 + row * 16)
            row = row + 1
        end
    end
    if row == 0 then fonts.print(2, "You travel alone.", x + 70, y + 196) end
    self:button("graveyard", "Graveyard", x + 50, y + 440, 160, 30)
    self:button("cancel", "Close", x + 268, y + 440, 160, 30)
end

function S:drawStash()
    local x, y = self:frame("Your Item Stash")
    local h = self:heroObject()
    fonts.print(5, "Stash (click to take)", x + 58, y + 56)
    fonts.print(5, "Backpack (click to store)", x + 366, y + 56)
    for i, id in ipairs(self.state.stash) do
        if i > 11 then break end
        local it = items.get(id)
        if it then self:button("take", it.name, x + 58, y + 84 + (i - 1) * 32, 300, 28, nil, i) end
    end
    for i, it in ipairs(h.pack) do
        self:button("store", it.name, x + 366, y + 84 + (i - 1) * 32, 268, 28, nil, i)
    end
    self:button("cancel", "Close", x + 268, y + 440, 160, 30)
    local d = self.dialog --[[@as CampaignMapDialog]]
    if d.note then fonts.print(2, d.note, x, y + 410, "center", 696) end
end

function S:drawHint()
    local x, y = self:frame("Hint")
    local hints = self.state:hints()
    local cy = y + 70
    for _, h in ipairs(hints) do
        for _, l in ipairs(h.lines) do cy = cy + line(self, l, x + 58, cy, 580, 5) + 8 end
        if h.more then
            self:button("morehint", "Tell me more", x + 58, cy, 160, 28, nil, h.index)
            cy = cy + 40
        end
    end
    if #hints == 0 then fonts.print(5, "You are on your own now.", x + 58, y + 80) end
    self:button("cancel", "Close", x + 268, y + 440, 160, 30)
end

local DRAW = {
    location = "drawLocationDialog", moreinfo = "drawMoreInfo", action = "drawActionDialog", result = "drawResult", ambush = "drawAmbush",
    journal = "drawJournal", bonuses = "drawBonuses", diplomacy = "drawDiplomacy", hero = "drawHero", stash = "drawStash",
    hint = "drawHint", resign = "drawResign",
}

function S:draw()
    UI.begin()
    kit.begin(self)
    self.help = ""
    love.graphics.clear(0, 0, 0)
    self:drawMap()
    if self.travel then self:drawTravel() end
    self:drawFrames()
    self:drawMenu()
    if self.dialog then
        self.hits = {}
        self[DRAW[self.dialog.kind]](self)
        fonts.print(5, self.help or "", 15, 578 + fonts.middleY(5, 20), "center", 770)
    end
    UI.finish()
end

-- Cursors: the campaign map shows the standard pointer glove (the menu cursor routine FUN_00456a30): POINTER (the
-- regular glove) over an active object and POINTERDOWN while a press that began on one is held. The map itself is a
-- full-screen button (BUTT_CAMP_FULLSCREEN), so with no dialog or menu open the whole screen counts as active and only
-- those two sprites are seen; the dimmed POINTERUP glove appears over dead areas of dialogs and the menu. The
-- ARROWSWORD / ARROWBOOK cursors of the older province selection screen (no opener in 1.04) need the province file
-- (Data/Etheria.prv, read by FUN_00587c70), which is not in the GOG install, so they are not used.
function S:cursorOver()
    if self.dialog and self.dialog.panel then return UI.panelOver end
    if self.dialog or self.menu then return kit.over(self) end
    return true
end

function S:drawTravel()
    local tr = self.travel --[[@as CampaignMapTravel]]
    local a = math.min(1, tr.t)
    local x = tr.x0 + (tr.x1 - tr.x0) * a - self.camX + VX
    local y = tr.y0 + (tr.y1 - tr.y0) * a - self.camY + VY
    love.graphics.setColor(1, 0.3, 0.2)
    love.graphics.circle("fill", x, y, 5)
    love.graphics.setColor(0, 0, 0)
    love.graphics.circle("line", x, y, 5)
    love.graphics.setColor(1, 1, 1)
end

-- Input -------------------------------------------------------------------------------------------------------

function S:update(dt)
    music.update()
    if self.travel then
        self.travel.t = self.travel.t + dt / 1.1
        if self.travel.t >= 1 then
            local tr = self.travel --[[@as CampaignMapTravel]]
            self.travel = nil
            self:arrive(tr.link)
        end
        return
    end
    if self.dialog or self.menu then return end
    -- the arrow keys move the map 10 / 18 / 26 pixels per key event on a slow / normal / fast scroll rate
    -- (campaign loop, `10 + rate * 8` in the 1.04 binary); openwbc3 scrolls continuously: 380 px/s is "normal"
    local sp = 380 * dt * (10 + run.options(self.state).scrollRate * 8) / 18
    local dx = (love.keyboard.isDown("right") and 1 or 0) - (love.keyboard.isDown("left") and 1 or 0)
    local dy = (love.keyboard.isDown("down") and 1 or 0) - (love.keyboard.isDown("up") and 1 or 0)
    self.camX = math.max(0, math.min(MAP - VW, self.camX + dx * sp))
    self.camY = math.max(0, math.min(MAP - VH, self.camY + dy * sp))
end

-- The campaign menu sounds option (the options dialog): the wavs the campaign dialogs play when they open.
---@param name string
function S:menuSound(name)
    if run.options(self.state).menuSounds ~= 0 then sound.play("Assets/SoundFX.xcr", name) end
end

---@param link table a route of the current location
function S:startTravel(link)
    local cur = self:location()
    local to = self.D.locations[link.to]
    self.dialog = nil
    self.travel = { x0 = cur.x, y0 = cur.y, x1 = to.x, y1 = to.y, t = 0, link = link }
    sound.play("Assets/SoundFX.xcr", "NewClick.wav")
    self:menuSound(link.kind == "Sea" and "Sail.wav" or "Land.wav")        -- FUN_0059d7d0: FUN_00594cb0 land / sail
end

---@param link table
function S:arrive(link)
    local amb = self.state:travel(link)
    local to = self.D.locations[self.state.pendingTravel or self.state.location]
    if amb then
        self:openAmbush(amb)
        self:menuSound("Ambush.wav")
    else
        self:centreOn(self.D.locations[self.state.location])
        self.state:save()
        self.dialog = { kind = "location" }
    end
end

-- Starts the battle of an action or ambush; `race` is the race picked in the new-battle dialog (default: the hero's own).
---@param act table an action or ambush
---@param mapCode string
---@param race integer?
function S:launch(act, mapCode, race)
    local scn, opts = run.setup(self.state, mapCode, nil, race)
    if not scn then
        local d = self.dialog --[[@as CampaignMapDialog]]
        d.note = tostring(opts)
        return
    end
    ---@cast opts table
    profile.setCurrent(self.hero.id)
    opts.title = act.name
    local state = self.state
    opts.victoryExtra = function(won) return run.victoryExtra(act, won) end
    opts.onFinish = function(won)
        self.pendingResult = { act = act, won = won }
    end
    self.dialog = nil
    if act.cost and act.type == "battle" then
        state.crowns = state.crowns - act.cost
    end
    local battle = require("src.screens.battle")
    state:save()
    run.applyResolution(state)       -- the campaign options' game resolution (FUN_005a1880)
    local function start(result)
        local army = {}
        for _, a in ipairs(result and result.army or {}) do army[#army + 1] = a end
        -- the mercenary companies picked in the selection dialog fight in this battle and are disbanded; a battle without
        -- army setup points (no army setup screen, so no selection) takes none along
        for _, a in ipairs(run.takeMercenaries(state, result and result.mercs)) do army[#army + 1] = a end
        state:save()
        opts.army, opts.retinue = army, result and result.retinue
        screens.push(battle, scn, opts)
    end
    if (opts.startPoints or 0) <= 0 then
        start(nil)
        return
    end
    self:openArmySetup(act, opts.startPoints, opts, start)
end

-- Troop selection: army setup points for regular troops, and who of the retinue comes along; in a campaign the extra
-- army points and the mercenary selection open over it.
---@param act table
---@param points integer
---@param opts table?
---@param onDone fun(result: table?)
function S:openArmySetup(act, points, opts, onDone)
    opts = opts or {}
    local rec = profile.get(self.hero.id) or self.hero
    screens.push(require("src.screens.armysetup"), {
        mode = "select", race = opts.race or self.hero.race, points = math.min(retinueMod.MAX_POINTS, points),
        campaign = self.state,
        techLevel = opts.techLevel, noRetinue = opts.noRetinue,
        slots = retinueMod.slotsOf(rec), retinue = retinueMod.get(rec), graveyard = retinueMod.graveyard(rec),
        onDone = onDone,
    })
end

-- The campaign options dialog; a reset starts the hero's campaign afresh (the reset callback at 0x005a4680: the
-- campaign file is deleted and made again, the map goes back to the start).
function S:openOptions()
    screens.push(require("src.screens.campaignoptions"), { state = self.state, onReset = function()
        cstate.delete(self.hero.id)
        local fresh = cstate.new(self.hero.id)
        fresh.introSeen = true
        fresh:save()
        self.state = fresh
        self.dialog, self.menu, self.travel = nil, false, nil
        self:centreOn(self.D.locations[fresh.location])
        return fresh
    end })
end

-- the wav each kind of action dialog plays when it opens (as the original's action dialogs do, menu sounds on)
local ACTION_WAV = { battle = "Battle.wav", message = "message.wav", choice = "message.wav", xp = "xp.wav",
                     retinue = "retinue.wav", mercenary = "Tavern.wav", item = "Merchant.wav" }

---@param act table
function S:openAction(act)
    self:menuSound(ACTION_WAV[act.type] or "message.wav")
    if act.type == "battle" then self:openBattle(act) return end
    self.dialog = { kind = "action", act = act }
end

-- Leaves a dialog the way Escape / Cancel do: sub-dialogs go back to the location popup.
function S:closeDialog()
    local d = self.dialog
    dropdown.close()
    if d and d.kind == "ambush" then return end                -- modal, the Fight button is the only way out
    if d and d.kind == "moreinfo" then
        self.camX, self.camY = d.camX, d.camY
        self.dialog = { kind = "location" }
    elseif d and d.kind == "action" then self.dialog = { kind = "location" }
    else self.dialog = nil end
end

---@param id string the hit id of a button / row
---@param extra any
function S:act(id, extra)
    local st = self.state
    local d = self.dialog --[[@as CampaignMapDialog]]
    if id == "menu" then self.menu = not self.menu return end
    if id == "graveyard" then
        screens.push(require("src.screens.graveyard"), retinueMod.graveyard(profile.get(self.hero.id) or self.hero)) return
    end
    if id:sub(1, 5) == "menu_" then
        self.menu = false
        local what = id:sub(6)
        if what == "exit" then
            st:save()
            screens.pop()
        elseif what == "options" then self:openOptions()
        else
            if what == "diplomacy" then self:openDiplomacy() else self.dialog = { kind = what } end
            -- the stash has its own help, opened when it is shown (the original also re-opens it on F1 there)
            if what == "stash" then require("src.screens.screenhelp").open(6) end
        end
        return
    end
    if id == "resign" then
        -- end the campaign: give the reward, then the credits take over and leave for the main menu (the original
        -- opens the credits after the resign option; its victory video is not in openwbc3's data)
        run.completeCampaign(st)
        screens.push(require("src.screens.credits"), true)
        return
    end
    if id == "close" or id == "cancel" or id == "moreinfo_done" then self:closeDialog()
    elseif id == "act" then self:openAction(self.actionList[extra])
    elseif id == "moreinfo" then self:openMoreInfo()
    elseif id == "fight" then self:launch(d.act, d.act.map, d.races and d.races[d.pick])
    elseif id == "fightambush" then
        local amb = d.amb --[[@as table]]
        self:launch(amb, amb.map, d.races and d.races[d.pick])
    elseif id == "resultok" then
        self.dialog = nil
        if st.pendingVideo then
            local name = st.pendingVideo
            st.pendingVideo = nil
            screens.push(require("src.screens.video"), { name }, nil)
            return
        end
        if st.location ~= (self.D.locations[st.location] and st.location) then end
        self:centreOn(self.D.locations[st.location])
        self.dialog = { kind = "location" }
    elseif id == "option" then
        run.chooseOption(st, d.act, extra)
        self.dialog = { kind = "action", act = { type = "message", name = d.act.name, message = "Your answer is noted." } }
    elseif id == "buy" then
        local cost = d.act.data and d.act.data.cost or 0
        if st.crowns >= cost then
            st.crowns = st.crowns - cost
            if d.act.type == "xp" then
                local h = self:heroObject()
                h:addXp(cost * 5 * math.max(1, h.level))
                self:saveHero(h)
                d.note = "Your training is complete."
            elseif d.act.unit then
                local rec = profile.get(self.hero.id) or self.hero
                retinueMod.give(rec, retinueMod.fresh(d.act.unit.code, d.act.unit.level), retinueMod.slotsOf(rec))
                profile.update(rec)
                self.hero = rec
                d.note = "A new recruit joins your retinue."
            end
            st:save()
        end
    elseif id == "hire" then
        if run.hire(st, d.offers[extra]) then table.remove(d.offers, extra) end
    elseif id == "buy_item" then
        local price = d.act.items and d.act.items.price or 100
        local it = items.get(d.stock[extra])
        if it and st.crowns >= price then
            local h = self:heroObject()
            if h:give(it) then self:saveHero(h) else st.stash[#st.stash + 1] = it.id end
            st.crowns = st.crowns - price
            table.remove(d.stock, extra)
            st:save()
        end
    elseif id == "sell_item" then
        local sell = d.act.sell or 40
        local source, index = extra[1], extra[2]
        if source == "pack" then
            local h = self:heroObject()
            h:drop(index)
            self:saveHero(h)
        else
            table.remove(st.stash, index)
        end
        st.crowns = st.crowns + sell
        st:save()
    elseif id == "take" then
        local h = self:heroObject()
        local it = items.get(st.stash[extra])
        if it and h:give(it) then
            table.remove(st.stash, extra)
            self:saveHero(h)
            st:save()
        else
            d.note = "Your backpack is full."
        end
    elseif id == "store" then
        local h = self:heroObject()
        local it = h:drop(extra)
        if it then st.stash[#st.stash + 1] = it.id self:saveHero(h) st:save() end
    elseif id == "scroll_up" or id == "scroll_down" then d.scroll = (d.scroll or 0) + extra
    elseif id == "journalvideo" then
        -- BUTT_CAMPAIGN_PLAYVIDEO: plays the entry's video again (converted/video/<name>.ogv; skipped when missing)
        local e = st.journal[extra]
        if e and e.video then screens.push(require("src.screens.video"), { e.video }, nil) end
    elseif id == "morehint" then st:moreHint(extra) st:save() end
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if button ~= 1 or self.travel then return end
    if self.dialog and self.dialog.panel then
        if dropdown.pressed(vx, vy) then return end
        self.dialog.panel:mousepressed(vx, vy, button)
        return
    end
    local id, extra = kit.click(self, vx, vy)
    if id then
        sound.play("Assets/SoundFX.xcr", "NewClick.wav")
        self:act(id, extra)
        return
    end
    if self.dialog then return end
    if self.menu then self.menu = false return end
    if vx >= VX and vx < VX + VW and vy >= VY and vy < VY + VH then
        self.drag = { x = vx, y = vy, camX = self.camX, camY = self.camY, moved = false }
    end
end

function S:mousemoved(x, y)
    local vx, vy = UI.toVirtual(x, y)
    if self.dialog and self.dialog.panel then self.dialog.panel:mousemoved(vx, vy) end
    if not self.drag then return end
    local dx, dy = vx - self.drag.x, vy - self.drag.y
    if math.abs(dx) + math.abs(dy) > 4 then self.drag.moved = true end
    if self.drag.moved then
        self.camX = math.max(0, math.min(MAP - VW, self.drag.camX - dx))
        self.camY = math.max(0, math.min(MAP - VH, self.drag.camY - dy))
    end
end

function S:mousereleased(x, y, button)
    if self.dialog and self.dialog.panel then
        local vx, vy = UI.toVirtual(x, y)
        if dropdown.isOpen() then return end
        self.dialog.panel:mousereleased(vx, vy, button)
        return
    end
    if button ~= 1 or not self.drag then return end
    local drag = self.drag --[[@as CampaignMapDrag]]
    self.drag = nil
    if drag.moved then return end
    local vx, vy = UI.toVirtual(x, y)
    for _, m in ipairs(self.markers or {}) do
        if (vx - m.x) ^ 2 + (vy - m.y) ^ 2 <= 14 ^ 2 then
            if m.code == self.state.location then
                self.dialog = { kind = "location" }
            else
                for _, l in ipairs(self:location().links) do
                    if l.to == m.code and self.state:locationOpen(m.code) then self:startTravel(l) return end
                end
                self.help = "You cannot travel there directly."
            end
            return
        end
    end
end

function S:keypressed(key)
    if key == "escape" then
        if dropdown.isOpen() then dropdown.close()
        elseif self.dialog then self:closeDialog()
        elseif self.menu then self.menu = false
        else self:act("menu") end
    elseif key == "space" or key == "return" then
        if not self.dialog then self.dialog = { kind = "location" } end
    end
end

function S:leave() if self.state then self.state:save() end end

return S
