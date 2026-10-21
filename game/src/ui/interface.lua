-- Interface system: draws XCI screens and panels on an 800x600 virtual canvas
-- that is scaled (aspect preserved) to the window, and routes mouse input to
-- panel buttons.
local xci = require("src.ui.xci")
local fonts = require("src.ui.fonts")
local vfs = require("src.vfs.vfs")
local bmp = require("src.formats.bmp")
local log = require("src.core.log")

local T = xci.TYPE

---@class Interface
---@field W integer               virtual canvas width (800)
---@field H integer               virtual canvas height (600)
---@field bitmaps table<integer, love.Image|false>  loaded XCG bitmaps (false: missing)
---@field ui XciUI                the interface definitions (nil until M.init)
---@field inGame boolean?         a battle runs (the UI scale option applies)
---@field panelOver boolean?      the mouse is over an active object of the panel drawn last
local M = { W = 800, H = 600, bitmaps = {} }

---@param gamedir string
---@param lang string
---@return boolean
function M.init(gamedir, lang)
    local ui, err = xci.load(gamedir, lang)
    if not ui then
        log.error("interface: %s", err)
        return false
    end
    M.ui = ui
    fonts.init(gamedir, lang)
    return true
end

-- Bitmap by XCG id: loaded from the archive the XCG names, or any archive
-- containing the file (many XCG records name archives that were merged).
---@param id integer
---@return love.Image?
function M.bitmap(id)
    local b = M.bitmaps[id]
    if b ~= nil then return b or nil end
    local rec = M.ui.gfx.bitmaps[id]
    b = false
    if rec and rec.file ~= "" then
        local data = vfs.read(rec.xcr, rec.file) or vfs.find(rec.file)
        if data then
            local ok, img = pcall(bmp.image, data, { key = true })
            if ok and img then
                b = img
                b:setFilter("linear", "linear")
            else log.warn("bitmap %s: %s", rec.file, tostring(img)) end
        else
            log.debug("bitmap %s (%s) not found", rec.file, rec.xcr)
        end
    end
    M.bitmaps[id] = b
    return b or nil
end

---@param name string
---@return love.Image?
function M.bitmapByName(name)
    local rec = M.ui.gfx.byName[name]
    return rec and M.bitmap(rec.id)
end

-- String `sub` (default 0) of the XCI string resource `resId`.
---@param resId integer
---@param sub? integer
---@return string?
function M.text(resId, sub)
    local list = M.ui.text[resId]
    return list and list[sub or 0] or nil
end

-- Virtual canvas -------------------------------------------------------------

-- User interface scale (options, 50..100 %): shrinks the whole UI inside the window.
---@return number
function M.userScale()
    local v = tonumber(require("src.core.config").get("graphics", "uiscale", 100)) or 100
    return math.max(50, math.min(100, v)) / 100
end

---@return number scale
---@return number ox
---@return number oy
function M.transform()
    local w, h = love.graphics.getDimensions()
    -- Menus always scale to the window height (aspect kept); the UI scale option only applies in battle.
    local s = math.min(w / M.W, h / M.H) * (M.inGame and M.userScale() or 1)
    local ox, oy = math.floor((w - M.W * s) / 2), math.floor((h - M.H * s) / 2)
    return s, ox, oy
end

function M.begin()
    local s, ox, oy = M.transform()
    love.graphics.push()
    love.graphics.translate(ox, oy)
    love.graphics.scale(s)
    -- the standard cursor of the other screens looks at the panel drawn last; each canvas starts clean
    M.panelOver = nil
end

function M.finish()
    love.graphics.pop()
end

-- Window pixels to the virtual 800x600 canvas.
---@param x number
---@param y number
---@return number vx
---@return number vy
function M.toVirtual(x, y)
    local s, ox, oy = M.transform()
    return (x - ox) / s, (y - oy) / s
end

