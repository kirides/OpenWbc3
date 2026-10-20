-- Patches are plain tables merged into the records, or functions that change a record in place (see docs/modding/registry.md).
content.unit:patch("AHBX", { hits = 40 })                       -- the Knights' peasant
content.unit:patch("AHFX", { cost = { gold = 120 } })           -- a cheaper Knight (the other costs stay)
content.unit:patch("AWGX", { behaviour = { conversion = content.REMOVE } })    -- the Dryad general: no special conversion rate any more
-- every army unit of the Dwarves gets 2 more hit points per size class: a computed update
content.unit:patch(function(u) return u.races and u.races.dwarf end, { hits = function(old) return (old or 0) + 2 end })
