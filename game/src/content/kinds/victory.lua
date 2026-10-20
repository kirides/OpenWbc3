-- Content kind `victory` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.4): the victory conditions of a battle. Key: the rule
-- name ("standard", "raze all" ...), see content/base/victory.lua for the fields (slot, alias, timer, running, defeat, alive, setup, total,
-- winners). The engine's rule code (src/game/victory.lua, Eco:checkVictory) walks the records instead of comparing rule names.
-- The context `winners` gets.
---@class VictoryContext
---@field alive integer[]
---@field withAllies fun(side: integer): integer[]
---@field timerDone fun(): boolean
---@field extend fun(seconds: number)

---@class VictoryRecord
---@field id string
---@field slot integer
---@field alias string[]?
---@field timer integer?
---@field running boolean?
---@field defeat { units: (true|"heroes")?, buildings: ("stopDefeat"|"notMines")? }?
---@field alive (fun(world: World, side: integer): boolean?)?
---@field setup (fun(world: World, startSides: integer[]))?
---@field total (fun(world: World, side: integer): number)?
---@field decidedAtEnd boolean?
---@field flagGame boolean?
---@field pitched boolean?
---@field computerHeroLevel integer?
---@field noComputerPack boolean?
---@field winners (fun(world: World, ctx: VictoryContext): integer[]?)?

return {
    name = "victory",
    doc = "victory conditions",
    slotted = true,
}
