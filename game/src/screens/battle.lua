-- Battle screen: map view, selection and orders, the original control panel
-- (src/ui/hud.lua), fog of war, events and the end of game.
local screens = require("src.core.screens")
local world_ = require("src.game.world")
local sprite = require("src.formats.sprite")
local gamedata = require("src.game.gamedata")
local economy = require("src.game.economy")
local fonts = require("src.ui.fonts")
local voices = require("src.audio.voices")
local sound = require("src.audio.sound")
local music = require("src.audio.music")
local cursor = require("src.ui.cursor")
local keymap = require("src.ui.keymap")
local unitMod = require("src.game.unit")
local speech = require("src.audio.speech")
local walls = require("src.game.walls")
local l10n = require("src.game.l10n")

local A = sprite.ANIM
local CW, CH = 32, 24

---@class BattleScreen: Screen
---@field scn table                      the scenario (formats/scn.lua)
---@field scnPath string?                where the scenario came from, for saved games
---@field random table?                  how a random map is made again (randommap.build), for saved games
---@field result BattleResult?          the outcome once the battle is over
---@field onFinish fun(won: boolean)?     called when the screen is left
---@field victoryExtra table?            campaign: the action's extra XP and reward text for the victory screen
---@field title string?
---@field victoryRule string|integer|nil  the world's victory rule (victory.lua)
---@field net Session?                   lockstep session of a network game
---@field netSeed integer?
---@field netStats {rows: table, t: number}?  the network statistics overlay
---@field desyncShown boolean?
---@field lostShown boolean?
---@field ironmanDeleted boolean?
---@field world World
---@field fog Fog
---@field fogMode integer                1 normal, 2 explored, 3 off, 4 hidden only
---@field hud HUD
---@field fx table                       decals, particles, lights, floating text (gfx/battlefx.lua)
---@field wfx table?                     weather effects (ui/weatherfx.lua)
---@field announcer table                system speech (audio/speech.lua)
---@field minimap love.Image?
---@field zoom number
---@field camX number
---@field camY number
---@field restoreCamera {x: number, y: number, zoom: number?}?  set by savegame.apply before the camera starts
---@field restoreRadius any                 set by savegame.apply: the restored showRadius
---@field showRadius any                    the entity whose range circle is shown (F-key debug)
---@field selection (Unit|Building)[]
---@field groups table<integer, (Unit|Building)[]>  control groups 0..9
---@field paused boolean
---@field showGrid boolean
---@field showCommandQueue boolean
---@field notices {text: string, t: number, d: number, side: integer?}[]
---@field demo boolean?
---@field demoOrdered boolean?
---@field scripts {t: number, code: string}[]   `--at <s> "<lua>"` dev scripts still to run
---@field clock number                   seconds since the battle screen opened
---@field heroKillCount integer
---@field heroicLevel integer
---@field availability {buildings: table<string, any>, armies: table<string, any>}?
---@field availCheck number?
---@field convQueue table[]?             conversations waiting to be shown
---@field convertMarks table<Unit|Building, (Unit|Building)[]>?
---@field breathAt number?
---@field breathWav number?
---@field wallDrag WallDrag?             a wall being dragged out (game/walls.lua)
---@field sparks {x: number, y: number, t: number, colour: table}?
---@field dragStart number[]?            screen position where a selection box started
---@field lastClick {t: number, e: Unit|Building}?
---@field sites {x: number, y: number}[]?   recent event positions, newest first
---@field siteTime number?
---@field siteIndex integer?
---@field infoBox {gx: integer, gy: integer, t0: number}?
---@field chat {text: string, mode: "all"|"allies"|"enemies"}?
---@field totals table?
---@field totalsAt number?
---@field tickAcc number?               real seconds not yet run as a simulation tick (S:stepWorld)
local S = {}

-- The outcome of a battle, made by the "gameover" event; the victory, results, level-up and retinue screens read it.
---@class BattleResult
---@field won boolean
---@field t number                     when it was decided (love.timer), or when the fanfare ended
---@field pending love.Source?         the victory / defeat fanfare still playing
---@field shown boolean?               the victory screen was opened
---@field xp number?                   the local hero's experience of the battle (battlexp.finish)
---@field heroRemoved boolean?         a dead Ironman hero
---@field games integer?               the hero's battle count after this one
---@field endHero Hero|false|nil       the local hero once the battle is decided (`endHero`), false: none
---@field levelsDue integer?
---@field levelsGained integer?
---@field levelsSettled boolean?
---@field retinue table?             race, profileRace, recruits, slots: for the retinue screen
---@field recruited boolean?

S.noStandardCursor = true
S.ownCursor = true      -- the battle view draws the map cursors (FUN_00420390), not the standard pointer hand

---@param scn table   the scenario (formats/scn.lua)
---@param opts table? player, humans, heroes, net, seed, restore, scripts, demo, onFinish ... (see the body)
function S:enter(scn, opts)
    opts = opts or {}
    require("src.ui.interface").inGame = true
    self.scn = scn
    self.result = nil                        -- the screen table is reused: drop the previous battle's outcome
    self.announcer = speech.announcer(love.timer.getTime())
    voices.reset()
    self.heroKillCount, self.heroicLevel = 0, 49       -- FUN_00518a10: heroic effort at the 50th hero kill, then every 50
    self.availability = nil                            -- the buildings / armies the side can raise (new-available lines)
    self.scnPath = opts.scnPath
    self.random = opts.random                -- how a random map is made again (randommap.build), for saved games
    self.onFinish = opts.onFinish
    self.victoryExtra = opts.victoryExtra          -- campaign: the action's extra XP and reward text for the victory screen
    self.net = opts.net                      -- lockstep session of a network game
    self.netSeed = opts.seed
    -- Tournament mode: the hero made on the creation screens is the local hero for this battle and never reaches the profile
    if opts.tournamentRec then require("src.game.profile").setTemporary(opts.tournamentRec) end
    if opts.seed then math.randomseed(opts.seed) end
    self.world = world_.new(scn, { player = opts.player or 0, humans = opts.humans, heroes = opts.heroes, net = opts.net ~= nil, resurrect = opts.resurrect, campaign = opts.campaign,
                                   profile = opts.profile, heroRace = opts.heroRace, restore = opts.restore, startPoints = opts.startPoints, tutorial = opts.tutorial,
                                   quests = opts.quests, night = opts.night, randomWeather = opts.randomWeather, victory = opts.victory, techLevel = opts.techLevel, mods = opts.mods, bonuses = opts.bonuses,
                                   retinue = opts.retinue, army = opts.army, armies = opts.armies, difficulty = opts.difficulty, heroLevel = opts.heroLevel, sideHeroes = opts.sideHeroes, advanced = opts.advanced,
                                   fogMode = opts.fogMode or 1 })
    self.fogMode = opts.fogMode or 1
    -- the hero's games with this race, which the campaign's AI level reads (FUN_004e2790 counts it when a battle is set up)
    if opts.profile and not opts.restore and not opts.demo then
        require("src.game.profile").addRaceGame(self.world.sides[self.world.player].race)
    end
    self.world.ai = require("src.game.ai").new(self.world)
    self.fog = require("src.game.fog").new(self.world, self.world.player)
    self.world.fog = self.fog
    if self.fogMode == 4 then self.fog.dim = 0; self.fog.hiddenOnly = true end
    if self.fogMode == 3 then self.fog.enabled = false
    elseif self.fogMode == 2 then
        local ffi = require("ffi")
        ffi.fill(self.fog.explored, self.fog.w * self.fog.h, 1)
        self.fog.uncovered = true
    end
    if opts.restore then require("src.game.savegame").apply(self, opts.restore) end
    -- the game speed picked in the setup (opts.gameSpeed 0..4; the original starts a game at that + 1 of its timer steps);
    -- without one the options screen's Game Speed counts, except in a network game, where the host's pick is sent to
    -- everybody and the speed keys do nothing. A saved game keeps its own (savegame.apply).
    if not opts.restore then
        local gameopts = require("src.core.gameopts")
        self.world.speed = opts.gameSpeed and gameopts.SPEEDS[opts.gameSpeed + 1] or (not opts.net and gameopts.gameSpeed()) or 1
    end
    self.fog:recompute()
    self.hud = require("src.ui.hud").new(self)
    self.hud:layout()
    self.zoom = 1
    self.selection = {}
    self.groups = {}
    self.paused = false
    self.showGrid = false
    self.showCommandQueue = false
    self.notices = {}
    self.demo = opts.demo
    self.scripts = opts.scripts or {}
    self.clock = 0
    self.world:listen(function(kind, a, b, c, d) self:onEvent(kind, a, b, c, d) end)
    self.fx = require("src.gfx.battlefx").new(self)       -- decals, particles, lights, floating text, footsteps
    -- start the camera on the player's hero / start position
    local side = self.world.sides[self.world.player]
    local fx, fy
    for _, u in ipairs(self.world.units) do
        if u.side == self.world.player then fx, fy = u.x, u.y break end
    end
    if not fx and side and side.startX >= 0 then fx, fy = side.startX * CW, side.startY * CH end
    fx, fy = fx or self.world.terrain.pixelW / 2, fy or self.world.terrain.pixelH / 2
    self:centreOn(fx, fy)
    if self.restoreCamera then
        self.zoom = self.restoreCamera.zoom or 1
        self.camX, self.camY = self.restoreCamera.x, self.restoreCamera.y
        self:clampCamera()
    end
    self.showRadius = self.restoreRadius or nil
    self:buildMinimap()
    music.play("battle")
    cursor.enable(true)
    self.title = opts.title --[[@as string?]]
    self.victoryRule = self.world.victoryRule
    require("src.core.log").info("advanced options: %s; game speed x%.2f",
        table.concat(require("src.game.advanced").active(self.world.advanced), ", "), self.world.speed)
    -- Tournament mode: points the temporary hero left unspent on its creation screens (OK works with points left, the
    -- original keeps them) are still to spend: the dialog opens first, the scenario information (pushed after it) shows on top
    local mine = self.world.eco:heroAlive(self.world.player)
    if mine and mine.h and mine.h.tournament and not opts.restore and mine.h:pending() > 0 and not opts.demo then
        screens.push(require("src.screens.levelup"), self)
    end
    if not (opts.noInfo or opts.restore or opts.demo or self.net) then self:openInfo(true) end
end

-- The player's hero as the conversation conditions see it (race, class) and speak it (name, portrait).
function S:heroIdentity()
    local side = self.world.sides[self.world.player]
    local rec = self.world.opts.profile and require("src.game.profile").current()
    if rec and rec.race ~= side.race then rec = nil end
    return { race = side.race, class = rec and rec.class, name = rec and rec.name or "", portrait = rec and rec.portrait or side.race }
end

-- Opens the conversations the scenario events asked for, one after the other (a network game cannot be held
-- up by a dialog, so there only the flags a conversation sets are applied).
function S:startConversations()
    local queue = self.convQueue
    if not queue or #queue == 0 then return end
    local name = table.remove(queue, 1)
    local conv = require("src.game.conversation").load(name)
    if not conv then return end
    if self.net then
        self:conversationDone(conv)
    else
        screens.push(require("src.screens.conversation"), self, conv, self:heroIdentity())
    end
end

function S:conversationDone(conv)
    if conv.flag then self.world.events:setFlag(conv.flag) end
end

-- Scenario information (mission text, victory condition, special rules). `automatic` is the popup at the
-- start of a battle, which stays away when there is nothing to say; Alt+I always opens it. A network game
-- cannot be held up by a dialog, so there the text goes to the message list.
function S:openInfo(automatic)
    local info = require("src.game.scenarioinfo").build(self.scn, { scnPath = self.scnPath, title = self.title,
                                                                    victory = self.victoryRule })
    if automatic and not info.any then return end
    if self.net then
        self:notify(info.heading, 8)
        for _, l in ipairs(info.text or {}) do self:notify(l, 8) end
        for _, l in ipairs(info.rules) do self:notify(l, 8) end
        return
    end
    screens.push(require("src.screens.rulesdialog"), self, info)
end

function S:leave()
    require("src.game.profile").setTemporary(nil)
    require("src.ui.interface").inGame = false
    cursor.enable(false)
    if self.wfx then self.wfx:stop() end
    require("src.audio.footsteps").stop()
    require("src.audio.ambience").stop()
    require("src.audio.heartbeat").stop()
    if self.net then self.net:close() self.net = nil end
    if self.onFinish then
        local finish = self.onFinish
        ---@cast finish -nil
        self.onFinish = nil
        finish(self.result and self.result.won or false)
    end
    self:saveProfile()
end

-- The player's hero is kept between skirmishes (a slain hero falls back to the
-- start of its level).
function S:saveProfile()
    local world = self.world
    if not world.opts.profile or self.ironmanDeleted then return end
    local side = world.sides[world.player]
    local hero = world.eco:heroAlive(world.player)
    local profile = require("src.game.profile")
    if hero and hero.h and hero.h.tournament then return end             -- a Tournament hero is never kept (FUN_0044fef0)
    local race = world:profileRace(world.player)
    if hero and hero.h then profile.save(race, hero.h)
    elseif side.fallenHero and not side.fallenHero.tournament then
        local h = require("src.game.hero").new(nil, side.fallenHero)
        profile.save(race, h)
    end
end

---@param tab integer?
---@param levelup boolean?
function S:openHero(tab, levelup)
    local hero = self.world.eco:heroAlive(self.world.player)
    if levelup and hero and hero.h:pending() > 0 and hero.h.latch then
        screens.push(require("src.screens.levelup"), self)
    else
        if levelup and hero and hero.h.latch then self:heroOp("levelDone") end      -- nothing to spend: the click clears it
        screens.push(require("src.screens.heroinfo"), self, tab)
    end
end

function S:saveGame(slot)
    if not self.scnPath then return false end
    local savegame = require("src.game.savegame")
    return savegame.write(slot, savegame.snapshot(self))
end

-- A hero reached a shrine, mausoleum or shop.
function S:openSite(hero, b)
    if b.shop then
        screens.push(require("src.screens.shop"), self, hero, b)
    elseif b.quest then
        local info = require("src.game.quests").visit(self.world, hero, b)
        if info then
            screens.push(require("src.screens.questdialog"), self, info, hero, b)
        else
            -- the original's message when the shrine has nothing to offer
            local strings = require("src.game.strings")
            local text = strings.get("Game.txt", "0187")
            if text then self:notify(text, 4) end
        end
    end
end

function S:openChooseFoe()
    screens.push(require("src.screens.choosefoe"), self)
end

function S:openSpells()
    local hero = self.world.eco:heroAlive(self.world.player)
    if hero and hero.h then screens.push(require("src.screens.spellbook"), self) end
end

function S:openMenu()
    screens.push(require("src.screens.gamemenu"), self)
end

-- The sound of a scenario event: a loose file in Data/ or an entry of the sound archives.
function S:playEventSound(name, ef)
    local file = name:lower():match("%.wav$") and name or name .. ".wav"
    local lang = require("src.core.config").language
    local opts = { volume = (ef and ef.number == 1) and 1 or nil }
    if ef and ef.type == 1 then
        local gx, gy = ef.x, ef.y
        local vw, vh = self:viewSize()
        opts.volume = 1 - math.min(1, math.max(math.abs(gx - (self.camX + vw / 2) / CW), math.abs(gy - (self.camY + vh / 2) / CH)) / 24)
    end
    for _, arch in ipairs({ "Assets/SoundFX.xcr", "CampaignSpeech.xcr", "GameSpeech.xcr" }) do
        if sound.exists(arch, file) then
            sound.play(arch, file, opts)
            return
        end
    end
    sound.playFile(require("src.core.config").gamedir .. "/Data/" .. file, opts)
end

function S:resume()
    cursor.enable(true)
    if self.result and self.result.shown then               -- back from the results screen or a level-up screen
        if not self:openLevelUps() and not self:openRecruiting() then screens.pop() end
    end
end

-- The local hero once the battle is decided: the unit's hero while it lives, else an object made from the saved record of
-- the fallen hero (written back by `storeEndHero`), so that the level counting, the level-up screens and the profile all
-- work on one state. nil without a hero.
function S:endHero()
    local result, world = self.result, self.world
    ---@cast result -nil                    -- called once the battle is decided
    if result.endHero == nil then
        local hero = world.eco:heroAlive(world.player)
        local rec = world.sides[world.player].fallenHero
        result.endHero = hero and hero.h or (rec and require("src.game.hero").new(nil, rec)) or false
    end
    return result.endHero or nil
end

function S:storeEndHero()
    local h = self:endHero()
    if h and not h.unit then self.world.sides[self.world.player].fallenHero = h:save() end
end

