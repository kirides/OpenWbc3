-- Reliable ordered messages over UDP (IPv4 and IPv6), modelled on ENet's host / peer / event API.
-- LÖVE's bundled ENet (1.3.13) is IPv4 only, so this runs on LuaSocket. One host owns up to two
-- sockets (v4 and v6) bound to the same port; peers are identified by address.
--
--   host = udp.host{ port = 24850 }          -- listening (port omitted/0 = ephemeral, client only)
--   peer = host:connect("192.168.0.5", 24850) / host:connect("::1", 24850) / host:connect("name", port)
--   for _, e in ipairs(host:service()) do   -- e.type = "connect" | "receive" | "disconnect"
--   peer:send(table)                         -- reliable, ordered, any size (fragmented)
--   host:sendRaw(data, ip, port)             -- plain datagram on the same socket (hole punching, discovery)
--   host.onRaw = function(data, ip, port)    -- datagrams that are not part of this protocol
--
-- Security / roaming model (LAN-grade, not cryptographically hardened):
--   * Connecting is a stateless-cookie handshake, so spoofed sources can neither fill the server nor
--     use it as a reflector:  CONNECT(nonce, padded) -> CHALLENGE(cookie = H(secret, addr, nonce, time))
--     -> CONNECT(nonce, cookie) -> ACCEPT(nonce, session token).  Wrong or missing cookie = no peer.
--   * The 64-bit session token (from the OS random source) is carried in every later packet and IS the
--     peer's identity. Packets with an unknown token are dropped; DISCONNECT/DATA/ACK need the token, so
--     an off-path attacker cannot kick or inject. A sniffer on the same LAN still sees the token.
--   * The address is only a hint: a valid packet from a new ip:port (wifi -> mobile, v4 -> v6) moves the
--     session there. A connected peer survives SESSION_TIMEOUT seconds of silence. A client given several
--     addresses for the host (name with A + AAAA) tries the next one while the host is silent;
--     peer:setRemote() does the same explicitly.
--
-- Packet layout (all multi-byte values big endian):
--   MAGIC "WS" | kind(1) | token(8) | ...      token = client nonce until ACCEPT, session token after
--   CONNECT     (1): cookie(16) + zero padding, at least 64 bytes in total (amplification guard)
--   ACCEPT      (2): session token(8)          token field echoes the client nonce
--   DATA        (3): seq(2) ack(2) frag(1) of(1) payload
--   ACK         (4): ack(2) mask(4)      cumulative ack + bit i = seq ack+1+i received
--   PING        (5): -  (keep-alive, answered with ACK)
--   DISCONNECT  (6): -
--   CHALLENGE   (7): cookie(16)                token field echoes the client nonce
-- Peers retransmit unacknowledged DATA, and give up after TIMEOUT (connecting) / SESSION_TIMEOUT seconds.
local serialize = require("src.core.serialize")
local log = require("src.core.log")

local M = {}

local MAGIC = "WS"
local K_CONNECT, K_ACCEPT, K_DATA, K_ACK, K_PING, K_DISCONNECT, K_CHALLENGE = 1, 2, 3, 4, 5, 6, 7
local HDR, TOKEN, COOKIE, MIN_CONNECT = 11, 8, 16, 64
local COOKIE_SECONDS, MAX_PEERS = 15, 64
local MTU_PAYLOAD = 1100
local WINDOW = 96
M.TIMEOUT = 8             -- handshake gives up after this
M.SESSION_TIMEOUT = 20    -- a connected session survives this much silence (roaming, short outages)

local function socketLib()
    local ok, s = pcall(require, "socket")
    return ok and s or nil
end

function M.available() return socketLib() ~= nil end

local function now()
    return love and love.timer and love.timer.getTime() or os.clock()
end

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function rd16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end
local function rd32(s, o) return ((s:byte(o) * 256 + s:byte(o + 1)) * 256 + s:byte(o + 2)) * 256 + s:byte(o + 3) end

-- sequence numbers wrap at 65536; a is "after" b when it is within half the range ahead
local function after(a, b) return a ~= b and ((a - b) % 65536) < 32768 end

