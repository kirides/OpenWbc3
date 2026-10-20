-- The original's generic message box (the binary's FUN_0042d7b0 fills panel 341
-- PNL_MESSAGE_BOX): a dimmed screen, a parchment with a title, up to three text lines and no, one or two buttons. With
-- one button it is the middle one (BUTT_MESSAGEBOX_ZERO, 309, 345), with two the left (BUTT_MESSAGEBOX_ONE at 216,
-- result false) and the right one (BUTT_MESSAGEBOX_TWO at 403, result true); the text arguments of FUN_0042d7b0
-- (title, string 1, string 2) land in the title and in text lines 1 and 2 (a lone string 2 goes into the second
-- line, FUN_0042d7b0). It is a widget that a screen owns and draws on top of itself, not a screen of the stack, so
-- that the screen under it goes on receiving network messages.
--
--   local box = msgbox.new{ title = "...", line1 = "...", line2 = "...", buttons = { "No", "Yes" },
--                           onResult = function(yes) ... end }
--   box:draw() / box:mousepressed(vx, vy, button) / box:mousereleased(...) / box:mousemoved(...) / box:keypressed(key)
local UI = require("src.ui.interface")

---@class MsgBoxConfig
---@field title string?
---@field line1 string?
---@field line2 string?
---@field buttons string[]?    none, one or two (left: false, right: true)
---@field onResult fun(yes: boolean)?

---@class MsgBox
---@field cfg MsgBoxConfig
---@field panel Panel
---@field count integer        buttons shown (0..2)
local M = {}
M.__index = M

---@param cfg MsgBoxConfig
---@return MsgBox
function M.new(cfg)
    local self = setmetatable({ cfg = cfg }, M) --[[@as MsgBox]]
    -- PNL_MESSAGE_BOX and its objects are part of every War4Int.xci
    local p = UI.panel("PNL_MESSAGE_BOX", { x = 0, y = 0, onButton = function(name) self:button(name) end })
    ---@cast p -nil
    self.panel = p
    local title = p:find("STR_PARCHLARGE_L400") --[[@as PanelItem]]
    p.itemStrings[title] = cfg.title or ""
    p.align[title] = "center"
    local lines = p:all("STR_PARCHSMALL_L400")
    local texts = { "", cfg.line1 or cfg.line2 or "", "" }          -- a single string sits in the second line
    if cfg.line1 and cfg.line2 then texts = { cfg.line1, cfg.line2, "" } end
    for i, it in ipairs(lines) do
        p.itemStrings[it] = texts[i] or ""
        p.align[it] = "center"
    end
    local zero, one, two = p:find("BUTT_MESSAGEBOX_ZERO"), p:find("BUTT_MESSAGEBOX_ONE"), p:find("BUTT_MESSAGEBOX_TWO")
    ---@cast zero -nil
    ---@cast one -nil
    ---@cast two -nil
    for _, it in ipairs({ zero, one, two }) do p:hideItem(it, true) end
    local b = cfg.buttons or {}
    if #b == 1 then
        p:hideItem(zero, false)
        p.itemStrings[zero] = b[1]
    elseif #b >= 2 then
        p:hideItem(one, false)
        p:hideItem(two, false)
        p.itemStrings[one], p.itemStrings[two] = b[1], b[2]
    end
    self.count = math.min(#b, 2)
    return self
end

---@param name string
function M:button(name)
    local yes = name ~= "BUTT_MESSAGEBOX_ONE"
    if self.cfg.onResult then self.cfg.onResult(yes) end
end

function M:draw()
    self.panel:draw()
end

function M:mousemoved(vx, vy) self.panel:mousemoved(vx, vy) end
function M:mousepressed(vx, vy, button) return self.panel:mousepressed(vx, vy, button) end
function M:mousereleased(vx, vy, button) return self.panel:mousereleased(vx, vy, button) end

-- Enter takes the right / only button, Escape the left one of two.
---@param key string
function M:keypressed(key)
    if self.count == 0 then return end
    if key == "return" or key == "kpenter" then self:button("BUTT_MESSAGEBOX_TWO")
    elseif key == "escape" and self.count == 2 then self:button("BUTT_MESSAGEBOX_ONE") end
end

return M
