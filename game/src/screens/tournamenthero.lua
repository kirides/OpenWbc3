-- Tournament mode: the hero creation every human player goes through after the game was started (the advanced option
-- "Tournament mode", points = the tournament level). Binary (1.04): the game-started handler `FUN_004e2660` (the host's
-- start message, tournament flag set and No Heroes clear) closes the lobby panels and opens hero creation with the
-- temporary flag and the points (`FUN_0054b040`): the same PNL_CREATEHERO screen as for a new profile hero (name,
-- race, class, "Customize..." for portrait, avatar, password, voice set; the mode list is greyed) with Cancel greyed
-- (button states `FUN_0054b620`) and no screen help of its own. OK (`FUN_0054bbd0`) refuses a name that is in the hero
-- book (texts 3 / 5..7, the check in front of the call is not exempt for temporary heroes), makes the hero at the
-- tournament level with the experience of that level, does NOT save it (the hero save `FUN_0044fef0` runs only for a
-- profile hero) and opens the level-up screens with the level as the points (`FUN_00552d90(TRUE, level)`, then `FUN_005522e0`):
-- screens/levelup.lua, standalone. The battle then starts (`FUN_004e2790`).
-- enter(onDone, points): onDone(rec) gets the temporary hero record (profile.lua: `temporary`), see profile.setTemporary.
local screens = require("src.core.screens")
local classes = require("src.game.classes")
local heroMod = require("src.game.hero")
local advanced = require("src.game.advanced")
local herocustom = require("src.game.herocustom")
local heroselect = require("src.screens.heroselect")
local profile = require("src.game.profile")
local UI = require("src.ui.interface")

-- The hero creation of heroselect.lua (the metatable falls back to it) with the methods below overridden; the class says
-- so (without it the language server takes S for the heroselect table itself and reports every override as a duplicate).
---@class TournamentHeroScreen: HeroSelectScreen
---@field onDone fun(rec: table)?    gets the temporary hero's record
---@field points integer             the tournament level
local S = setmetatable({}, { __index = heroselect })
S.__index = S
S.helpId = 2                -- F1 shows the hero creation help (screen help 2) ...
S.noFirstHelp = true        -- ... but it does not open by itself (`FUN_0054b040` calls the screen help
                            -- `FUN_00448870(2, 0)` only without the temporary flag)

---@param onDone fun(rec: table)?
---@param points integer
function S:enter(onDone, points)
    self.onDone, self.points = onDone, points
    self.list = profile.list()          -- the hero book: a temporary hero may not take a name that is in it
    self.index = 1
    self.notice = nil
    self:startNew()
end

function S:startNew()
    self.mode = "new"
    self.new = { name = "", race = 0, class = "Warrior", password = "", heroMode = 0, tournament = true }
    self:setRace(0)
    self:buildCreatePanel()
end

function S:buildCreatePanel()
    heroselect.buildCreatePanel(self)
    if self.cpanel then self.cpanel:setDisabled("BUTT_CANCEL_STARTUP", true) end
end

-- There is no way back from the creation of a Tournament hero.
function S:act(id, extra)
    if id == "cancelnew" then return end
    heroselect.act(self, id, extra)
end

-- The temporary hero as a profile record: nothing of it is written (profile.lua `temporary`).
---@param name string
---@param h table the hero's save
---@return table rec
function S:record(name, h)
    local n = self.new
    return { id = "tournament", temporary = true, name = name, race = n.race, class = n.class, portrait = n.portrait,
             voice = n.voice, avatar = n.avatar, password = "", mode = 0, battles = 0, hero = h }
end

function S:create()
    local n = self.new
    local name = n.name:match("^%s*(.-)%s*$")
    if name == "" then return end
    for _, h in ipairs(self.list) do
        if h.name:lower() == name:lower() then
            self.notice = ("%s %s %s"):format(UI.text(3, 5) or "Hero Already Exists!", UI.text(3, 6) or "", UI.text(3, 7) or "")
            return
        end
    end
    local save = classes.newHero(n.class, n.race)
    local attr, skill = advanced.tournamentPoints(self.points)
    save.level, save.tournament, save.xp = self.points, true, heroMod.xpFor(self.points)
    save.points = { attr = attr * heroMod.ATTR_POINTS, skill = skill }
    local hero = heroMod.new(nil, save)
    screens.push(require("src.screens.levelup"), nil, {
        hero = hero, name = name, avatar = herocustom.AVATAR_CODES[n.avatar], always = true,
        onDone = function()
            local rec = self:record(name, hero:save())
            screens.pop()               -- this screen
            if self.onDone then self.onDone(rec) end
        end,
    })
end

return S
