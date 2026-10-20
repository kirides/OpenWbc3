-- Immediate-mode widgets for the setup screens (virtual 800x600 coordinates, original fonts).
-- Usage per frame: kit.begin(self); then kit.button(self, id, ...) etc. register hit boxes that
-- kit.click(self, vx, vy) resolves in mousepressed.
local fonts = require("src.ui.fonts")
local UI = require("src.ui.interface")

local M = {}

---@class KitHit             a hit box registered this frame
---@field id string?           nil: a disabled widget (counts for the cursor, not for clicks)
---@field x number
---@field y number
---@field w number
---@field h number
---@field extra any           given back by M.click
---@field keep boolean?        a hit of an open cycler popup: clicking it leaves the popup open

---@class KitCycler           a cycler drawn this frame that can open a popup
---@field x number
---@field y number
---@field w number
---@field h number
---@field items fun(self: KitHost|Screen): (string[]?, integer?)  the labels on offer and the current one

---@class KitPopup            the open popup of a cycler
---@field id string            the cycler's id
---@field focus integer?       entry kept in the middle of the visible rows
---@field top integer?         first visible entry

-- The kit's state on the screen that uses it (its widgets take the screen as `self`; screens are KitHost|Screen).
---@class KitHost
---@field hits KitHit[]?
---@field cyclers table<string, KitCycler>?
---@field popup KitPopup?
---@field mx number            mouse position on the virtual canvas, set by M.begin
---@field my number
---@field drag string?         id of the slider being dragged

M.GOLD = { 0.86, 0.7, 0.47 }
M.DIM = { 0.55, 0.5, 0.45 }

---@param self KitHost|Screen
function M.begin(self)
    self.hits = {}
    self.cyclers = {}
    local mx, my = love.mouse.getPosition()
    self.mx, self.my = UI.toVirtual(mx, my)
end

---@param self KitHost|Screen
---@return boolean
local function inside(self, x, y, w, h)
    return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h
end
M.inside = inside

-- Hits of an open cycler popup carry `keep` so that clicking them does not close the popup.
---@param self KitHost|Screen
---@param id string?
---@return boolean hovered
local function hit(self, id, x, y, w, h, extra, keep)
    local hv = inside(self, x, y, w, h)
    self.hits[#self.hits + 1] = { id = id, x = x, y = y, w = w, h = h, extra = extra, keep = keep }
    return hv
end

-- Whether the mouse is over one of the widgets drawn this frame: the kit's hit boxes with an id, a
-- disabled button having none like the original's inactive object (its active flag, tested by FUN_00456a30).
---@param self KitHost|Screen
---@return boolean
local function over(self)
    for i = #(self.hits or {}), 1, -1 do
        local h = self.hits[i]
        if h.id and self.mx >= h.x and self.mx < h.x + h.w and self.my >= h.y and self.my < h.y + h.h then
            return true
        end
    end
    return false
end
M.over = over

-- Resolves a click; returns id, extra of the topmost (last registered) hit box. Hits marked `keep` (the ones of an
-- open cycler popup that leave it open) stop a click from closing that popup. Clicking a cycler's middle text opens
-- its popup (extra = "popup") or closes it when it is already open; the caller should not act on that click.
---@param self KitHost|Screen
---@param vx number
---@param vy number
---@return string? id
---@return any extra
function M.click(self, vx, vy)
    for i = #(self.hits or {}), 1, -1 do
        local h = self.hits[i]
        if vx >= h.x and vx < h.x + h.w and vy >= h.y and vy < h.y + h.h then
            local c = (self.cyclers or {})[h.id]
            if c then
                if self.popup and self.popup.id == h.id then self.popup = nil
                else self.popup = { id = h.id } end
                return h.id, "popup"
            end
            if self.popup and not h.keep then self.popup = nil end
            return h.id, h.extra
        end
    end
    self.popup = nil
end

---@param dim? number
function M.backdrop(dim)
    UI.drawScreen("SCR_STARTUP")
    love.graphics.setColor(0, 0, 0, dim or 0.72)
    love.graphics.rectangle("fill", 0, 0, 800, 600)
    love.graphics.setColor(1, 1, 1)
end

function M.panel(x, y, w, h, alpha)
    local g = love.graphics
    g.setColor(0.07, 0.04, 0.03, alpha or 0.92)
    g.rectangle("fill", x, y, w, h, 4, 4)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], 0.9)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 4, 4)
    g.setColor(1, 1, 1)
