-- Little-endian binary reader over a Lua string, backed by LuaJIT FFI.
local ffi = require("ffi")
local bit = require("bit")

---@class BinReader
---@field data string   the wrapped string (kept alive for `ptr`)
---@field ptr ffi.cdata* const uint8_t* to the string's bytes
---@field pos integer    0-based read position
---@field size integer
local Reader = {}
Reader.__index = Reader

local u8p = ffi.typeof("const uint8_t*")

-- Wrap a string. `pos` is 0-based.
---@param data string
---@param pos integer?
---@return BinReader
function Reader.new(data, pos)
    return setmetatable({
        data = data,               -- keep the string alive
        ptr = ffi.cast(u8p, data),
        pos = pos or 0,
        size = #data,
    }, Reader)
end

---@param pos integer
function Reader:seek(pos) self.pos = pos end
---@param n integer
function Reader:skip(n) self.pos = self.pos + n end
---@return integer
function Reader:tell() return self.pos end
---@return integer
function Reader:remaining() return self.size - self.pos end
---@return boolean
function Reader:eof() return self.pos >= self.size end

-- Raises an error (reported at the reader's caller) when fewer than n bytes are left.
---@param n integer
function Reader:check(n)
    if self.pos + n > self.size then
        error(("read past end (pos %d + %d > %d)"):format(self.pos, n, self.size), 3)
    end
end

---@return integer
function Reader:u8()
    self:check(1)
    local v = self.ptr[self.pos]
    self.pos = self.pos + 1
    return v
end

---@return integer
function Reader:i8()
    local v = self:u8()
    return v >= 0x80 and v - 0x100 or v
end

---@return integer
function Reader:u16()
    self:check(2)
    local p, o = self.ptr, self.pos
    self.pos = o + 2
    return p[o] + p[o + 1] * 256
end

---@return integer
function Reader:i16()
    local v = self:u16()
    return v >= 0x8000 and v - 0x10000 or v
end

---@return integer
function Reader:u32()
    self:check(4)
    local p, o = self.ptr, self.pos
    self.pos = o + 4
    return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216
end

---@return integer
function Reader:i32()
    local v = self:u32()
    return v >= 0x80000000 and v - 0x100000000 or v
end

---@return number
function Reader:f32()
    self:check(4)
    local f = ffi.new("float[1]")
    ffi.copy(f, self.ptr + self.pos, 4)
    self.pos = self.pos + 4
    return tonumber(f[0]) --[[@as number]]
end

---@param n integer
---@return string
function Reader:bytes(n)
    self:check(n)
    local s = self.data:sub(self.pos + 1, self.pos + n)
    self.pos = self.pos + n
    return s
end

-- Fixed-size, zero-padded string field.
---@param n integer
---@return string
function Reader:fixstr(n)
    local s = self:bytes(n)
    local z = s:find("\0", 1, true)
    if z then s = s:sub(1, z - 1) end
    return s
end

-- Zero-terminated string.
---@return string
function Reader:cstr()
    local z = self.data:find("\0", self.pos + 1, true)
    if not z then
        local s = self.data:sub(self.pos + 1)
        self.pos = self.size
        return s
    end
    local s = self.data:sub(self.pos + 1, z - 1)
    self.pos = z
    return s
end

-- Free-standing helpers on raw strings (0-based offsets).
local M = { Reader = Reader }

---@param s string
---@param o integer 0-based offset
---@return integer
function M.u16(s, o) local a, b = s:byte(o + 1, o + 2) return a + b * 256 end
---@param s string
---@param o integer 0-based offset
---@return integer
function M.u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
---@param s string
---@param o integer 0-based offset
---@return integer
function M.i32(s, o)
    local v = M.u32(s, o)
    return v >= 0x80000000 and v - 0x100000000 or v
end

---@param s string
---@param pos integer? 0-based
---@return BinReader
function M.reader(s, pos) return Reader.new(s, pos) end

return M
