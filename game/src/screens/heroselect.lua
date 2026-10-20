-- "Select a Hero": browse the player's heroes, create a new one, delete, look at details,
-- or load a saved game. enter(onDone) - onDone() runs after a hero was chosen.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local kit = require("src.ui.kit")
local fonts = require("src.ui.fonts")
local portraits = require("src.ui.portraits")
local profile = require("src.game.profile")
local classes = require("src.game.classes")
local music = require("src.audio.music")
local dropdown = require("src.ui.dropdown")
local herocustom = require("src.game.herocustom")

---@class HeroSelectScreen: Screen
---@field onDone fun(rec: table)?    runs after a hero was chosen (gets its profile record)
---@field mode string                "list", "new", "password", "delete" (or a --show sub)
---@field list table[]               the profile's heroes (profile.list)
---@field index integer              the hero shown
---@field notice string?             e.g. "Hero Already Exists!"
---@field new { name: string, race: integer, class: string, password: string, heroMode: integer, portrait: integer?, avatar: integer?, voice: integer? } the hero being created (mode "new")
---@field sorted integer[]?          class numbers sorted by their displayed name
---@field panel Panel?               PNL_SH (the list)
---@field cpanel Panel?              PNL_CREATEHERO
---@field ppanel Panel?              the password prompt
---@field dpanel Panel?              the delete question
---@field raceButton PanelItem?      create panel drop-downs
---@field classButton PanelItem?
---@field editFont integer           font of the name field
---@field pwAction string?           "select" / "load": what the password is asked for
---@field pwText string              the password being typed
---@field pwFont integer
local S = {}
S.helpId = 1          -- screen help (src/screens/screenhelp.lua)

---@param onDone fun(rec: table)?
function S:enter(onDone)
    self.onDone = onDone
    self.mode = "list"
    self.list = profile.list()
    self.index = 1
    local cur = profile.current()
    for i, h in ipairs(self.list) do if cur and h.id == cur.id then self.index = i end end
    self.notice = nil
    self:buildPanel()
    if #self.list == 0 then self:startNew() end
end

