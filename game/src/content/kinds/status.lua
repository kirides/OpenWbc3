-- Content kind `status` (stage 3, docs/data-driven/03-spells-effects.md 3.4): the timed effects on units, `u.fx[id] = { t1, value, ... }`.
-- Key: the effect name ("poison", "stun" ...). The engine (src/game/status.lua) applies, refreshes and expires them and runs these rules:
--   stat            the statistic the effect's value is added to (combat, speed, armor, resistance, damage)
--   bonus           { stat = n } fixed modifiers while the effect lasts (Drunkenness, Fanaticism)
--   stats           function(u, st, f): changes the statistics table of the unit (slow, disease, fear ...)
--   negative        removed by the cures and by "clear negative effects"
--   stuns           the unit cannot act while it lasts
--   tick            { every = ms (default 1000), first = ms to the first tick (default every), fn = function(u, f, t) }:
--                   runs while it lasts (poison, burning)
--   expire          function(u, f): when it runs out
--   onRemove        function(u): when something removes it early
--   resist          { type, pct }: reduces damage of that type by value (default pct) percent;  immuneRanged: ranged damage does nothing
--   damage          { type, range }: a damage effect that can replace the unit's attack (Fire Breathing, Ice Floe)
--   infection       poison / disease: only a unit without any infection or `blocksInfection` effect can catch one
---@class StatusRecord
---@field id string
---@field doc string?
---@field stat string?
---@field bonus table<string, number>?
---@field stats (fun(u: Unit, st: UnitStats, f: StatusEffect))?
---@field negative boolean?
---@field stuns boolean?
---@field tick { every: integer?, first: integer?, fn: fun(u: Unit, f: StatusEffect, t: number) }?
---@field expire (fun(u: Unit, f: StatusEffect))?
---@field onRemove (fun(u: Unit))?
---@field resist { type: integer, pct: integer? }?
---@field immuneRanged boolean?
---@field damage { type: integer, range: integer }?
---@field infection boolean?
---@field blocksInfection boolean?

return {
    name = "status",
    doc = "timed effects on units",
}
