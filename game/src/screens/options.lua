-- Options screen (panel PNL_GAMEOPTIONS): three tabs (Gameplay, Graphics, Sound) of up to
-- ten drop-down buttons in two columns, Credits, Okay (keeps the changes) and Cancel (restores the settings the
-- screen was opened with). The texts are the XCI texts the original uses (TXT_OPTIONS_*, ids 259..274, 346, 312);
-- the lists and their meaning follow the original screen. Settings live in
-- openwbc3.ini (src/core/gameopts.lua says which values are the original's defaults).
-- Additions of openwbc3 (not in the original screen): full screen, vertical sync and interface scale buttons on the
-- Graphics tab, and a language dropdown on the Gameplay tab (the original picks its language from the folders the
-- install has and has no way to change it once running) - picking it there only stores it in openwbc3.ini, so the
-- data already loaded this session stays as it is and the new language applies on the next start. The original's
-- CPU / RAM / version lines and the EAX, 3D provider and music-set entries are left out (EAX is shown greyed as
-- "N/A", like on a machine without it).
-- Options that are stored but not used by the simulation or renderer yet: see docs/missing.md.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local dropdown = require("src.ui.dropdown")
local config = require("src.core.config")
local opts = require("src.core.gameopts")
local music = require("src.audio.music")
local sound = require("src.audio.sound")
local strings = require("src.game.strings")
local fs = require("src.core.fs")

-- One drop-down button of a tab: its label, its list and what picking an entry does.
---@class OptionSpec
---@field label fun(): string
---@field items (fun(): string[])?
---@field pick fun(i: integer)?
---@field disabled boolean?          greyed (EAX)

---@class OptionsScreen: Screen
---@field saved table                the settings the screen was opened with (Cancel restores them)
---@field musicSet0 string           the music set it was opened with
---@field lang0 string?
---@field modes { [1]: integer, [2]: integer }[]   the display modes (width, height) of the resolution list
---@field tab integer                1 Gameplay, 2 Graphics, 3 Sound
---@field panel Panel                PNL_GAMEOPTIONS
---@field slots PanelItem[]          the ten drop-downs: left column, then right column
---@field extra PanelItem[]          openwbc3's four drop-downs under the lists (Graphics tab)
---@field tabs PanelItem[]
---@field resolutions fun(): { [1]: integer, [2]: integer }[]   for the setup screen's resolution button
---@field applyWindow fun()
local S = { overlay = true }

local function T(id, sub) return UI.text(id, sub) or "" end
local function fmt(id, sub, arg)
    return (T(id, sub):gsub("%%s", function() return arg end))
end

local function onOff(v) return T(264, v and 6 or 5) end

-- Copy of the settings, restored by Cancel.
local function copyIni()
    local out = {}
    for sec, kv in pairs(config.ini or {}) do
        out[sec] = {}
        for k, v in pairs(kv) do out[sec][k] = v end
    end
    return out
end

local function applyAudio()
    music.volume = opts.volumePercent("music") / 100
    if music.current then music.current:setVolume(music.volume) end
    sound.volume = opts.volumePercent("effects") / 100
end

local function applyWindow()
    love.window.setFullscreen(config.get("graphics", "fullscreen", false) --[[@as boolean]])
    love.window.setVSync(config.get("graphics", "vsync", true) and 1 or 0)
    local w, h = tonumber(config.get("graphics", "width", 0)), tonumber(config.get("graphics", "height", 0))
    -- (config.get gives a number for a number default)
    ---@cast w number
    ---@cast h number
    if w > 0 and h > 0 and not love.window.getFullscreen() then
        love.window.updateMode(w, h, { resizable = true, minwidth = 800, minheight = 600 })
    end
end

-- The languages the install actually has, in the original's order. The same Credits.xml probe the
-- startup detection uses (core/config.lua detect).
local function languages()
    local out = {}
    for _, name in ipairs({ "English", "French", "German", "Spanish", "Italian",
                            "Korean", "Taiwanese", "Polish", "Russian", "Japanese" }) do
        if fs.exists((config.gamedir or "") .. "/" .. name .. "/Credits.xml") then out[#out + 1] = name end
    end
    if #out == 0 then out[1] = config.language or "English" end
    return out
end

-- Display modes of the monitor that hold the 800x600 interface.
local function resolutions()
    local seen, list = {}, {}
    for _, m in ipairs(love.window.getFullscreenModes()) do
        local key = m.width .. "x" .. m.height
        if m.width >= 800 and m.height >= 600 and not seen[key] then
            seen[key] = true
            list[#list + 1] = { m.width, m.height }
        end
    end
    table.sort(list, function(a, b) return a[1] ~= b[1] and a[1] < b[1] or a[2] < b[2] end)
    return list
end

local function pair(id, a, b, getBool, setBool)
    -- a two-entry list On / Off (or the two texts a, b of one resource)
    return { items = function() return { T(id, a), T(id, b) } end, pick = function(i) setBool(i == 1) end,
             label = function() return T(id, getBool() and a or b) end }
end

local function toggle(id, sub, name)
    return {
        items = function() return { fmt(id, sub, onOff(true)), fmt(id, sub, onOff(false)) } end,
        pick = function(i) opts.set(name, i == 1) end,
        label = function() return fmt(id, sub, onOff(opts.get(name) ~= false)) end,
    }
end

local function level(id, sub, name, count, textId, textBase)
    -- levels 0..count-1 whose names are texts textBase.. of resource textId
    return {
        items = function()
            local out = {}
            for i = 0, count - 1 do out[#out + 1] = fmt(id, sub, T(textId, textBase + i)) end
            return out
        end,
        pick = function(i) opts.set(name, i - 1) end,
        label = function() return fmt(id, sub, T(textId, textBase + (tonumber(opts.get(name)) or 0))) end,
    }
end

-- Four-step effect level: Off, Minimum, Average, Maximum (GENERAL 5, GENERAL3 5..7).
local function effect(id, sub, name)
    local names = { T(264, 5), T(270, 5), T(270, 6), T(270, 7) }
    return {
        items = function()
            local out = {}
            for i = 1, 4 do out[i] = fmt(id, sub, names[i]) end
            return out
        end,
        pick = function(i) opts.set(name, i - 1) end,
        label = function() return fmt(id, sub, names[(tonumber(opts.get(name)) or 0) + 1] or names[1]) end,
    }
end

local TABS = { "gameplay", "graphics", "sound" }

-- Specs per tab, slot 1..5 left column, 6..10 right column (the original's buttons are numbered in that order).
---@type table<string, OptionSpec[]>
local SPECS = {
    gameplay = {
        { items = function() return { T(263, 2), T(263, 1), T(263, 0) } end,
          pick = function(i) opts.set("helplevel", i - 1) end,
          label = function() return T(263, 2 - math.max(0, math.min(2, opts.helpLevel()))) end },
        { items = function()
              local out = {}
              for i = 0, 4 do out[#out + 1] = fmt(263, 3, T(264, i)) end
              return out
          end,
          pick = function(i) opts.setScrollRate(i) end,
          label = function() return fmt(263, 3, T(264, opts.scrollRate() - 1)) end },
        { items = function()
              local out = {}
              for i = 0, 4 do out[#out + 1] = fmt(263, 4, T(264, i)) end
              return out
          end,
          pick = function(i) opts.set("gamespeed", i - 1) end,
          label = function() return fmt(263, 4, T(264, tonumber(opts.get("gamespeed")) or 2)) end },
        pair(263, 5, 6, function() return opts.groupMove() end, function(v) opts.set("groupmove", v) end),
        pair(274, 0, 1, function() return opts.spacebarPauses() end, function(v) opts.set("spacebar", v) end),
        pair(274, 2, 3, function() return not opts.leftClickInterface() end, function(v) opts.set("rightclick", v) end),
        { items = function() return { strings.get("Game.txt", "0751") or "Female", strings.get("Game.txt", "0752") or "Male" } end,
          pick = function(i) opts.set("sysvoice", i - 1) end,
          label = function()
              return strings.get("Game.txt", opts.systemVoiceFemale() and "0751" or "0752") or "System Voice"
          end },
        pair(312, 2, 3, function() return opts.get("tips") ~= false end, function(v) opts.set("tips", v) end),
        -- openwbc3's own: the original has no in-session language switch, so this only records the choice in
        -- openwbc3.ini and the new language takes effect on the next start
        { items = languages,
          pick = function(i)
              local lang = languages()[i]
              config.language = lang
              config.abbrev = config.abbrevFor(lang)
              config.set("game", "language", lang)
          end,
          label = function() return "Language: " .. (config.language or "English") end },
        -- openwbc3's own, off like the original: a fallen hero rises again (the setup screen of the original has no such
        -- option, so it lives here; stored as [skirmish] resurrect in openwbc3.ini, used by skirmish and network games)
        { items = function() return { "Hero resurrection: " .. onOff(true), "Hero resurrection: " .. onOff(false) } end,
          pick = function(i) config.set("skirmish", "resurrect", i == 1) end,
          label = function() return "Hero resurrection: " .. onOff(config.get("skirmish", "resurrect", false) == true) end },
    },
    graphics = {
        { items = function()
              local out = {}
              for _, m in ipairs(S.modes) do out[#out + 1] = fmt(266, 0, m[1] .. " x " .. m[2]) end
              return out
          end,
          pick = function(i)
              local m = S.modes[i]
              config.set("graphics", "fullscreen", false)
              config.set("graphics", "width", m[1])
              config.set("graphics", "height", m[2])
              applyWindow()
          end,
          label = function()
              local w, h = love.graphics.getDimensions()
              return fmt(266, 0, w .. " x " .. h)
          end },
        toggle(266, 1, "shadows"),
        toggle(266, 2, "ambient"),
        toggle(266, 3, "blood"),
        level(266, 4, "gamma", 5, 270, 0),
        pair(346, 0, 1, function() return opts.get("floattext") ~= false end, function(v) opts.set("floattext", v) end),
        effect(266, 6, "particles"),
        toggle(266, 7, "decals"),
        effect(267, 0, "lighting"),
        pair(267, 1, 2, function() return opts.get("mouseeffects") ~= false end, function(v) opts.set("mouseeffects", v) end),
    },
    sound = {
        toggle(268, 1, "envsound"),
        toggle(268, 2, "footsteps"),
        { items = function()
              local out = {}
              for i = 0, 4 do out[#out + 1] = fmt(268, 3, T(265, i)) end
              return out
          end,
          pick = function(i) opts.setVolumeLevel("effects", i); applyAudio() end,
          label = function() return fmt(268, 3, T(265, opts.volumeLevel("effects") - 1)) end },
        { items = function()
              local out = {}
              for i = 0, 4 do out[#out + 1] = fmt(268, 4, T(265, i)) end
              return out
          end,
          pick = function(i) opts.setVolumeLevel("music", i); applyAudio() end,
          label = function() return fmt(268, 4, T(265, opts.volumeLevel("music") - 1)) end },
        toggle(268, 5, "combatsounds"),
        { items = function() return { T(269, 0), T(269, 1), T(269, 2) } end,
          pick = function(i) opts.set("unitspeech", i - 1) end,
          label = function() return T(269, math.max(0, math.min(2, opts.unitSpeech()))) end },
        { disabled = true, label = function() return fmt(268, 6, T(265, 5)) end },
        pair(269, 3, 4, function() return opts.get("buildup") ~= false end, function(v) opts.set("buildup", v) end),
        pair(269, 5, 6, function() return opts.get("heartbeat") ~= false end, function(v) opts.set("heartbeat", v) end),
        -- music set: the titles of the Music/*.ini files (FUN_00413c00 / FUN_00413ff0); the label is the title alone, empty when
        -- the chosen file is not in the list
        { items = function()
              local out = {}
              for _, m in ipairs(music.sets()) do out[#out + 1] = m.title end
              return out
          end,
          pick = function(i) config.set("audio", "musicset", music.sets()[i].file) end,
          label = function()
              local file = music.setFile()
              for _, m in ipairs(music.sets()) do
                  if m.file:lower() == file:lower() then return m.title end
              end
              return ""
          end },
    },
}

-- noDim: kept for the callers that open the screen over a dialog; the panel covers the whole canvas anyway.
function S:enter()
    self.saved = copyIni()
    self.musicSet0 = music.setFile()
    self.lang0 = config.language
    self.modes = resolutions()
    self.tab = self.tab or 1
    local p = UI.panel("PNL_GAMEOPTIONS", { x = 0, y = 0, onButton = function(name, it) self:button(name, it) end })
    ---@cast p -nil
    self.panel = p
    -- the droplist buttons by slot: left column top to bottom, then right column
    local list = p:all("BUTT_OPTIONS_DROPLIST")
    table.sort(list, function(a, b)
        if a.e.x ~= b.e.x then return a.e.x < b.e.x end
        return a.e.y < b.e.y
    end)
    self.slots = list
    for _, it in ipairs(list) do p.align[it] = "left" end
    -- four more drop-downs below the lists on the Graphics tab (openwbc3's own settings)
    self.extra = {
        p:add("BUTT_OPTIONS_DROPLIST", 136, 389, "EXTRA1"),
        p:add("BUTT_OPTIONS_DROPLIST", 409, 389, "EXTRA2"),
        p:add("BUTT_OPTIONS_DROPLIST", 136, 424, "EXTRA3"),
        p:add("BUTT_OPTIONS_DROPLIST", 409, 424, "EXTRA4"),
    }
    for _, it in ipairs(self.extra) do p.align[it] = "left" end
    self.tabs = p:all("BUTT_GAMEOPTIONS_OPTION")
    for i, it in ipairs(self.tabs) do p.itemStrings[it] = T(259, i - 1) end
    -- hide the info lines (CPU / RAM / version) and give the title and the buttons their texts
    for _, it in ipairs(p:all("STR_MEDIUM200")) do p.itemStrings[it] = "" end
    p.itemStrings[p:find("STR_LARGE750")] = T(0, 3)
    p.align[p:find("STR_LARGE750")] = "center"
    p.itemStrings[p:find("BUTT_OKAY_STARTUP")] = T(2, 6)
    p.itemStrings[p:find("BUTT_CANCEL_STARTUP")] = T(2, 5)
    p.itemStrings[p:find("BUTT_CREDITS_200")] = T(0, 7)
    self:refresh()
end

function S:leave() dropdown.close() end

---@return OptionSpec[]
function S:extraSpecs()
    return {
        { label = function() return "Full screen: " .. onOff(love.window.getFullscreen()) end,
          items = function() return { "Full screen: " .. onOff(true), "Full screen: " .. onOff(false) } end,
          pick = function(i) config.set("graphics", "fullscreen", i == 1); applyWindow() end },
        { label = function() return "Vertical sync: " .. onOff(config.get("graphics", "vsync", true)) end,
          items = function() return { "Vertical sync: " .. onOff(true), "Vertical sync: " .. onOff(false) } end,
          pick = function(i) config.set("graphics", "vsync", i == 1); applyWindow() end },
        { label = function() return ("Interface scale: %d%%"):format(config.get("graphics", "uiscale", 100)) end,
          items = function()
              local out = {}
              for v = 50, 100, 10 do out[#out + 1] = ("Interface scale: %d%%"):format(v) end
              return out
          end,
          pick = function(i) config.set("graphics", "uiscale", 40 + i * 10) end },
        -- openwbc3's own, off like the original (which has no such bar): the strip of learned spells above the panel
        { label = function() return "Spell bar: " .. onOff(opts.get("spellbar") == true) end,
          items = function() return { "Spell bar: " .. onOff(true), "Spell bar: " .. onOff(false) } end,
          pick = function(i) opts.set("spellbar", i == 1) end },
    }
end

-- Texts and states of the ten buttons for the current tab.
function S:refresh()
    local p = self.panel
    local specs = SPECS[TABS[self.tab]]
    for i, it in ipairs(self.slots) do
        local spec = specs[i]
        p:setItemDisabled(it, spec == nil or spec.disabled)
        p.itemStrings[it] = spec and spec.label() or ""
    end
    local extras = self.tab == 2 and self:extraSpecs() or {}
    for i, it in ipairs(self.extra) do
        p:hideItem(it, extras[i] == nil)
        p.itemStrings[it] = extras[i] and extras[i].label() or ""
    end
end

---@param it PanelItem
---@return OptionSpec?
function S:specFor(it)
    for i, s in ipairs(self.slots) do
        if s == it then return SPECS[TABS[self.tab]][i] end
    end
    for i, s in ipairs(self.extra) do
        if s == it then return self:extraSpecs()[i] end
    end
end

-- Okay (keep the changes) or Cancel.
---@param keep boolean
function S:finish(keep)
    dropdown.close()
    if keep then
        config.save()
        -- a different music set starts over with the menu theme (the options save FUN_00414160 rereads the set, FUN_00510710)
        if music.setFile() ~= self.musicSet0 then
            music.init()
            music.stop()
            music.play("intro")
        end
    else
        config.ini = self.saved
        if config.language ~= self.lang0 then
            config.language = self.lang0
            config.abbrev = config.abbrevFor(self.lang0)
        end
        applyAudio()
        applyWindow()
    end
    screens.pop()
end

---@param name string
---@param it PanelItem
function S:button(name, it)
    if name == "BUTT_OKAY_STARTUP" then self:finish(true)
    elseif name == "BUTT_CANCEL_STARTUP" then self:finish(false)
    elseif name == "BUTT_CREDITS_200" then screens.push(require("src.screens.credits"))
    elseif name == "BUTT_GAMEOPTIONS_OPTION" then
        for i, t in ipairs(self.tabs) do if t == it then self.tab = i end end
        self:refresh()
    elseif name == "BUTT_OPTIONS_DROPLIST" or name:match("^EXTRA%d$") then
        local spec = self:specFor(it)
        if not spec or not spec.items then return end
        local mx, my = UI.toVirtual(love.mouse.getPosition())
        local items = spec.items()
        if #items == 0 then return end
        dropdown.open(items, mx, my, function(i)
            spec.pick(i)
            self:refresh()
        end)
    end
end

function S:update() music.update() end

function S:draw()
    require("src.ui.frame").dim()
    UI.begin()
    self.panel:draw()
    -- the selected tab's radio uses the original's checkbox art (CheckBox.bmp, BM_CHECKBOX): the
    -- panel draws the empty ring (row 0) for every tab, and the selected one gets the checked
    -- glyph (row 4, the bright skull) -- same rows as the tip / options checkboxes.
    local t = self.tabs[self.tab]
    if t then
        local img = UI.bitmapByName("BM_CHECKBOX")
        if img then
            local h = t.ob.h
            local q = love.graphics.newQuad(0, 4 * h, img:getWidth(), h, img:getDimensions())
            love.graphics.draw(img, q, self.panel.x + t.e.x, self.panel.y + t.e.y)
        end
    end
    dropdown.draw()
    UI.finish()
end

function S:mousemoved(x, y) self.panel:mousemoved(UI.toVirtual(x, y)) end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if dropdown.pressed(vx, vy) then return end
    self.panel:mousepressed(vx, vy, button)
end

function S:mousereleased(x, y, button)
    if dropdown.isOpen() then return end
    local vx, vy = UI.toVirtual(x, y)
    self.panel:mousereleased(vx, vy, button)
end

function S:keypressed(key)
    if dropdown.isOpen() then
        if key == "escape" then dropdown.close() end
        return
    end
    if key == "escape" then self:finish(false)
    elseif key == "return" or key == "kpenter" then self:finish(true)
    elseif key == "f11" then
        config.set("graphics", "fullscreen", not love.window.getFullscreen())
        applyWindow()
        self:refresh()
    end
end

-- Dev: --show options:graphics | sound | gameplay
function S:dev(sub)
    for i, n in ipairs(TABS) do if n == sub then self.tab = i end end
    self:refresh()
end

-- the setup screen's resolution button (BUTT_SS_RES) uses the same mode list and window code
S.resolutions, S.applyWindow = resolutions, applyWindow

return S
