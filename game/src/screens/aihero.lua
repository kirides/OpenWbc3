-- The AI hero panel of the side selection screen (PNL_VIEWHERO, opened by right-clicking a computer side as
-- the 1.04 binary does: the opener FUN_004edd00, the fill routine FUN_004ed7e0 and the button handler at
-- 0x004ee060): the computer hero's portrait (the race's), its race and class (drop-down lists of the 16 races and
-- 28 classes), its level (arrows, 4..50) and the AI script (the "AI File" button opens PNL_SELECTAIFILE). The four
-- stat lines stay "Strength : ?" ... (text 288.1-4). Okay keeps everything the panel shows, Cancel drops it, as does a
-- script picked in the list.
--
--   screens.push(require("src.screens.aihero"), { hero = { race, class, level }, file = "x.ai", files = { { file, name } },
--                sideRace = 3 | nil, heroLevel = 12, onDone = function(hero, file) end })
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local classes = require("src.game.classes")
local aihero = require("src.game.aihero")
local portraits = require("src.ui.portraits")
local dropdown = require("src.ui.dropdown")

---@class AIHeroConfig
---@field hero table             { race, class, level }; unset ones get their defaults
---@field file string?           the AI script
---@field files { file: string, name: string }[]?
---@field sideRace integer?
---@field heroLevel integer?
---@field onDone fun(hero: table, file: string?)?

---@class AIHeroScreen: Screen
---@field cfg AIHeroConfig
---@field hero table             { race, class, level } (aihero.fill)
---@field file string?
---@field panel Panel?
---@field raceLabel PanelItem?
---@field classLabel PanelItem?
---@field levelText PanelItem?
---@field raceButton PanelItem?
---@field classButton PanelItem?
---@field fileName PanelItem?
---@field leftArrow PanelItem?
---@field rightArrow PanelItem?
local S = { overlay = true }

local function raceText(r)
    return (r < 8 and UI.text(15, r) or UI.text(104, r - 8)) or classes.RACE_NAMES[r] or "?"
end

-- classes.list()[i + 1] is the original's class number i (texts 8..11, eight per group)
local function classText(i)
    return UI.text(8 + math.floor(i / 8), i % 8) or classes.list()[i + 1][1]
end

---@param cfg AIHeroConfig?
function S:enter(cfg)
    cfg = cfg or { hero = {}, files = {}, heroLevel = 1 }
    self.cfg = cfg
    -- the fill routine FUN_004ed7e0: what is unset gets its default when the panel opens
    self.hero = aihero.fill(cfg.hero, cfg.sideRace, cfg.heroLevel)
    self.file = cfg.file
    local p = UI.panel("PNL_VIEWHERO", { x = 0, y = 0, onButton = function(name, it) self:button(name, it) end })
    self.panel = p
    if not p then return end
    p:hide("IM_PORTRAIT")                 -- drawn by us
    p:hide("PAD_FULLSCREEN800x600")
    p:setString("STR_LARGE400", UI.text(288, 0) or "AI Hero")
    p.align[p:find("STR_LARGE400")] = "center"
    for _, n in ipairs({ "BUTT_LEFT_20", "BUTT_RIGHT_20" }) do p:setString(n, "") end   -- arrows only
    self.raceLabel = p:setTextAt("STR_MEDIUM200", 300, 180, UI.text(3, 3) or "Race")
    self.classLabel = p:setTextAt("STR_MEDIUM200", 300, 248, UI.text(3, 4) or "Class")
    self.levelText = p:at("STR_MEDIUM200", 519, 205)
    p.align[self.levelText] = "center"
    for i, y in ipairs({ 300, 320, 340, 360 }) do
        local it = p:at("STR_SMALL260", 87, y)
        ---@cast it -nil
        p.align[it] = "center"
        p.itemStrings[it] = UI.text(288, i) or ""
    end
    p:setTextAt("STR_MEDIUM220", 107, 160, "")
    self.raceButton = p:at("BUTT_OPTIONS_DROPLIST", 300, 200)
    self.classButton = p:at("BUTT_OPTIONS_DROPLIST", 300, 268)
    p.align[self.raceButton] = "left"
    p.align[self.classButton] = "left"
    self.fileName = p:at("STR_MEDIUM265", 495, 329)
    self.leftArrow, self.rightArrow = p:at("BUTT_LEFT_20", 593, 223), p:at("BUTT_RIGHT_20", 625, 223)
