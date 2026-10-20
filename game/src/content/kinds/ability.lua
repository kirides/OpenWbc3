-- Content kind `ability` (stage 4, docs/data-driven/04-heroes-abilities-rules.md 4.2): the special buttons of units and buildings. Key: the
-- ability's name. `kind` says what the record is: "spell" (a troop's mana button reusing a spell), "morph" (the Undead morph chain),
-- "building" (the extra buttons of a building); the fields of each are documented in content/base/abilities.lua. The behaviour of drunkenness,
-- fanaticism, sacrifice and the wisp merge is coded in game/armyabilities.lua (they are not records).

---@class AbilityRecord
---@field id string
---@field kind "spell"|"morph"|"building"
---@field icon integer                  Panel_Icons index
---@field name string                   Game.txt key or a plain name
---@field order integer?                button order
---@field units string[]?               spell: the troops that have the button
---@field mana integer?                 spell: the mana cost (0: none); the button is enabled from it
---@field cost integer?                 spell: the mana a press needs and takes when it differs from `mana` (Freeze)
---@field all boolean?                  spell: every selected caster uses it (Invisibility), not just the first
---@field spell integer?                spell: the slot of the spell whose effect it reuses
---@field power (string|table<string, string>)?   spell: caster code -> power-up it needs; building: the power-up that enables it
---@field race table<string, string>?   spell: caster code -> race id the side must be for the button to appear
---@field limit string?                 spell: the army type that must fit under the army limit first
---@field from string?                  morph: the unit it morphs from
---@field to string?                    morph: the unit it becomes
---@field res string?                   morph: the resource of the price
---@field amount integer?               morph: the price
---@field need string[]?                morph: the buildings it needs
---@field req string?                   morph: Game.txt key of the requirement text
---@field slot integer?                 building: 1 / 2, the button below the unload button
---@field buildings string[]?           building: the building codes that offer it
---@field races string[]?               building: the race ids it is shown for
---@field orPower boolean?              building: or for anyone who bought the power-up
---@field buildingRace table<string, string>?   building: a race per building code
---@field family string[]?              building: the levels of the power-up
---@field needsPower boolean?          building: the button only appears once the power-up is bought (Famine)
---@field room boolean?                building: the button is only enabled while the army limit has room
---@field free boolean?                 building: no power-up needed
---@field crystal integer?              building: the cost of a one-shot
---@field gold integer?
---@field resource string?              building: what hiring costs
---@field each integer?                 building: the price per hired unit
---@field max integer?                  building: most units one press hires
---@field unit string?                  building: the unit it hires
---@field delay integer?                building: ms between two presses of a hiring button
---@field weather string?               building: the weather it makes
---@field effect string?                building: the effect it fires ("balm", "holy" ...)
---@field morph string?                 building: the unit it turns into a skeleton
---@field snd integer?                  building: the sound of the effect
---@field dialog string?                building: the dialog it opens ("trade")
---@field key integer?                  its KeyMap.txt ability key: the case of FUN_00426350 (game/abilitykeys.lua)
---@field keyUnits string[]?            spell: the casters the key tries, when not `units`
---@field keyFirst string[]?            spell: casters the key looks for in the selection only, before `keyUnits`
---@field keyLoop string[]?             spell: every selected caster of these codes casts (Invisibility)
---@field keyNoPower boolean?           spell: the key ignores `power`
---@field keyBuildings string[]?        building: the buildings the key looks for, in order
---@field keyUnpaid boolean?            building: the key casts without taking the price

return {
    name = "ability",
    doc = "unit and building abilities",
}