end

---@param text string
---@param y number
---@param font? integer
function M.title(text, y, font)
    fonts.print(font or 1, text, 0, y, "center", 800)
end

-- A text button. opts: disabled, font, selected.
---@param self KitHost|Screen
---@param id string
---@param label string
---@param opts? { disabled: boolean?, font: integer?, selected: boolean? }
---@return boolean hovered
function M.button(self, id, label, x, y, w, h, opts)
    opts = opts or {}
    local g = love.graphics
    local hv = hit(self, not opts.disabled and id or nil, x, y, w, h)
    local pressed = hv and love.mouse.isDown(1)
    local shade = opts.disabled and 0.12 or (opts.selected and 0.34 or (hv and 0.28 or 0.16))
    g.setColor(shade, shade * 0.62, shade * 0.28, 0.95)
    g.rectangle("fill", x, y + (pressed and 1 or 0), w, h, 4, 4)
    local c = opts.disabled and M.DIM or M.GOLD
    g.setColor(c[1], c[2], c[3], opts.disabled and 0.5 or 1)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 4, 4)
    local fid = opts.font or 5
    local d, f = fonts.get(fid)
    local ty = y + math.floor((h - (f and f:getHeight() or 16)) / 2) + 3 + (pressed and 1 or 0)
    g.setColor(1, 1, 1, opts.disabled and 0.45 or 1)
    fonts.print(fid, label, x, ty, "center", w, opts.disabled and 0.5 or 1)
    g.setColor(1, 1, 1)
    return hv
end

-- Left/right arrow buttons.
---@param self KitHost|Screen
---@param id string
---@param dir integer  -1 left, 1 right, 2 down
---@param size? number
---@return boolean hovered
function M.arrow(self, id, dir, x, y, size)
    local g = love.graphics
    size = size or 36
    local hv = hit(self, id, x, y, size, size)
    g.setColor(hv and 0.34 or 0.18, hv and 0.21 or 0.11, 0.08, 0.95)
    g.rectangle("fill", x, y, size, size, 4, 4)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3])
    g.rectangle("line", x + 0.5, y + 0.5, size - 1, size - 1, 4, 4)
    local cx, cy, r = x + size / 2, y + size / 2, size * 0.22
    if dir < 0 then g.polygon("fill", cx + r, cy - r, cx - r, cy, cx + r, cy + r)
    elseif dir > 0 then g.polygon("fill", cx - r, cy - r, cx + r, cy, cx - r, cy + r)
    elseif dir == 2 then g.polygon("fill", cx - r, cy - r * 0.5, cx + r, cy - r * 0.5, cx, cy + r)
    end
    g.setColor(1, 1, 1)
    return hv
end

-- A labelled value box with arrows (a "dropdown" that cycles): returns nothing, registers id.."_prev"/"_next".
-- `items` is a function giving the values on offer: it is called when the popup opens and returns the list of
-- labels plus the 1-based index of the current one, so the caller keeps one source of truth for both. Clicking the
-- middle text opens a popup with all of them (kit.popup draws it, and it gets a scroller past M.POPUP_ROWS);
-- clicking an entry registers id.."_pick" with its index.
---@param self KitHost|Screen
---@param id string
---@param label string?
---@param value string
---@param h number?
---@param items? fun(self: KitHost|Screen): (string[]?, integer?)
function M.cycler(self, id, label, value, x, y, w, h, items)
    local g = love.graphics
    h = h or 28
    g.setColor(0, 0, 0, 0.8)
    g.rectangle("fill", x, y, w, h, 3, 3)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], 0.8)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 3, 3)
    local hv = hit(self, id, x + h, y, w - 2 * h, h)
    if hv then
        g.setColor(1, 1, 1, 0.07)
        g.rectangle("fill", x + h, y, w - 2 * h, h)
    end
    M.arrow(self, id .. "_prev", -1, x, y, h)
    M.arrow(self, id .. "_next", 1, x + w - h, y, h)
    fonts.print(5, value, x + h, y + fonts.middleY(5, h), "center", w - 2 * h)
    if label then fonts.print(2, label, x, y - 15, "left", w) end
    if items then
        self.cyclers = self.cyclers or {}
        self.cyclers[id] = { x = x, y = y, w = w, h = h, items = items }
    end