---@param name string
function M.drawScreen(name)
    local scr = M.ui.screens[name]
    love.graphics.clear(0, 0, 0)
    if scr and scr.type == 0 then
        local img = M.bitmap(scr.source[1])
        if img then
            if not M.inGame then
                -- fill the whole window: dimmed stretched copy behind, the aspect-correct image on top
                local w, h = love.graphics.getDimensions()
                love.graphics.push()
                love.graphics.origin()
                love.graphics.setColor(0.4, 0.4, 0.4)
                love.graphics.draw(img, 0, 0, 0, w / img:getWidth(), h / img:getHeight())
                love.graphics.setColor(1, 1, 1)
                love.graphics.pop()
            end
            love.graphics.draw(img, 0, 0)
        end
    end
end

-- Panels ------------------------------------------------------------------------

---@class PanelItem          an object of a panel (an XCI object at its place)
---@field e XciPlace|XciPanelEntry  place on the panel: the panel's entry, or one given by Panel:add / frame.lua
---@field ob XciObject
---@field name string
---@field quads table<integer, love.Quad>?  button rows, cached
---@field quad love.Quad?                    image part, cached
---@field scale number?                      drawn and hit at this size (openwbc3's additions, e.g. bigger arrows)

---@class PanelOpts
---@field x number?
---@field y number?
---@field onButton fun(name: string, it: PanelItem)?
---@field onFocus fun(name: string)?

---@class Panel               an XCI panel on the virtual canvas (M.panel)
---@field def XciPanelDef
---@field name string
---@field x number
---@field y number
---@field onButton fun(name: string, it: PanelItem)?  a button was clicked
---@field onFocus fun(name: string)?                  the mouse moved onto a button
---@field state table<string, integer>          per name: 0 normal, 3 disabled
---@field hidden table<string, boolean>
---@field strings table<string, string>         per name: text instead of the XCI one
---@field itemStrings table<PanelItem, string>
---@field itemState table<PanelItem, integer>
---@field itemHidden table<PanelItem, boolean>
---@field align table<PanelItem, "left"|"center"|"right">
---@field owner table<PanelItem, fun(x: number, y: number)>
---@field noArt table<PanelItem, boolean>
---@field items PanelItem[]                     in drawing order (z)
---@field hover PanelItem?
---@field pressed PanelItem?
local Panel = {}
Panel.__index = Panel

-- A panel of War4Int.xci; nil (logged) when there is none of that name.
---@param name string
---@param opts? PanelOpts
---@return Panel?
function M.panel(name, opts)
    local def = M.ui.panels[name]
    if not def then
        log.error("panel %s not found", name)
        return nil
    end
    opts = opts or {}
    ---@type Panel
    local p = setmetatable({
        def = def, name = name,
        x = opts.x or def.x, y = opts.y or def.y,
        onButton = opts.onButton, onFocus = opts.onFocus,
        state = {}, hidden = {}, strings = {},
        itemStrings = {}, itemState = {}, itemHidden = {}, align = {},
        owner = {}, noArt = {},
        items = {},
    }, Panel)
    for _, e in ipairs(def.objects) do
        local ob = M.ui.objects[e.ui]
        if ob then p.items[#p.items + 1] = { e = e, ob = ob, name = e.name } end
    end
    table.sort(p.items, function(a, b) return a.e.z < b.e.z end)
    return p
end

-- The first item of that name.
---@param name string
---@return PanelItem?
function Panel:find(name)
    for _, it in ipairs(self.items) do if it.name == name then return it end end
end

-- Adds an object of the interface definition (a button, usually) at panel
-- position (x, y) under the given name; returns the item.
---@param objName string
---@param x number
---@param y number
---@param name? string
---@return PanelItem?
function Panel:add(objName, x, y, name)
    local ob = M.ui.objByName[objName]
    if not ob then return nil end
    local it = { e = { x = x, y = y, z = 1e9 + #self.items }, ob = ob, name = name or objName }
    self.items[#self.items + 1] = it
    return it
end

---@param name string
---@param on? boolean   default true
function Panel:hide(name, on) self.hidden[name] = on ~= false end
function Panel:setString(name, s) self.strings[name] = s end
function Panel:setDisabled(name, on) self.state[name] = on and 3 or 0 end

-- Several objects of a panel can share a name; these address one by position
-- (panel coordinates as listed by `--panel NAME --dump`).
---@param name string
---@param x number
---@param y number
---@return PanelItem?
function Panel:at(name, x, y)
    for _, it in ipairs(self.items) do
        if it.name == name and it.e.x == x and it.e.y == y then return it end
    end
end

---@param name string
---@param x number
---@param y number
---@param s string
---@return PanelItem?
function Panel:setTextAt(name, x, y, s)
    local it = self:at(name, x, y)
    if it then self.itemStrings[it] = s end
    return it
end

---@param it PanelItem
---@param on boolean?
function Panel:setItemDisabled(it, on) self.itemState[it] = on and 3 or nil end
---@param it PanelItem
---@param on? boolean   default true
function Panel:hideItem(it, on) self.itemHidden[it] = on ~= false end

-- Images of subtype 25 are drawn by the game's own code in the original (the picture of a retinue slot, a gravestone):
-- `fn(x, y)` draws one at its place on the screen (it replaces the dialog shade the subtype means otherwise).
---@param it PanelItem
---@param fn fun(x: number, y: number)
function Panel:setOwnerDraw(it, fn) self.owner[it] = fn end

-- A button without art of its own (the hit areas that name the generic BM_BUTTON200 as their bitmap): only its text
-- and its area count.
---@param it PanelItem
---@param on? boolean   default true
function Panel:hideArt(it, on) self.noArt[it] = on ~= false end

-- Items of the given name, in a stable top-to-bottom, left-to-right order.
---@param name string
---@return PanelItem[]
function Panel:all(name)
    local out = {}
    for _, it in ipairs(self.items) do if it.name == name then out[#out + 1] = it end end
    table.sort(out, function(a, b)
        if a.e.y ~= b.e.y then return a.e.y < b.e.y end
        return a.e.x < b.e.x
    end)
    return out
end

local function buttonText(ob)
    if ob.text and ob.text ~= 0xFFFFFFFF then
        return M.text(ob.text, math.max(0, ob.textSub or 0))
    end
end

---@param it PanelItem
function Panel:drawItem(it)
    local e, ob = it.e, it.ob
    if self.hidden[it.name] or self.itemHidden[it] then return end
    local x, y = self.x + e.x, self.y + e.y
    local g = love.graphics
    if ob.type == T.BUTTON then
        local st = self.itemState[it] or self.state[it.name] or 0
        if st ~= 3 then
            if self.pressed == it then st = 2 elseif self.hover == it then st = 1 end
        end
        -- invisible hit areas (subtype 4 with the placeholder bitmap 1, e.g. BUTT_SIDESEL_SHIELD) draw no art
        local img = not (ob.subtype == 4 and ob.source == 1) and not self.noArt[it] and M.bitmap(ob.source) or nil
        if img then
            local rows = math.max(1, math.floor(img:getHeight() / math.max(1, ob.h)))
            local row = math.min(st, rows - 1)
            it.quads = it.quads or {}
            local q = it.quads[row]
            if not q then
                q = g.newQuad(0, row * ob.h, math.min(ob.w, img:getWidth()), ob.h, img:getDimensions())
                it.quads[row] = q
            end
            g.draw(img, q, x, y, 0, it.scale or 1)
        end
        local s = self.itemStrings[it] or self.strings[it.name] or buttonText(ob)
        if s and ob.fonts then
            local fid = ob.fonts[1]
            if st == 1 and ob.fonts[2] ~= 0 then fid = ob.fonts[2] end
            if st == 3 and ob.fonts[3] ~= 0 then fid = ob.fonts[3] end
            local d, f = fonts.get(fid)
            if d then
                if self.align[it] == "left" then       -- drop-down buttons: text on the left, arrow on the right
                    fonts.print(fid, s, x + 12, y + fonts.middleY(fid, ob.h), "left", ob.w - 36)
                else
                    fonts.print(fid, s, x, y + fonts.middleY(fid, ob.h), "center", ob.w)
                end
            end
        end
    elseif ob.type == T.IMAGE then
        if ob.subtype == 25 and self.owner[it] then
            self.owner[it](x, y)
        elseif ob.subtype == 25 then
            -- full-screen shade behind a dialog
            g.setColor(0, 0, 0, 0.6)
            g.rectangle("fill", x, y, ob.w, ob.h)
            g.setColor(1, 1, 1)
        elseif ob.subtype == 22 then
            local img = M.bitmap(ob.source)
            local r = ob.srcRect
            if img and r then
                it.quad = it.quad or g.newQuad(r[1], r[2], math.min(r[3], img:getWidth() - r[1]),
                    math.min(r[4], img:getHeight() - r[2]), img:getDimensions())
                g.draw(img, it.quad, x, y)
            end
        end
    elseif ob.type == T.STRING then
        ---@type string?
        local s = self.itemStrings[it] or self.strings[it.name]
        if not s and ob.text and ob.text ~= 0xFFFFFFFF then s = M.text(ob.text, math.max(0, ob.textSub or 0)) end
        if s then fonts.print(ob.font, s, x, y, self.align[it] or "left", ob.w) end
    elseif ob.type == T.PRIMITIVE then
        local c = ob.colors and ob.colors[1]
        if c then
            g.setColor(c[1] / 31, c[2] / 31, c[3] / 31, 0.8)
            g.rectangle("fill", x, y, ob.w, ob.h)
            g.setColor(1, 1, 1)
        end
    end
end

function Panel:draw()
    for _, it in ipairs(self.items) do self:drawItem(it) end
    -- the standard cursor of the screens that have no widgets of their own (core/screens.lua) asks
    -- the panel drawn last; the original's standard cursor FUN_00456a30 uses the hit test FUN_00460fd0
    local mx, my = love.mouse.getPosition()
    M.panelOver = self:over(M.toVirtual(mx, my)) and true or nil
end

-- The original's standard cursor (FUN_00456a30) counts BUTTON, EDITOR, SCROLLBAR and
-- LISTBOX objects, not only the buttons that can be clicked, and only while they take input.
---@param vx number
---@param vy number
---@return boolean
function Panel:over(vx, vy)
    for i = #self.items, 1, -1 do
        local it = self.items[i]
        local t = it.ob.type
        if (t == T.BUTTON or t == T.EDITOR or t == T.SCROLLBAR or t == T.LISTBOX)
            and not self.hidden[it.name] and not self.itemHidden[it]
            and (self.itemState[it] or self.state[it.name] or 0) ~= 3 then
            local x, y, sc = self.x + it.e.x, self.y + it.e.y, it.scale or 1
            if vx >= x and vy >= y and vx < x + it.ob.w * sc and vy < y + it.ob.h * sc then return true end
        end
    end
    return false
end

-- The enabled button at (vx, vy), if any.
---@param vx number
---@param vy number
---@return PanelItem?
function Panel:hit(vx, vy)
    for i = #self.items, 1, -1 do
        local it = self.items[i]
        if it.ob.type == T.BUTTON and not self.hidden[it.name] and not self.itemHidden[it]
            and (self.itemState[it] or self.state[it.name] or 0) ~= 3 then
            local x, y, sc = self.x + it.e.x, self.y + it.e.y, it.scale or 1
            if vx >= x and vy >= y and vx < x + it.ob.w * sc and vy < y + it.ob.h * sc then return it end
        end
    end
end

function Panel:mousemoved(vx, vy)
    local it = self:hit(vx, vy)
    if it ~= self.hover then
        self.hover = it
        if it and self.onFocus then self.onFocus(it.name) end
    end
end

---@return boolean consumed
function Panel:mousepressed(vx, vy, button)
    if button ~= 1 then return false end
    local it = self:hit(vx, vy)
    self.pressed = it
    return it ~= nil
end

---@return boolean consumed
function Panel:mousereleased(vx, vy, button)
    if button ~= 1 then return false end
    local it = self:hit(vx, vy)
    local was = self.pressed
    self.pressed = nil
    if it and it == was then
        require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
        if self.onButton then self.onButton(it.name, it) end
        return true
    end
    return false
end

return M
