-- Compiles every Lua file of the game without running it and reports syntax errors.
--   love game --selftest --lua tools/dev/syntax.lua
-- (or `pwsh tools/dev/love.ps1 -- --selftest --lua tools/dev/syntax.lua`)
local count, bad = 0, 0

---@param dir string folder in the game folder ("" = the game folder)
local function walk(dir)
    for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
        local path = dir == "" and name or dir .. "/" .. name
        local info = love.filesystem.getInfo(path)
        if info and info.type == "directory" and name ~= "converted" then
            walk(path)
        elseif name:match("%.lua$") then
            count = count + 1
            local ok, chunk, err = pcall(love.filesystem.load, path)
            if not ok or not chunk then
                bad = bad + 1
                print("[error] " .. tostring(ok and err or chunk))
            end
        end
    end
end

walk("")
print(("[info] syntax: %d files, %d errors"):format(count, bad))
if bad > 0 then os.exit(1) end