end

-- How many popup entries are visible at once; a longer list gets a scroller.
M.POPUP_ROWS = 10

-- Draws the popup of the cycler whose middle text was clicked; call it after all other drawing so it sits on top.
-- Rows register id.."_pick" with the entry's index, the scroller id.."_scroll"; both keep the popup open.
---@param self KitHost|Screen
function M.popup(self)
    local p = self.popup
    if not p then return end
    local c = (self.cyclers or {})[p.id]
    if not c then self.popup = nil return end -- its cycler is no longer drawn (tab switched, side closed)
    local g = love.graphics
    local list, at = c.items(self)
    local n = list and #list or 0
    if n == 0 then self.popup = nil return end
    ---@cast list -nil
    at = math.max(1, math.min(n, at or 1))
    local rows = math.min(n, M.POPUP_ROWS)
    local focus = math.max(1, math.min(n, p.focus or at))
    p.focus = focus
    local top = math.max(1, math.min(n - rows + 1, focus - math.floor(rows / 2)))
    p.top = top
    -- wide enough for the longest entry, anchored under the box and moved above when it would not fit
    local pw = c.w
    for i = 1, n do pw = math.max(pw, fonts.width(5, tostring(list[i])) + 30) end
    pw = math.min(pw, 792)
    local ph = rows * 20 + 12
    local px = math.max(4, math.min(800 - pw - 4, c.x))
    local py = c.y + c.h + 6
    if py + ph > 596 then py = math.max(4, c.y - 6 - ph) end
    g.setColor(0.05, 0.03, 0.02, 0.95)
    g.rectangle("fill", px, py, pw, ph, 4, 4)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], 0.9)
    g.rectangle("line", px + 0.5, py + 0.5, pw - 1, ph - 1, 4, 4)
    local tw = pw - 26
    for i = top, top + rows - 1 do
        local ry = py + 6 + (i - top) * 20
        local hv = inside(self, px + 4, ry, tw, 20)
        if i == at then
            g.setColor(0.4, 0.26, 0.1, 0.9)
            g.rectangle("fill", px + 4, ry, tw, 20)
            g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3])
            g.polygon("fill", px + 8, ry + 4, px + 8, ry + 16, px + 14, ry + 10)
        elseif hv then
            g.setColor(1, 1, 1, 0.07)
            g.rectangle("fill", px + 4, ry, tw, 20)
        end
        g.setColor(1, 1, 1)
        fonts.print(5, list[i], px + 18, ry + fonts.middleY(5, 20))
        hit(self, p.id .. "_pick", px + 4, ry, tw, 20, i, true)
    end
    if n > rows then
        local tx, ty, th2 = px + pw - 14, py + 6, ph - 12
        g.setColor(0.3, 0.22, 0.12)
        g.rectangle("fill", tx, ty, 8, th2)
        local th = math.max(16, th2 * rows / n)
        g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3])
        g.rectangle("fill", tx, ty + (th2 - th) * (top - 1) / (n - rows), 8, th)
        local f = th2 > th and math.max(0, math.min(1, (self.my - ty) / (th2 - th))) or 0
        local focusAt = 1 + math.floor(f * (n - rows) + 0.5) + math.floor(rows / 2)
        hit(self, p.id .. "_scroll", tx - 6, ty, 20, th2, focusAt, true)
    end
end

-- A horizontal integer slider with its value shown at the right. Press registers `id` (set self.drag = id
-- in the click handler); while self.drag == id and the button is held, returns the value under the mouse.
---@param self KitHost|Screen
---@param id string
---@param label string?
---@param value number
---@return number value
function M.slider(self, id, label, value, min, max, x, y, w)
    local g = love.graphics
    local tx, tw = x, w - 44
    if self.drag == id then
        if love.mouse.isDown(1) then
            local f = math.max(0, math.min(1, (self.mx - tx) / tw))
            value = min + math.floor(f * (max - min) + 0.5)
        else
            self.drag = nil
        end
    end
    local hv = hit(self, id, tx - 6, y - 4, tw + 12, 24)
    local f = (value - min) / (max - min)
    g.setColor(0, 0, 0, 0.8)
    g.rectangle("fill", tx, y + 6, tw, 6, 3, 3)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], 0.5)
    g.rectangle("fill", tx, y + 6, tw * f, 6, 3, 3)
    g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], (hv or self.drag == id) and 1 or 0.85)
    g.rectangle("line", tx + 0.5, y + 6.5, tw - 1, 5, 3, 3)
    g.rectangle("fill", tx + tw * f - 5, y + 1, 10, 16, 2, 2)
    g.setColor(1, 1, 1)
    fonts.print(5, tostring(value), x + w - 40, y - 2, "right", 40)
    if label then fonts.print(2, label, x, y - 22, "left", w) end
    return value