end

function S:leave() dropdown.close() end

local function nameOf(files, file)
    for _, f in ipairs(files or {}) do
        if f.file == file then return f.name end
    end
end

---@param ok boolean
function S:finish(ok)
    screens.pop()
    if ok and self.cfg.onDone then self.cfg.onDone(self.hero, self.file) end
end

function S:chooseFile()
    local items, at = { "None" }, 1
    local files = self.cfg.files or {}
    for _, f in ipairs(files) do
        items[#items + 1] = f.name
        if self.file == f.file then at = #items end
    end
    screens.push(require("src.screens.aifilelist"), { items = items, selected = at,
        onDone = function(index) self.file = index > 1 and files[index - 1] and files[index - 1].file or nil end })
end

---@param name string
---@param it PanelItem?
function S:button(name, it)
    local h = self.hero
    local mx, my = UI.toVirtual(love.mouse.getPosition())
    if name == "BUTT_OKAY_200" then self:finish(true)
    elseif name == "BUTT_CANCEL_200" then self:finish(false)
    elseif name == "BUTT_HERODATAAI_AIFILE" then self:chooseFile()
    elseif it == self.leftArrow or it == self.rightArrow then
        h.level = aihero.stepLevel(h.level, it == self.leftArrow and -1 or 1)
    elseif it == self.raceButton then
        local items, slots = {}, classes.raceSlots()
        for _, r in ipairs(slots) do items[#items + 1] = raceText(r) end
        dropdown.open(items, mx, my, function(i) h.race = slots[i] end)
    elseif it == self.classButton then
        local items = {}
        for c = 0, aihero.classCount() - 1 do items[#items + 1] = classText(c) end
        dropdown.open(items, mx, my, function(i) h.class = i - 1 end)
    end
end

function S:update() require("src.audio.music").update() end

function S:draw()
    local p, h = self.panel, self.hero
    UI.begin()
    if p then
        p.itemStrings[self.raceButton] = raceText(h.race)
        p.itemStrings[self.classButton] = classText(h.class)
        p.itemStrings[self.levelText] = ((UI.text(5, 4) or "Level: %d"):gsub("%%d", tostring(h.level)))
        p.itemStrings[self.fileName] = nameOf(self.cfg.files, self.file) or "None"
        p:draw()
        local img = portraits.get(h.race)           -- Portrait<race>.bmp
        if img then
            local iw, ih = img:getDimensions()
            love.graphics.draw(img, 167, 187, 0, 98 / iw, 98 / ih)
        end
    end
    dropdown.draw()
    UI.finish()
end

function S:mousemoved(x, y)
    if self.panel then self.panel:mousemoved(UI.toVirtual(x, y)) end
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if dropdown.pressed(vx, vy) then return end
    if self.panel then self.panel:mousepressed(vx, vy, button) end
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.panel then self.panel:mousereleased(vx, vy, button) end
end

function S:keypressed(key)
    if dropdown.isOpen() then
        if key == "escape" then dropdown.close() end
        return
    end
    if key == "escape" then self:finish(false)
    elseif key == "return" or key == "kpenter" then self:finish(true) end
end

function S:dev(sub)
    self:enter({ hero = sub == "set" and { race = 5, class = 13, level = 20 } or {}, heroLevel = 8, sideRace = 1,
                 files = { { file = "A.ai", name = "Raider" }, { file = "B.ai", name = "Turtle" } } })
end

return S
