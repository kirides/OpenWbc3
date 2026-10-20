-- Edit boxes of the scenario editor's dialogs (editorobject.lua, editorsides.lua, editoritems.lua): a set of named text
-- buffers with one focused field, typed into by the screen's textinput / keypressed callbacks. A field is { kind = "num" |
-- "text", maxLen, min, max, text }; a number field takes digits (and a leading minus when `min` is negative) and is
-- clamped into [min, max] when it is left (Enter, Tab) or read with `number`. The dialogs read the buffers when their
-- Done / Apply button is pressed, as the original's dialogs read their edit boxes (FUN_0045dc50) then.
local kit = require("src.ui.kit")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local vfs = require("src.vfs.vfs")
local bmpMod = require("src.formats.bmp")

---@class EditorField
---@field kind string          "num" or "text"
---@field maxLen integer       characters
---@field min number?
---@field max number?
---@field text string

---@class EditorFields
---@field prefix string        hit id prefix of the boxes
---@field fields table<string, EditorField>
---@field order string[]       the keys in the order they were added (Tab)
---@field focus string?        key of the focused field
local F = {}
F.__index = F

---@param prefix string
---@return EditorFields
function F.new(prefix)
    return setmetatable({ prefix = prefix, fields = {}, order = {}, focus = nil }, F)
end

