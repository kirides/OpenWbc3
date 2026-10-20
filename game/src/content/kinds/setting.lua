-- Content kind `setting`: named constants of the rules (docs/data-driven/01-content-registry.md 1.3, stage 4).
-- Record: { id = "xp.table", value = <number|string|boolean|table>, own = true|nil, doc = "..." }
--   value  the constant; patch it with content.setting:patch("xp.table", { value = ... }) (tables merge field-wise)
--   own    true when the number is openwbc3's own choice (the original data does not give it); the dump shows which
--          values are inventions. Numbers from the original carry a comment naming their origin in the base file.
--   doc    one line for modders
-- `content.setting:value(id, default)` reads a value (the engine's accessor).
---@class SettingRecord
---@field id string
---@field value any
---@field own boolean?
---@field doc string?

return {
    name = "setting",
    doc = "named rule constants (step times, xp table, economy amounts ...)",
    fields = { value = "the constant", own = "true: openwbc3's own number", doc = "one line for modders" },
    validate = function(rec)
        if rec.value == nil then return "has no value" end
    end,
}
