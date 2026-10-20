-- Content kind `attitude` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.3): the stances of units, as rule sets (src/game/attitude.lua
-- explains what the engine does with them). Key: the attitude's name, which is what a unit and a save store. Fields:
--   order         position in the attitude list of the interface (the nine built-in ones are 1..9, the install's CustomUnitAI/*.uai follow)
--   text          Game.txt id of the name (the description is the next id); `title` / `desc` are plain texts instead (custom attitudes, mods)
--   icon          index of the stance icon of SkillIcons.bmp (attitude.lua ICONS)
--   size          the active area, in cells around the guard point
--   designated    the attitude follows a designated unit (Guardian), spells: the unit also casts spells on its own
--   idle          the action when no rule holds (nil: stay), rules: up to 10 { priority, name, overrides, conds = { { code, unit, area,
--                 result, extra = { threshold, 0, 0 } } ... }, action = { code, unit, area, extra } }; the codes are the engine's
--                 (attitude.lua CONDITION and ACTION), `unit` is 0 me, 1 my hero, 2 the designated unit
--   custom        read from a .uai file of the install
local CONDITIONS, ACTIONS = 8, 10

---@class AttitudeRecordCondition
---@field code integer                  attitude.lua CONDITION
---@field unit integer                  0 me, 1 my hero, 2 the designated unit
---@field area boolean
---@field result boolean
---@field extra integer[]               { threshold, 0, 0 }

---@class AttitudeRecordAction
---@field code integer                  attitude.lua ACTION
---@field unit integer
---@field area boolean
---@field extra integer[]

---@class AttitudeRecordRule
---@field priority integer
---@field name string
---@field overrides boolean
---@field conds AttitudeRecordCondition[]
---@field action AttitudeRecordAction

---@class AttitudeRecord
---@field id string
---@field order integer
---@field text string?                  Game.txt id of the name (the description is the next id)
---@field title string?                 plain name (custom attitudes, mods)
---@field desc string?                  plain description
---@field icon integer
---@field size integer                  the active area in cells around the guard point
---@field centre integer?               from a .uai file
---@field designated boolean?
---@field spells boolean?
---@field idle AttitudeRecordAction?
---@field rules AttitudeRecordRule[]
---@field custom boolean?               read from a .uai file of the install

return {
    name = "attitude",
    doc = "unit attitudes: rule sets of conditions and actions",
    sortBy = "order",
    ---@param rec AttitudeRecord
    validate = function(rec)
        if type(rec.order) ~= "number" then return "order must be a number" end
        if type(rec.icon) ~= "number" then return "icon must be a number" end
        if type(rec.rules) ~= "table" then return "rules must be a list" end
        if not rec.text and not rec.title then return "needs a text (Game.txt id) or a title" end
        local function action(a, what)
            if type(a) ~= "table" or type(a.code) ~= "number" or a.code < 0 or a.code > ACTIONS then return what .. " has no known action code" end
        end
        for i, r in ipairs(rec.rules) do
            if type(r.priority) ~= "number" then return ("rule %d has no priority"):format(i) end
            for j, c in ipairs(r.conds or {}) do
                if type(c.code) ~= "number" or c.code < 0 or c.code > CONDITIONS then return ("rule %d condition %d has no known code"):format(i, j) end
            end
            local msg = action(r.action, ("rule %d"):format(i))
            if msg then return msg end
        end
        if rec.idle then return action(rec.idle, "the idle action") end
    end,
}