-- What the victory screen says about levels (binary FUN_00455b40, run while the screen is built): the points the hero still
-- has to spend count as levels gained, plus the levels the battle's experience owes it (`Hero:levelsDue`, at most four, the
-- levels themselves follow with Continue, `openLevelUps`). Not for a hero that is removed (Ironman), frozen, temporary or in
-- a game without heroes, nor in the tutorial.
function S:prepareLevels()
    local result, world = self.result, self.world
    ---@cast result -nil                    -- called once the battle is decided
    if result.heroRemoved or self.ironmanDeleted or world.opts.tutorial or (world.mods or {}).noHeroes then return end
    local h = self:endHero()
    if not h or h.frozen or h.tournament then return end
    local pending = math.max(h.points.attr, h.points.skill)
    result.levelsDue = h:levelsDue()
    result.levelsGained = math.max(0, pending) + result.levelsDue
end

-- Continue on the victory screen (binary 0x004546F0): the hero gets the levels counted for it, then the attribute screen
-- opens while attribute points are left, the skill screen while skill points are left, and only then the retinue
-- screen (`openRecruiting`). Returns whether a level-up screen was opened.
function S:openLevelUps()
    local result, world = self.result, self.world
    ---@cast result -nil                    -- called once the battle is decided
    if result.levelsSettled or not result.levelsDue then return false end
    result.levelsSettled = true
    local h = self:endHero()
    if not h then return false end
    h:applyLevels(result.levelsDue)
    h.latch = nil
    self:storeEndHero()
    self:saveProfile()
    if h.points.attr <= 0 and h.points.skill <= 0 then return false end
    local rec = world.opts.profile and require("src.game.profile").current()
    local unit = world.eco:heroAlive(world.player)
    screens.push(require("src.screens.levelup"), self, {
        hero = h, name = rec and rec.name or unit and unit.name or "Hero", avatar = world:heroCode(world.player),
        beforePop = function() self:storeEndHero() self:saveProfile() end,       -- the spent points are kept at once
    })
    return true
end

-- After a battle of a hero's own: the retinue screen in recruiting mode (the original opens it after the victory
-- screen FUN_00454b70 and the level-up screens). Returns whether it was opened; the battle closes when it is done.
function S:openRecruiting()
    local result = self.result
    ---@cast result -nil                    -- called once the battle is decided
    local info = result.retinue
    if not info or result.recruited then return false end
    result.recruited = true
    local profile = require("src.game.profile")
    local rec = profile.recordFor(info.profileRace)
    if not rec then return false end
    screens.push(require("src.screens.armysetup"), {
        mode = "recruit", race = info.race, slots = info.slots, retinue = require("src.game.retinue").get(rec),
        recruits = info.recruits, graveyard = require("src.game.retinue").graveyard(rec), team = 1,
        onDone = function(chosen)
            local fresh = profile.recordFor(info.profileRace)      -- the hero was saved meanwhile (profile.save keeps the rest)
            if fresh then
                fresh.retinue = chosen.retinue
                profile.update(fresh)
            end
        end,
    })
    return true
end

