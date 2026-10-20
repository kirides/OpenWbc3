-- Developer commands of the content registry (docs/data-driven/01-content-registry.md 1.7, 6.4), headless:
--   --content-report                      builds the registry, prints errors, warnings and the hash
--   --dump-content [dir] [kind ...]       writes <dir>/<kind>.lua for the given kinds (default: all); default dir is
--                                         <LÖVE save directory>/dump (gitignored by living outside the repository)
local config = require("src.core.config")
local log = require("src.core.log")
local fs = require("src.core.fs")

local M = {}

---@param args string[]
---@param name string
---@return boolean
local function has(args, name)
    for _, a in ipairs(args) do if a == name then return true end end
    return false
end

-- True when the command line asks for one of these commands.
---@param args string[]
---@return boolean
function M.wanted(args)
    return has(args, "--dump-content") or has(args, "--content-report") or has(args, "--mods-list") or has(args, "--check-mod")
end

---@param args string[]
---@return integer exit code
function M.run(args)
    if not config.load(args) then return 1 end
    require("src.vfs.vfs").init(config.gamedir, config.language)
    local content = require("src.content")
    local mods = require("src.content.mods")
    mods.configure(args)
    if has(args, "--mods-list") then
        local planned, errors = mods.plan()
        local on = {}
        for _, rec in ipairs(planned) do on[rec.manifest.id] = true end
        for _, rec in ipairs(mods.discover() --[[@as table[] ]]) do
            local m = rec.manifest
            print(("%-8s %-24s %s %s  (%s: %s)"):format(m and (on[m.id] and "enabled" or "off") or "BROKEN", m and m.id or rec.folder,
                m and m.version or "", m and m.name or rec.error, rec.source, rec.folder))
        end
        for _, e in ipairs(errors) do print("note    " .. e) end
        return 0
    end
    local report = require("src.content.loader").setup()
    if has(args, "--check-mod") then
        for _, info in ipairs(mods.loaded()) do print(("loaded  %s %s (%s)"):format(info.id, info.version, info.scope)) end
        for _, e in ipairs(mods.errors()) do print("error   " .. e) end
        for _, e in ipairs(report.errors) do print("error   " .. e.text) end
        for _, w in ipairs(report.warnings) do print("warning " .. w.text) end
        local bad = #report.errors > 0 or #mods.errors() > 0 or #mods.loaded() == 0
        print(bad and "check-mod: FAILED" or ("check-mod: ok, content hash " .. content.hash()))
        return bad and 1 or 0
    end
    local failed = #report.errors > 0
    if has(args, "--content-report") then
        for _, e in ipairs(report.errors) do print("error   " .. e.text) end
        for _, w in ipairs(report.warnings) do print("warning " .. w.text) end
        local counts = {}
        for _, k in ipairs(content.kinds()) do
            if k:count() > 0 then counts[#counts + 1] = k.name .. "=" .. k:count() end
        end
        print(("content: %d errors, %d warnings, hash %s"):format(#report.errors, #report.warnings, content.hash()))
        print("records: " .. (#counts > 0 and table.concat(counts, " ") or "none"))
    end
    for i, a in ipairs(args) do
        if a == "--dump-content" then
            local dir, names = nil, {}
            for j = i + 1, #args do
                local v = args[j]
                if v:sub(1, 2) == "--" then break end
                if content.hasKind(v) then names[#names + 1] = v elseif not dir then dir = v end
            end
            if #names == 0 then
                for _, k in ipairs(content.kinds()) do names[#names + 1] = k.name end
            end
            if not dir then love.filesystem.createDirectory("dump") end
            for _, name in ipairs(names) do
                local text = content.dump(name)
                if dir then
                    fs.mkdirs(dir)
                    local f = assert(io.open(dir .. "/" .. name .. ".lua", "wb"))
                    f:write(text)
                    f:close()
                else
                    love.filesystem.write("dump/" .. name .. ".lua", text)
                end
            end
            log.info("content: dumped %d kinds to %s", #names, dir or (love.filesystem.getSaveDirectory() .. "/dump"))
        end
    end
    return failed and 1 or 0
end

return M
