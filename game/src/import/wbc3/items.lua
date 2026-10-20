-- Importer: the item catalogue <Lang>/Items.xcr/Items.xml -> `item` records (kinds/item.lua). The names and descriptions are
-- the install's text in the language it was started with.
--   <Item id> <Name> <Power id type data [chance level]>text</Power> <Description> <Image iconrow iconcol/> <Data value level rarity/>
local vfs = require("src.vfs.vfs")
local text = require("src.core.text")

local ENTITIES = { ["&apos;"] = "'", ["&quot;"] = '"', ["&lt;"] = "<", ["&gt;"] = ">", ["&amp;"] = "&" }
local function unescape(s)
    return (s:gsub("&%a+;", ENTITIES))
end

local function attrs(tag)
    local a = {}
    for k, v in tag:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do a[k] = unescape(v) end
    return a
end

---@param content Content
return function(content)
    local xml = vfs.find("Items.xml")
    if not xml then
        content.warn("Items.xml missing")
        return
    end
    xml = text.fromCP1252(xml)
    local tiers = content.setting:value("item.tiers", {})
    for id, body in xml:gmatch('<Item%s+id="(%d+)"%s*>(.-)</Item>') do
        local it = { id = tonumber(id), powers = {} }
        it.name = unescape(body:match("<Name>(.-)</Name>") or "?")
        it.desc = unescape((body:match("<Description>(.-)</Description>") or ""):gsub("%s+", " "))
        for tag, slash, inner in body:gmatch("<Power(%s[^>]-)(/?)>([^<]*)") do
            local a = attrs(tag)
            if a.type then
                inner = slash == "" and inner:match("^%s*(.-)%s*$") or ""
                it.powers[#it.powers + 1] = { type = a.type, data = tonumber(a.data) or 0, chance = tonumber(a.chance),
                                              level = tonumber(a.level), text = inner ~= "" and unescape(inner) or nil }
            end
        end
        local img = body:match("<Image([^>]*)/?>")
        local ia = img and attrs(img) or {}
        it.row, it.col = tonumber(ia.iconrow) or 0, tonumber(ia.iconcol) or 0
        local d = body:match("<Data([^>]*)/?>")
        local da = d and attrs(d) or {}
        it.value = tonumber(da.value) or 0
        it.tier = tiers[da.level or "minor"] or 1
        it.tierName = da.level or "minor"
        it.rarity = tonumber(da.rarity) or 0
        it.slot = it.row
        content.item:add(it)
    end
end
