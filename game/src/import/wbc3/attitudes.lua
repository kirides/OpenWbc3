-- Importer: the install's custom unit attitudes (CustomUnitAI/*.uai, formats/uai.lua) as `attitude` records after the built-in ones
-- (the *.uai loader FUN_00505ad0: at most 100 attitudes in all, a file with a bad header is skipped). The name and description come
-- from Names.cfg CUAI_NAME_<ROOT> / CUAI_DESC_<ROOT> when it has them, else from the file; the id is the file's root name.
local strings = require("src.game.strings")
local config = require("src.core.config")

local ATTITUDE_LIMIT = 100
local ICON_COUNT, ICON_UNKNOWN = 12, 10       -- attitude.lua ICONS: an icon beyond the sheet's twelve shows the question mark

---@param content Content
return function(content)
    if not config.gamedir then return end
    local uai = require("src.formats.uai")
    local count, order = #content.attitude:all(), 100
    for _, f in ipairs(uai.files()) do
        if count >= ATTITUDE_LIMIT then break end
        local ai = uai.load(f.file)
        if ai and not content.attitude[f.root] then
            local key = f.root:upper()
            content.attitude:add{
                id = f.root, order = order, custom = true,
                title = strings.get("Names.cfg", "CUAI_NAME_" .. key) or ai.name,
                desc = strings.get("Names.cfg", "CUAI_DESC_" .. key) or ai.description,
                icon = ai.icon >= ICON_COUNT and ICON_UNKNOWN or ai.icon, size = ai.size, centre = ai.centre,
                designated = ai.designated, spells = ai.spells, rules = ai.rules, idle = ai.idle,
            }
            count, order = count + 1, order + 1
        end
    end
end