end

-- The original's checkbox art (CheckBox.bmp, BM_CHECKBOX): eight rows of 17 px -- unchecked
-- (normal / hover / pressed / disabled) then checked (normal = bright skull / hover = brighter ring /
-- pressed = dim skull / disabled). So the row is (checked and 4 or 0) + state. Falls back to a
-- hand-made box if the XCI art is not loaded.
---@param self KitHost|Screen
---@param id string
---@param label string
---@param checked boolean?
function M.checkbox(self, id, label, checked, x, y)
    local g = love.graphics
    local hv = hit(self, id, x, y, 260, 22)
    local img = UI.bitmapByName("BM_CHECKBOX")
    if img then
        local state = (hv and love.mouse.isDown(1)) and 2 or (hv and 1 or 0)
        local row = (checked and 4 or 0) + state
        local h = 17
        local q = g.newQuad(0, row * h, img:getWidth(), h, img:getWidth(), img:getHeight())
        g.draw(img, q, x + 1, y + 2)
    else
        g.setColor(0, 0, 0, 0.8)
        g.rectangle("fill", x, y + 1, 20, 20, 3, 3)
        g.setColor(M.GOLD[1], M.GOLD[2], M.GOLD[3], hv and 1 or 0.8)
        g.rectangle("line", x + 0.5, y + 1.5, 19, 19, 3, 3)
        if checked then g.rectangle("fill", x + 5, y + 6, 10, 10) end
        g.setColor(1, 1, 1)
    end
    fonts.print(5, label, x + 28, y)
end

-- A single line text input (handled by M.textinput / M.key). Returns nothing.
---@param self KitHost|Screen
---@param id string
---@param text string
---@param h number?
---@param focused boolean?
---@param selected boolean? the whole text is selected (Ctrl+A); drawn highlighted
function M.input(self, id, text, x, y, w, h, focused, selected)
    local g = love.graphics
    h = h or 30
    hit(self, id, x, y, w, h)
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", x, y, w, h, 3, 3)
    local c = focused and { 1, 0.9, 0.6 } or M.GOLD
    g.setColor(c[1], c[2], c[3])
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 3, 3)
    if focused and selected and text ~= "" then
        g.setColor(0.3, 0.45, 0.8, 0.6)
        g.rectangle("fill", x + 7, y + 3, math.min(w - 14, fonts.width(5, text) + 2), h - 6)
        g.setColor(c[1], c[2], c[3])
    end
    local caret = focused and not selected and (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    fonts.print(5, text .. caret, x + 8, y + 4)
end

-- Editing keys shared by the text inputs: Ctrl+A selects the whole text, Ctrl+V pastes the clipboard (replacing a
-- selection), Delete / Backspace remove the selection. Returns the new text, the new selection flag and whether the
-- key was handled (plain Backspace without a selection is left to the caller).
---@param text string
---@param key string
---@param selected boolean?
---@param accept fun(text: string): string  filters the pasted text and clamps the result
---@return string text
---@return boolean selected
---@return boolean handled
function M.editKey(text, key, selected, accept)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if ctrl and key == "a" then
        return text, text ~= "", true
    elseif ctrl and key == "v" then
        local clip = (love.system.getClipboardText() or ""):gsub("[\r\n].*", "")
        return accept((selected and "" or text) .. clip), false, true
    elseif key == "delete" or (key == "backspace" and selected) then
        return selected and "" or text, false, selected or key == "delete"
    end
    return text, selected or false, false
end

---@param text string
---@param t string
---@param maxLen? integer
---@return string
function M.textinput(text, t, maxLen)
    if #text >= (maxLen or 20) then return text end
    if t:match("^[%w%s%-'_%.]+$") then return text .. t end
    return text
end

---@param text string
---@return string
function M.backspace(text)
    local byteoffset = require("utf8").offset(text, -1)
    if byteoffset then return text:sub(1, byteoffset - 1) end
    return text
end

return M
