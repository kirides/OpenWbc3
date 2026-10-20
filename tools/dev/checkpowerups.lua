-- Checks the power-up records (game/content/base/powerups.lua, game/content/base/races.lua) against the 1.04 binary.
--   pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/checkpowerups.lua "<Battlecry III-orig.exe>" [<FUN_004391c0.c>]
-- (run from the repository root; the exe is the 1.04 binary, md5 d8d6debd538857fec26a133f483342da, the one Ghidra shows as
-- "Battlecry III.exe"). Method and background: docs/formats.md "Power-up data of the binary".
--
-- 1. Picture order. FUN_00439050 returns the index of a power-up code in the list of the local side's race: the lists
--    are tables of 4-character codes in .data, one per race slot 0..15 (the start addresses are the `case` labels of
--    that function), each followed by its length as an int32. They are read straight from the file and compared with
--    every race record's `powerupOrder`.
-- 2. Cost and research time (optional second argument). FUN_004391c0 is a ladder of `if (param_1 == <code>)` /
--    `if (param_1 < <code>)` tests that store the cost into `param_2[0..3]` (gold, metal, crystal, stone, int16 each)
--    and the research time in seconds into the int32 at byte offset 8 (`*(undefined4 *)(param_2 + 4)`), with `goto LAB_...`
--    shared tails. The file is the pseudo-C that Ghidra's decompiler prints for it (plain text: with the MCP tool's JSON
--    result, `jq -r .code`).
--    The few statements the function uses are interpreted here and every power-up record is compared with the result.
-- The army statistic bonuses (power-up apply FUN_00436500, calls of FUN_00438760) are not checked by this script.
local exePath, cPath = ...
assert(exePath, "usage: checkpowerups.lua <exe> [<FUN_004391c0.c>]")
local content = require("src.content")

local f = assert(io.open(exePath, "rb"))
local data = f:read("*a")
f:close()
---@param o integer file offset
---@return integer
local function u16(o) return data:byte(o + 1) + data:byte(o + 2) * 256 end
---@param o integer file offset
---@return integer
local function u32(o) return u16(o) + u16(o + 2) * 65536 end

-- virtual address -> file offset through the PE section table
local pe = u32(0x3c)
local nsec, optSize = u16(pe + 6), u16(pe + 20)
local base = u32(pe + 24 + 28)
---@param va integer virtual address
---@return integer
local function fileOffset(va)
    for i = 0, nsec - 1 do
        local o = pe + 24 + optSize + i * 40
        local vsize, vaddr, rsize, raw = u32(o + 8), u32(o + 12), u32(o + 16), u32(o + 20)
        local rva = va - base
        if rva >= vaddr and rva < vaddr + math.min(vsize, rsize) then return raw + rva - vaddr end
    end
    error("address not in the file")
end

local failures = 0
---@param fmt string
local function fail(fmt, ...) failures = failures + 1 print("[fail] " .. fmt:format(...)) end

-- 1. the race lists: race slot -> start address (the switch of FUN_00439050); the length int32 follows the table
local STARTS = { [0] = 0x006089dc, 0x00608a74, 0x00608ae0, 0x00608b50, 0x00608bec, 0x00608c64, 0x00608cc0, 0x00608d48,
                 0x00608dd0, 0x00608f44, 0x00608e54, 0x00608ecc, 0x00608fdc, 0x006090f8, 0x00609174, 0x00609070 }
