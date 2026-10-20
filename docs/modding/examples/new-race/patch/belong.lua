-- Everything the Orcs can have, the Goblins can have: sets of race ids on the units and buildings, and the production lists per race.
content.unit:patch(function(u) return u.races.orc end, function(u) u.races["new_race:goblins"] = true end)
content.building:patch(function(b) return b.races.orc end, function(b) b.races["new_race:goblins"] = true end)
content.building:patch(function(b) return b.produces and b.produces.orc end, function(b)
    b.produces["new_race:goblins"] = content.clone(b.produces.orc)
end)
-- The tech tree and the per-race overrides are keyed by race id as well: copy the Orcs' entries.
for _, kind in ipairs({ content.unit, content.building, content.powerup }) do
    kind:patch(function(t) return t.requires and t.requires.orc or t.priority and t.priority.orc or t.byRace and t.byRace.orc end, function(t)
        for _, field in ipairs({ "requires", "priority", "byRace" }) do
            if t[field] and t[field].orc ~= nil then t[field]["new_race:goblins"] = content.clone(t[field].orc) end
        end
    end)
end
