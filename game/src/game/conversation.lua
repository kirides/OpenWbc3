-- Scenario conversations (<Lang>/Campaign.xcr/<name>.nis, started by the ENIS event effect): characters
-- with a portrait and a name, then messages that are shown one after another. A message can carry a
-- condition on the player's hero ("evil", "not highelf and not immortal", "or ..."), and a <Flag id="n"/>
-- element names an event flag that is set when the conversation ends.
local vfs = require("src.vfs.vfs")
local xml = require("src.core.xml")
local text = require("src.core.text")
local content = require("src.content")

local M = {}

local function set(...)
    local t = {}
    for _, v in ipairs({ ... }) do t[v] = true end
    return t
end

local GOOD_CLASS, EVIL_CLASS = set("healer", "paladin"), set("deathknight", "assassin", "defiler", "necromancer", "lichelord")
local WIZARD = set("druid", "runemaster", "shaman", "elementalist", "defiler", "archmage", "necromancer", "pyromancer",
                   "summoner", "alchemist", "illusionist", "icemage", "lichelord", "sage")
local ROGUE = set("thief", "assassin", "merchant", "bard")

-- who = { race = 0..15, class = "Paladin" }
---@param word string
---@param who {class: string?, race: integer}
---@return boolean
local function test(word, who)
    local class = (who.class or ""):lower()
    local race = who.race
    local rec = content.race:bySlot(race)
    local named = content.race:byWord(word)
    if named then return rec == named end
    local alignment, mortal = rec and rec.alignment, rec and rec.mortal
    if word == "evil" then return EVIL_CLASS[class] or (alignment == "evil" and not GOOD_CLASS[class]) or false end
    if word == "good" then return GOOD_CLASS[class] or (alignment == "good" and not EVIL_CLASS[class]) or false end
    if word == "mortal" then return mortal or false end
    if word == "immortal" then return not mortal end
    if word == "wizard" then return WIZARD[class] or false end
    if word == "rogue" then return ROGUE[class] or false end
    return class == word      -- a class name (the original tests "warrior", "priest" and "thief" the same way)
end

-- "[or] [and] [not] word" terms, evaluated left to right like the original
---@param cond string?
---@param who {class: string?, race: integer} the hero
---@return boolean
function M.test(cond, who)
    if not cond or cond == "" then return true end
    local result = true
    local words = {}
    for w in cond:lower():gmatch("%S+") do words[#words + 1] = w end
    local i = 1
    while i <= #words do
        local join = "and"
        if words[i] == "or" or words[i] == "and" then join = words[i] i = i + 1 end
        local negate = false
        if words[i] == "not" then negate = true i = i + 1 end
        if not words[i] then break end
        local v = test(words[i], who)
        if negate then v = not v end
        if join == "or" then result = result or v else result = result and v end
        i = i + 1
    end
    return result
end

-- Returns { characters = { [id] = { name, portrait } }, messages = { { character, text, condition } }, flag }
-- or nil when the file does not exist. Character 0 is the player's hero (filled in by the caller).
-- A conversation (NIS) of the campaign.
---@class Conversation
---@field characters table<integer, {name: string, portrait: integer}>
---@field messages {character: integer, text: string, condition: string?}[]
---@field flag integer?

---@param name string
---@return Conversation?
function M.load(name)
    local data = vfs.read("Campaign.xcr", name)
    if not data then return nil end
    local root = xml.parse(text.fromCP1252(data))
    if not root or root.tag ~= "NIS" then return nil end
    local conv = { characters = {}, messages = {} }
    for _, c in ipairs(xml.all(root, "Character")) do
        conv.characters[tonumber(c.attrs.id) or 0] = { name = xml.text(c), portrait = tonumber(c.attrs.portrait) or 0 }
    end
    for _, m in ipairs(xml.all(root, "Message")) do
        conv.messages[#conv.messages + 1] = { character = tonumber(m.attrs.character) or 0, text = xml.text(m),
                                              condition = m.attrs.condition }
    end
    local flag = xml.child(root, "Flag")
    conv.flag = flag and tonumber(flag.attrs.id) or nil
    return conv
end

return M
