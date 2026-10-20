-- The mod manager (docs/data-driven/06-mod-runtime.md 6.4): the mods found in <save directory>/mods, in `[mods] path=` and on the command
-- line, which of them are enabled, in what order they load, what they need and what went wrong at the last start. A change is written to
-- <save directory>/mods/enabled.lua and applies the next time the game starts (the content registry is built once, before the main menu).
-- Mods are code: the manager says which ones run Lua (a "gameplay" mod) and that the sandbox prevents accidents, not malice.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local kit = require("src.ui.kit")
local fonts = require("src.ui.fonts")
local mods = require("src.content.mods")

-- A row of the list: a mod folder (content/mods.lua discover's record) and whether it is enabled.
---@class ModRow
---@field rec table                  { id, folder, dir, manifest, source, error }
---@field on boolean
---@field cli boolean?               enabled with --mod for this session
---@field broken boolean?            no manifest

---@class ModsScreen: Screen
---@field sel integer                the selected row
---@field top integer                the first row shown
---@field changed boolean            the list was changed (written on leave)
---@field notice string?
---@field order string[]             the enabled ids in load order
---@field items ModRow[]
---@field loadedIds table<string, boolean>   the mods running this session
local S = {}

local ROW_H, ROWS = 34, 10

-- Words wrapped to a width in virtual pixels (font n): the list of lines.
local function wrap(font, text, width)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            local try = line == "" and word or (line .. " " .. word)
            if line ~= "" and fonts.width(font, try) > width then
                lines[#lines + 1] = line
                line = word
            else
                line = try
            end
        end
        lines[#lines + 1] = line
    end
    return lines
end

local function printLines(font, lines, x, y, step)
    for i, line in ipairs(lines) do fonts.print(font, line, x, y + (i - 1) * step) end
    return y + #lines * step
end

function S:enter()
    self.sel, self.top, self.changed, self.notice = 1, 0, false, nil
    self:refresh()
end

-- The list: enabled mods in load order first, then the others by name; broken folders last.
function S:refresh()
    local found = mods.discover() --[[@as table[] ]]   -- (a list, never nil)
    local byId, enabled = {}, {}
    for _, rec in ipairs(found) do
        if rec.manifest then byId[rec.manifest.id] = rec end
    end
    self.order = self.order or mods.enabledIds()
    local items, seen = {}, {}
    for _, id in ipairs(self.order) do
        if byId[id] and not seen[id] then items[#items + 1] = { rec = byId[id], on = true } seen[id] = true end
    end
    local others = {}
    for _, rec in ipairs(found) do
        if rec.manifest and not seen[rec.manifest.id] then
            others[#others + 1] = { rec = rec, on = rec.source == "cli", cli = rec.source == "cli" }     -- --mod enables it for this session
        end
    end
    table.sort(others, function(a, b) return a.rec.manifest.name:lower() < b.rec.manifest.name:lower() end)
    for _, it in ipairs(others) do items[#items + 1] = it end
    for _, rec in ipairs(found) do
        if not rec.manifest then items[#items + 1] = { rec = rec, on = false, broken = true } end
    end
    self.items = items
    self.loadedIds = {}
    for _, m in ipairs(mods.loaded()) do self.loadedIds[m.id] = true end
end

local function ids(items)
    local out = {}
    for _, it in ipairs(items) do
        if it.on and not it.broken and not it.cli then out[#out + 1] = it.rec.manifest.id end
    end
    return out
end

function S:leave()
    if self.changed then mods.saveEnabled(ids(self.items)) end
end

function S:update(dt) end

-- Dev: `--show mods` (with --mod <dir> to have something to list).
function S:dev() end

function S:draw()
    UI.begin()
    kit.begin(self)
    kit.backdrop(0.82)
    kit.title("Mods", 14, 1)
    kit.panel(30, 52, 420, ROWS * ROW_H + 16)
    local n = #self.items
    self.top = math.max(0, math.min(math.max(0, n - ROWS), self.top))
    for row = 1, ROWS do
        local i = self.top + row
        local it = self.items[i]
        if not it then break end
        local y = 60 + (row - 1) * ROW_H
        local m = it.rec.manifest
        if i == self.sel then
            love.graphics.setColor(0.3, 0.2, 0.08, 0.9)
            love.graphics.rectangle("fill", 38, y, 404, ROW_H - 4)
            love.graphics.setColor(1, 1, 1)
        end
        kit.button(self, "pick", "", 76, y, 360, ROW_H - 4, { font = 2 })
        self.hits[#self.hits].extra = i
        kit.checkbox(self, "toggle", "", it.on, 44, y + 4)
        self.hits[#self.hits].extra = i
        self.hits[#self.hits].w = 24
        local name = m and m.name or it.rec.folder
        local status = ""
        if it.broken then status = "broken" elseif it.on and self.loadedIds[m.id] then status = "loaded"
        elseif it.on then status = "on next start" end
        fonts.print(5, name, 86, y + 5, "left", 250)
        fonts.print(2, (m and ("v" .. m.version) or "") .. "  " .. status, 290, y + 8, "right", 140)
    end
    if #self.items == 0 then
        fonts.print(5, "No mods found.", 30, 120, "center", 420)
        fonts.print(2, "Put mod folders into", 30, 150, "center", 420)
        fonts.print(2, love.filesystem.getSaveDirectory() .. "/" .. mods.root, 30, 170, "center", 420)
    end
    -- the detail panel
    kit.panel(466, 52, 304, ROWS * ROW_H + 16)
    local it = self.items[self.sel]
    if it then
        local m = it.rec.manifest
        if m then
            fonts.print(1, m.name, 476, 62, "left", 284)
            fonts.print(2, ("%s %s%s"):format(m.id, m.version, m.author and ("  by " .. tostring(m.author)) or ""), 476, 92, "left", 284)
            local at = printLines(5, wrap(5, tostring(m.description or ""), 284), 476, 118, 20) + 12
            local lines = {}
            lines[#lines + 1] = m.scope == "cosmetic" and "Art, sound and text only." or "Changes the rules: runs Lua when the game starts."
            if #m.depends > 0 then lines[#lines + 1] = "Needs: " .. table.concat(m.depends, ", ") end
            if #m.conflicts > 0 then lines[#lines + 1] = "Conflicts with: " .. table.concat(m.conflicts, ", ") end
            lines[#lines + 1] = "Folder: " .. it.rec.folder .. " (" .. (it.rec.source == "cli" and "command line" or it.rec.source) .. ")"
            printLines(2, wrap(2, table.concat(lines, "\n"), 284), 476, at, 18)
        else
            fonts.print(1, it.rec.folder, 476, 62, "left", 284)
            printLines(5, wrap(5, "Not loaded: " .. tostring(it.rec.error), 284), 476, 100, 20)
        end
    end
    local errors = mods.errors()
    if #errors > 0 then printLines(2, wrap(2, errors[1], 284), 476, 52 + ROWS * ROW_H - 40, 16) end
    -- buttons
    local can = it and it.rec.manifest ~= nil
    kit.button(self, "up", "Earlier", 30, 420, 100, 32, { disabled = not (can and it.on and self.sel > 1 and self.items[self.sel - 1].on) })
    kit.button(self, "down", "Later", 140, 420, 100, 32, { disabled = not (can and it.on and self.items[self.sel + 1] and self.items[self.sel + 1].on) })
    kit.button(self, "back", "Done", 620, 548, 150, 36)
    local warn = "Mods run Lua. The sandbox prevents accidents, not malice: only enable mods you trust."
    fonts.print(2, warn, 30, 470, "left", 740)
    if self.changed then fonts.print(5, "Restart the game for the changes to take effect.", 30, 500, "left", 740) end
    if self.notice then fonts.print(5, self.notice, 30, 525, "left", 740) end
    UI.finish()
end

---@param id string the kit button
---@param extra any the button's extra value (a row index)
function S:act(id, extra)
    if id == "back" then
        screens.pop()
    elseif id == "pick" then
        self.sel = extra
    elseif id == "toggle" then
        local it = self.items[extra]
        if it and it.cli then
            self.notice = "This mod was enabled with --mod for this session."
        elseif it and not it.broken then
            it.on = not it.on
            self.sel = extra
            self.changed = true
            self.order = ids(self.items)
            self:refresh()
        end
    elseif id == "up" or id == "down" then
        local j = self.sel + (id == "up" and -1 or 1)
        self.items[self.sel], self.items[j] = self.items[j], self.items[self.sel]
        self.sel = j
        self.changed = true
        self.order = ids(self.items)
        self:refresh()
    end
end

function S:mousepressed(x, y, button)
    if button ~= 1 then return end
    local vx, vy = UI.toVirtual(x, y)
    local id, extra = kit.click(self, vx, vy)
    if id then
        require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
        self:act(id, extra)
    end
end

function S:wheelmoved(_, dy) self.top = self.top - dy end

function S:keypressed(key)
    if key == "escape" then self:act("back")
    elseif key == "up" then self.sel = math.max(1, self.sel - 1)
    elseif key == "down" then self.sel = math.min(#self.items, self.sel + 1) end
    if self.sel <= self.top then self.top = self.sel - 1 elseif self.sel > self.top + ROWS then self.top = self.sel - ROWS end
end

return S