for slot = 0, 15 do
    local list = {}
    local o = fileOffset(STARTS[slot])
    -- the table ends where the next table or the length word begins; the length word is the int32 after the last code, so
    -- walk codes until a word is no printable code and take the count from it
    local n = 0
    while true do
        local c = data:sub(o + n * 4 + 1, o + n * 4 + 4)
        if c:match("^[%u%d][%u%d][%u%d][%u%d]$") then n = n + 1 else break end
    end
    local count = u32(o + n * 4)
    if count ~= n then fail("race slot %d: %d codes before the length word %d", slot, n, count) end
    for i = 0, n - 1 do list[#list + 1] = data:sub(o + i * 4 + 1, o + i * 4 + 4) end
    local rec = content.race:bySlot(slot)
    local mine = rec and rec.powerupOrder or {}
    if #mine ~= #list then
        fail("race slot %d: record lists %d power-ups, the binary %d", slot, #mine, #list)
    else
        for i = 1, #list do
            if mine[i] ~= list[i] then fail("race slot %d entry %d: %s, binary %s", slot, i, tostring(mine[i]), list[i]) break end
        end
    end
end
print(("order: 16 race lists read from the exe, %d failures so far"):format(failures))

-- 2. cost and time out of the decompiled FUN_004391c0
if cPath then
    local src = assert(io.open(cPath, "rb")):read("*a"):gsub("\r", "")
    local lines = {}
    for line in src:gmatch("[^\n]+") do lines[#lines + 1] = line:gsub("^%s+", ""):gsub("%s+$", "") end

    -- Flatten the text into statements. An `if` chain is a list of parts (if / else if / else): a false condition continues
    -- at the next part (or after the chain), reaching a part header from above means the previous part is done and
    -- continues after the chain. `goto` may land anywhere, so execution is a program counter over the flat list.
    local code, labels, chains = {}, {}, {}
    local function add(st) code[#code + 1] = st return #code end
    for i, line in ipairs(lines) do
        local lab = line:match("^(LAB_%x+):$")
        local c1 = line:match("^if %((.*)%) {$")
        local c2 = line:match("^else if %((.*)%) {$")
        local cg, lg = line:match("^if %((.*)%) goto (LAB_%x+);$")
        if lab then
            labels[lab] = #code + 1
        elseif cg then
            add({ k = "cgoto", cond = cg, label = lg })
        elseif c1 then
            local n = add({ k = "if", cond = c1 })
            chains[#chains + 1] = { n }
        elseif line:match("^else if %(.*%) goto LAB_%x+;$") then
            -- a part without braces ends its chain
            local c, l = line:match("^else if %((.*)%) goto (LAB_%x+);$")
            local chain = table.remove(chains)
            chain[#chain + 1] = add({ k = "elseif", cond = c })
            add({ k = "goto", label = l })
            for k, n in ipairs(chain) do
                code[n].after = #code + 1
                code[n].nextPart = chain[k + 1] or #code + 1
                code[n].chain = chain
            end
        elseif c2 or line == "else {" then
            local n = add({ k = c2 and "elseif" or "else", cond = c2 })
            local chain = chains[#chains]
            chain[#chain + 1] = n
        elseif line == "}" then
            local nxt = lines[i + 1]
            if not (nxt and nxt:match("^else")) and #chains > 0 then
                local chain = table.remove(chains)
                for k, n in ipairs(chain) do
                    code[n].after = #code + 1                    -- the statement after the chain
                    code[n].nextPart = chain[k + 1] or #code + 1
                    code[n].chain = chain
                end
            end
        elseif line:match("^goto LAB_%x+;$") then
            add({ k = "goto", label = line:match("(LAB_%x+)") })
        elseif line == "return;" then
            add({ k = "return" })
        else
            local target, value = line:match("^(.-) = (.-);$")
            if target then add({ k = "assign", target = target, value = value }) end
        end
    end
    ---@param c string a condition of the decompiled function
    ---@param regs table<string, integer> the local variables
    ---@return boolean
    local function evalCond(c, regs)
        local a, op, b = c:match("^(%S+) ([=!<>]=?) (%S+)$")
        if not a then
            local neg, name = c:match("^(!?)(%a+%d+)$")
            if name then return (regs[name] ~= nil and regs[name] ~= 0) ~= (neg == "!") end
            error("condition not understood: " .. c)
        end
        local x, y = regs[a] or tonumber(a), regs[b] or tonumber(b)
        if x == nil or y == nil then error("operand not understood: " .. c) end
        if op == "==" then return x == y elseif op == "!=" then return x ~= y
        elseif op == "<" then return x < y elseif op == "<=" then return x <= y
        elseif op == ">" then return x > y else return x >= y end
    end
    -- Runs the flattened function for the power-up `id` (its code as an int32): { [0..3] = cost, time = seconds }.
    ---@param id integer
    ---@return table
    local function run(id)
        local regs = { param_1 = id }
        local out = {}
        local pc, steps, viaChain = 1, 0, nil
        while pc <= #code do
            steps = steps + 1
            assert(steps < 100000, "no end")
            local st = code[pc]
            local nextpc = pc + 1
            if st.k == "elseif" or st.k == "else" then
                if not (viaChain and viaChain.pc == pc and viaChain.chain == st.chain) then
                    nextpc = st.after              -- reached from above: the part before it ran, so leave the chain
                elseif st.k == "elseif" and not evalCond(st.cond, regs) then
                    nextpc = st.nextPart
                    viaChain = { pc = nextpc, chain = st.chain }
                end
            elseif st.k == "if" then
                if not evalCond(st.cond, regs) then
                    nextpc = st.nextPart
                    viaChain = { pc = nextpc, chain = st.chain }
                end
            elseif st.k == "cgoto" then
                if evalCond(st.cond, regs) then nextpc = labels[st.label] end
            elseif st.k == "goto" then
                nextpc = labels[st.label]
            elseif st.k == "return" then
                return out
            else
                local t, v = st.target, st.value
                local val
                local a, b = v:match("^(%S+) == (%S+)$")
                if a then val = (regs[a] or tonumber(a)) == (regs[b] or tonumber(b)) and 1 or 0
                else val = regs[v] or tonumber(v) end
                local idx = t == "*param_2" and 0 or t:match("^param_2%[(%d+)%]$")
                if idx then out[tonumber(idx)] = val
                elseif t:match("^%*%(undefined4 %*%)%(param_2 %+ 4%)$") then out.time = val
                elseif t:match("^%a+%d+$") then regs[t] = val
                else error("target not understood: " .. t) end
            end
            assert(nextpc, "jump target missing at statement " .. pc .. " (" .. tostring(st.k) .. " " .. tostring(st.label or st.cond) .. ")")
            pc = nextpc
        end
        return out
    end
    local compared, bad, defaulted = 0, 0, {}
    for _, rec in ipairs(content.powerup:all()) do
        local c = rec.id
        if c:match("^[PR]") then
            local id = c:byte(1) + c:byte(2) * 256 + c:byte(3) * 65536 + c:byte(4) * 16777216
            local ok, out = pcall(run, id)
            local g, m, cr, s = rec.cost.gold, rec.cost.metal, rec.cost.crystal, rec.cost.stone
            compared = compared + 1
            if not src:find(string.format("0x%x", id), 1, true) then defaulted[#defaulted + 1] = c end
            if not ok then
                bad = bad + 1
                fail("%s: %s", c, tostring(out))
            elseif (out[0] or 0) ~= g or (out[1] or 0) ~= m or (out[2] or 0) ~= cr or (out[3] or 0) ~= s or (out.time or 0) ~= rec.time then
                bad = bad + 1
                fail("%s: record %d/%d/%d/%d %ds, binary %s/%s/%s/%s %ss", c, g, m, cr, s, rec.time,
                    tostring(out[0]), tostring(out[1]), tostring(out[2]), tostring(out[3]), tostring(out.time))
            end
        end
    end
    print(("cost: %d power-ups compared with FUN_004391c0, %d differ"):format(compared, bad))
    -- a code without a case of its own falls to the function's default (100 gold, 100 metal, 60 s): those records match by that
    print(("cost: %d codes have no case in the function (the default applies): %s"):format(#defaulted, table.concat(defaulted, " ")))
end
print(failures == 0 and "checkpowerups: identical" or ("checkpowerups: %d failures"):format(failures))