-- The end of a battle of the player's own hero (battle end FUN_0041c520, recruit list FUN_0043f3e0): the members of
-- the retinue that fell go to the graveyard, the others keep what they learned, and the survivors that qualify become
-- recruits for the retinue screen. Not for a Tournament hero (it is temporary), a hero that was removed (Ironman) or the tutorial.
function S:settleRetinue(removed)
    local world = self.world
    local profile = require("src.game.profile")
    local retinue = require("src.game.retinue")
    local me = world.player
    local side = world.sides[me]
    if not world.opts.profile or world.opts.tutorial or self.ironmanDeleted or removed or world.retinueSettled then return end
    world.retinueSettled = true
    local hero = world.eco:heroAlive(me)
    if hero and hero.h and hero.h.tournament then return end
    local rec = profile.recordFor(world:profileRace(me))
    if not rec then return end
    local alive = {}
    for _, u in ipairs(world.units) do
        if u.side == me and u.retinueIndex and u:alive() then alive[u.retinueIndex] = { level = u.level or 0, xp = u.xp or 0 } end
    end
    local roll = math.random(0, 9)
    -- the general of the recruits is the HERO's race's (`FUN_0043f3e0` reads the hero record's race at 0x00709cfc, not the
    -- side's: a campaign battle played with an allied race, a skirmish seat of another race)
    local recruits = retinue.recruits(retinue.collect(world, me), { race = world:heroRaceOf(me) or side.race,
        short = world.time < 300000, roll = roll, nameOf = retinue.nameFor,
        pitched = require("src.game.victory").get(world.victoryRule, "pitched") == true })
    -- a random map is "Random" in the graveyard (the graveyard's FUN_0054f980 compares the stored name with XCI text 83)
    retinue.settle(rec, { brought = world.brought[me] or {}, alive = alive, fallen = world.fallen[me],
                          scenario = self.random and require("src.ui.interface").text(83, 0)
                              or self.title or (self.scn.header and self.scn.header.name) or "" })
    profile.update(rec)
    self.result.retinue = { race = side.race, profileRace = world:profileRace(me), recruits = recruits, slots = retinue.slotsOf(rec) }
end

-- Geometry ------------------------------------------------------------------------

function S:scale()
    return (self.hud.base or 1) * self.zoom
end

function S:viewSize()
    local w = love.graphics.getWidth()
    local s = self:scale()
    return w / s, (self.hud.mapBottom or love.graphics.getHeight()) / s
end

function S:clampCamera()
    local vw, vh = self:viewSize()
    local t = self.world.terrain
    self.camX = math.max(0, math.min(self.camX, t.pixelW - vw))
    self.camY = math.max(0, math.min(self.camY, t.pixelH - vh))
end

---@param wx number
---@param wy number
function S:centreOn(wx, wy)
    local vw, vh = self:viewSize()
    self.camX, self.camY = wx - vw / 2, wy - vh / 2
    self:clampCamera()
end

---@param sx number
---@param sy number
---@return number wx, number wy
function S:toWorld(sx, sy)
    local s = self:scale()
    return sx / s + self.camX, sy / s + self.camY
end

function S:buildMinimap()
    local mm = self.scn.minimap
    if not mm or #mm < 128 * 128 * 3 then return end
    local img = love.image.newImageData(128, 128)
    for y = 0, 127 do
        for x = 0, 127 do
            local o = (y * 128 + x) * 3 + 1
            local b, g, r = mm:byte(o, o + 2)
            img:setPixel(x, y, r / 255, g / 255, b / 255, 1)
        end
    end
    self.minimap = love.graphics.newImage(img)
end

function S:teamColor(side)
    local s = self.world.sides[side]
    return s and s.color or 6
end

---@param text string
---@param seconds number?  how long it shows (default 4)
---@param side integer?
function S:notify(text, seconds, side)
    self.notices[#self.notices + 1] = { text = text, t = love.timer.getTime(), d = seconds or 4, side = side }
    if #self.notices > 5 then table.remove(self.notices, 1) end
end

-- Events ----------------------------------------------------------------------------

local SYSTEM = speech.SYSTEM

-- The announcer (FUN_0050f1b0; rules in src/audio/speech.lua): plays System[F]<n>.wav for the local player and returns
-- whether it did.
---@param n integer  System<n>.wav (speech.SYSTEM)
---@return boolean played
function S:systemSpeech(n)
    local limit
    if n == SYSTEM.tooManyMen then limit = select(2, self.world.eco:armyLimit(self.world.player)) end
    if not self.announcer:request(n, love.timer.getTime(), limit or 0) then return false end
    -- the options screen's System Voice: female ("SystemF<n>.wav", the default) or male; female ships in English
    -- only, so fall back to the male file when the current language lacks it
    local female = require("src.core.gameopts").systemVoiceFemale()
    local name = ("System%s%d.wav"):format(female and "F" or "", n)
    if not sound.exists("GameSpeech.xcr", name) then name = ("System%d.wav"):format(n) end
    return sound.play("GameSpeech.xcr", name, { voice = true }) ~= nil
end

-- Whether side `i` is an ally of the local player (same team; the neutral side is nobody's ally).
---@param i integer
---@return boolean
function S:isAlly(i)
    local world = self.world
    return i ~= world.player and i ~= 6 and world.sides[i] ~= nil and not world:enemies(world.player, i)
end

-- The view in cells: left, top, width, height (the width getter is FUN_00490940).
function S:viewCells()
    local vw, vh = self:viewSize()
    return self.camX / CW, self.camY / CH, vw / CW, vh / CH
end

-- Where the side's base is: its highest-level keep, else its start position.
function S:baseCell()
    local world = self.world
    local me = world.player
    local best, bx, by = -1, nil, nil
    for _, b in ipairs(world.buildings) do
        if b.side == me and b.hp > 0 and economy.isKeep(b.code) then
            local level = tonumber(b.code:sub(4, 4)) or 0
            if level > best then best, bx, by = level, b.gx, b.gy end
        end
    end
    if best < 0 then
        local sd = world.sides[me]
        bx, by = sd.startX, sd.startY
    end
    return bx, by
end

-- A unit of the local player was hit (the army hit reaction FUN_00522860, "Notification Sounds"): only when it is
-- outside the view. A hero below 50 hit points is "near death", a hero hit for 2 or more "under attack", a troop hit
-- for 2 or more by an enemy "troops under attack".
function S:unitHit(u, attacker, dmg)
    local left, top, w, h = self:viewCells()
    if u.gx >= left and u.gx <= left + w and u.gy >= top and u.gy <= top + h then return end
    local played
    if u.hero then
        if u.hp - dmg < 50 then
            played = self:systemSpeech(SYSTEM.heroNearDeath)
        elseif dmg > 1 then
            played = self:systemSpeech(SYSTEM.heroUnderAttack)
        end
    elseif dmg > 1 and attacker and attacker.side ~= self.world.player then
        played = self:systemSpeech(SYSTEM.troopsUnderAttack)
        if played then self:notify(l10n.own("Your forces are under attack!"), 3) end
    end
    if played then self:logSite(u.x, u.y) end
end

-- A building of the local player was hit by an enemy (hit reaction FUN_0052b180): outside the view by more than
-- ten cells; near the base (within 20 cells of its keep) "base under attack", elsewhere "buildings under attack",
-- both for hits of 2 or more.
function S:buildingHit(b, dmg)
    if dmg <= 1 then return end
    local left, top, w, h = self:viewCells()
    if not (b.gx < left - 10 or b.gx > left + w + 10 or b.gy < top - 10 or b.gy > top + h + 10) then return end
    local bx, by = self:baseCell()
    local near = bx and b.gx > bx - 20 and b.gx < bx + 20 and b.gy > by - 20 and b.gy < by + 20
    if self:systemSpeech(near and SYSTEM.baseUnderAttack or SYSTEM.buildingsUnderAttack) then self:logSite(b.x, b.y) end
end

-- A keep starts converting (net message 541, FUN_004af380): when the keep is out of the view and buildings of the local
-- player are within its reach the announcer warns, "base under attack" when the keep is within 20 cells of the base,
-- else "buildings under attack". The original also shows the conversion warning text 1161, which the 1.04
-- text files do not contain, so only the voice plays.
function S:keepConverting(keep)
    local world = self.world
    if keep.side == world.player or not keep.convert then return end
    local mine = false
    for _, b in ipairs(world.eco:conversionList(keep.side, keep.gx, keep.gy, keep.convert.range)) do
        if b.side == world.player then mine = true break end
    end
    if not mine then return end
    local left, top, w, h = self:viewCells()
    if keep.gx >= left and keep.gx <= left + w and keep.gy >= top and keep.gy <= top + h then return end
    local bx, by = self:baseCell()
    local near = bx and keep.gx > bx - 20 and keep.gx < bx + 20 and keep.gy > by - 20 and keep.gy < by + 20
    if self:systemSpeech(near and SYSTEM.baseUnderAttack or SYSTEM.buildingsUnderAttack) then self:logSite(keep.x, keep.y) end
end

-- "Need more gold / stone / metal / crystal" for the first resource of `cost` the local player is short of, in the
-- order the original checks them (crystal, metal, gold, stone).
function S:needMore(resource)
    local id = speech.NEED[resource]
    if id then self:systemSpeech(id) end
end

-- New armies / buildings available (the dependency counter FUN_0040b350): checked about once a second, like the
-- original after every dependency gain (a finished building, upgrade, conversion or bought power-up). The first
-- check of a battle only records what is available.
function S:checkAvailability(now)
    local world = self.world
    if world.over or world.opts.tutorial then return end
    if self.availCheck and now - self.availCheck < 1 then return end
    self.availCheck = now
    local buildings, armies = world.eco:available(world.player)
    local old = self.availability
    self.availability = { buildings = buildings, armies = armies }
    if not old then return end
    local newB, newA = false, false
    for code in pairs(buildings) do if not old.buildings[code] then newB = true end end
    for code in pairs(armies) do if not old.armies[code] then newA = true end end
    if newB and newA then self:systemSpeech(SYSTEM.newArmiesBuildings)
    elseif newB then self:systemSpeech(SYSTEM.newBuildings)
    elseif newA then self:systemSpeech(SYSTEM.newArmies) end
end

-- The voice of a group: the member with the highest voice priority speaks (FUN_00531730: the first
-- of the highest voice priority, army field +0x20e, in selection order).
function S:bestVoice(units)
    local best, bp = nil, -1
    for _, u in ipairs(units) do
        local p = speech.voicePriority(u, (require("src.game.rules").armyInfo(u.code) or {}).general)
        if p > bp then best, bp = u, p end
    end
    return best
end

function S:speakOrder(units)
    local best = self:bestVoice(units)
    if best then voices.say(best, "Order") end
end

function S:onEvent(kind, a, b, c, d)
    local world = self.world
    local me = world.player
    if kind == "message" then
        self:notify(a, 8)
    elseif kind == "tutorial" then
        self.hud:openTutorial(a, b, c, d)
    elseif kind == "overlay" then
        self.hud:openOverlay(a, b)
    elseif kind == "conversation" then
        self.convQueue = self.convQueue or {}
        self.convQueue[#self.convQueue + 1] = a
    elseif kind == "sound" then
        -- a == name, b == the side the event was about, c == the effect (type 1: positional, number 1: full volume)
        if (not self.net or b == me) and (a or "") ~= "" then self:playEventSound(a, c) end
    elseif kind == "scroll" then
        -- a == x, b == y (cells), c == slide; only for the side the event was about
        if not self.net or d == nil or d == me then self:centreOn(a * CW + 16, b * CH + 12) end
    elseif kind == "visit" then
        if a.side == me and a.hero then self:openSite(a, b) end
    elseif kind == "famine" then
        -- a == the drained mine, b == the amount, c == the casting side (Game.txt 0900 / 0901)
        local strings = require("src.game.strings")
        local key = c == me and "0900" or (a.side == me and "0901" or nil)
        local fmt = key and strings.get("Game.txt", key)
        if fmt then self:notify((fmt:gsub("%%d", tostring(b))), 5) end
        if key then self:logSiteOf(a) end
    elseif kind == "questaccepted" then
        -- the original only plays the system voice (FUN_0043d350; not when the quest is finished at once, c == quiet)
        if a.side == me and not c then self:systemSpeech(15) end   -- system speech 15: quest received
    elseif kind == "questdone" then
        if a.side == me then self:systemSpeech(16) end            -- system speech 16: quest completed (FUN_0043d560)
    elseif kind == "questexpired" then
        -- the original only plays the system voice
        if a == me then self:systemSpeech(21) end   -- system speech 21: quest expired (FUN_0051c7d0)
    elseif kind == "questlost" then
        if a == me then
            local strings = require("src.game.strings")
            self:notify(strings.get("Game.txt", "0188") or "Another hero has completed your quest...", 5)
        end
    elseif kind == "spellcast" then
        local spells = require("src.game.spells")
        if a.side == me then
            self:notify(c and spells.name(b) or ("%s failed"):format(spells.name(b)), 2)
            self:logSiteOf(a)
        end
        -- (the cast's STEZ<nn>.wav is battlefx's: spellSound)
        if a.side == me then voices.say(a, "Spell") end
    elseif kind == "itemspell" then
        -- an item's cast spell power: the floating text and light are battlefx's, no log line or voice (FUN_005777a0)
    elseif kind == "produced" and a.side == me then
        if not a.hero then voices.say(a, "Ready") end       -- the ready speech (FUN_0050c790) skips heroes
    elseif kind == "built" and a.side == me then
        self:notify(("%s completed"):format(a.name or a.code))
        self:logSiteOf(a)
        -- the builder steps out and speaks its "Build" line (building finished, FUN_0052bfd0: unit sound 13);
        -- a hero's is its conversion line
        if b and b.side == me then voices.say(b, b.hero and "Conversion" or "Build") end
    elseif kind == "upgraded" and a.side == me then
        self:notify(l10n.own("Upgraded to %s"):format(a.name or a.code))
        if self:systemSpeech(SYSTEM.upgradeComplete) then self:logSiteOf(a) end
    elseif kind == "converted" then
        if a.side == me then
            self:notify(("%s converted"):format(a.name or a.code))
            sound.playAt("Assets/SoundFX.xcr", "Crystallize.wav", a.gx, a.gy)
            self:logSiteOf(a)
        end
    elseif kind == "noconversions" then
        -- Convert on a keep with nothing in reach (Game.txt 0065)
        if a.side == me then
            self:notify(require("src.game.strings").get("Game.txt", "0065") or "There is nothing here to convert...", 2)
        end
    elseif kind == "keepconverting" then
        self:keepConverting(a)
    elseif kind == "keepconverted" then
        -- the building update FUN_0052c250: KeepConversion.wav for the local player, at most once a second
        if a.side == me then
            sound.play("Assets/SoundFX.xcr", "KeepConversion.wav", { cooldown = 1 })
            self:logSiteOf(a)           -- and its info box on the minimap (FUN_0052c250 calls FUN_004dcf70)
        end
    elseif kind == "levelup" and a.side == me then
        sound.play("Assets/SoundFX.xcr", "HeroLevelUp.wav")
        self:notify(l10n.own("%s reached level %d - click the portrait to spend points, K for spells"):format(a.name or "Hero", a.h.level), 8)
        self:logSiteOf(a)
    elseif kind == "gainedlevel" and a.side == me then
        -- a troop gained a level: the original plays GainedLevel.wav next to it (one sound per 500 ms)
        -- (its EZ12 / EZ57 level-up pictures are battlefx's: FUN_00527100)
        sound.playAt("Assets/SoundFX.xcr", "GainedLevel.wav", a.gx, a.gy, { cooldown = 0.5 })
    elseif kind == "itemfound" and a.side == me then
        sound.play("Assets/SoundFX.xcr", "Statpop.wav")
        self:notify(l10n.own("Found %s"):format(b.name), 6)
        self:logSiteOf(a)
    elseif kind == "resourcefound" and a.side == me then
        sound.play("Assets/SoundFX.xcr", "goodselect.wav")
        self:notify(l10n.own("Found %d %s"):format(c, b), 6)
        self:logSiteOf(a)
    elseif kind == "chestopen" and a.side == me then
        sound.play("Assets/SoundFX.xcr", "Statpop.wav")
        screens.push(require("src.screens.chest"), self, a, b)
    elseif kind == "packfull" and a.side == me then
        self:notify(l10n.game("0732", "Your backpack is full."), 4)
        self:logSiteOf(a)
    elseif kind == "itemdropped" and a.dropped then
        self:notify(l10n.own("Treasure!"), 3)
        self:logSiteOf(a)
    elseif kind == "herodied" then
        -- "hero fallen" for the local hero (FUN_005210b0), another side's hero "allied hero destroyed" / "enemy hero destroyed"
        if a.side ~= me and a.side < 6 then
            if self:systemSpeech(self:isAlly(a.side) and SYSTEM.alliedHeroDestroyed or SYSTEM.enemyHeroDestroyed) then
                self:logSiteOf(a)
            end
        end
        if a.side == me then
            self:systemSpeech(SYSTEM.heroFallen)
            self:notify(l10n.game("0033", "Your hero is dead!"), 8)
            self:logSiteOf(a)
            -- Ironman heroes die for good: the hero and its campaign are deleted
            local profile = require("src.game.profile")
            local rec = world.opts.profile and profile.recordFor(world:profileRace(me))
            if rec and rec.mode == 1 and not self.ironmanDeleted then
                self.ironmanDeleted = true
                profile.deleteIronman(rec)          -- also puts it on the deleted Ironman list
                self:notify(l10n.own("Ironman hero lost - the hero is gone"), 8)
            end
        end
    elseif kind == "converting" and a.side == me then
        self:logSiteOf(a)
    elseif kind == "conversiondone" and a.side == me then
        -- the converter's line comes when the conversion is done (the order completion FUN_00520c90: unit sound 15)
        voices.say(a, "Conversion")
        self:logSiteOf(a)
    elseif kind == "cantbuild" and a.side == me then
        -- a blocked place is the builder's "can't build" line; a lack of resources the announcer's "need more ..."
        -- (the build step FUN_00524450: the placement check FUN_00435900 first, then the cost)
        if b == "cost" then self:needMore(c) else voices.say(a, "CantBuild") end
        self:notify(b == "cost" and "Not enough resources" or "Cannot build there")
        self:logSiteOf(a)
    elseif kind == "needmore" then
        if a == me then self:needMore(b) end
    elseif kind == "toomanymen" then
        if a == me then
            if b then self.announcer:forceTooManyMen() end         -- a refused summon: FUN_005776c0 forces the line
            self:systemSpeech(SYSTEM.tooManyMen)
        end
    elseif kind == "deathblow" then
        -- a melee deathblow is shouted by the attacker (any side) when it is in sight
        if a.side == me or self:shown(a) then voices.deathblow(a) end
    elseif kind == "breath" then
        -- dragon breath FUN_00542150: DragonBreath0.wav and DragonBreath1.wav in turn at the end cell, not twice within 3 s
        if not self.breathAt or world.time > self.breathAt + 3000 then
            self.breathAt = world.time
            self.breathWav = 1 - (self.breathWav or 1)
            sound.playAt("Assets/SoundFX.xcr", ("DragonBreath%d.wav"):format(self.breathWav), a, b)
        end
    elseif kind == "breathhit" then
        -- the effect picture a breath puts on a walking army it hurt (FUN_0044e8f0 on the army, one frame in front)
        local set = b and require("src.gfx.anims").get(b)
        if set and set:has(A.STAND) and self:shown(a) then
            world.effects = world.effects or {}
            world.effects[#world.effects + 1] = { kind = "sprite", code = b, x = a.x, y = a.y, t0 = world.time,
                                                  dur = set:frames(A.STAND) * 50 }
        end
        if c then self.fx:emit(a, c) end
    elseif kind == "powerup" then
        -- FUN_00436500: "research complete" for a power-up of the local side (the spell research ones say "learned a new
        -- spell" through FUN_00438180 instead; they are the "spellresearch" event)
        if a == me then self:systemSpeech(SYSTEM.researchComplete) end
    elseif kind == "spellresearch" then
        -- FUN_00438180: the research line ("+%d %s", Game.txt 0129) and the "learned a new spell" voice; without a hero
        -- Game.txt 0131 and nothing else
        if a == me then
            local strings = require("src.game.strings")
            if b then
                self:systemSpeech(SYSTEM.learnedNewSpell)
                local fmt = strings.get("Game.txt", "0129") or "You have gained +%d casting to your %s skill."
                self:notify(fmt:format(c, require("src.game.powerups").SPHERE_NAMES[b]), 6)
            else
                self:notify(strings.get("Game.txt", "0131") or "You have no hero to learn the spell...", 6)
            end
        end
    elseif kind == "knightsquest" then
        -- FUN_00438de0: the "Choose a Foe" dialog opens for the local player only
        if a == me then self:openChooseFoe() end
    elseif kind == "titan" then
        -- a titan raised after the first two minutes: "enemy titan" / "allied titan" (FUN_00519ae0, after 120000 ms)
        if a.side ~= me and self.world.sides[me] then
            self:systemSpeech(self:isAlly(a.side) and SYSTEM.alliedTitan or SYSTEM.enemyTitan)
        end
    elseif kind == "kill" then
        -- FUN_00518a10: the 50th, 100th ... army the local hero killed is a "heroic effort"
        if a.side == me and a.hero and b.kind == "unit" and b.side ~= me and not unitMod.isCritter(b.code) then
            self.heroKillCount = self.heroKillCount + 1
            if self.heroKillCount > self.heroicLevel then
                self:systemSpeech(SYSTEM.heroicEffort)
                self.heroicLevel = self.heroicLevel + 50
            end
        end
    elseif kind == "attacked" then
        -- our units or buildings are hit (c == the damage): the announcer warns when it happens out of sight, and the
        -- place goes into the site log
        if a.side == me and c then
            if a.kind == "building" then
                if b.side ~= me then self:buildingHit(a, c) end
            else
                self:unitHit(a, b, c)
            end
        end
    elseif kind == "destroyed" then
        sound.playAt("Assets/SoundFX.xcr", ("Falling%d.wav"):format(math.random(0, 1)), a.gx, a.gy)
    elseif kind == "defeated" then
        if a == me then
            self:notify(l10n.own("You have been defeated"), 8)
        else
            self:notify(("%s have been vanquished"):format(gamedata.RACES[world.sides[a].race] or "?"), 6)
            -- the side-defeated message (0x21c, FUN_004af270): "enemy vanquished" for a side not allied to the local
            -- player while another side not allied to it still stands; 1.04 never plays "ally vanquished" (10)
            local enemies = 0
            for i = 0, 5 do
                local sd = world.sides[i]
                if i ~= me and sd.used and not sd.defeated and not self:isAlly(i) then enemies = enemies + 1 end
            end
            if not self:isAlly(a) and enemies > 0 then self:systemSpeech(SYSTEM.enemyVanquished) end
        end
    elseif kind == "gameover" then
        local won = false
        for _, s in ipairs(a) do if s == me then won = true end end
        self.result = { won = won, t = love.timer.getTime() }
        if not world.xpAwarded and not world.opts.tutorial then
            -- the experience of the finished battle (FUN_004553f0): every side's hero, the local one's is shown
            world.xpAwarded = true
            self.result.xp, self.result.heroRemoved = require("src.game.battlexp").finish(world, won, self.fogMode)
        end
        self:settleRetinue(self.result.heroRemoved)
        self:saveProfile()
        self:prepareLevels()
        if self.world.opts.profile and not self.ironmanDeleted then
            local profile = require("src.game.profile")
            self.result.games = profile.addBattle()
            if won then profile.addRaceWin(world.sides[me].race) end      -- the profile's win counters
        end
        -- "victory / defeat build-up" (FUN_00513e00 / FUN_00513c80): the fanfare plays first and the result
        -- (with the announcer) follows when it has ended; without the option, or with the sound off, no fanfare
        local src = require("src.core.gameopts").on("buildup") and sound.volume > 0
            and sound.play("Assets/SoundFX.xcr", won and "Victory.wav" or "Defeat.wav")
        if src then self.result.pending = src else self:systemSpeech(won and SYSTEM.victory or SYSTEM.defeat) end
    end
end

-- Update ----------------------------------------------------------------------------

-- One frame of a network game: the lockstep session decides how many ticks we may run.
function S:updateNet(dt)
    local world = self.world
    local commands = require("src.game.commands")
    local seed = self.netSeed or 1
    -- the content (records, mods) is part of the state the peers compare: another mod set shows up in the first checksum
    local contentSalt = tonumber(require("src.content").hash():sub(1, 6), 16) % 65521
    self.net:update(dt,
        function(cmd) commands.apply(world, cmd) end,
        function(tick)
            math.randomseed(seed + tick * 7919)
            world:update(1 / 30)
        end,
        function() return world:hash() + contentSalt end,
        function(side)
            world.sides[side].ai = true
            if world.ai then world.ai:adopt(side) end
            self:notify(l10n.game("0237", "%s has left the game..."):format(self.net.names[side] or ("Player " .. (side + 1))), 6)
        end)
    if self.net.desync and not self.desyncShown then
        self.desyncShown = true
        require("src.core.log").warn("desync: %s", tostring(self.net.desync))
        self:notify("The game is out of sync: " .. tostring(self.net.desync), 15)
    end
    if self.net.lost and not self.lostShown then
        self.lostShown = true
        self:notify("The connection to the host was lost", 15)
        self.net = nil
        self.paused = true
    end
end

-- Called every frame by the screen stack while a dialog or menu is open over the battle (screens.lua). A network
-- game cannot pause: the other players need our inputs every turn, and a silent peer is dropped after 20 s, so the
-- lockstep session keeps running behind the menu like in the original.
function S:underUpdate(dt)
    if not self.net then return end
    dt = math.min(dt, 0.1)
    if not self.result then self:updateNet(dt) end
    if self.net then self:pollChat() end
    self.fog:update(self.world.time)
end

-- Advances a game without network by the same fixed ticks a network game runs (lockstep.TICK, 30 a second): the
-- simulation then does not depend on the frame rate (no time lost at the end of each walking step or swing, the
-- same results at 30 and at 144 frames a second). The original's own tick rate is not traced in the 1.04 binary yet.
---@param dt number real seconds of this frame
function S:stepWorld(dt)
    local tick = require("src.game.lockstep").TICK
    local acc = (self.tickAcc or 0) + dt
    while acc >= tick - 1e-9 do                         -- the tolerance: two 1/60 s frames make a tick
        acc = acc - tick
        self.world:update(tick)
    end
    self.tickAcc = math.max(acc, 0)
end

function S:update(dt)
    dt = math.min(dt, 0.1)
    self.hud:layout()
    local w, h = love.graphics.getDimensions()
    -- while a wall is dragged the edge scroll is at its slowest rate (rate 1 in the original)
    -- the original scrolls `rate` cells per event: 60 events a second at the screen edge, 20 for the arrow keys (gameopts.lua)
    local go = require("src.core.gameopts")
    local rate = self.wallDrag and 1 or go.scrollRate()
    local edgeSpeed, keySpeed = go.SCROLL_EDGE_EVENTS * rate * dt, go.SCROLL_KEY_EVENTS * rate * dt   -- cells this frame
    local mx, my = love.mouse.getPosition()
    local dx, dy = 0, 0                                 -- cells to move this frame
    if love.keyboard.isDown("left") then dx = dx - keySpeed end
    if love.keyboard.isDown("right") then dx = dx + keySpeed end
    if love.keyboard.isDown("up") then dy = dy - keySpeed end
    if love.keyboard.isDown("down") then dy = dy + keySpeed end
    if love.window.hasMouseFocus() and not self.dragStart and not self.hud.miniDrag then
        if mx <= 2 then dx = dx - edgeSpeed elseif mx >= w - 3 then dx = dx + edgeSpeed end
        if my <= 2 then dy = dy - edgeSpeed elseif my >= h - 3 then dy = dy + edgeSpeed end
    end
    self.showCommandQueue = love.keyboard.isDown("lshift", "rshift") or love.keyboard.isDown("lalt", "ralt")
    if self.wallDrag and self.hud.mode ~= "place" then self.wallDrag = nil end
    self.camX = self.camX + dx * CW
    self.camY = self.camY + dy * CH
    self.hud:update()
    self:clampCamera()

    local vw, vh = self:viewSize()
    sound.listenerX, sound.listenerY = (self.camX + vw / 2) / CW, (self.camY + vh / 2) / CH
    if self.net then
        self:underUpdate(dt)
    elseif not self.paused and not self.result then
        self:stepWorld(dt)
    end
    self.fog:update(self.world.time)
    self.fx:update(dt)
    local r = self.result
    if r and r.pending and not r.pending:isPlaying() then
        r.pending, r.t = nil, love.timer.getTime()
        self:systemSpeech(r.won and SYSTEM.victory or SYSTEM.defeat)
    end
    self:checkAvailability(love.timer.getTime())
    self.wfx = self.wfx or require("src.ui.weatherfx").new()
    self.wfx:update(self.world, dt)
    if self.convQueue and screens.top() == self then self:startConversations() end
    music.update()
    if self.demo then self:updateDemo() end
    self.clock = self.clock + dt
    for i = #self.scripts, 1, -1 do
        local sc = self.scripts[i]
        if self.clock >= sc.t then
            table.remove(self.scripts, i)
            local fn, err = loadstring(sc.code)
            if fn then
                setfenv(fn, setmetatable({ S = self, W = self.world }, { __index = _G }))
                local ok, e = pcall(fn)
                if not ok then print("[script] " .. tostring(e)) end
            else
                print("[script] " .. tostring(err))
            end
        end
    end

    for i = #self.selection, 1, -1 do
        local e = self.selection[i]
        if (e.kind == "unit" and not e:alive()) or (e.kind == "building" and (e.hp <= 0 or e.destroyed)) then
            e.selected = false
            table.remove(self.selection, i)
        end
    end
    self:updateCursor()
end

-- Demo mode (--demo): the player's army attacks the nearest enemy and the
-- camera follows it. Used for automated visual checks.
function S:updateDemo()
    local world = self.world
    if world.time > 500 and not self.demoOrdered then
        self.demoOrdered = true
        local mine = {}
        for _, u in ipairs(world.units) do if u.side == world.player and u:alive() then mine[#mine + 1] = u end end
        self:select(mine, true)
        local target, bestD
        local c = mine[1]
        if c then
            for _, u in ipairs(world.units) do
                if u:alive() and world:enemies(world.player, u.side) then
                    local d = (u.x - c.x) ^ 2 + (u.y - c.y) ^ 2
                    if not bestD or d < bestD then target, bestD = u, d end
                end
            end
            if target then for _, u in ipairs(mine) do u:orderAttack(target) end end
        end
    end
    local follow = self.selection[1]
    if follow then
        local vw, vh = self:viewSize()
        self.camX = self.camX + ((follow.x - vw / 2) - self.camX) * 0.1
        self.camY = self.camY + ((follow.y - vh / 2) - self.camY) * 0.1
        self:clampCamera()
    end
end

-- Selection & orders ------------------------------------------------------------------

-- Tells the simulation what is selected, when a scenario event depends on it (not needed otherwise).
function S:syncSelection()
    local events = self.world.events
    if not (events and events.usesSelection) then return end
    local ids = {}
    for i, e in ipairs(self.selection) do ids[i] = e.id end
    self:issue({ t = "select", ids = ids })
end

function S:clearSelection()
    for _, e in ipairs(self.selection) do e.selected = false end
    self.selection = {}
    self:syncSelection()
end

---@param list (Unit|Building)[]
---@param quiet boolean?  no selection voice
function S:select(list, quiet)
    self:clearSelection()
    for _, e in ipairs(list) do
        e.selected = true
        self.selection[#self.selection + 1] = e
    end
    self:syncSelection()
    self.hud.mode = nil
    self.hud.dialog = nil
    self.hud.infoPage = nil
    -- a click or a box: the best-voiced of the selected armies asks to speak (the box selection FUN_005319f0 /
    -- FUN_00531dd0 ends by asking FUN_00531730's pick for its select sound), a single unit just itself
    local first = list[1]
    if not quiet and first and first.kind == "unit" and first.side == self.world.player then
        local units = {}
        for _, e in ipairs(list) do
            if e.kind == "unit" and e.side == first.side then units[#units + 1] = e end
        end
        voices.say(self:bestVoice(units) or first, "Select")
    end
end

function S:ownUnits()
    local out = {}
    for _, e in ipairs(self.selection) do
        if e.kind == "unit" and e.side == self.world.player then out[#out + 1] = e end
    end
    return out
end

-- Hero point / item / spell changes (so that every player of a network game sees the same hero).
function S:heroOp(op, a)
    local hero = self.world.eco:heroAlive(self.world.player)
    if hero then self:issue({ t = "hero", id = hero.id, op = op, a = a }) end
end

-- Keeps the battle running under a dialog that does not pause it (the chest dialog); a network game already runs
-- through `underUpdate`.
---@param dt number
function S:runBackground(dt)
    if self.net or self.paused or self.result then return end
    self:stepWorld(dt)
    self.fog:update(self.world.time)
    self.fx:update(dt)
end

-- Sends a command (executed at once, or at the agreed tick in a network game).
---@param cmd Command
function S:issue(cmd)
    cmd.side = self.world.player
    if self.net then self.net:submit(cmd) else require("src.game.commands").apply(self.world, cmd) end
end

local function idsOf(list)
    local out = {}
    for i, u in ipairs(list) do out[i] = u.id end
    return out
end

-- Order feedback: a few glowing orbs jump out of the clicked spot, bounce and fade (cyan for a move, red for
-- an attack, blue for garrison / visit, green for a rally point). Display only, so the spread is a fixed table
-- rather than random numbers.
local SPARK_COLOURS = {
    cyan = { 0.25, 0.9, 1 }, red = { 1, 0.2, 0.15 }, blue = { 0.35, 0.45, 1 }, green = { 0.3, 1, 0.3 }, yellow = { 1, 0.9, 0.2 },
}
local SPARK_SPREAD = { { -26, -95 }, { -12, -125 }, { 0, -110 }, { 14, -135 }, { 28, -100 } }
local SPARK_LIFE, SPARK_GRAVITY = 1.0, 520

---@param wx number
---@param wy number
---@param colour string?  a SPARK_COLOURS key (default cyan)
function S:sparkle(wx, wy, colour)
    if require("src.core.gameopts").get("mouseeffects") == false then return end     -- options: Mouse Click Effects
    self.sparks = { x = wx, y = wy, t = love.timer.getTime(), colour = SPARK_COLOURS[colour] or SPARK_COLOURS.cyan }
end

local glowImage
local function glow()
    if not glowImage then
        local n = 32
        local d = love.image.newImageData(n, n)
        for y = 0, n - 1 do
            for x = 0, n - 1 do
                local r = math.sqrt((x + 0.5 - n / 2) ^ 2 + (y + 0.5 - n / 2) ^ 2) / (n / 2)
                local a = math.max(0, 1 - r)
                d:setPixel(x, y, 1, 1, 1, a * a * (r < 0.3 and 1 or 0.7))
            end
        end
        glowImage = love.graphics.newImage(d)
    end
    return glowImage
end

-- R (all radii key): the command radius of the local side's heroes (FUN_00532940 collects only the heroes; the radius
-- is the hero's command capped at 19, FUN_0049a6c0). The radius drawing FUN_00499e60 draws an
-- ellipse of r * 32 by r * 24 pixels around the hero as an arc of 200 degrees (600 of 1080 steps) that circles round,
-- colour fading from white at its start to blue (31,31,31 -> 1,12,31 in 5-bit) at its end. The speed of the circling
-- (the original advances 15 degrees per drawn frame) is openwbc3's own choice: one turn in 1.5 s.
local RADIUS_ARC, RADIUS_SEGMENTS, RADIUS_TURN = math.rad(200), 40, 1.5
function S:drawRadius()
    local g = love.graphics
    local head = (love.timer.getTime() / RADIUS_TURN) % 1 * 2 * math.pi
    g.setLineWidth(2)
    for _, u in ipairs(self:myUnits()) do
        local r = u.hero and u:alive() and u.h and math.min(19, u.h.mod.commandRadius or 0)
        if r and r > 0 then
            local prevX, prevY
            for k = 0, RADIUS_SEGMENTS do
                local f = k / RADIUS_SEGMENTS
                local a = head + f * RADIUS_ARC
                local x, y = u.x + math.cos(a) * r * CW, u.y + math.sin(a) * r * CH
                if prevX then
                    g.setColor(1 - f * 30 / 31, 1 - f * 19 / 31, 1, 0.85)
                    g.line(prevX, prevY, x, y)
                end
                prevX, prevY = x, y
            end
        end
    end
    g.setLineWidth(1)
    g.setColor(1, 1, 1)
end

function S:drawSparks()
    local sp = self.sparks
    if not sp then return end
    local age = love.timer.getTime() - sp.t
    if age >= SPARK_LIFE then self.sparks = nil return end
    local g = love.graphics
    local img = glow()
    local fade = 1 - age / SPARK_LIFE
    g.setBlendMode("add")
    g.setColor(sp.colour[1], sp.colour[2], sp.colour[3], fade)
    g.ellipse("line", sp.x, sp.y, 14 * (1 - fade) + 4, 7 * (1 - fade) + 2)    -- ring on the ground
    for _, v in ipairs(SPARK_SPREAD) do
        -- ballistic arc (v < 0 is upwards) with one bounce at 40% of the launch speed
        local v0 = v[2]
        local h = v0 * age + SPARK_GRAVITY * age * age / 2
        if h > 0 then
            local a2 = age + 2 * v0 / SPARK_GRAVITY
            local v1 = v0 * 0.4
            h = math.min(0, v1 * a2 + SPARK_GRAVITY * a2 * a2 / 2)
        end
        local x, y = sp.x + v[1] * age, sp.y + h
        local size = 0.6 + 0.6 * fade
        g.setColor(sp.colour[1], sp.colour[2], sp.colour[3], fade)
        g.draw(img, x, y, 0, size, size, 16, 16)
    end
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1)
end

-- Whether right-clicking e gives an attack order. The original's alliance matrix is FALSE
-- whenever one of the two sides is the neutral one (set up by FUN_004de740), so the
-- neutral side is hostile to every real side and its units and buildings get attacked; pillaged
-- buildings are never attacked, and shops and quest sites are matched before the attack in the
-- original's right-click handler (0x00421190: the search and shop tests) - there
-- only a hero is diverted, so openwbc3 keeping them peaceful for everyone is its own choice.
function S:attackable(e)
    if e == nil or e.side == nil then return false end
    if e.kind == "building" and (e.pillaged or e.shop or e.quest) then return false end
    local world = self.world
    return world:enemies(world.player, e.side) or (e.side == 6 and world.player ~= 6)
end

-- Smart right-click (or the active command mode) at world position (wx, wy).
function S:command(wx, wy, mode)
    local world = self.world
    local eco = world.eco
    local first = self.selection[1]
    local gx, gy = math.floor(wx / CW), math.floor(wy / CH)
    if first and first.kind == "building" and first.side == world.player then
        -- right click on one of our own resource buildings moves the rally point onto it (workers walk in)
        local e = world:pick(wx, wy)
        if e and e.kind == "building" and e.mine and e.side == world.player then gx, gy = e.gx, e.gy end
        self:issue({ t = "rally", bid = first.id, gx = gx, gy = gy })
        self:sparkle(wx, wy, "green")
        return
    end
    local units = self:ownUnits()
    if #units == 0 then return end
    -- Shift queues the order behind the current ones, Alt does it first and resumes the rest afterwards
    local queue = love.keyboard.isDown("lshift", "rshift") or nil
    local interrupt = love.keyboard.isDown("lalt", "ralt") or nil
    local target = world:pick(wx, wy)
    if target and not self:shown(target) then target = nil end
    self:speakOrder(units)

    -- gives `kind` to the units `accept` takes, returns the rest. `interrupt` may be overridden (nil) for orders the
    -- original has no insert mode for (Garrison: the binary keeps the plain garrison action on Alt and its Garrison
    -- order function has no insert mode).
    local function task(kind, accept, limit, alt)
        local rest, take = {}, {}
        for _, u in ipairs(units) do
            if (not limit or #take < limit) and accept(u) then take[#take + 1] = u else rest[#rest + 1] = u end
        end
        if #take > 0 then
            ---@cast target -nil                -- task() is only called for a building target
            self:issue({ t = "task", kind = kind, ids = idsOf(take), bid = target.id, queue = queue,
                         interrupt = alt == nil and interrupt or alt })
        end
        units = rest
    end

    -- right-clicking an enemy only ever attacks: in the original the only way to convert is the
    -- Convert button (the Ctrl+C shortcut, FUN_00427fb0, presses it through FUN_004d2290),
    -- the right-click chain has no convert action at all
    if mode ~= "move" and target and self:attackable(target) then
        if #units > 0 then
            self:issue({ t = "attack", ids = idsOf(units), target = { kind = target.kind, id = target.id }, queue = queue,
                         interrupt = interrupt })
        end
        self:sparkle(wx, wy, "red")
        return
    end
    if mode ~= "move" and mode ~= "attack" and target and target.kind == "building" then
        if target.side == 6 and (target.quest or target.shop) then
            task("visit", function(u) return u.hero end, 1)
        elseif target.side == world.player and eco:garrisonCap(target) > 0 then
            -- FUN_0051c240: only a unit a garrison can hold
            task("garrison", function(u) return u:canGarrison() end, eco:garrisonCap(target) - eco:garrisoned(target), false)
        elseif target.side == world.player and target.mine then
            -- FUN_00523e70: only a builder works a mine
            task("mine", function(u) return u:canWorkInMine() > 0 end, 8 - target.mine.workers)
        end
        if #units == 0 then
            self:sparkle(wx, wy, target.side == world.player and "blue" or "cyan")
            return
        end
    end
    -- a Minotaur right-clicked on one of its own critters gets the attack order and eats it
    -- (an attack order on the critter; the kill routine FUN_005210b0 heals the attacker, Eating.wav)
    if mode ~= "move" and target and target.kind == "unit" and target.side == world.player
        and unitMod.isCritter(target.code) then
        local take, rest = {}, {}
        for _, u in ipairs(units) do
            if u:isMinotaur() then take[#take + 1] = u else rest[#rest + 1] = u end
        end
        if #take > 0 then
            self:issue({ t = "attack", ids = idsOf(take), target = { kind = "unit", id = target.id },
                         queue = queue, interrupt = interrupt })
            units = rest
            self:sparkle(wx, wy, "red")
            return
        end
    end
    -- the Attack button on open ground is an attack-move: the group move without "ignore threats" (right-click map
    -- action 0x00421190, command mode 2 without a target -> FUN_00530870 with the last argument 0), a move the units'
    -- attitudes may divert into fights on the way (attitude.lua, playerOrder)
    local attack = mode == "attack" or nil
    self:marchInFormation(units, gx, gy, queue, interrupt, nil, attack)
    self:sparkle(wx, wy, attack and "red" or "cyan")
end

-- March in formation: slots around the cell (gx, gy), at the pace of the slowest unit unless `noPace`. The formation is
-- the group leader's (formation.leader): its type and direction. A target 5 or more cells from the centre of the group
-- turns the formation (formation.directionFor) and hands the leader's type and the new direction to every unit of the
-- group, as the original's group move (FUN_00530870) does; the rotate keys and the formation buttons call this with
-- the leader's own cell, so that this check applies to them too. `attack`: an attack-move.
function S:marchInFormation(units, gx, gy, queue, interrupt, noPace, attack)
    local world = self.world
    local formation = require("src.game.formation")
    local n = #units
    local sx, sy, pace = 0, 0, math.huge
    for _, u in ipairs(units) do
        sx, sy = sx + u.gx, sy + u.gy
        pace = math.min(pace, u:stats().speed)
    end
    local fx, fy = math.floor(sx / n), math.floor(sy / n)       -- the centre of the group, whole cells
    -- options "Group Move": with the slowest unit (default) or as fast as possible; Ctrl does the other one
    if noPace or require("src.core.gameopts").groupMove() == love.keyboard.isDown("lctrl", "rctrl") then pace = math.huge end
    local leader = formation.leader(units)
    ---@cast leader -nil                        -- callers pass a group of units: there is a leader
    local kind, dir = formation.state(leader)
    local newDir = formation.directionFor(gx - fx, gy - fy, dir)
    if newDir ~= dir then
        dir = newDir
        formation.apply(units, kind, dir)
    end
    local moves = {}
    for _, slot in ipairs(formation.assign(formation.KINDS[kind], units, gx, gy, dir)) do
        local u = slot.unit
        local tx, ty = world:nearestFree(slot.gx, slot.gy, u.move, 6)
        if tx then moves[#moves + 1] = { u.id, tx, ty } end
    end
    if #moves > 0 then
        self:issue({ t = "move", moves = moves, pace = n > 1 and pace ~= math.huge and pace or nil, queue = queue, interrupt = interrupt,
                      attack = attack })
    end
end

-- Formation panel buttons and the rotate keys / buttons: the original (0x004ce8d0 / FUN_004ce960 /
-- FUN_004ce9f0) changes the formation type or steps the direction of the group leader alone (`kind` = index into
-- formation.KINDS; `turn` +1 anticlockwise (the [ key) / -1 clockwise (the ] key), eight directions) and then moves the
-- whole group to the leader's cell with the speed of every unit, inserted before the current orders.
function S:formUp(kind, turn)
    local formation = require("src.game.formation")
    local units = self:ownUnits()
    if #units < 2 then return end
    local leader = formation.leader(units)
    ---@cast leader -nil                        -- two units or more: there is a leader
    local k, d = formation.state(leader)
    if kind then k = kind end
    if turn then d = (d + turn) % formation.DIRECTIONS end
    leader.formationType, leader.formationDir = k, d
    voices.say(leader, "Order")
    self:marchInFormation(units, leader.gx, leader.gy, nil, true, true)
end

function S:placementCell(wx, wy)
    return math.floor(wx / CW), math.floor(wy / CH)
end

function S:mapClick(x, y, button)
    local world = self.world
    local hud = self.hud
    local wx, wy = self:toWorld(x, y)
    if hud.mode == "place" then
        if button == 1 then
            local gx, gy = self:placementCell(wx, wy)
            local b = hud.placeBuilder
            if b and b:alive() then
                if world.eco:canPlace(hud.placeCode, gx, gy, world.player, true) then
                    -- Shift appends, Alt inserts the build order (the binary's append / insert place-building actions,
                    -- both keep the placement grid open while a modifier is held)
                    local shift = love.keyboard.isDown("lshift", "rshift")
                    local alt = love.keyboard.isDown("lalt", "ralt")
                    if walls.isWall(hud.placeCode) and not shift and not alt then
                        -- a wall piece starts a drag: the pieces under the mouse are collected until the button comes up
                        local t = world.terrain
                        self.wallDrag = walls.start(hud.placeCode, gx, gy, t.w, t.h)
                        return
                    end
                    self:issue({ t = "build", id = b.id, code = hud.placeCode, gx = gx, gy = gy,
                                 queue = shift or nil, interrupt = alt or nil })
                    voices.say(b, "Order")
                    if not shift and not alt then hud.mode = nil end
                else
                    sound.play("Assets/SoundFX.xcr", "Error.wav")
                end
            else
                hud.mode = nil
            end
        else
            hud.mode = nil
            self.wallDrag = nil         -- the right button cancels a drag in progress
        end
        return
    end
    if hud.mode == "spell" then
        local id = hud.spellId
        ---@cast id -nil                        -- the spell mode is entered with a spell
        hud.mode = nil
        local hero = hud:hero()
        if button ~= 1 or not hero then return end
        local spells = require("src.game.spells")
        local kind = spells.targetKind(id)
        local target
        if kind == "ground" then
            target = { gx = math.floor(wx / CW), gy = math.floor(wy / CH) }
        else
            local e = world:pick(wx, wy)
            if e and e.kind == "unit" and self:shown(e) then
                local enemy = e.side == 6 or world:enemies(world.player, e.side)
                if (kind == "enemy" and enemy) or (kind == "ally" and not enemy) then target = e end
            end
        end
        if target then
            local ok, why = spells.canCast(hero, id)
            if ok then
                self:issue({ t = "cast", id = hero.id, spell = id,
                             target = target.gx and not target.kind and { gx = target.gx, gy = target.gy } or { unit = target.id } })
            else
                self:notify(why == "mana" and "Not enough mana" or "Cannot cast now", 2)
                if why == "mana" then voices.say(hero, "Mana") end
                if why == "recovering" and self.fx then self.fx:recovering(hero) end      -- "recovering" over the hero
            end
        else
            self:notify(l10n.own("Invalid target"), 2)
        end
        return
    end
    if hud.mode == "move" or hud.mode == "attack" or hud.mode == "rally" then
        if button == 1 then self:command(wx, wy, hud.mode) end
        hud.mode = nil
        return
    end
    if hud.mode == "patrol" then
        local shift = love.keyboard.isDown("lshift", "rshift")
        if button == 1 then
            local units = self:ownUnits()
            if #units > 0 then
                local gx, gy = math.floor(wx / CW), math.floor(wy / CH)
                self:issue({ t = "patrol", ids = idsOf(units), points = { { gx, gy } }, queue = shift or nil })
                self:speakOrder(units)
                self:sparkle(wx, wy, "cyan")
            end
        end
        if not shift or button ~= 1 then hud.mode = nil end     -- Shift: keep adding points to the path
        return
    end
    if hud.mode == "guard" then
        hud.mode = nil
        local attitude = hud.guardAttitude          -- set when Guardian / Magic Guardian was picked from the attitude list
        hud.guardAttitude = nil
        local e = button == 1 and world:pick(wx, wy) or nil
        local units = self:ownUnits()
        if e and e.kind == "unit" and e.side == world.player and #units > 0 then
            self:issue({ t = "guard", ids = idsOf(units), target = e.id, attitude = attitude })
            self:speakOrder(units)
            self:sparkle(wx, wy, "blue")
        end
        return
    end
    if button == 1 then
        self.dragStart = { x, y }
    elseif button == 2 then
        if love.keyboard.isDown("lctrl", "rctrl") then
            self.hud:openAttitude(x, y)        -- Ctrl + right click: the attitude list
        elseif require("src.core.gameopts").leftClickInterface() then
            self:rightClickInterface(wx, wy)   -- left click interface: the right button still has its orders
        else
            self:command(wx, wy)
        end
    end
end

-- A Building.cfg [BUILDINGS] race column ("armies" or "build") for the race of the building's side (the race table
-- bytes +0x58 / +0x68 the 1.04 binary reads through FUN_00587720 / FUN_00587750).
---@param b Building
---@param column "armies"|"build"
---@return boolean
function S:raceColumn(b, column)
    local info = require("src.game.rules").building(b.code)
    local side = self.world.sides[b.side]
    return info ~= nil and side ~= nil and info[column][side.race] == true
end

-- The right button in the left click interface (the 1.04 map action 0x00423050, right button without a command mode):
-- an own building whose race "build" column is set and whose keep conversion is not running (FUN_0052e730,
-- FUN_0052fc00 == 0) gets selected and its production menu opened (action 0x30); with an own building selected whose
-- race "armies" column is set (FUN_0052e710) it sets that building's rally point (action 0xc, snapped onto an own
-- resource building under the cursor); anything else deselects. The original also skips the menu for a building
-- under construction without a builder while a unit with the Build skill is selected; here an unfinished building
-- never opens it (whether the menu opens for one at all was not traced in 1.04).
function S:rightClickInterface(wx, wy)
    local world = self.world
    local e = world:pick(wx, wy)
    local b = (e and e.kind == "building") and e or nil
    local first = self.selection[1]
    if b and b.side == world.player and b.complete and not b.convert and self:raceColumn(b, "build") then
        self:select({ b })
        self.hud.dialog = { kind = "production", building = b }
        return
    end
    if first and first.kind == "building" and first.side == world.player and self:raceColumn(first, "armies") then
        local gx, gy = math.floor(wx / CW), math.floor(wy / CH)
        if b and b.mine and b.side == world.player then gx, gy = b.gx, b.gy end
        self:issue({ t = "rally", bid = first.id, gx = gx, gy = gy })
        self:sparkle(wx, wy, "green")
        return
    end
    self:clearSelection()
end

-- Input ------------------------------------------------------------------------------

function S:mousepressed(x, y, button)
    if self.result then
        if love.timer.getTime() - self.result.t > 1 and not self.result.shown and not self.result.pending then
            self.result.shown = true
            screens.push(require("src.screens.victory"), self)   -- Continue returns here (resume); Advanced shows the statistics
        end
        return
    end
    if self.netStats then self.netStats = nil return end        -- a click closes the network statistics
    if self.hud:mousepressed(x, y, button) then return end
    self:mapClick(x, y, button)
end

function S:mousemoved(x, y)
    self.hud:mousemoved(x, y)
    if self.wallDrag then
        -- a drag-built wall collects the cell under the mouse (the original reacts to button-drag events only)
        local world = self.world
        local wx, wy = self:toWorld(x, y)
        local gx, gy = self:placementCell(wx, wy)
        walls.add(self.wallDrag, gx, gy, function(code, cx, cy)
            return world.eco:canPlace(code, cx, cy, world.player, true)
        end)
    end
end

-- The button comes up: the builder builds the first section now and queues the rest (the build-wall-section order).
function S:finishWallDrag()
    local drag, hud = self.wallDrag, self.hud
    ---@cast drag -nil                          -- only called while a wall is being dragged
    self.wallDrag = nil
    hud.mode = nil
    local b = hud.placeBuilder
    if b and b:alive() then
        self:issue({ t = "build", id = b.id, sections = walls.list(drag) })
        voices.say(b, "Order")
    end
end

function S:mousereleased(x, y, button)
    if self.wallDrag and button == 1 then return self:finishWallDrag() end
    if self.hud:mousereleased(x, y, button) then return end
    if button ~= 1 or not self.dragStart then return end
    local sx, sy = self.dragStart[1], self.dragStart[2]
    self.dragStart = nil
    local world = self.world
    if math.abs(x - sx) < 4 and math.abs(y - sy) < 4 then
        local wx, wy = self:toWorld(x, y)
        local e = world:pick(wx, wy)
        -- left click interface: a click on anything that is not ours gives the selected units an order; on one of our
        -- own buildings the garrison / mine order is taken instead of selecting it (the original also resumes
        -- abandoned construction sites here, which openwbc3 never leaves abandoned)
        if require("src.core.gameopts").leftClickInterface() and #self:ownUnits() > 0 then
            if not (e and e.side == world.player and self:shown(e)) then
                self:command(wx, wy)
                return
            elseif e.kind == "building" and e.side == world.player
                and (world.eco:garrisonCap(e) > world.eco:garrisoned(e) or (e.mine and e.mine.workers < 8)) then
                self:command(wx, wy)
                return
            end
        end
        if e and self:shown(e) then
            local now = love.timer.getTime()
            if self.lastClick and now - self.lastClick.t < 0.35 and self.lastClick.e == e and e.kind == "unit"
                and e.side == world.player then
                local list = {}
                local vw, vh = self:viewSize()
                for _, u in ipairs(world.units) do
                    if u:alive() and u.side == e.side and u.code == e.code and u.x >= self.camX and u.y >= self.camY
                        and u.x <= self.camX + vw and u.y <= self.camY + vh then
                        list[#list + 1] = u
                    end
                end
                self:select(list)
            elseif love.keyboard.isDown("lshift", "rshift") and e.kind == "unit" and e.side == world.player then
                local list = { unpack(self.selection) }
                list[#list + 1] = e
                self:select(list, true)
            else
                self:select({ e })
            end
            self.lastClick = { t = now, e = e }
        else
            self:clearSelection()
        end
        return
    end
    local x0, y0 = self:toWorld(math.min(sx, x), math.min(sy, y))
    local x1, y1 = self:toWorld(math.max(sx, x), math.max(sy, y))
    local list = {}
    for _, u in ipairs(world.units) do
        if u:alive() and u.side == world.player and u.x >= x0 and u.x <= x1 and u.y - 12 >= y0 and u.y - 12 <= y1 then
            list[#list + 1] = u
        end
    end
    -- heroes first so they speak and show in the panel
    table.sort(list, function(a, b) return (a.hero and 1 or 0) > (b.hero and 1 or 0) end)
    if #list > 0 then self:select(list) else self:clearSelection() end
end

function S:wheelmoved(_, dy)
    local mx0, my0 = love.mouse.getPosition()
    local spellbar = require("src.ui.spellbar")
    local _, oy = spellbar.origin(self.hud)
    if spellbar.enabled() and my0 >= oy and my0 < oy + 26 and mx0 < 8 + 8 * 100 then
        self.hud.spellPage = (self.hud.spellPage or 0) - (dy > 0 and 1 or -1)
        return
    end
    local old = self:scale()
    if dy > 0 then self.zoom = math.min(2, self.zoom + 0.25) elseif dy < 0 then self.zoom = math.max(0.5, self.zoom - 0.25) end
    local new = self:scale()
    if old ~= new then
        local mx, my = love.mouse.getPosition()
        local wx, wy = mx / old + self.camX, my / old + self.camY
        self.camX, self.camY = wx - mx / new, wy - my / new
        self:clampCamera()
    end
end

-- Keyboard ------------------------------------------------------------------------------
-- The shortcuts are those of the original game (src/ui/keymap.lua reads KeyMap.txt); the original's controls
-- tips (shift queues orders, tab cycles production buildings ...) are in <language>/TipOfTheDay.xml.

-- Positions of recent events, newest first: Page Up / Space cycle the view back through them. This is the original's
-- message log: it keeps positions only, the last 8 of them, and a press within 2 seconds of the previous one goes one
-- entry further back, otherwise to the newest. The original logs a position every time an info box is drawn for the
-- player, so every info-box message below records the place of the item that triggered it.
local MAX_SITES, SITE_TOLERANCE = 8, 2
function S:logSite(x, y)
    self.sites = self.sites or {}
    table.insert(self.sites, 1, { x = x, y = y })
    if #self.sites > MAX_SITES then table.remove(self.sites) end
    self.siteTime = nil
    -- FUN_004dcf70: the minimap box starts only when none is running (the place is logged either way)
    if not self.infoBox then self.infoBox = { gx = math.floor(x / CW), gy = math.floor(y / CH), t0 = love.timer.getTime() } end
end

-- Log the place of the unit / building behind an info-box message (the original logs the item's map position).
function S:logSiteOf(e)
    if e and e.x and e.y then self:logSite(e.x, e.y) end
end

function S:previousSite()
    local sites = self.sites or {}
    if #sites == 0 then return end
    local now = love.timer.getTime()
    if self.siteTime and now - self.siteTime <= SITE_TOLERANCE then
        self.siteIndex = self.siteIndex % MAX_SITES + 1
        if not sites[self.siteIndex] then self.siteIndex = 1 end
    else
        self.siteIndex = 1
    end
    self.siteTime = now
    local site = sites[self.siteIndex]
    self:centreOn(site.x, site.y)
end

-- Own units (alive), all of them or those inside the current view, optionally of one type.
function S:myUnits(onScreen, code)
    local out = {}
    local vw, vh = self:viewSize()
    for _, u in ipairs(self.world.units) do
        if u:alive() and u.side == self.world.player and not u.hidden and (not code or u.code == code) then
            if not onScreen or (u.x >= self.camX and u.x <= self.camX + vw and u.y >= self.camY and u.y <= self.camY + vh) then
                out[#out + 1] = u
            end
        end
    end
    return out
end

-- Tab / Shift+Tab: the next / previous building that produces (Ctrl: only units).
function S:cycleProduction(backwards, unitsOnly)
    local world = self.world
    local list = {}
    for _, b in ipairs(world.buildings) do
        if b.side == world.player and b.hp > 0 and b.complete then
            local ok = false
            for _, code in ipairs(world.eco:productionList(b)) do
                if code:sub(1, 1) == "A" or not unitsOnly then ok = true break end
            end
            if ok then list[#list + 1] = b end
        end
    end
    if #list == 0 then return end
    local at = 0
    for i, b in ipairs(list) do if self.selection[1] == b then at = i end end
    at = backwards and (at - 2) % #list + 1 or at % #list + 1
    self:select({ list[at] })
    self:centreOn(list[at].x, list[at].y)
end

-- '.': the next builder that has nothing to do.
function S:nextIdleBuilder()
    local list = {}
    for _, u in ipairs(self:myUnits()) do
        if u.state == "idle" and self.hud:isBuilder(u) and not u.hero then list[#list + 1] = u end
    end
    if #list == 0 then self:notify(l10n.own("No idle builders"), 2) return end
    local at = 0
    for i, u in ipairs(list) do if self.selection[1] == u then at = i end end
    local u = list[at % #list + 1]
    self:select({ u })
    self:centreOn(u.x, u.y)
end

function S:selectSame(onScreen)
    local first = self.selection[1]
    local code = first and first.kind == "unit" and first.side == self.world.player and first.code or nil
    if not code then return end
    self:select(self:myUnits(onScreen, code))
end

-- Resign (Alt+R, game menu). With the advanced option "Resignation kills a side" every player's side is neutralised by
-- the resign command (and the battle ends with the defeat); without it the player just leaves the battle and the side
-- stays as it is (the resign yes / no dialog; not traced in the 1.04 binary yet).
function S:resign()
    if self.result then return end
    if self.world.advanced.resignKills then self:issue({ t = "resign" }) else screens.pop() end
end

function S:destroySelection()
    local ids, bids = {}, {}
    for _, e in ipairs(self.selection) do
        if e.side == self.world.player then
            if e.kind == "unit" then ids[#ids + 1] = e.id elseif e.kind == "building" then bids[#bids + 1] = e.id end
        end
    end
    if #ids + #bids > 0 then self:issue({ t = "destroy", ids = ids, bids = bids }) end
end

function S:openQuest()
    local world = self.world
    local hero = world.eco:heroAlive(world.player)
    if not hero or not world.opts.quests then return end
    local quests = require("src.game.quests")
    -- the shrine of the side's own quest (the picked quest of a shrine nobody visited is not the side's business);
    -- the hero need not be there, so the page is read only
    local q = world.sides[world.player].quest
    for _, b in ipairs(world.buildings) do
        if q and b.id == q.srcId and b.side == q.srcSide and b.quest and b.quest.state == "held" then
            local info = quests.visit(world, hero, b, true)
            if info then screens.push(require("src.screens.questdialog"), self, info, hero, b) end
            return
        end
    end
end

function S:togglePause()
    if not self.net then self.paused = not self.paused end
end

-- Chat: Enter starts a message to everybody,
-- Ctrl+Enter one to the allies, Shift+Enter one to the enemies; Enter sends it, Escape drops it. At most 79
-- characters and 420 pixels of text. Messages stay on screen for 15 seconds, like the original's text panel.
-- Chat travels beside the lockstep turns (lockstep.chat), so it cannot affect the simulation.
local CHAT_LENGTH, CHAT_WIDTH, CHAT_SECONDS = 79, 420, 15
local CHAT_MODES = { all = "To all: ", allies = "To allies: ", enemies = "To enemies: " }

function S:playerName(side)
    local n = self.net and self.net.names and self.net.names[side]
    return n or ("Player " .. (side + 1))
end

function S:startChat(mode)
    self.chat = { text = "", mode = mode }
end

function S:chatKey(key)
    local chat = self.chat
    ---@cast chat -nil                          -- only called while the chat line is open
    if key == "escape" then self.chat = nil
    elseif key == "backspace" then
        local off = require("utf8").offset(chat.text, -1)
        if off then chat.text = chat.text:sub(1, off - 1) end
    elseif key == "return" or key == "kpenter" then
        self.chat = nil
        local text = chat.text
        if text:match("^%s*$") then return end
        local world = self.world
        local me = world.player
        local sides = {}
        for _, side in ipairs(self.net and self.net.sides or { me }) do
            local ally = not world:enemies(me, side)
            if chat.mode == "all" or (chat.mode == "allies") == ally then sides[#sides + 1] = side end
        end
        if self.net then self.net:chat(text, sides)
        else self:chatMessage(me, text) end
    end
end

function S:chatText(t)
    local chat = self.chat
    ---@cast chat -nil                          -- only called while the chat line is open
    if #chat.text >= CHAT_LENGTH or t:match("%c") then return end
    local d, f = fonts.get(4)
    if f and f:getWidth(chat.text .. t) >= CHAT_WIDTH then return end
    chat.text = chat.text .. t
end

function S:chatMessage(side, text)
    self:notify(self:playerName(side) .. ": " .. text, CHAT_SECONDS, side)
end

function S:pollChat()
    local inbox = self.net.chatInbox
    for i = 1, #inbox do self:chatMessage(inbox[i].side, inbox[i].text) end
    if #inbox > 0 then self.net.chatInbox = {} end
end

function S:textinput(t)
    if self.chat then self:chatText(t) end
end

-- The special-ability keys of KeyMap.txt (game/abilitykeys.lua): the original tries them before every other shortcut
-- (FUN_00427fb0 calls FUN_00427f70 first). The casters and buildings are picked here, with the cells the screen shows
-- for the on-screen fallback, and go out as commands. Returns whether the key is used up.
---@param key string
---@return boolean
function S:abilityKey(key)
    local cases = keymap.abilities(key)
    if #cases == 0 then return false end
    return self:abilityCase(cases)
end

-- Runs ability cases (one case number or a list, abilitykeys.press) for the player: the troops' spell buttons come
-- here too (they call the same handler in the original). Returns whether a case was done.
---@param cases integer|integer[]
---@return boolean
function S:abilityCase(cases)
    if type(cases) ~= "table" then cases = { cases } end
    local vw, vh = self:viewSize()
    local view = { math.floor(self.camX / CW), math.floor(self.camY / CH),
                   math.floor((self.camX + vw - 1) / CW), math.floor((self.camY + vh - 1) / CH) }
    local world = self.world
    local cmds, done = require("src.game.abilitykeys").press(world, world.player, cases, self.selection, view)
    for _, cmd in ipairs(cmds) do self:issue(cmd) end
    return done
end

function S:keypressed(key)
    local world = self.world
    local is = keymap.is
    local hud = self.hud
    local dlg = hud.dialog
    if self.chat then return self:chatKey(key) end
    if (key == "return" or key == "kpenter") and not self.result and not hud.dialog then
        local ctrl, shift = love.keyboard.isDown("lctrl", "rctrl"), love.keyboard.isDown("lshift", "rshift")
        self:startChat(ctrl and "allies" or (shift and "enemies" or "all"))
        return
    end
    if dlg and dlg.kind == "repair" and (is("repairFast", key) or is("repairSlow", key)) then
        hud:startRepair(is("repairFast", key) and 1 or 0)    -- shortcuts of the original repair dialog
        return
    end
    if self.netStats then
        -- the network statistics dialog (FUN_00566760) closes on Esc and swallows every other key
        if key == "escape" then self.netStats = nil end
        return
    end
    if not self.result and self:abilityKey(key) then return end
    if key == "escape" then
        if hud.dialog then hud.dialog = nil
        elseif hud.tutorial then hud:closeTutorial()
        elseif hud.mode then hud.mode = nil
        elseif #self:ownUnits() > 0 then
            if love.keyboard.isDown("lshift", "rshift") then
                self:issue({ t = "unqueue", ids = idsOf(self:ownUnits()) })     -- Shift+Esc: drop the last order
            else
                hud:runCommand("stop")      -- Esc is the original's stop
            end
        elseif #self.selection > 0 then self:clearSelection()
        else self:openMenu() end
        return
    end
    local sel1 = hud:selection()[1]
    if key == "g" and sel1 and sel1.kind == "building" and sel1.code == "BAGR" and sel1.side == world.player then
        self:issue({ t = "ability", bid = sel1.id, ability = "gravestone" })   -- the original's G key
        return
    end
    if key == "end" then
        self:issue({ t = "unqueue", ids = idsOf(self:ownUnits()), all = true })       -- all but the running order
    elseif key == "tab" then
        self:cycleProduction(love.keyboard.isDown("lshift", "rshift"), love.keyboard.isDown("lctrl", "rctrl"))
    elseif key == "home" then
        local sd = world.sides[world.player]
        if sd.startX and sd.startX >= 0 then self:centreOn(sd.startX * CW + 16, sd.startY * CH + 12) end
    elseif key == "i" and love.keyboard.isDown("lalt", "ralt") then
        self:openInfo()
    elseif is("victory", key) then
        self:openInfo()
    elseif is("diplomacy", key) then
        hud:openDiplomacy()
    elseif is("gameMenu", key) then self:openMenu()
    elseif is("options", key) then screens.push(require("src.screens.options"), true)
    elseif is("save", key) and not self.net and not self.world.advanced.tournament then screens.push(require("src.screens.saveslots"), "save", self)
    elseif is("load", key) and not self.net and not self.world.advanced.tournament then screens.push(require("src.screens.saveslots"), "load", self)
    elseif is("quit", key) then self:openMenu()
    elseif is("resign", key) then
        self:resign()
    elseif is("pause", key) then self:togglePause()
    elseif is("previousSite", key) then self:previousSite()
    elseif key == "space" then
        -- options "Spacebar": pauses (the default; not in network games) or visits the last message
        if not require("src.core.gameopts").spacebarPauses() then self:previousSite()
        elseif not self.net then self:togglePause() end
    elseif key:match("^f[1-8]$") then
        hud:castSlot(tonumber(key:sub(2)) --[[@as integer]])         -- f1..f8: a digit
    elseif is("spellbook", key) then self:openSpells()
    elseif is("inventory", key) then self:openHero(6)
    elseif is("quests", key) then self:openQuest()
    elseif key == "l" and not love.keyboard.isDown("lctrl", "rctrl", "lalt", "ralt") then self:openHero(1, true)
    elseif is("healingPotion", key) then self:heroOp("potion", "health")
    elseif is("manaPotion", key) then self:heroOp("potion", "mana")
    elseif is("selectHero", key) then
        local hero = world.eco:heroAlive(world.player)
        if hero then self:select({ hero }) end
    elseif is("addRemoveHero", key) then
        local hero = world.eco:heroAlive(world.player)
        if hero then
            local list, found = {}, false
            for _, e in ipairs(self.selection) do
                if e == hero then found = true else list[#list + 1] = e end
            end
            if not found then list[#list + 1] = hero end
            if #list > 0 then self:select(list, true) end
        end
    elseif is("centreGroup", key) and self.selection[1] then
        self:centreOn(self.selection[1].x, self.selection[1].y)
    elseif is("formations", key) then hud:runCommand("formations")     -- presses the Formations button (FUN_004d2290)
    elseif key == "[" or key == "]" then
        -- rotate the formation (FUN_00427fb0, keys 0x5b / 0x5d): only for a group of two or more armies
        if #self:ownUnits() > 1 and self.selection[1].kind == "unit" then self:formUp(nil, key == "[" and 1 or -1) end
    elseif is("attack", key) or is("attack2", key) then hud:runCommand("attack")
    elseif is("move", key) then hud:runCommand("move")
    elseif is("rally", key) then hud:runCommand("rally")
    elseif is("produce", key) then hud:runCommand("production")
    elseif is("repair", key) and not dlg then hud:runCommand("repair")
    elseif is("unload", key) then hud:runCommand("unload")
    elseif is("build", key) then hud:pressButton("build")
    elseif is("walls", key) then hud:pressButton("walls")
    elseif is("convert", key) then hud:runCommand("convert")
    elseif is("patrol", key) then hud:runCommand("patrol")
    elseif is("guard", key) then hud:runCommand("guard")
    elseif is("destroy", key) then self:destroySelection()
    elseif is("defaultAttitude", key) then
        local ids, bids = {}, {}
        for _, e in ipairs(self.selection) do
            if e.side == world.player then
                if e.kind == "unit" then ids[#ids + 1] = e.id else bids[#bids + 1] = e.id end
            end
        end
        if #ids + #bids > 0 then
            self:issue({ t = "attitude", ids = ids, bids = bids, attitude = require("src.game.attitude").DEFAULT })
        end
    elseif is("idleBuilder", key) then self:nextIdleBuilder()
    elseif is("allRadius", key) then self.showRadius = not self.showRadius
    elseif is("networkStats", key) and not dlg and not self.result and not self.chat then
        self.netStats = { rows = require("src.ui.netstats").rows(self.net, world), t = love.timer.getTime() }
    elseif is("helpPopups", key) then
        -- the popup help key: the help level goes (level + 1) % 3 and the new one is announced with
        -- Game.txt 0067 + level (0067 / 0068 / 0069); the original shows it as a centred text for 2 s
        local opts = require("src.core.gameopts")
        local level = (opts.helpLevel() + 1) % 3
        opts.set("helplevel", level)
        self:notify(require("src.game.strings").get("Game.txt", ("%04d"):format(67 + level)) or ("Popup help " .. level), 2)
    elseif is("speedUp", key) or is("speedUp2", key) or is("speedDown", key) then
        -- five steps, as the game clock FUN_00458dd0 of the original: x0.5, 0.75, 1, 1.5, 2; the keys do not
        -- go below step 1 and do nothing while paused (game time is not scaled in network games)
        if not self.net then
            local STEPS = { 0.5, 0.75, 1, 1.5, 2 }
            local NAMES = { "0089", "0090", "0091", "0092", "0093" }      -- Game.txt "Game Speed: Very Slow" ...
            local cur = 3
            for k, v in ipairs(STEPS) do if v == world.speed then cur = k end end
            cur = math.max(1, math.min(5, cur + (is("speedDown", key) and -1 or 1)))
            world.speed = STEPS[cur]
            self:notify(require("src.game.strings").get("Game.txt", NAMES[cur]) or ("x" .. world.speed), 3)
        end
    elseif is("selectAll", key) then self:select(self:myUnits(false))
    elseif is("selectAllType", key) then self:selectSame(false)
    elseif is("selectScreen", key) then self:select(self:myUnits(true))
    elseif is("selectScreenType", key) then self:selectSame(true)
    elseif key == "f9" then
        self.fog.enabled = not self.fog.enabled
    elseif key == "f10" then
        self.showGrid = not self.showGrid
    elseif key:match("^%d$") then
        local n = tonumber(key)
        ---@cast n -nil                         -- a digit
        if love.keyboard.isDown("lctrl", "rctrl") then
            self.groups[n] = { unpack(self.selection) }
        elseif self.groups[n] then
            local list = {}
            for _, e in ipairs(self.groups[n]) do
                if (e.kind == "unit" and e:alive()) or (e.kind == "building" and e.hp > 0) then list[#list + 1] = e end
            end
            self:select(list)
        end
    end
end

-- Drawing -----------------------------------------------------------------------------

-- Drawing order key. The original sorts its display list by a draw-order row: a flyer is
-- lifted by 192 pixels (8 cell heights) so it draws above every ground item, including the
-- buildings it would otherwise hide behind (the army's row, 0x00536400).
local function sortKey(e)
    if e.sortY then return e.sortY end                    -- an effect picture (gfx/effectitems.lua)
    if e.kind == "unit" then
        if e.move == 1 then return e.y + (CH << 3) end
        return e.y
    end
    if e.shape then return e.y + (math.max(1, e.shape.h) - 1) * CH end
    return e.y
end

-- Whether the player can see an object: own/allied always, enemy units only in
-- visible cells, buildings and features once explored.
---@param e Unit|Building|Feature
---@return boolean
function S:shown(e)
    local fog = self.fog
    if not fog.enabled then return true end
    if e.kind == "unit" then
        if fog:allied(e.side) then return true end
        -- "hidden map" has no fog of war: the visibility test FUN_0047f560 tests explored instead of visible cells
        if fog.hiddenOnly then return fog:isExplored(e.gx, e.gy) end
        return fog:isVisible(e.gx, e.gy)
    end
    return fog:isExplored(e.gx, e.gy)
end

function S:drawEntity(e)
    if e.kind == "fxpic" then
        require("src.gfx.effectitems").draw(e.item, self.world.time)
        return
    end
    local team = self:teamColor(e.side or 6)
    if e.kind == "unit" then
        e:draw(function(s) return self:teamColor(s) end)
        return
    end
    local set = e.set
    if not set then return end
    local g = love.graphics
    if e.kind == "chest" then
        set:draw(A.STAND, e.dir, 0, e.x, e.y)
        return
    end
    local anim = e.anim
    if e.kind == "building" and e.rubbleSince then
        -- the wreck of a destroyed building: the collapsed look is the first construction stage (a mine
        -- has its own abandoned sprite, the upgrade levels of a building borrow their base's stage, which
        -- is openwbc3's fallback as those codes ship no construction sheet); it fades out over the last
        -- quarter of its stay and world.update then removes it altogether
        local wreckSet, wreckAnim = set, set:has(A.DIE) and A.DIE or (set:has(A.SPECIAL) and A.SPECIAL or nil)
        if not wreckAnim then
            local base = require("src.gfx.anims").get(e.code:sub(1, 3) .. "0")
            if base and base:has(A.SPECIAL) then wreckSet, wreckAnim = base, A.SPECIAL end
        end
        if not wreckAnim then return end
        local left = world_.RUBBLE_MS - (self.world.time - e.rubbleSince)
        g.setColor(1, 1, 1, math.max(0, math.min(1, left / (world_.RUBBLE_MS / 4))))
        wreckSet:draw(wreckAnim, 0, 0, e.x, e.y, team)
        g.setColor(1, 1, 1)
        return
    end
    if e.kind == "building" and not e.complete and set:has(A.SPECIAL) then
        -- the special sheet holds three construction stages (changing at 34% and 67%)
        local p = e.site and (self.world.time - e.site.t0) / (e.site.t1 - e.site.t0) or 1
        local stage = p < 0.34 and 0 or (p < 0.67 and 1 or 2)
        set:draw(A.SPECIAL, 0, stage, e.x, e.y, team)
        return
    end
    if e.kind == "building" and e.pillaged and not e.mine and set:has(A.SPECIAL) then
        -- a pillaged temple (FUN_0052c250): the special art, frame 0, then 1 and 2 as the recovery nears
        local left = e.pillaged - self.world.time
        set:draw(A.SPECIAL, 0, left < 40000 and 2 or (left < 80000 and 1 or 0), e.x, e.y, team)
        return
    end
    if e.kind == "building" and e.pillaged and set:has(A.DIE) then
        set:draw(A.DIE, 0, 0, e.x, e.y, team)
        return
    end
    if not set:has(anim) then anim = A.STAND end
    if not set:has(anim) then return end
    local n = set:frames(anim)
    local frame = e.frame
    if n > 1 then
        -- buildings and features step their STAND frames one every 100 ms; the
        -- building's step uses the .ani effectActivation frame as the delay when set
        local a = set.info[anim]
        local step = (e.kind == "building" and a and a.effectActivation or 0) or 100
        if step <= 0 then step = 100 end
        frame = math.floor((self.world.time + (e.phase or 0)) / step) % n
        -- the "ambient animations" option stops the idle animation of buildings and features
        -- (the building and feature frame steps, the latter FUN_0053d250, advance the frames only when it is on)
        if not require("src.core.gameopts").on("ambient") then frame = 0 end
    end
    if e.kind == "building" and not e.complete then
        -- construction: fade in with progress
        local p = e.site and math.max(0.15, math.min(1, (self.world.time - e.site.t0) / (e.site.t1 - e.site.t0))) or 1
        g.setColor(1, 1, 1, 0.35 + 0.65 * p)
        set:draw(anim, e.dir or 0, 0, e.x, e.y, team)
        g.setColor(1, 1, 1)
        return
    end
    set:draw(anim, e.dir or 0, frame, e.x, e.y, e.kind == "building" and team or nil)
    if e.kind == "building" then self:drawFires(e) end
end

-- Fires on a damaged building: the first burns
-- while the hits are at or below 3/4 of the maximum, the second at 1/2, the third at 1/4, at the BUI file's fire
-- points. Which effect (EF01 / EF02 / EF03) a fire uses is (sum of the four code letters + fire number) mod 3:
-- 1 -> EF02, 2 -> EF03, else EF01. The speed of the animation (10 frames per second) is openwbc3's choice. A burning
-- building loops the fire sound (the original plays Fire.wav as a looping ambient channel per burning item).
local FIRE_EFFECT = { [0] = "EF01", "EF02", "EF03" }
function S:drawFires(b)
    local sound = require("src.audio.sound")
    if b.hp <= 0 or b.pillaged or not b.complete or b.code == "BAGR" or b.side == nil then
        if b.fireSound then sound.stopLoop(b.fireSound); b.fireSound = nil end
        return
    end
    local t = require("src.game.gamedata").building(b.code)
    if not t or not t.fire then return end
    local max = b.maxHp or 0
    local levels = { math.floor(3 * max / 4), math.floor(max / 2), math.floor(max / 4) }
    local sum = 0
    for i = 1, #b.code do sum = sum + b.code:byte(i) end
    local anims = require("src.gfx.anims")
    local burning = false
    for i = 1, 3 do
        if b.hp <= levels[i] then
            burning = true
            local set = anims.get(FIRE_EFFECT[(sum + i - 1) % 3])
            local n = set and set:has(A.STAND) and set:frames(A.STAND) or 0
            if n > 0 then
                ---@cast set -nil                   -- n > 0 only with a set
                local p = t.fire[i]
                set:draw(A.STAND, 0, math.floor(self.world.time / 100 + i * 3) % n, b.x + p[1], b.y + p[2])
            end
        end
    end
    if burning and not b.fireSound then
        b.fireSound = sound.playLoopAt("Assets/SoundFX.xcr", "Fire.wav", b.gx, b.gy, { volume = 0.6 })
    elseif not burning and b.fireSound then
        sound.stopLoop(b.fireSound)
        b.fireSound = nil
    end
end

-- The conversion highlight (the building's mark FUN_0052f870, drawn by 0x00538660): every building that
-- the local player's army or keep is about to convert is drawn with its selection ring, without the health bar. The
-- list is the one made when the conversion starts (by the conversion routines FUN_0051cbb0 / FUN_0052f9b0, only
-- for the local side) and the marks go when the converter stops. The ring is the 1.04 art of SelectionRings.BMP in
-- the size class and offset of the building's .ani (green for the player's own buildings, red for the others'); the
-- tables are those at 0x00611b0c / 0x00611b28 / 0x00611b44 / 0x00611b60. Not modelled: a building two converters
-- mark loses its mark when the first of them stops (the original's single flag), openwbc3 keeps it until the last
-- one has.
local RING_MY_X, RING_THEIR_X = { [0] = 0, 0, 0, 0, 0, 422, 722 }, { [0] = 218, 218, 218, 218, 218, 422, 722 }
local RING_MY_Y, RING_THEIR_Y = { [0] = 0, 33, 82, 155, 260, 0, 0 }, { [0] = 0, 33, 82, 155, 260, 228, 301 }
local RING_W, RING_H = { [0] = 44, 65, 97, 141, 197, 300, 396 }, { [0] = 33, 49, 73, 105, 147, 228, 301 }
local ringQuads = {}

function S:drawBuildingRing(b)
    local img = require("src.ui.hud").bitmap("SelectionRings.BMP")
    local set = b.set
    if not (img and set) then return end
    local a = set.info[b.anim or 0]
    if not (a and a.used) then a = set.info[0] end
    if not a then return end
    local size = math.min(a.selSize or 0, 6)
    local mine = b.side == self.world.player
    local sx, sy = (mine and RING_MY_X or RING_THEIR_X)[size], (mine and RING_MY_Y or RING_THEIR_Y)[size]
    local w, h = RING_W[size], RING_H[size]
    local iw, ih = img:getDimensions()
    w, h = math.min(w, iw - sx), math.min(h, ih - sy)         -- (the two largest sizes run past the bitmap)
    local key = size * 2 + (mine and 1 or 0)
    local q = ringQuads[key]
    if not q then
        q = love.graphics.newQuad(sx, sy, w, h, iw, ih)
        ringQuads[key] = q
    end
    local function signed(v) return v >= 0x8000 and v - 0x10000 or v end
    love.graphics.draw(img, q, b.x - signed(a.selOriginX or 0), b.y - signed(a.selOriginY or 0))
end

function S:drawConversions()
    local world = self.world
    local me = world.player
    local marks = self.convertMarks or {}
    self.convertMarks = marks
    local g = love.graphics
    g.setColor(1, 1, 1)
    local drawn = {}
    local function mark(conv, list)
        for _, b in ipairs(list) do
            if b.hp > 0 and b.side ~= conv.side and not drawn[b] and self:shown(b) then
                drawn[b] = true
                self:drawBuildingRing(b)
            end
        end
    end
    for conv in pairs(marks) do
        local running = conv.kind == "unit" and conv.state == "convert" and conv.converting or conv.convert
        if not running or conv.side ~= me or (conv.kind == "unit" and not conv:alive()) then marks[conv] = nil end
    end
    for _, u in ipairs(world.units) do
        if u.side == me and u.state == "convert" and u.converting then
            marks[u] = marks[u] or world.eco:conversionTargets(u)
            mark(u, marks[u])
        end
    end
    for _, b in ipairs(world.buildings) do
        if b.side == me and b.convert and b.hp > 0 then
            marks[b] = marks[b] or world.eco:conversionList(b.side, b.gx, b.gy, b.convert.range)   -- (a restored save)
            mark(b, marks[b])
        end
    end
end

-- Dashed order line. The original walks the segment with Bresenham and plots a
-- point every 8th pixel, with a plus mark drawn on a subset of them that shifts over the 100 ms order-display
-- frames. Neither setDash nor setLineStipple exists in this build, so the marks are stepped along the segment here.
local function drawDashedLine(g, x1, y1, x2, y2, phase)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.floor(dist / 8))
    for i = 1, steps do
        local t = i / steps
        local px, py = x1 + dx * t, y1 + dy * t
        g.rectangle("fill", px - 1, py - 1, 2, 2)
        if ((i + phase) % 4) == 0 then
            g.line(px - 3, py, px + 3, py)
            g.line(px, py - 3, px, py + 3)
        end
    end
end

-- The pixel destination of an order and its display colour key (see drawOrderDisplay). Orders are the plain
-- specs Unit:enqueue stores (move / attack / build / taskb) plus the running order from Unit:currentOrder (task).
local function orderPoint(world, o)
    if o.kind == "move" then return o.x * CW + 16, o.y * CH + 12, "move"
    elseif o.kind == "attack" then
        local t = o.target
        if t and ((t.kind == "unit" and t:alive()) or (t.kind == "building" and t.hp > 0)) then return t.x, t.y, "attack" end
    elseif o.kind == "build" then return o.gx * CW + 16, o.gy * CH + 12, "build"
    elseif o.kind == "taskb" then
        local b = o.building
        if b and b.hp > 0 then return b.x, b.y, "convert" end
    elseif o.kind == "task" then
        local tk = o.task
        if tk.building and tk.building.hp > 0 then return tk.building.x, tk.building.y, "convert"
        elseif tk.gx then return tk.gx * CW + 16, tk.gy * CH + 12, "build" end
    end
end

-- The original's order display: a chain of dashed lines
-- from each selected unit through its running order and the waiting ones, with a pulsing end box per destination.
-- The chain reads running-first, so it also shows the order of execution (Shift appends behind, Alt inserts in front).
-- Colours from the retail build: move/patrol green, attack red, build / convert cyan. A single unit
-- gets the full path; a group gets end boxes only (the original's single-army vs multi-army flag).
function S:drawOrderDisplay()

    if (self.showCommandQueue or false) == false then return end

    local g = love.graphics
    local world = self.world
    local units = self:ownUnits()
    if #units == 0 then return end
    local lines = #units == 1
    -- animated dash offset and the pulsing end-box size (a triangle wave over 16 frames, like the order-display frame
    -- counter)
    local t = love.timer.getTime()
    local ph = (t * 10) % 16
    local n = (ph <= 8 and ph or 16 - ph)
    local box = 2 + n
    local phase = math.floor(ph)
    local COLOUR = {
        move = { 0, 0.75 + n / 255, 0 }, attack = { 0.5 + n / 255, 0, 0 },
        build = { 0, 0.5, 0.5 + n / 255 }, convert = { 0, 0.5 + n / 255, 0.5 + n / 255 },
    }
    for _, u in ipairs(units) do
        local x, y = u.x, u.y
        local chain = { u:currentOrder() }
        for _, o in ipairs(u.queue or {}) do chain[#chain + 1] = o end
        for _, o in ipairs(chain) do
            local px, py, key
            if o.kind == "convert" then
                -- the deferred convert order: the node's end equals its start (binary), so a cyan box sits
                -- at the chain cursor - the spot the unit will convert from when the order runs.
                px, py, key = x, y, "convert"
            else
                px, py, key = orderPoint(world, o)
            end
            if px then
                if lines then
                    local c = COLOUR[key]
                    g.setLineWidth(1)
                    g.setColor(c[1], c[2], c[3], 0.85)
                    drawDashedLine(g, x, y, px, py, phase)
                end
                local c = COLOUR[key]
                g.setColor(c[1], c[2], c[3], 0.9)
                g.rectangle("fill", px - box / 2, py - box / 2, box, box)
                x, y = px, py
            end
        end
        -- patrol: the loop points continue the chain (green)
        if u.patrol then
            for _, p in ipairs(u.patrol.points) do
                local px, py = p[1] * CW + 16, p[2] * CH + 12
                if lines then
                    g.setLineWidth(1)
                    g.setColor(0, 0.75 + n / 255, 0, 0.85)
                    drawDashedLine(g, x, y, px, py, phase)
                end
                g.setColor(0, 0.75 + n / 255, 0, 0.9)
                g.rectangle("fill", px - box / 2, py - box / 2, box, box)
                x, y = px, py
            end
        end
    end
    g.setColor(1, 1, 1)
end


function S:drawSelectionBackground(e)
    local g = love.graphics
    if e.kind == "unit" then
        g.setColor(0.2, 1, 0.2, 0.9)
        g.ellipse("line", e.x, e.y, 14, 7)
        if e.state == "convert" and e.converting then
            local p = (self.world.time - e.converting.t0) / (e.converting.t1 - e.converting.t0)
            g.setColor(1, 0.9, 0.3, 0.9)
            g.arc("line", "open", e.x, e.y - 30, 12, -math.pi / 2, -math.pi / 2 + 2 * math.pi * p)
        end
    else
        g.setColor(0.2, 1, 0.2, 0.7)
        for _, c in ipairs(self.world:shapeCells(e.gx, e.gy, e.shape or { w = 1, h = 1 })) do
            g.rectangle("line", c[1] * CW, c[2] * CH, CW, CH)
        end
        if e.rally then
            g.setColor(1, 1, 0.3, 0.8)
            g.line(e.x, e.y, e.rally[1] * CW + 16, e.rally[2] * CH + 12)
            g.circle("line", e.rally[1] * CW + 16, e.rally[2] * CH + 12, 5)
        end
    end
    g.setColor(1, 1, 1)
end

-- The bars of a selected unit, under its selection ring: the army drawing 0x00538660 blits the ring
-- and then the health bar 1 pixel below the ring box (44 x 7, a 4 pixel pill out of 16
-- pre-drawn ones that shrink and turn red as the hits go down) and the mana bar at the same y
-- and left edge but only 32 of those 44 pixels wide and 2 pixels tall, before the sprite, which
-- covers them. The mana bar is only drawn for the player's own armies and shows one of 8 levels,
-- floor(7 * mana / maxMana) (FUN_0051b2c0, -1 for a troop without mana).
function S:drawSelectionBars(e)
    local g = love.graphics
    if e.kind ~= "unit" then return end
    local x, y = e.x - 14, e.y + 8
    local frac = math.max(0, math.min(1, e.hp / (e.maxHp > 0 and e.maxHp or 1)))
    g.setColor(0, 0, 0, 0.7)
    g.rectangle("fill", x, y, 28, 4)
    g.setColor(1 - frac, frac, 0.1)
    g.rectangle("fill", x, y, 28 * frac, 4)
    local mana, maxMana = e.mana, e.maxMana
    if e.h then mana, maxMana = e.h.mana, e.h.mod.mana end
    if maxMana and maxMana > 0 and e.side == self.world.player then
        local level = math.floor(7 * (mana or 0) / maxMana)
        if level < 0 then level = 0 elseif level > 7 then level = 7 end
        g.setColor(0, 0, 0, 0.8)
        g.rectangle("fill", x, y + 2, 20, 2)
        g.setColor(0.34, 0.45, 1)
        g.rectangle("fill", x, y + 2, 20 * level / 7, 2)
    end
    g.setColor(1, 1, 1)
end

function S:drawPlacement()
    local hud = self.hud
    if hud.mode ~= "place" then return end
    local g = love.graphics
    local mx, my = love.mouse.getPosition()
    local wx, wy = self:toWorld(mx, my)
    local gx, gy = self:placementCell(wx, wy)
    local t = gamedata.building(hud.placeCode)
    if not t then return end
    if self.wallDrag then return self:drawWallDrag() end
    local ok = self.world.eco:canPlace(hud.placeCode, gx, gy, self.world.player, true)
    local set = require("src.gfx.anims").get(hud.placeCode)
    if set then
        g.setColor(1, 1, 1, 0.55)
        set:draw(A.STAND, 0, 0, gx * CW + 16, gy * CH + 12, self:teamColor(self.world.player))
    end
    for _, c in ipairs(self.world:shapeCells(gx, gy, t.shape)) do
        local free = self.world:free(c[1], c[2], 0)
        if ok then g.setColor(0.2, 1, 0.2, 0.35) elseif free then g.setColor(1, 0.8, 0.2, 0.35) else g.setColor(1, 0.1, 0.1, 0.45) end
        g.rectangle("fill", c[1] * CW, c[2] * CH, CW, CH)
    end
    g.setColor(1, 1, 1)
end

-- The sections of a wall being dragged: the ghost of each piece as it will be built.
function S:drawWallDrag()
    local g = love.graphics
    local world = self.world
    local set
    for _, s in ipairs(self.wallDrag.sections) do
        local t = gamedata.building(s.code)
        set = require("src.gfx.anims").get(s.code)
        if set then
            g.setColor(1, 1, 1, 0.55)
            set:draw(A.STAND, 0, 0, s.gx * CW + 16, s.gy * CH + 12, self:teamColor(world.player))
        end
        if t then
            for _, c in ipairs(world:shapeCells(s.gx, s.gy, t.shape)) do
                g.setColor(0.2, 1, 0.2, 0.35)
                g.rectangle("fill", c[1] * CW, c[2] * CH, CW, CH)
            end
        end
    end
    g.setColor(1, 1, 1)
end

function S:draw()
    local g = love.graphics
    local W, H = g.getDimensions()
    local world = self.world
    self.hud:layout()
    local vw, vh = self:viewSize()
    g.clear(0, 0, 0)
    g.push()
    g.scale(self:scale())
    g.translate(-math.floor(self.camX), -math.floor(self.camY))

    world.terrain:draw(self.camX, self.camY, vw, vh)
    self.fx:drawGround(require("src.gfx.anims"))

    if self.showGrid then
        local t = world.terrain
        local x0, y0 = math.floor(self.camX / CW), math.floor(self.camY / CH)
        for gy = y0, y0 + math.ceil(vh / CH) + 1 do
            for gx = x0, x0 + math.ceil(vw / CW) + 1 do
                if t:inside(gx, gy) then
                    if not world:free(gx, gy, 0) then
                        g.setColor(1, 0, 0, 0.25)
                        g.rectangle("fill", gx * CW, gy * CH, CW, CH)
                    end
                    g.setColor(1, 1, 1, 0.12)
                    g.rectangle("line", gx * CW, gy * CH, CW, CH)
                end
            end
        end
        g.setColor(1, 1, 1)
    end

    local list = {}
    local mx0, my0, mx1, my1 = self.camX - 200, self.camY - 100, self.camX + vw + 200, self.camY + vh + 300
    local function consider(e)
        if e.x >= mx0 and e.x <= mx1 and e.y >= my0 and e.y <= my1 and self:shown(e) then list[#list + 1] = e end
    end
    for _, e in ipairs(world.features) do consider(e) end
    for _, e in ipairs(world.chests) do consider(e) end
    for _, e in ipairs(world.buildings) do consider(e) end
    for _, e in ipairs(world.units) do if not e.hidden then consider(e) end end
    -- the effect pictures (spells, critical hits, stuns ...) sit in the list at their own row, in front of or behind the armies
    self.fx.items:collect(list, function(o) return self:shown(o) end, mx0, my0, mx1, my1)
    table.sort(list, function(a, b)
        local da, db = a.kind == "unit" and a.state == "dead", b.kind == "unit" and b.state == "dead"
        if da ~= db then return da end
        local ka, kb = sortKey(a), sortKey(b)
        if ka ~= kb then return ka < kb end
        return a.id < b.id
    end)

    -- the original's army drawing order (0x00538660): the spell aura on the ground, then the
    -- selection ring, then the bars, and the sprite last of all, so a tall sprite covers its
    -- own ring and bars
    self:drawAuras()
    self:drawConversions()
    self:drawOrderDisplay()
    for _, e in ipairs(self.selection) do self:drawSelectionBackground(e) end
    for _, e in ipairs(self.selection) do self:drawSelectionBars(e) end
    g.setColor(1, 1, 1)
    for _, e in ipairs(list) do self:drawEntity(e) end

    -- missiles: sheets have 16 direction rows (missiles.direction); they fly the original's steps (missiles.lua)
    local anims = require("src.gfx.anims")
    local missiles = require("src.game.missiles")
    for _, m in ipairs(world.missiles) do
        local x, y, dx, dy = missiles.pose(m, world.time)
        local sprite = missiles.SPRITE[m.code] or m.code
        local set = sprite and anims.get(sprite)
        if require("bit").band(m.flags, missiles.F.LIGHTNING) ~= 0 then
            -- the lightning has no sheet: the original draws it as an instant jagged bolt of five lines with a colour ramp
            -- (an instant, linear lightning missile). The jitter is a hash of the launch time, so it doesn't use
            -- math.random (network games must draw the same).
            local step = math.floor((world.time - m.t0) / 90) % 4
            local x0, y0 = m.x0, m.y0
            for line = 0, 4 do
                local pts = { x0, y0 }
                for i = 1, 6 do
                    local f = i / 7
                    pts[#pts + 1] = x0 + (m.x1 - x0) * f + math.sin(m.t0 * 0.031 + i * 78.233 + step * 37.719 + line * 5.1) * 9
                    pts[#pts + 1] = y0 + (m.y1 - y0) * f + math.cos(m.t0 * 0.017 + i * 12.345 + step * 91.17 + line * 3.7) * 9
                end
                pts[#pts + 1] = m.x1
                pts[#pts + 1] = m.y1
                local r, gr, b = missiles.lightningColour(m.code, line)
                g.setColor(r / 255, gr / 255, b / 255, 0.9)
                g.setLineWidth(line == 0 and 2 or 1)
                g.line(pts)
            end
            g.setLineWidth(1)
            g.setColor(1, 1, 1)
        elseif m.instant then
            -- the dragon breath is drawn by its own effect picture (missiles.lua launch)
        elseif sprite == "EDUM" then
            -- the ice shards and the ice floe are the invisible dummy picture: only their particles show (gfx/emitters.lua)
        elseif set and set.has then
            -- the flight is discrete like the original's (one frame per 25 / 50 ms; not traced in 1.04 yet): the picture on
            -- the step it is at, with its own animation frames, and the after-image frames of the sheet (columns `frames` ..) on
            -- the steps behind it; a thrown sheep, cow or goblin is drawn with the special animation of its unit sheet
            local f = m.frame
            local steps = m.steps
            ---@cast steps -nil                 only instant missiles have no steps
            local frames, trail = missiles.FRAMES[m.code] or 1, m.trail or 0
            local anim = require("bit").band(m.flags, 0x4000) ~= 0 and A.SPECIAL or A.STAND
            if set:has(anim) then
                if f < m.maxSteps and steps[f] then
                    set:draw(anim, missiles.direction(m, f), frames > 1 and f % frames or 0, steps[f].px, steps[f].py)
                end
                local prev = f - 1
                for i = 0, trail - 1 do
                    if prev < 0 then break end
                    if prev < m.maxSteps and steps[prev] then
                        set:draw(A.STAND, missiles.direction(m, prev), i + frames, steps[prev].px, steps[prev].py)
                    end
                    prev = prev - 1
                end
            end
        else
            local ang = math.atan2(dy, dx)
            g.setColor(0.95, 0.9, 0.7)
            g.setLineWidth(2)
            g.line(x - math.cos(ang) * 6, y - math.sin(ang) * 6, x + math.cos(ang) * 6, y + math.sin(ang) * 6)
            g.setLineWidth(1)
            g.setColor(1, 1, 1)
        end
    end

    self:drawEffects()
    self:drawSiteMarks()
    self:drawPlacement()

    self:drawSparks()
    if self.showRadius then self:drawRadius() end
    self.fx:drawOver(require("src.gfx.anims"), fonts)
    self.fog:draw()

    g.pop()

    if self.dragStart then
        local mx, my = love.mouse.getPosition()
        local sx, sy = self.dragStart[1], self.dragStart[2]
        g.setColor(0.2, 1, 0.2, 0.9)
        g.rectangle("line", math.min(sx, mx), math.min(sy, my), math.abs(mx - sx), math.abs(my - sy))
        g.setColor(1, 1, 1)
    end
    
    self:drawWeather()
    self.hud:draw()
    self:drawNotices()
    self:drawNetStats()
    self:drawEventStatus()
    if self.net and self.net.stallTime > 0.8 then
        g.push()
        g.scale(self.hud.s)
        fonts.print(1, "Waiting for other players...", 0, 150, "center", W / self.hud.s)
        g.pop()
    end
    if self.paused then
        g.push()
        g.scale(self.hud.s)
        fonts.print(1, l10n.game("0088", "Game Paused"), 0, 200, "center", W / self.hud.s)
        g.pop()
    end
    if self.result then self:drawResult() end
    if screens.top() == self then cursor.draw(self.hud.s) end
end

-- "!" over a shrine the player can still take a quest from, "?" where its quest is finished.
function S:drawSiteMarks()
    local world = self.world
    local g = love.graphics
    local quests = require("src.game.quests")
    local sd = world.sides[world.player].quest
    for _, b in ipairs(world.buildings) do
        local q = b.quest
        if q and q.state ~= "recovery" and b.hp > 0 and self:shown(b) then
            local def = quests.def(b)
            local here = sd and sd.srcId == b.id and sd.srcSide == b.side
            local ready = here and def ~= nil and quests.met(world, world.player, def)
            if not sd or here then
                local bob = math.sin(love.timer.getTime() * 4) * 3
                g.setColor(0, 0, 0, 0.6)
                g.circle("fill", b.x, b.y - 90 + bob, 11)
                g.setColor(ready and { 0.4, 1, 0.4 } or { 1, 0.9, 0.2 })
                g.circle("line", b.x, b.y - 90 + bob, 11)
                g.printf(ready and "?" or "!", b.x - 10, b.y - 99 + bob, 20, "center")
                g.setColor(1, 1, 1)
            end
        end
    end
end

-- Spell auras: the looping aura a buffed caster carries at its base while the buff lasts, and
-- the expanding ground ring a cast leaves behind. The army drawing blits its effect list before
-- the army itself, and FUN_0044e8f0 with the add-to-base flag puts the effect at the
-- item's pixel position and two grid rows north, so the y-sorted display list draws it under the
-- sprite; the effect item (vtable 0x005eb038) runs the frames every 50 ms and loops them (it is
-- not removed when finished). The aura goes under the selection ring, the bars and the sprite.
local CASTER_AURA = { "resistance", "armor" }   -- fx kinds whose entry carries an `effect` sprite
function S:drawAuras()
    local g = love.graphics
    local now = self.world.time
    local anims = require("src.gfx.anims")
    for _, u in ipairs(self.world.units) do
        if u:alive() and u.fx and self:shown(u) then
            local drawn
            for _, kind in ipairs(CASTER_AURA) do
                local f = u.fx[kind]
                local code = f and f.effect
                if code and f.t1 and f.t1 > now and not (drawn and drawn[code]) then
                    drawn = drawn or {}
                    drawn[code] = true
                    local set = anims.get(code)
                    local n = set and set:frames(A.STAND) or 0
                    ---@cast set -nil               -- drawn only when n > 0, which needs a set
                    if n > 0 then set:draw(A.STAND, 0, math.floor(now / 50) % n, u.x, u.y) end
                end
            end
        end
    end
    local effects = self.world.effects
    if effects then
        for _, e in ipairs(effects) do
            if e.kind == "ring" then
                local p = (now - e.t0) / e.dur
                if p >= 0 and p <= 1 then
                    local c = e.col
                    g.setColor(c[1], c[2], c[3], 0.6 * (1 - p))
                    g.setLineWidth(3)
                    local r = e.r * (0.3 + 0.7 * p)
                    g.ellipse("line", e.x, e.y, r, r * 0.5)
                    g.setColor(c[1], c[2], c[3], 0.15 * (1 - p))
                    g.ellipse("fill", e.x, e.y, r, r * 0.5)
                end
            end
        end
    end
    g.setLineWidth(1)
    g.setColor(1, 1, 1)
end

-- Spell effects over the map: lightning bolts and one-shot sprites (world coordinates).
function S:drawEffects()
    -- (the persistent pictures of a stun and of a burning army are effect items now: gfx/battlefx.lua `statusPictures`)
    local effects = self.world.effects
    if not effects then return end
    local g = love.graphics
    local now = self.world.time
    for _, e in ipairs(effects) do
        local p = (now - e.t0) / e.dur
        if p >= 0 and p <= 1 then
            local c = e.col
            if e.kind == "bolt" then
                local pts = { e.x0, e.y0 }
                local n = 7
                local step = math.floor(p * 6)
                for i = 1, n - 1 do
                    local f = i / n
                    -- deterministic jitter so the bolt flickers a few times
                    local j1 = math.sin(e.seed * 12.9898 + i * 78.233 + step * 37.719) * 10
                    local j2 = math.cos(e.seed * 4.1414 + i * 12.345 + step * 91.17) * 10
                    pts[#pts + 1] = e.x0 + (e.x1 - e.x0) * f + j1
                    pts[#pts + 1] = e.y0 + (e.y1 - e.y0) * f + j2
                end
                pts[#pts + 1] = e.x1
                pts[#pts + 1] = e.y1
                g.setColor(c[1], c[2], c[3], 1 - p)
                g.setLineWidth(2)
                g.line(pts)
            elseif e.kind == "sprite" then
                -- a one-shot animation (the level-up sprites EZ12 / EZ57 of the original)
                local anims = require("src.gfx.anims")
                local set = anims.get(e.code)
                if set and set:has(A.STAND) then
                    local n = set:frames(A.STAND)
                    local f = math.min(n - 1, math.floor(p * n))
                    set:draw(A.STAND, 0, f, e.x, e.y)
                end
            end
        end
    end
    g.setLineWidth(1)
    g.setColor(1, 1, 1)
end

-- Night tint (with its transition), rain, lightning over the map view (src/ui/weatherfx.lua); the rain and thunder
-- sounds are started from its update.
function S:drawWeather()
    local g = love.graphics
    self.wfx = self.wfx or require("src.ui.weatherfx").new()
    self.wfx:draw(self.world, g.getWidth(), self.hud.mapBottom or g.getHeight(), self:scale())
end

-- Countdown clock and counters that scenario events started, top right under the resources.
function S:drawEventStatus()
    local world = self.world
    local lines = {}
    local clock = world.clock
    if clock then
        local left = math.max(0, math.ceil((clock.total - (world.time - clock.t0)) / 1000))
        lines[#lines + 1] = ("%d:%02d"):format(math.floor(left / 60), left % 60)
    end
    for side = 0, 5 do
        local c = world.events.counters[side]
        if c and c.active then lines[#lines + 1] = tostring(c.value) end
    end
    -- victory modes with a running total (cached for 1.5 s like the original's update interval)
    if require("src.game.victory").RUNNING[world.victoryRule or ""] then
        local now = love.timer.getTime()
        if not self.totalsAt or now - self.totalsAt > 1.5 then
            self.totalsAt, self.totals = now, require("src.game.victory").totals(world)
        end
        if self.totals then self.hud:drawRunningTotal(self.totals) end
    end
    if #lines == 0 then return end
    local g = love.graphics
    g.push()
    g.scale(self.hud.s)
    local w = g.getWidth() / self.hud.s
    for i, l in ipairs(lines) do fonts.print(5, l, 0, 24 + (i - 1) * 18, "right", w - 10) end
    g.pop()
end

local SIDE_RGB = { { 200, 0, 0 }, { 0, 0, 200 }, { 0, 200, 0 }, { 150, 0, 200 }, { 50, 50, 50 }, { 200, 150, 0 }, { 125, 125, 125 } }

-- Ctrl+N: the figures are refreshed once a second, like the original's dialog.
function S:drawNetStats()
    local ns = self.netStats
    if not ns then return end
    local netstats = require("src.ui.netstats")
    if love.timer.getTime() - ns.t >= 1 then
        ns.rows, ns.t = netstats.rows(self.net, self.world), love.timer.getTime()
    end
    local g = love.graphics
    local s = self.hud.s
    local W, H = g.getDimensions()
    g.push()
    g.scale(s)
    netstats.draw(ns.rows, W / s, H / s, function(side) return self:teamColor(side) end)
    g.pop()
end

function S:drawNotices()
    local g = love.graphics
    local now = love.timer.getTime()
    local s = self.hud.s
    g.push()
    g.scale(s)
    local y = 40
    for i = #self.notices, 1, -1 do
        local n = self.notices[i]
        if now - n.t < n.d then
            local a = math.min(1, (n.d - (now - n.t)) * 2)
            local x = 10
            if n.side then      -- chat: a square in the sender's colour
                local c = SIDE_RGB[(self:teamColor(n.side) or 0) + 1] or SIDE_RGB[7]
                g.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a)
                g.rectangle("fill", 10, y + 3, 10, 10)
                g.setColor(1, 1, 1)
                x = 26
            end
            fonts.print(5, n.text, x, y, nil, nil, a)
            y = y + 18
        end
    end
    if self.chat then
        local c = SIDE_RGB[(self:teamColor(self.world.player) or 0) + 1] or SIDE_RGB[7]
        local blink = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
        g.setColor(c[1] / 255, c[2] / 255, c[3] / 255)
        g.rectangle("fill", 10, y + 3, 10, 10)
        g.setColor(1, 1, 1)
        fonts.print(5, CHAT_MODES[self.chat.mode] .. self.chat.text .. blink, 26, y)
    end
    g.pop()
end

function S:drawResult()
    if self.result.pending or self.result.shown then return end          -- the fanfare first; later the other screens
    local g = love.graphics
    local W, H = g.getDimensions()
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 0, W, H)
    g.push()
    g.scale(self.hud.s)
    local w = W / self.hud.s
    fonts.print(1, self.result.won and l10n.game("0728", "Victory") or l10n.game("0729", "Defeat"), 0, 220, "center", w)
    fonts.print(5, l10n.game("0730", "Click to leave") .. " " .. l10n.game("0731", "battle..."), 0, 270, "center", w)
    g.pop()
end

-- Cursor --------------------------------------------------------------------------------

function S:updateCursor()
    local hud = self.hud
    local mx, my = love.mouse.getPosition()
    if hud.dialog then
        -- the battle dialogs use the pointer hand (trade dialog 0x00572dd0, production dialog FUN_00568e30:
        -- POINTER over one of their controls, POINTERUP elsewhere inside the dialog)
        cursor.set(hud:dialogOver(mx, my) and "POINTER" or "POINTERUP")
        return
    end
    if my >= hud.mapBottom then
        cursor.set("POINTER")             -- FUN_00420390: everything below the map area is the panel
        return
    end
    if hud.mode == "move" then cursor.set("WALK") return end
    if hud.mode == "attack" then cursor.set("FIGHT") return end
    if hud.mode == "rally" then cursor.set("SELECT") return end
    if hud.mode == "patrol" then cursor.set("PATROL") return end      -- FUN_00420390: the patrol / guard modes
    if hud.mode == "guard" then cursor.set("GUARD") return end
    if hud.mode == "place" or self.dragStart then cursor.set("ARROW") return end
    local world = self.world
    local units = self:ownUnits()
    local wx, wy = self:toWorld(mx, my)
    local target = world:pick(wx, wy)
    if target and not self:shown(target) then target = nil end
    local first = self.selection[1]
    if first and first.side ~= nil and first.side ~= world.player then
        cursor.set("ARROW")             -- something that is not ours is selected: no orders
    elseif #units > 0 and units[1].hero and #units == 1 and target and target.kind == "building" and target.side == 6
        and (target.quest or target.shop) then
        cursor.set("RUIN")              -- a hero over a shrine, lair or shop: the search cursor
    elseif #units > 0 then
        -- FUN_00420390: one unit that cannot hit the enemy under the cursor shows SELECT
        -- instead of FIGHT. The original tests the target's flyer flag (bit 21), which is the A of the Army.cfg
        -- STATUS column's move letter and matches the type's moveType 1 for every unit.
        local mismatch = false
        if #units == 1 and first.kind == "unit" and target and target.kind == "unit" and self:attackable(target) then
            local flyer = target.move == 1
            mismatch = (not first:canAttackAir() and flyer) or (not first:canAttackGround() and not flyer)
        end
        if target and self:attackable(target) and not mismatch then
            cursor.set("FIGHT")
        elseif target and target.side == world.player and self:canWork(first, target) then
            cursor.set("RESUMEBUILDING")
        elseif target then
            cursor.set("SELECT")
        else
            cursor.set("WALK")
        end
    else
        cursor.set(target and "SELECT" or "ARROW")
    end
end

-- FUN_00420390: an own building or critter the selected unit can put to work, which is
-- what the RESUMEBUILDING cursor promises. The original's abandoned-construction branch has nothing
-- to do here (openwbc3 never leaves an abandoned site: the builder stays in b.site.builder) and its
-- transport case never applies (its transport and ship flag bits are zero; not checked in the 1.04 binary).
function S:canWork(u, e)
    if u.kind ~= "unit" then return false end
    if e.kind == "building" then
        if e.mine then
            return e.mine.workers < 8 and u:canWorkInMine() > 0
        elseif self.world.eco:garrisonCap(e) > 0 then
            return self.world.eco:garrisonCap(e) > self.world.eco:garrisoned(e) and u:canGarrison()
        end
    elseif e.kind == "unit" and e.side == u.side then
        return u:isMinotaur() and unitMod.isCritter(e.code)
    end
    return false
end

function S:resize()
    self.hud:layout()
    self:clampCamera()
end

return S
