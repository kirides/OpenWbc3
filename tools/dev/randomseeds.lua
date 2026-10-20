-- Builds random maps for many seeds (every terrain, size and side count) and checks them: connected corners, start
-- locations free / reachable / not crowded, towers, buildings and critters on the map.
--   pwsh tools/dev/love.ps1 -Timeout 600 -- --selftest --lua tools/dev/randomseeds.lua [count]
local n = tonumber((...)) or 50
local problems = require("src.tools.randomtest").seeds(n)
if problems > 0 then print(problems .. " problems") end
