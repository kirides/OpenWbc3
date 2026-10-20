-- A small XML reader: elements, attributes, text, entities, comments. parse() returns the root
-- node { tag, attrs = {}, children = {}, text = "" }.
local M = {}

---@class XmlNode
---@field tag string                  "#root" for the document node (returned only when it has no element)
---@field attrs table<string, string> unescaped attribute values
---@field children XmlNode[]
---@field text string                 unescaped text content, concatenated

local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function unescape(s)
    return (s:gsub("&(#?%w+);", function(e)
        if ENT[e] then return ENT[e] end
        local n = e:match("^#(%d+)$")
        if n then return string.char(tonumber(n) % 256) end
        return "&" .. e .. ";"
    end))
end
M.unescape = unescape

local function attrs(s)
    local a = {}
    for k, q, v in s:gmatch('([%w_:%-]+)%s*=%s*(["\'])(.-)%2') do a[k] = unescape(v) end
    return a
end

-- The first top-level element (or the "#root" node when there is none).
---@param src string
---@return XmlNode
function M.parse(src)
    local root = { tag = "#root", attrs = {}, children = {}, text = "" }
    local stack = { root }
    local pos = 1
    local n = #src
    while pos <= n do
        local lt = src:find("<", pos, true)
        if not lt then break end
        local text = src:sub(pos, lt - 1)
        if text:find("%S") then
            local top = stack[#stack]
            top.text = top.text .. unescape(text)
        end
        if src:sub(lt, lt + 3) == "<!--" then
            local e = src:find("-->", lt + 4, true)
            pos = e and e + 3 or n + 1
        elseif src:sub(lt, lt + 1) == "<?" then
            local e = src:find("?>", lt + 2, true)
            pos = e and e + 2 or n + 1
        elseif src:sub(lt, lt + 8) == "<![CDATA[" then
            local e = src:find("]]>", lt + 9, true)
            local top = stack[#stack]
            top.text = top.text .. src:sub(lt + 9, (e or n + 1) - 1)
            pos = e and e + 3 or n + 1
        else
            local gt = src:find(">", lt, true)
            if not gt then break end
            local inner = src:sub(lt + 1, gt - 1)
            if inner:sub(1, 1) == "/" then
                if #stack > 1 then stack[#stack] = nil end
            else
                local selfClose = inner:sub(-1) == "/"
                if selfClose then inner = inner:sub(1, -2) end
                local tag, rest = inner:match("^([%w_:%-%.]+)%s*(.*)$")
                if tag then
                    local node = { tag = tag, attrs = attrs(rest), children = {}, text = "" }
                    local top = stack[#stack]
                    top.children[#top.children + 1] = node
                    if not selfClose then stack[#stack + 1] = node end
                end
            end
            pos = gt + 1
        end
    end
    for _, node in ipairs(root.children) do
        return node
    end
    return root
end

-- Helpers ------------------------------------------------------------------------------------

-- The node's text with white space collapsed (returns gsub's count as a second value).
---@param node XmlNode
function M.text(node)
    return (node.text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

-- First child with the tag, or nil.
---@param node XmlNode
---@param tag string
---@return XmlNode?
function M.child(node, tag)
    for _, c in ipairs(node.children) do
        if c.tag == tag then return c end
    end
end

-- All children with the tag.
---@param node XmlNode
---@param tag string
---@return XmlNode[]
function M.all(node, tag)
    local out = {}
    for _, c in ipairs(node.children) do
        if c.tag == tag then out[#out + 1] = c end
    end
    return out
end

return M
