-- Content kind `missile` (stage 3, docs/data-driven/03-spells-effects.md 3.5): the missile pictures. Key: the picture code ("EMA0" ...).
--   flags       the DIMN flags (speed, path, carry-through, splash, instant ...), see game/missiles.lua `F`
--   sprite      the picture a ball is drawn with when it is not the code itself
--   piercing    plain piercing missile: buildings and missile-resistant units take a sixteenth of its damage
--   lightning   { { baseR, stepR }, { baseG, stepG }, { baseB, stepB } }: the colour ramp of an instant bolt's lines
--   trail       after-image frames behind the picture (sheet columns `frames` ..), default 0
--   frames      animation frames of the picture itself (default 1); dirs: the direction rows of its sheet (default 16);
--               spinner: turns through its rows instead of facing along the flight
--   picture     dragon breath: first three letters of its effect pictures (E?B0 .. E?B7)
--   special     the breath always carries its special attack; doubleVs "good" / "evil": takes double damage
--   attack      breath: { kind = "reduceArmour" | "drainXp" | "crystallize", amount } done to every army it hurts (Unit.breathSpecial)
--   after       breath: { sprite = effect picture, emit = emitter code } put on a walking army it hurts
---@class MissileRecord
---@field id string
---@field flags integer
---@field sprite string?
---@field piercing boolean?
---@field lightning integer[][]?
---@field trail integer?
---@field frames integer?
---@field dirs integer?
---@field spinner boolean?
---@field picture string?
---@field special boolean?
---@field doubleVs string?
---@field attack { kind: string, amount: integer }?
---@field after { sprite: string, emit: string? }?
---@field burst string?                 the effect picture a Titan's ball bursts with
---@field getsUp integer?               one in n: a thrown goblin gets up again

return {
    name = "missile",
    doc = "missile pictures",
}
