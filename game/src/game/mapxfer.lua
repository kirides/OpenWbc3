-- Scenario transfer in the network lobby (the host sends a map a joined player lacks, or has in another version).
--
-- Verified in the 1.04 binary: the host's handler of the scenario file request (message 3024 / 0xbd0, FUN_004e7270)
-- reads the .SCN in 0x3ea (1002) byte pieces and sends each as a data message (3021 / 0xbcd) with the piece number,
-- the piece count (file size / 1002 + 1) and the byte count, pausing 20 ms between them (5 ms on IPX); the receiver
-- collects the pieces (FUN_004e8b90) and writes the file when all have arrived (FUN_004e8c40).
-- The original compares a CRC stored in the scenario header (FUN_004e0590 against the header reader FUN_0041bb50); openwbc3's
-- editor does not maintain that field, so openwbc3 compares its own checksum of the whole file (XOR of the
-- little-endian 32-bit words, the last word zero padded) together with the file size - openwbc3's own choice.
-- The pieces are larger than the original's (the UDP layer of udp.lua is reliable, ordered and does the pacing).
-- A received map is stored with the editor's maps (user directory "scenarios/"), where the map list finds it.
local ffi = require("ffi")
local bit = require("bit")

local M = { PIECE = 4096 }

-- Checksum of a scenario file (see above).
---@param data string
---@return integer
function M.checksum(data)
    local n = #data
    local words = math.floor(n / 4)
    local sum = 0
    if words > 0 then
        local p = ffi.cast("const uint32_t *", data)
        for i = 0, words - 1 do sum = bit.bxor(sum, p[i]) end
    end
    local rest = n - words * 4
    if rest > 0 then
        local w = 0
        for k = 1, rest do w = w + data:byte(words * 4 + k) * 2 ^ (8 * (k - 1)) end
        sum = bit.bxor(sum, w)
    end
    return sum % 4294967296
end

-- The data messages of a file: { t = "mapdata", i = piece number (0 based), n = piece count, data = bytes }.
---@param data string
---@param seq any the transfer it belongs to
---@return {t: "mapdata", seq: any, i: integer, n: integer, data: string}[]
function M.pieces(data, seq)
    local n = math.floor(#data / M.PIECE) + 1
    local out = {}
    for i = 0, n - 1 do
        out[#out + 1] = { t = "mapdata", seq = seq, i = i, n = n, data = data:sub(i * M.PIECE + 1, (i + 1) * M.PIECE) }
    end
    return out
end

-- Collects the pieces of one transfer; returns the file when the last one arrived.
---@return fun(m: table): string? collect
function M.collector()
    local got, count, total = {}, 0, nil
    return function(m)
        if type(m.i) ~= "number" or type(m.n) ~= "number" or type(m.data) ~= "string" then return nil end
        total = total or m.n
        if m.n ~= total or m.i < 0 or m.i >= total or got[m.i] then return nil end
        got[m.i] = m.data
        count = count + 1
        if count < total then return nil end
        return table.concat(got, "", 0, total - 1) or nil
    end
end

-- Writes a received scenario into the user directory; returns the file name or nil, message.
---@param label string?
---@param data string
---@return string? file
---@return string? err
function M.store(label, data)
    local lib = require("src.game.editorlib")
    local name = lib.safeName((label or ""):gsub("%.[sS][cC][nN]$", ""))
    if name == "" then name = "Received map" end
    love.filesystem.createDirectory(lib.USER_DIR)
    local file = name .. ".SCN"
    local ok, err = love.filesystem.write(lib.USER_DIR .. "/" .. file, data)
    if not ok then return nil, tostring(err) end
    return file
end

return M