function S:resume()
    self.list = profile.list()
    self.index = math.min(math.max(1, self.index), math.max(1, #self.list))
end

---@return table? rec the profile record shown
function S:hero() return self.list[self.index] end

-- developer aid (--show heroselect:new / :delete / :customize)
function S:dev(sub)
    if sub == "new" then self:startNew() self.new.name = "Aldric"
    elseif sub == "daemon" then
        self:startNew()
        self.new.name = "sage"
        self:setRace(11)
        self.new.class = "Sage"
    elseif sub and sub:match("^customize") then          -- customize / customizevoice / customizemode
        self:dev("daemon")
        local c = require("src.screens.herocustomize")
        screens.push(c, self.new)
        if sub == "customizevoice" then c:button("BUTT_OPTIONS_DROPLIST", c.voiceButton)
        elseif sub == "customizemode" then c:button("BUTT_OPTIONS_DROPLIST", c.modeButton) end
    elseif sub == "password" and self:hero() then        -- the password prompt (the hero gets a password for the shot)
        self:hero().password = "secret"
        self:askPassword("select")
    elseif sub == "delete" and self:hero() then self:openDelete()
    elseif sub and sub:match("^info") and self:hero() then      -- info / info3: More Info on that tab
        screens.push(require("src.screens.heroinfo"), nil, tonumber(sub:match("%d+")) or 1, self:hero())
    else self.mode = sub end
end

-- New hero ------------------------------------------------------------------------------
-- PNL_CREATEHERO as in the original (opener FUN_0054b040): name field, race and class drop-down lists (classes sorted
-- by their displayed name), the starting attributes of the choice and "Customize...", which opens the
-- customisation screen (portrait, avatar, password, voice set, mode).

local NAME_LENGTH = 19              -- the original's name holds 20 bytes including the terminator
local FORBIDDEN = "[~!@#$%^&*{}%[%]:;\"'\\|<>.,?/`]"      -- the original replaces these in a name by '_' (FUN_0054b620)

local function raceText(r)
    return (r < 8 and UI.text(15, r) or UI.text(104, r - 8)) or classes.RACE_NAMES[r] or "?"
end

-- classes.list()[i + 1] is the original's class number i (texts 8..11, eight per group)
local function classText(i)
    return UI.text(8 + math.floor(i / 8), i % 8) or classes.list()[i + 1][1]
end

local function classNumber(name)
    for i, c in ipairs(classes.list()) do if c[1] == name then return i - 1 end end
    return 0
end

local function sortedClasses()
    local list = {}
    for i = 0, #classes.list() - 1 do list[#list + 1] = i end
    table.sort(list, function(a, b) return classText(a) < classText(b) end)
    return list
end

function S:startNew()
    self.mode = "new"
    self.new = { name = "", race = 0, class = "Warrior", password = "", heroMode = 0 }
    self:setRace(0)
    self:buildCreatePanel()
    -- the new-hero screen has its own help (the original opens it when the create screen is set up)
    require("src.screens.screenhelp").open(2)
end

-- A new race brings its own default portrait, avatar and voice set.
---@param race integer
function S:setRace(race)
    local n = self.new
    n.race = race
    n.portrait = herocustom.defaultPortrait(race)
    n.avatar = herocustom.defaultAvatar(race)
    n.voice = herocustom.defaultVoice(race)
end

function S:buildCreatePanel()
    local p = UI.panel("PNL_CREATEHERO", { x = 0, y = 0, onButton = function(name, it) self:createButton(name, it) end })
    self.cpanel = p
    if not p then return end
    p:hide("IM_PORTRAIT")           -- drawn by us
    p:setString("BUTT_OKAY_STARTUP", "")
    p:setString("BUTT_CANCEL_STARTUP", "")
    p:setString("STR_LARGE750", UI.text(3, 0) or "Create New Hero")
    p.align[p:find("STR_LARGE750")] = "center"
    p:setTextAt("STR_MEDIUM120", 346, 211, UI.text(3, 2) or "Name")
    p:setTextAt("STR_MEDIUM120", 346, 275, UI.text(3, 3) or "Race")
    p:setTextAt("STR_MEDIUM120", 346, 339, UI.text(3, 4) or "Class")
    for _, y in ipairs({ 325, 341, 357, 373 }) do p.align[p:at("STR_SMALL120", 209, y)] = "center" end
    self.raceButton = p:at("BUTT_OPTIONS_DROPLIST", 346, 298)
    self.classButton = p:at("BUTT_OPTIONS_DROPLIST", 346, 362)
    p.align[self.raceButton] = "left"
    p.align[self.classButton] = "left"
    local ob = UI.ui.objByName.BUTT_OPTIONS_DROPLIST
    self.editFont = ob and ob.fonts and ob.fonts[1] or 5
end

---@param name string
---@param it PanelItem?
function S:createButton(name, it)
    if name == "BUTT_OKAY_STARTUP" then self:create()
    elseif name == "BUTT_CANCEL_STARTUP" then self:act("cancelnew")
    elseif name == "BUTT_CUSTOMIZE" then
        screens.push(require("src.screens.herocustomize"), self.new)
    elseif name == "BUTT_OPTIONS_DROPLIST" then
        local mx, my = UI.toVirtual(love.mouse.getPosition())
        if it == self.raceButton then
            local items = {}
            for r = 0, 15 do items[#items + 1] = raceText(r) end
            dropdown.open(items, mx, my, function(i) self:setRace(i - 1) end)
        elseif it == self.classButton then
            local items = {}
            self.sorted = self.sorted or sortedClasses()
            for _, c in ipairs(self.sorted) do items[#items + 1] = classText(c) end
            dropdown.open(items, mx, my, function(i) self.new.class = classes.list()[self.sorted[i] + 1][1] end)
        end
    end
end

local function nameTaken(list, name)
    for _, h in ipairs(list) do
        if h.name:lower() == name:lower() then return true end
    end
end

function S:create()
    local n = self.new
    local name = n.name:match("^%s*(.-)%s*$")
    if name == "" then return end
    if nameTaken(self.list, name) then
        self.notice = ("%s %s %s"):format(UI.text(3, 5) or "Hero Already Exists!", UI.text(3, 6) or "", UI.text(3, 7) or "")
        return
    end
    local rec = profile.create({ name = name, race = n.race, class = n.class, portrait = n.portrait,
                                 voice = n.voice, avatar = n.avatar, password = n.password, mode = n.heroMode })
    profile.setCurrent(rec.id)
    self.list = profile.list()
    for i, h in ipairs(self.list) do if h.id == rec.id then self.index = i end end
    self.mode = "list"
    self.notice = nil
end

-- Drawing ----------------------------------------------------------------------------------

-- PNL_SH (War4Int.xci) is the original layout: full-screen background, the stone slab with the hero
-- (IM_SH_PICTURE, bitmap 560), previous/next arrows, four skull buttons and the thumbs down/up.
local BUTTONS = {
    BUTT_NEWHERO_200 = "new", BUTT_MOREINFO_200 = "info", BUTT_DELETE_200 = "delete",
    BUTT_LOADGAME_200 = "load", BUTT_PREVIOUS = "prev", BUTT_NEXT = "next",
    BUTT_CANCEL_STARTUP = "back", BUTT_OKAY_STARTUP = "select",
}

function S:buildPanel()
    local p = UI.panel("PNL_SH", {
        x = 0, y = 0,
        onButton = function(name) if self.mode == "list" and BUTTONS[name] then self:act(BUTTONS[name]) end end,
    })
    self.panel = p
    if not p then return end
    p:hide("IM_SH_BACKGROUND")      -- drawn by us, so the slab can go behind the texts
    p:hide("IM_PORTRAIT")
    p:hide("BUTT_SH_FULLSCREEN")
    p:setString("BUTT_OKAY_STARTUP", "")
    p:setString("BUTT_CANCEL_STARTUP", "")
    p:setString("STR_LARGE750", "Select a Hero")
    p.align[p:find("STR_LARGE750")] = "center"
    p.align[p:find("STR_MEDIUM_LARGE_240")] = "center"
    for _, it in ipairs(p:all("STR_SMALL220")) do p.align[it] = "center" end
end

function S:drawList()
    local h = self:hero()
    local p = self.panel
    local g = love.graphics
    local bg, slab = UI.bitmap(550), UI.bitmap(560)
    UI.drawScreen("SCR_STARTUP")    -- dimmed copy filling the window around the 4:3 picture
    if bg then g.draw(bg, 0, 0) end
    if slab then g.draw(slab, 276, 157) end
    if p then
        local many = #self.list > 1
        p:hideItem(p:find("BUTT_PREVIOUS") --[[@as PanelItem]], not many)
        p:hideItem(p:find("BUTT_NEXT") --[[@as PanelItem]], not many)
        p:setDisabled("BUTT_MOREINFO_200", not h)
        p:setDisabled("BUTT_DELETE_200", not h)
        p:setDisabled("BUTT_OKAY_STARTUP", not h)
        p:setString("STR_MEDIUM_LARGE_240", h and h.name or "")
        p:setTextAt("STR_SMALL220", 288, 331, h and classes.RACE_NAMES[h.race] or "")
        p:setTextAt("STR_SMALL220", 288, 350, h and h.class or "")
        p:setTextAt("STR_SMALL220", 288, 369, h and ("Level: %d"):format(h.hero and h.hero.level or 1) or "")
        p:draw()
    end
    if h then portraits.draw(h.portrait, 350, 219, 98, 98) end
    if self.notice then fonts.print(5, self.notice, 0, 520, "center", 800) end
end

function S:drawNew()
    local p, n = self.cpanel, self.new
    love.graphics.clear(0, 0, 0, 1)         -- the picture is 4:3, the original leaves the rest black
    if not p then return end
    local attr = classes.baseAttr(n.race, n.class)
    for i, key in ipairs({ "str", "dex", "int", "cha" }) do
        p:setTextAt("STR_SMALL120", 209, 325 + (i - 1) * 16, (UI.text(5, i - 1) or "%d"):format(attr[key]))
    end
    p.itemStrings[self.raceButton] = raceText(n.race)
    p.itemStrings[self.classButton] = classText(classNumber(n.class))
    p:setDisabled("BUTT_OKAY_STARTUP", n.name:match("^%s*$") ~= nil)
    p:draw()
    local img = portraits.get(n.portrait)
    if img then
        local iw, ih = img:getDimensions()
        love.graphics.draw(img, 221, 212, 0, 98 / iw, 98 / ih)
    end
    local caret = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    fonts.print(self.editFont, n.name .. caret, 356, 234 + fonts.middleY(self.editFont, 17))
    if self.notice then fonts.print(5, self.notice, 0, 480, "center", 800) end
end

-- Password prompt (PNL_PASSWORD, opener FUN_00555bc0, handler 0x00555d20): a hero with a password asks for it before it is
-- chosen, before a saved game is loaded and before it is deleted; the comparison ignores case (profile.passwordMatches),
-- a wrong password plays the editor error sound and keeps the prompt, Cancel returns to the list. The heading is text 4
-- of TXT_HCRE_IDENTITY_NAME (FUN_00555bc0). Not verified: whether the entry is masked (it is shown as typed here).
-- This screen is the only way to pick a hero, also for the campaign and the multiplayer lobby (the main menu pushes it
-- with a callback), as in the original where all of them go through its hero selection screen.
local PASSWORD_LENGTH = 15

function S:askPassword(action)
    local h = self:hero()
    if not h then return end
    if not h.password or h.password == "" then return self:passwordOk(action) end
    self.pwAction, self.pwText, self.mode = action, "", "password"
    local p = UI.panel("PNL_PASSWORD", { x = 0, y = 0, onButton = function(name) self:passwordButton(name) end })
    self.ppanel = p
    if p then
        p:setString("STR_PARCHLARGE_L400", UI.text(142, 4) or "Enter password")
        p.align[p:find("STR_PARCHLARGE_L400")] = "center"
        local ob = UI.ui.objByName.EDIT_PASSWORD
        self.pwFont = ob and ob.fonts and ob.fonts[1] or 5
    end
end

function S:passwordOk(action)
    if action == "select" then
        local h = self:hero()
        ---@cast h -nil
        self.mode = "list"
        profile.setCurrent(h.id)
        screens.pop()
        if self.onDone then self.onDone(h) end
    elseif action == "load" then
        self.mode = "list"
        screens.push(require("src.screens.saveslots"), "load")
    elseif action == "delete" then
        self:deleteHero()
    end
end

function S:passwordSubmit()
    local h = self:hero()
    if h and profile.passwordMatches(h, self.pwText) then
        require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
        self:passwordOk(self.pwAction)
    else
        require("src.audio.sound").play("Assets/SoundFX.xcr", "Error.wav")
    end
end

function S:passwordButton(name)
    if name == "BUTT_OKAY_180" then self:passwordSubmit()
    elseif name == "BUTT_CANCEL_180" then self.mode = "list" end
end

function S:drawPassword()
    local p = self.ppanel
    if not p then return end
    p:draw()
    local caret = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    fonts.print(self.pwFont, self.pwText .. caret, 270, 285 + fonts.middleY(self.pwFont, 19))
end

-- Delete (FUN_00555a70 opens the box, its callback 0x00555ad0 deletes): the Delete button and key open the generic OK / Cancel
-- dialog (PNL_OKAYCANCEL, FUN_004361c0) headed "Delete Hero" (TXT_EXTRAHERO 0) with the text of TXT_EXTRAHERO 1
-- and 2 wrapped to 380 pixels; only after OK a hero with a password asks for it (the password prompt), then the hero,
-- its saved game and its campaign files go. PNL_SECUREHERODELETE belongs to the GameSpy secure heroes
-- (it deletes a record of the game service's hero database) and is not used for local heroes.
function S:openDelete()
    if not self:hero() then return end
    self.mode = "delete"
    local p = UI.panel("PNL_OKAYCANCEL", { x = 0, y = 0, onButton = function(name) self:deleteButton(name) end })
    self.dpanel = p
    if not p then return end
    p:setString("STR_LARGE400", UI.text(6, 0) or "Delete Hero")
    p.align[p:find("STR_LARGE400")] = "center"
    local ob = UI.ui.objByName.STR_MEDIUM500
    local _, f = fonts.get(ob.font)
    local text = ("%s %s"):format(UI.text(6, 1) or "", UI.text(6, 2) or "")
    local lines = {}
    if f then local _, w = f:getWrap(text, 380) lines = w else lines = { text } end
    for i, it in ipairs(p:all("STR_MEDIUM500")) do
        p.itemStrings[it] = lines[i] or ""
        p.align[it] = "center"
    end
end

function S:deleteButton(name)
    if name == "BUTT_OKAY_180" then self:askPassword("delete")
    elseif name == "BUTT_CANCEL_180" then self.mode = "list" end
end

function S:deleteHero()
    profile.delete(self:hero().id)
    self.list = profile.list()
    self.index = math.min(self.index, math.max(1, #self.list))
    self.mode = "list"
    if #self.list == 0 then self:startNew() end
end

function S:drawDelete()
    local p = self.dpanel
    if p then p:draw() end
end

function S:draw()
    UI.begin()
    kit.begin(self)
    if self.mode ~= "new" then kit.backdrop() end
    if self.mode == "list" then self:drawList()
    elseif self.mode == "new" then self:drawNew()
    elseif self.mode == "password" then
        self:drawList()
        self:drawPassword()
    else
        self:drawList()
        self.hits = {}
        self:drawDelete()
    end
    dropdown.draw()
    UI.finish()
end

-- Input ---------------------------------------------------------------------------------------

local function wrap(i, n) return (i - 1) % n + 1 end

function S:act(id, extra)
    if id == "prev" then self.index = wrap(self.index - 1, #self.list)
    elseif id == "next" then self.index = wrap(self.index + 1, #self.list)
    elseif id == "new" then self:startNew()
    elseif id == "info" then screens.push(require("src.screens.heroinfo"), nil, 1, self:hero())
    elseif id == "delete" then self:openDelete()
    elseif id == "load" then
        self:askPassword("load")
    elseif id == "back" then screens.pop()
    elseif id == "select" then
        self:askPassword("select")
    elseif id == "cancelnew" then
        if #self.list > 0 then self.mode = "list" self.notice = nil else screens.pop() end
    end
end

-- the panel of the current mode (list or create)
function S:activePanel()
    if self.mode == "list" then return self.panel end
    if self.mode == "new" then return self.cpanel end
    if self.mode == "password" then return self.ppanel end
    if self.mode == "delete" then return self.dpanel end
end

function S:mousemoved(x, y)
    local p = self:activePanel()
    if p then p:mousemoved(UI.toVirtual(x, y)) end
end

function S:mousereleased(x, y, button)
    local p = self:activePanel()
    if not p then return end
    local vx, vy = UI.toVirtual(x, y)
    p:mousereleased(vx, vy, button)
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if dropdown.pressed(vx, vy) then return end
    if button ~= 1 then return end
    local p = self:activePanel()
    if p then p:mousepressed(vx, vy, button) return end
    local id, extra = kit.click(self, vx, vy)
    if id then
        require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
        self:act(id, extra)
    end
end

function S:textinput(t)
    if self.mode == "password" then
        if #self.pwText < PASSWORD_LENGTH and not t:match("%c") then self.pwText = (self.pwText .. t):sub(1, PASSWORD_LENGTH) end
        return
    end
    if self.mode ~= "new" or dropdown.isOpen() then return end
    local n = self.new
    if #n.name < NAME_LENGTH and not t:match("%c") then
        n.name = (n.name .. t):sub(1, NAME_LENGTH):gsub(FORBIDDEN, "_")
        self.notice = nil
    end
end

function S:keypressed(key)
    if self.mode == "password" then
        if key == "backspace" then self.pwText = kit.backspace(self.pwText)
        elseif key == "return" or key == "kpenter" then self:passwordSubmit()
        elseif key == "escape" then self.mode = "list" end
        return
    end
    if self.mode == "new" then
        if dropdown.isOpen() then
            if key == "escape" then dropdown.close() end
            return
        end
        if key == "backspace" then self.new.name = kit.backspace(self.new.name)
        elseif key == "return" or key == "kpenter" then self:create()
        elseif key == "escape" then self:act("cancelnew") end
        return
    end
    if self.mode == "delete" then
        if key == "escape" then self.mode = "list" end
        return
    end
    if self.mode ~= "list" then
        if key == "escape" or key == "return" then self.mode = "list" end
        return
    end
    if key == "left" and #self.list > 1 then self:act("prev")
    elseif key == "right" and #self.list > 1 then self:act("next")
    elseif key == "return" or key == "kpenter" then self:act("select")
    elseif key == "escape" then self:act("back")
    elseif key == "delete" and self:hero() then self:openDelete() end
end

function S:update() music.update() end

function S:leave() dropdown.close() end

return S