-- Adds (or resets) field `key`. spec: kind, maxLen (characters), min / max (numbers), text (initial)
---@param key string
---@param spec { kind: string?, maxLen: integer?, min: number?, max: number?, text: any }
---@return EditorField
function F:set(key, spec)
    local f = self.fields[key]
    if not f then self.order[#self.order + 1] = key end
    f = { kind = spec.kind or "text", maxLen = spec.maxLen or 19, min = spec.min, max = spec.max, text = tostring(spec.text or "") }
    self.fields[key] = f
    if self.focus == nil then self.focus = key end
    return f
end

function F:clear()
    self.fields, self.order, self.focus = {}, {}, nil
end

function F:text(key) return self.fields[key] and self.fields[key].text or "" end

-- The value of a number field, clamped; `default` when it is empty.
---@param key string
---@param default number?
---@return number?
function F:number(key, default)
    local f = self.fields[key]
    if not f then return default end
    local v = tonumber(f.text)
    if not v then return default end
    v = math.floor(v)
    if f.min and v < f.min then v = f.min end
    if f.max and v > f.max then v = f.max end
    return v
end

function F:setText(key, text) if self.fields[key] then self.fields[key].text = tostring(text) end end

-- Clamps a number field's text to its range (what is shown after leaving the field).
function F:settle(key)
    local f = self.fields[key]
    if f and f.kind == "num" then
        local v = self:number(key)
        if v then f.text = tostring(v) elseif f.text ~= "" then f.text = "" end
    end
end

-- Draws the box at the virtual position; `S` is the editor screen (its widget helpers register the click).
---@param S EditorScreen
function F:draw(S, key, x, y, w, h)
    local f = self.fields[key]
    if not f then return end
    S.widgets.textBox(S, self.prefix .. key, f.text, x, y, w, h, self.focus == key)
end

-- A click on a registered id; returns true when it was one of ours.
---@param id string
---@return boolean
function F:click(id)
    local key = id:sub(#self.prefix + 1)
    if id:sub(1, #self.prefix) == self.prefix and self.fields[key] then
        if self.focus and self.focus ~= key then self:settle(self.focus) end
        self.focus = key
        return true
    end
    return false
end

---@param t string
---@return boolean
function F:textinput(t)
    local f = self.fields[self.focus or ""]
    if not f then return false end
    if f.kind == "num" then
        if t:match("^%d$") or (t == "-" and (f.min or 0) < 0 and f.text == "") then
            if #f.text < 9 then f.text = f.text .. t end
        end
    elseif t:match("^[%w%s%p]$") then       -- plain ASCII: the scenario's text fields are Windows-1252
        if #f.text < f.maxLen then f.text = f.text .. t end
    end
    return true
end

-- backspace / return / tab; returns true when the key was ours
---@param key string
---@return boolean
function F:keypressed(key)
    local f = self.fields[self.focus or ""]
    if not f then return false end
    if key == "backspace" then
        f.text = kit.backspace(f.text)
        return true
    elseif key == "return" or key == "kpenter" or key == "tab" then
        self:settle(self.focus)
        if key == "tab" and #self.order > 1 then
            for i, k in ipairs(self.order) do
                if k == self.focus then self.focus = self.order[i % #self.order + 1] break end
            end
        end
        return true
    end
    return false
end

-- Small widgets of the editor panels, drawn the way the original's art is laid out ---------------------------------------------

local quads = {}
local function quad(img, key, x, y, w, h)
    local q = quads[key]
    if not q then
        q = love.graphics.newQuad(x, y, w, h, img:getDimensions())
        quads[key] = q
    end
    return q
end

-- A check box (bitmap 50, rows of 18: unchecked normal / hover / pressed / disabled, then the same checked) with its label
-- to the right. `id` / `extra` are what S:click receives; hit area w x 18.
---@param S EditorScreen
function F.checkBox(S, id, x, y, checked, label, extra, disabled, w)
    local g = love.graphics
    local img = UI.bitmap(50)
    local hv = S.widgets.reg(S, not disabled and id or nil, x, y, w or 18, 18, extra)
    if img then
        local row = (checked and 4 or 0) + (disabled and 3 or ((hv and love.mouse.isDown(1)) and 2 or (hv and 1 or 0)))
        g.setColor(1, 1, 1)
        g.draw(img, quad(img, "cb" .. row, 0, row * 18, 18, 18), x, y)
    end
    if label then fonts.print(5, label, x + 24, y + fonts.middleY(5, 18), "left", (w or 150) - 24, disabled and 0.5 or 1) end
    return hv
end

local lockImages = {}
local function lockImage(name)
    local img = lockImages[name]
    if img == nil then
        local data = vfs.find(name)
        local ok, res = pcall(bmpMod.image, data or "", { key = true })
        img = ok and res or false
        lockImages[name] = img
    end
    return img or nil
end

-- A lock button (locked.bmp / unlocked.bmp, 18 x 17, the "Over" pictures for the hover): the scenario locks a setup value
-- against change in the skirmish setup.
---@param S EditorScreen
function F.lock(S, id, x, y, locked, extra, disabled)
    local g = love.graphics
    local hv = S.widgets.reg(S, not disabled and id or nil, x, y, 18, 17, extra)
    local base = locked and "locked" or "unlocked"
    g.setColor(1, 1, 1, disabled and 0.5 or 1)
    local over = hv and not disabled and lockImage(base .. "Over.bmp")
    if over then
        g.draw(over, x, y)
    else
        local img = lockImage(base .. ".bmp")
        if img then g.draw(img, quad(img, base, 0, 0, 18, 17), x, y) end
    end
    g.setColor(1, 1, 1)
    return hv
end

-- A horizontal scroll bar of the editor panels (bitmap 51: arrow, track, arrow, thumb, 162 x 16 in all). `pos` is 0..1;
-- the track registers `id` (a click sets the value: S:click gets extra = "track" / "left" / "right").
---@param S EditorScreen
function F.hbar(S, id, x, y, pos, extra)
    local g = love.graphics
    local img = UI.bitmap(51)
    S.widgets.reg(S, id, x + 16, y, 130, 16, extra and extra .. ":track" or "track")
    S.widgets.reg(S, id, x, y, 16, 16, extra and extra .. ":left" or "left")
    S.widgets.reg(S, id, x + 146, y, 16, 16, extra and extra .. ":right" or "right")
    if img then
        g.setColor(1, 1, 1)
        g.draw(img, quad(img, "hb", 0, 0, 162, 16), x, y)
        g.draw(img, quad(img, "hbt", 162, 0, 16, 16), x + 16 + math.max(0, math.min(1, pos)) * 114, y)
    end
end

-- The position 0..1 a click at virtual x means on a bar drawn at `x`.
function F.hbarPos(x, vx) return math.max(0, math.min(1, (vx - (x + 24)) / 114)) end

return F