local function isV6(ip) return ip:find(":", 1, true) ~= nil end

-- Unguessable bytes: OS random source, else a time-seeded fallback (LAN-grade).
local okffi, ffi = pcall(require, "ffi")
local advapi
if okffi and ffi.os == "Windows" then
    pcall(ffi.cdef, "int SystemFunction036(void *buffer, unsigned long length);")
    local ok, lib = pcall(ffi.load, "advapi32")
    if ok then advapi = lib end
end
local fallbackRng
local function randomBytes(n)
    if advapi then
        local buf = ffi.new("uint8_t[?]", n)
        if advapi.SystemFunction036(buf, n) ~= 0 then return ffi.string(buf, n) end
    end
    local f = io.open("/dev/urandom", "rb")
    if f then
        local r = f:read(n)
        f:close()
        if r and #r == n then return r end
    end
    if not fallbackRng then
        fallbackRng = love.math.newRandomGenerator(os.time(), math.floor(love.timer.getTime() * 1e6) % 2 ^ 31)
    end
    local out = {}
    for i = 1, n do out[i] = string.char(fallbackRng:random(0, 255)) end
    return table.concat(out)
end

-- (the LÖVE 12 form: container type first; the bundled language-server annotations are LÖVE 11's)
---@diagnostic disable-next-line: param-type-mismatch, redundant-parameter
local function sha256(str) return love.data.hash("string", "sha256", str) --[[@as string]] end

local function hex(str) return (str:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Resolves a host name to its addresses (a literal is returned as is); the first is the preferred one.
local function resolveAll(name)
    if name:match("^%d+%.%d+%.%d+%.%d+$") or isV6(name) then return { name } end
    local list = socketLib().dns.getaddrinfo(name)
    if not list then return nil end
    local v4, v6, out = {}, {}, {}
    for _, a in ipairs(list) do
        if a.family == "inet" then v4[#v4 + 1] = a.addr elseif a.family == "inet6" then v6[#v6 + 1] = a.addr end
    end
    for _, a in ipairs(v4) do out[#out + 1] = a end
    for _, a in ipairs(v6) do out[#out + 1] = a end
    return #out > 0 and out or nil
end

-- For the lobby client (lobby.lua), which runs on a host of this module.
M.resolve, M.randomBytes = resolveAll, randomBytes

-- Peer ---------------------------------------------------------------------------------------------

-- One remote endpoint of a UdpHost (a connection in either direction).
---@class UdpPeer
---@field host UdpHost the host whose socket this peer uses
---@field ip string current remote address (moves when the session roams)
---@field port integer
---@field token string 8 bytes: the session token (the client nonce until ACCEPT)
---@field state "connecting"|"connected"|"disconnected"
---@field sendSeq integer next sequence number to send
---@field recvNext integer next sequence number to deliver
---@field unacked table<integer, UdpInFlight> seq -> DATA packet in flight
---@field queue UdpQueued[] fragments waiting for window space
---@field recv table<integer, UdpFragment> seq -> fragment received out of order
---@field partial string[]? fragments of the message being reassembled
---@field lastRecv number time of the last packet from the peer
---@field lastSend number time of the last packet to the peer
---@field rtt number smoothed round trip time in seconds
---@field connectedAt number?
---@field sentBytes integer
---@field dataSent integer DATA packets sent for the first time
---@field dataResent integer DATA packets sent again
---@field id string key in host.peers ("ip:port" for outgoing peers, the hex token for incoming ones)
---@field addrs {ip: string, port: integer}[] addresses known for the remote (client: the host's A + AAAA)
---@field addrIndex integer the entry of addrs in use
---@field lastSwitch number time of the last address switch
---@field outgoing boolean? true for peers made by Host:connect
---@field nonce string? the client nonce of the handshake
---@field cookie string? the host's challenge cookie (client side)
---@field cookies table<string, string>? client side with several candidates: the challenge cookie per "ip:port"
---@field side integer? the side the remote plays (set by lockstep.lua)
local Peer = {}
Peer.__index = Peer

---@class UdpInFlight
---@field body string DATA packet body
---@field sent number time it was last sent
---@field tries integer

---@class UdpQueued
---@field seq integer
---@field frag integer
---@field of integer
---@field payload string

---@class UdpFragment
---@field frag integer
---@field of integer
---@field payload string

-- What Host:service returns.
---@class UdpEvent
---@field type "connect"|"receive"|"disconnect"
---@field peer UdpPeer
---@field data any? the message (receive)
---@field reason string? "local" | "remote" | "timeout" (disconnect)

---@param host UdpHost
---@param ip string
---@param port integer
---@param token string
---@return UdpPeer
local function newPeer(host, ip, port, token)
    return setmetatable({
        host = host, ip = ip, port = port, token = token, state = "connecting",
        sendSeq = 0, recvNext = 0,          -- next sequence to send / to deliver
        unacked = {},                        -- seq -> { packet, sent, tries }
        queue = {},                          -- packets waiting for window space
        recv = {},                           -- seq -> { frag, of, payload } received out of order
        partial = nil,                       -- fragments of the message being reassembled
        lastRecv = now(), lastSend = 0, rtt = 0.1, connectedAt = nil,
        sentBytes = 0, dataSent = 0, dataResent = 0, id = ip .. ":" .. port, addrs = { { ip = ip, port = port } },
        addrIndex = 1, lastSwitch = 0,
    }, Peer)
end

---@param kind integer
---@param body string?
function Peer:raw(kind, body)
    local pkt = MAGIC .. string.char(kind) .. self.token .. (body or "")
    self.host:sendRaw(pkt, self.ip, self.port)
    self.lastSend = now()
end

-- Reliable ordered message (a Lua table). Returns false when the peer is gone.
---@param tbl any
---@return boolean
function Peer:send(tbl)
    if self.state == "disconnected" then return false end
    local s = serialize.encode(tbl)
    local count = math.max(1, math.ceil(#s / MTU_PAYLOAD))
    for i = 1, count do
        local chunk = s:sub((i - 1) * MTU_PAYLOAD + 1, i * MTU_PAYLOAD)
        local seq = self.sendSeq
        self.sendSeq = (self.sendSeq + 1) % 65536
        self.queue[#self.queue + 1] = { seq = seq, frag = i, of = count, payload = chunk }
    end
    self:pump()
    return true
end

-- Moves queued messages into flight while the window has room.
function Peer:pump()
    local inflight = 0
    for _ in pairs(self.unacked) do inflight = inflight + 1 end
    while #self.queue > 0 and inflight < WINDOW do
        local m = table.remove(self.queue, 1)
        local body = u16(m.seq) .. u16((self.recvNext - 1) % 65536) .. string.char(m.frag, m.of) .. m.payload
        self.unacked[m.seq] = { body = body, sent = now(), tries = 1 }
        self.dataSent = self.dataSent + 1
        self:raw(K_DATA, body)
        inflight = inflight + 1
    end
end

-- Round trip time in milliseconds (smoothed over the acknowledged packets) and reliability in percent (the share of
-- the DATA packets sent that did not have to be sent again), for the network statistics dialog.
---@return integer rttMs
---@return number reliability percent
function Peer:stats()
    local rel = 100
    if self.dataSent > 0 then rel = 100 * (1 - math.min(1, self.dataResent / (self.dataSent + self.dataResent))) end
    return math.floor(self.rtt * 1000 + 0.5), rel
end

function Peer:disconnect()
    if self.state == "disconnected" then return end
    for _ = 1, 3 do self:raw(K_DISCONNECT) end
    self:drop("local")
end

---@param reason string
function Peer:drop(reason)
    if self.state == "disconnected" then return end
    self.state = "disconnected"
    local h = self.host
    h.peers[self.id] = nil
    if h.byToken[self.token] == self then h.byToken[self.token] = nil end
    if self.nonce and h.byNonce[self.nonce] == self then h.byNonce[self.nonce] = nil end
    if self.nonce and h.connecting[self.nonce] == self then h.connecting[self.nonce] = nil end
    self.host.events[#self.host.events + 1] = { type = "disconnect", peer = self, reason = reason }
end

-- Sends ack info for what we received.
function Peer:sendAck()
    local ack = (self.recvNext - 1) % 65536
    local mask = 0
    for i = 0, 31 do
        local seq = (self.recvNext + i) % 65536
        if self.recv[seq] then mask = mask + 2 ^ i end
    end
    self:raw(K_ACK, u16(ack) .. u32(mask))
end

local function acked(self, seq)
    local u = self.unacked[seq]
    if u then
        if u.tries == 1 then self.rtt = self.rtt * 0.8 + (now() - u.sent) * 0.2 end
        self.unacked[seq] = nil
    end
end

---@param ack integer
---@param mask integer?
function Peer:handleAck(ack, mask)
    -- cumulative: everything up to and including `ack`
    for seq in pairs(self.unacked) do
        if not after(seq, ack) then acked(self, seq) end
    end
    if mask and mask ~= 0 then
        for i = 0, 31 do
            if math.floor(mask / 2 ^ i) % 2 == 1 then acked(self, (ack + 1 + i) % 65536) end
        end
    end
    self:pump()
end

---@param frag integer
---@param of integer
---@param payload string
function Peer:deliver(frag, of, payload)
    if of == 1 then
        local t = serialize.decode(payload)
        if t then self.host.events[#self.host.events + 1] = { type = "receive", peer = self, data = t } end
        return
    end
    self.partial = self.partial or {}
    -- delivery is ordered, so fragments come 1, 2 .. of: anything else is a broken (or hostile) message, which must
    -- not grow the buffer without bound - it is dropped
    if frag ~= #self.partial + 1 or frag > of then
        self.partial = nil
        return
    end
    self.partial[#self.partial + 1] = payload
    if frag == of then
        local t = serialize.decode(table.concat(self.partial))
        self.partial = nil
        if t then self.host.events[#self.host.events + 1] = { type = "receive", peer = self, data = t } end
    end
end

---@param body string
function Peer:handleData(body)
    if #body < 6 then return end
    local seq, ack = rd16(body, 1), rd16(body, 3)
    local frag, of = body:byte(5), body:byte(6)
    self:handleAck(ack, 0)
    local payload = body:sub(7)
    if seq == self.recvNext then
        self:deliver(frag, of, payload)
        self.recvNext = (self.recvNext + 1) % 65536
        -- deliver buffered successors
        while true do
            local r = self.recv[self.recvNext]
            if not r then break end
            self.recv[self.recvNext] = nil
            self:deliver(r.frag, r.of, r.payload)
            self.recvNext = (self.recvNext + 1) % 65536
        end
    elseif after(seq, self.recvNext) and ((seq - self.recvNext) % 65536) < 512 then
        self.recv[seq] = { frag = frag, of = of, payload = payload }
    end
    self:sendAck()
end

local function connectBody(cookie)
    local body = cookie or string.rep("\0", COOKIE)
    return body .. string.rep("\0", MIN_CONNECT - HDR - #body)
end

-- Client handshake packet: cookie (zeros until the host challenged us), padded to MIN_CONNECT. With several
-- candidate addresses (a host behind NAT: public, LAN, relay) it goes to all of them at once; the first that
-- answers becomes the peer's address.
function Peer:sendConnect()
    if #self.addrs > 1 then
        for _, a in ipairs(self.addrs) do
            local cookie = self.cookies and self.cookies[a.ip .. ":" .. a.port]
            self.host:sendRaw(MAGIC .. string.char(K_CONNECT) .. self.token .. connectBody(cookie), a.ip, a.port)
        end
        self.lastSend = now()
        return
    end
    self:raw(K_CONNECT, connectBody(self.cookie))
end

-- Client, while connecting: one more address to try (e.g. the lobby's relay once punching took too long).
---@param ip string
---@param port integer
function Peer:addCandidate(ip, port)
    for _, a in ipairs(self.addrs) do
        if a.ip == ip and a.port == port then return end
    end
    self.addrs[#self.addrs + 1] = { ip = ip, port = port }
    if self.state == "connecting" and self.host.connecting[self.nonce] == self then
        self.lastRecv = now()           -- a new way in: the handshake gets its full time again
        self:sendConnect()
    end
end

-- The session moved to another address: our packets go there from now on.
---@param ip string
---@param port integer
function Peer:moveTo(ip, port)
    if ip == self.ip and port == self.port then return end
    log.info("udp: peer %s moved %s:%s -> %s:%s", self.id, self.ip, tostring(self.port), ip, tostring(port))
    self.ip, self.port = ip, port
end

-- Client: reach the host at a different address (the session is kept; the host follows our token).
---@param address string
---@param port integer
---@return boolean
function Peer:setRemote(address, port)
    local list = resolveAll(address)
    if not list then return false end
    self.addrs, self.addrIndex = {}, 1
    for i, ip in ipairs(list) do self.addrs[i] = { ip = ip, port = port } end
    self:moveTo(list[1], port)
    self:raw(K_PING)
    return true
end

---@param t number
function Peer:update(t)
    if self.state == "disconnected" then return end
    local limit = self.state == "connecting" and M.TIMEOUT or M.SESSION_TIMEOUT
    if t - self.lastRecv > limit then
        self:drop("timeout")
        return
    end
    if self.state == "connecting" then
        if t - self.lastSend > 0.4 then self:sendConnect() end
        return
    end
    -- host silent and we know other addresses for it (e.g. we roamed from v4 to v6): try the next one
    if self.outgoing and #self.addrs > 1 and t - self.lastRecv > 2 and t - self.lastSwitch > 1.5 then
        self.lastSwitch = t
        self.addrIndex = self.addrIndex % #self.addrs + 1
        local a = self.addrs[self.addrIndex]
        self:moveTo(a.ip, a.port)
        self:raw(K_PING)
    end
    local rto = math.max(0.12, self.rtt * 2)
    for seq, u in pairs(self.unacked) do
        if t - u.sent > rto * math.min(4, u.tries) then
            u.sent, u.tries = t, u.tries + 1
            self.dataResent = self.dataResent + 1
            self:raw(K_DATA, u.body)
        end
    end
    if t - self.lastSend > 1 then self:raw(K_PING) end
end

-- Host -----------------------------------------------------------------------------------------------

-- A UDP endpoint: one or two sockets (v4, v6) on the same port and the peers reached through them.
---@class UdpHost
---@field peers table<string, UdpPeer> peer.id -> peer
---@field byToken table<string, UdpPeer> session token -> peer
---@field byNonce table<string, UdpPeer> client nonce -> peer (host side: retransmitted CONNECTs)
---@field connecting table<string, UdpPeer> client nonce -> outgoing peer still in the handshake (client side)
---@field events UdpEvent[] events since the last service()
---@field socks {v4: any?, v6: any?} LuaSocket UDP objects
---@field onRaw fun(data: string, ip: string, port: integer)? datagrams that are not part of this protocol
---@field onTick fun(t: number)? set by lobby.lua (the lobby server client)
---@field relay (fun(ip: string, data: string): any)? set by lobby.lua: sends through the lobby server
---@field secret string 32 random bytes for the cookies
---@field port integer the bound port
---@field accepting boolean accepts incoming connections
local Host = {}
Host.__index = Host

---@class UdpHostOptions
---@field port integer? listen port; nil / 0 = any
---@field ipv4 boolean? default true
---@field ipv6 boolean? default true
---@field accept boolean? default: a port was given

-- opts: port (listen port; nil/0 = any), ipv4 (default true), ipv6 (default true), accept (default = port given)
---@param opts UdpHostOptions?
---@return UdpHost?
---@return string? err
function M.host(opts)
    opts = opts or {}
    local s = socketLib()
    if not s then return nil, "LuaSocket is not available" end
    local h = setmetatable({ peers = {}, byToken = {}, byNonce = {}, connecting = {}, events = {}, socks = {}, onRaw = nil,
                             secret = randomBytes(32), port = opts.port or 0,
                             accepting = opts.accept ~= false and (opts.port or 0) ~= 0 }, Host)
    local want4, want6 = opts.ipv4 ~= false, opts.ipv6 ~= false
    local port = opts.port or 0
    if want4 then
        local u = s.udp()
        local ok, err = u:setsockname("0.0.0.0", port)
        if ok then
            u:settimeout(0)
            if port == 0 then port = select(2, u:getsockname()) end
            h.socks.v4 = u
        else
            u:close()
            if not want6 then return nil, err end
        end
    end
    if want6 and s.udp6 then
        local u = s.udp6()
        pcall(u.setoption, u, "ipv6-v6only", true)
        local ok = u:setsockname("::", port)
        if ok then
            u:settimeout(0)
            if port == 0 then port = select(2, u:getsockname()) end
            h.socks.v6 = u
        else
            u:close()
        end
    end
    if not h.socks.v4 and not h.socks.v6 then return nil, "cannot open a UDP socket" end
    h.port = port
    return h
end

---@param data string
---@param ip string
---@param port integer
---@return boolean
function Host:sendRaw(data, ip, port)
    -- a peer reached through the lobby server's relay (lobby.lua): the datagram goes there, wrapped
    if ip:sub(1, 6) == "relay:" then return self.relay ~= nil and self.relay(ip, data) and true or false end
    local sock = isV6(ip) and self.socks.v6 or self.socks.v4
    if not sock then return false end
    local ok = sock:sendto(data, ip, port)
    return ok ~= nil
end

---@param data string
---@param port integer
function Host:broadcast(data, port)
    if self.socks.v4 then
        pcall(self.socks.v4.setoption, self.socks.v4, "broadcast", true)
        self.socks.v4:sendto(data, "255.255.255.255", port)
    end
    if self.socks.v6 then self.socks.v6:sendto(data, "ff02::1", port) end
end

---@param address string ip literal or host name
---@param port integer
---@return UdpPeer?
---@return string? err
function Host:connect(address, port)
    local list = resolveAll(address)
    if not list then return nil, "cannot resolve " .. tostring(address) end
    local candidates = {}
    for i, ip in ipairs(list) do candidates[i] = { ip = ip, port = port } end
    return self:connectTo(candidates)
end

-- Connects to whichever of several addresses of the same host answers first (a host behind NAT: its public
-- addresses, its LAN addresses, a relay - see lobby.lua). The handshake goes to all of them at once.
---@param candidates {ip: string, port: integer}[] at least one
---@return UdpPeer
function Host:connectTo(candidates)
    local first = candidates[1]
    for _, p in pairs(self.peers) do
        if p.outgoing and p.ip == first.ip and p.port == first.port then return p end
    end
    local p = newPeer(self, first.ip, first.port, randomBytes(TOKEN))   -- token = our nonce until ACCEPT
    p.outgoing, p.nonce = true, p.token
    p.addrs = {}
    for _, a in ipairs(candidates) do p:addCandidate(a.ip, a.port) end
    self.peers[p.id] = p
    self.connecting[p.nonce] = p
    p:sendConnect()
    return p
end

function Host:cookie(ip, port, nonce, bucket)
    return sha256(self.secret .. bucket .. "|" .. ip .. "|" .. port .. "|" .. nonce):sub(1, COOKIE)
end

function Host:handleConnect(data, nonce, body, ip, port, t)
    if not self.accepting or #data < MIN_CONNECT then return end
    local bucket = math.floor(t / COOKIE_SECONDS)
    local cookie = body:sub(1, COOKIE)
    if cookie ~= self:cookie(ip, port, nonce, bucket) and cookie ~= self:cookie(ip, port, nonce, bucket - 1) then
        -- stateless: nothing is stored until the sender proves it receives at this address
        self:sendRaw(MAGIC .. string.char(K_CHALLENGE) .. nonce .. self:cookie(ip, port, nonce, bucket), ip, port)
        return
    end
    local p = self.byNonce[nonce]       -- a retransmitted CONNECT (our ACCEPT got lost)
    if not p then
        local count = 0
        for _ in pairs(self.peers) do count = count + 1 end
        if count >= MAX_PEERS then return end
        p = newPeer(self, ip, port, randomBytes(TOKEN))
        p.state, p.connectedAt, p.nonce, p.id = "connected", t, nonce, hex(p.token)
        self.peers[p.id] = p
        self.byToken[p.token] = p
        self.byNonce[nonce] = p
        self.events[#self.events + 1] = { type = "connect", peer = p }
    end
    p.lastRecv = t
    self:sendRaw(MAGIC .. string.char(K_ACCEPT) .. nonce .. p.token, ip, port)
end

function Host:handle(data, ip, port)
    if #data < HDR or data:sub(1, 2) ~= MAGIC then
        if self.onRaw then self.onRaw(data, ip, port) end
        return
    end
    local kind, token, body = data:byte(3), data:sub(4, 11), data:sub(12)
    local t = now()
    if kind == K_CONNECT then return self:handleConnect(data, token, body, ip, port, t) end
    if kind == K_CHALLENGE or kind == K_ACCEPT then
        -- matched by the nonce, not the address: with several candidates any of them may answer
        local p = self.connecting[token]
        if not (p and p.state == "connecting" and p.nonce == token) then return end
        local known = false
        for _, a in ipairs(p.addrs) do known = known or (a.ip == ip and a.port == port) end
        if not known then return end
        if kind == K_CHALLENGE then
            if #body >= COOKIE then
                p.cookie = body:sub(1, COOKIE)
                p.cookies = p.cookies or {}
                p.cookies[ip .. ":" .. port] = p.cookie
                if #p.addrs > 1 then
                    self:sendRaw(MAGIC .. string.char(K_CONNECT) .. p.token .. connectBody(p.cookie), ip, port)
                    p.lastSend = t
                else
                    p:sendConnect()
                end
            end
        elseif #body >= TOKEN then
            self.connecting[p.nonce] = nil
            p:moveTo(ip, port)                -- the candidate that answered
            p.token, p.state, p.connectedAt, p.lastRecv = body:sub(1, TOKEN), "connected", t, t
            self.byToken[p.token] = p
            self.events[#self.events + 1] = { type = "connect", peer = p }
        end
        return
    end
    local p = self.byToken[token]
    if not p then return end            -- unknown session: drop silently
    p.lastRecv = t
    p:moveTo(ip, port)                  -- roaming: the token, not the address, identifies the session
    if kind == K_DATA then p:handleData(body)
    elseif kind == K_ACK then
        if #body >= 6 then p:handleAck(rd16(body, 1), rd32(body, 3)) end
    elseif kind == K_PING then p:sendAck()
    elseif kind == K_DISCONNECT then p:drop("remote") end
end

-- Pumps the sockets; returns the events since the last call.
---@return UdpEvent[]
function Host:service()
    for _, sock in pairs(self.socks) do
        for _ = 1, 400 do
            local data, ip, port = sock:receivefrom()
            if not data then break end
            self:handle(data, ip, port)
        end
    end
    local t = now()
    for _, p in pairs(self.peers) do p:update(t) end
    if self.onTick then self.onTick(t) end
    local out = self.events
    self.events = {}
    return out
end

function Host:close()
    for _, p in pairs(self.peers) do p:raw(K_DISCONNECT) end
    for _, sock in pairs(self.socks) do pcall(sock.close, sock) end
    self.socks = {}
    self.peers, self.byToken, self.byNonce, self.connecting = {}, {}, {}, {}
end

-- The addresses this machine can be reached at (best effort): { v4 = ip, v6 = ip }.
---@return {v4: string?, v6: string?}
function M.localAddresses()
    local s = socketLib()
    local out = {}
    if not s then return out end
    local u = s.udp()
    if u:setpeername("8.8.8.8", 80) then out.v4 = u:getsockname() end
    u:close()
    if s.udp6 then
        local u6 = s.udp6()
        if u6:setpeername("2001:4860:4860::8888", 80) then
            local ip = u6:getsockname()
            if ip and ip ~= "::" then out.v6 = ip end
        end
        u6:close()
    end
    return out
end

return M
