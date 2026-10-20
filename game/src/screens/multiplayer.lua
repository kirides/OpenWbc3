-- Network games over UDP (IPv4 and IPv6): host a game, or join one on the LAN, by address or through the internet
-- lobby (docs/lobby.md: a lobby server lists published games and introduces players to hosts; when hole punching
-- fails it relays). enter(hero) - the hero record that plays. The host's lobby is screens/mphost.lua.
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local kit = require("src.ui.kit")
local fonts = require("src.ui.fonts")
local net = require("src.game.net")
local lobby = require("src.game.lobby")
local profile = require("src.game.profile")
local classes = require("src.game.classes")
local config = require("src.core.config")
local music = require("src.audio.music")
local log = require("src.core.log")
local bit = require("bit")

local ROWS = 7                  -- games shown per page
local RELAY_AFTER = 4           -- seconds of a lobby join without an answer before the relay is asked for
local LAN_TIMEOUT, LOBBY_TIMEOUT = 6, 14

---@class MultiplayerScreen: Screen
---@field hero table?              the profile record that plays
---@field mode "menu"|"hostopts"|"join"|"password"|"connecting"|"hold"|"wait"
---@field tab "lan"|"internet"     the join view's list
---@field address string           the address typed in
---@field lobbyServer string       the lobby server ([net] lobby= in openwbc3.ini)
---@field joinCode string          the id of an unlisted internet game
---@field password string          the password typed in (joining) or set (hosting)
---@field publish boolean          hosting: publish the game on the lobby server
---@field unlisted boolean         hosting: published but not listed (players need the join code)
---@field focus string?            the text field that has the keyboard: "address" | "lobby" | "code" | "password"
---@field notice string?
---@field available boolean        LuaSocket is there
---@field devAuto boolean?         --show multiplayer:join / :online
---@field devOnline boolean?       --show multiplayer:online: join the first listed internet game
---@field client JoinConnection?   the connection being made
---@field listener table?          the LAN game finder (net.listener)
---@field hosts table[]?           the games found on the LAN
---@field browse {host: UdpHost, lobby: LobbyClient}? the internet list's socket and lobby client
---@field page integer             the internet list's page (0 based)
---@field pendingGame LobbyGame?   the game waiting for its password
---@field box MsgBox?
local S = {}
S.helpId = 11          -- screen help (src/screens/screenhelp.lua)

function S:enter(hero)
    self.hero = hero or profile.current()
    self.mode = "menu"
    self.tab = "lan"
    self.address = config.get("net", "address", "")
    self.lobbyServer = os.getenv("OPENWBC3_LOBBY") or config.get("net", "lobby", "")   -- the variable: dev and tests
    self.joinCode, self.password = "", ""
    self.publish = config.get("net", "publish", false) == true
    self.unlisted = false
    self.focus = nil
    self.notice = nil
    self.page = 0
    self.available = net.available()
end

-- developer aid: --show multiplayer:join connects to localhost
function S:dev(sub)
    if sub == "join" then self.devAuto = true self:join("::1", net.PORT) end
    if sub == "internet" then self:openJoin() self:showTab("internet") end
    if sub == "online" then                         -- joins the first game the lobby lists (the internet path end to end)
        self.devAuto, self.devOnline = true, true
        self:openJoin()
        self:showTab("internet")
    end
    if sub == "hostopts" then self.mode = "hostopts" end
end

function S:resume()
    music.play("intro")
    -- coming back from a game: the connection is over
    if self.client then
        if self.client.lobby then self.client.lobby:close() end
        self.client.host:close()
        self.client = nil
        self.mode = "menu"
    end
end

function S:closeListener()
    if self.listener then self.listener.close() self.listener = nil end
end

function S:closeBrowse()
    if self.browse then
        self.browse.lobby:close()
        self.browse.host:close()
        self.browse = nil
    end
end

function S:leave()
    self:closeListener()
    self:closeBrowse()
    if self.client then
        if self.client.lobby then self.client.lobby:close() end
        self.client.host:close()
        self.client = nil
    end
end

-- Hosting ---------------------------------------------------------------------------------------------------------

function S:host()
    config.set("net", "publish", self.publish)
    if self.publish then
        config.set("net", "lobby", self.lobbyServer)
    end
    config.save()
    local opts = { publish = self.publish, unlisted = self.unlisted, password = self.password,
                   lobby = self.lobbyServer }
    local ok, why = pcall(function()
        screens.push(require("src.screens.mphost"), self.hero, opts)
    end)
    if not ok then self.notice = tostring(why) end
end

-- Joining ---------------------------------------------------------------------------------------------------------

function S:openJoin()
    self.mode = "join"
    self.listener = net.listener()
    self.hosts = {}
    if self.tab == "internet" then self:showTab("internet") end
end

-- Switches the join view's list; the internet list opens a socket and a lobby client for browsing.
---@param tab "lan"|"internet"
function S:showTab(tab)
    self.tab = tab
    self.notice = nil
    if tab ~= "internet" then
        self:closeBrowse()
        return
    end
    if self.browse then return end
    if self.lobbyServer == "" then
        self.notice = "No lobby server set"
        return
    end
    local host, err = net.client()
    if not host then self.notice = tostring(err) return end
    local client, lerr = lobby.client(host, self.lobbyServer)
    if not client then host:close() self.notice = lerr return end
    self.browse = { host = host, lobby = client }
    self.page = 0
    client:list(self.page, net.VERSION)
end

local function parseAddress(s)
    s = s:match("^%s*(.-)%s*$")
    local ip, port = s:match("^%[(.+)%]:(%d+)$")          -- [v6]:port
    if ip then return ip, tonumber(port) end
    ip = s:match("^%[(.+)%]$")
    if ip then return ip, net.PORT end
    local a, p = s:match("^([^:]+):(%d+)$")                -- v4 or name:port
    if a then return a, tonumber(p) end
    return s, net.PORT                                     -- bare name, v4 or v6 address
end

---@param address string
---@param port integer
function S:join(address, port)
    if not self.hero then self.notice = "Select a hero first" return end
    local host, err = net.client()
    if not host then self.notice = tostring(err) return end
    local peer, perr = host:connect(address, port)
    if not peer then host:close() self.notice = tostring(perr) return end
    self.client = { host = host, peer = peer, since = love.timer.getTime(), players = {}, info = {},
                    password = self.password }
    self.mode = "connecting"
    self.notice = nil
    config.set("net", "address", address .. (port ~= net.PORT and (":" .. port) or ""))
    config.save()
end

-- Joins internet game `id` through the lobby: the lobby introduces us to the host (both sides punch), the handshake
-- goes to every address of the host at once, and after a few seconds without an answer the relay is added.
---@param id integer
---@param relayOk boolean? the host accepts a relay (from the list; true when unknown)
function S:joinLobby(id, relayOk)
    if not self.hero then self.notice = "Select a hero first" return end
    if not self.browse then self:showTab("internet") end
    local b = self.browse
    if not b then return end
    self.browse = nil                                   -- the browsing socket becomes the game's socket
    b.lobby:list(nil)
    local c = { host = b.host, lobby = b.lobby, since = love.timer.getTime(), players = {}, info = {},
                password = self.password, gameId = id, relayOk = relayOk ~= false }
    ---@cast c JoinConnection   -- the peer is set when the host answers (connectTo / the connect event)
    self.client = c
    self.mode = "connecting"
    self.notice = nil
    b.lobby:join(id, function(j)
        if self.client ~= c then return end
        if j.status ~= lobby.STATUS_OK then
            self.notice = j.status == lobby.STATUS_NO_GAME and "The game is gone" or "The game cannot be joined now"
            self:leaveGame()
            return
        end
        c.relayOk = c.relayOk and bit.band(j.flags, lobby.FLAG_RELAY) ~= 0
        if not c.peer and #j.candidates > 0 then c.peer = c.host:connectTo(j.candidates) end
    end)
end

-- After a few seconds of a lobby join without an answer: ask the lobby for a relay and add it as a candidate.
---@param c JoinConnection
function S:tryRelay(c)
    if c.relayAsked or not c.lobby or not c.relayOk then return end
    c.relayAsked = true
    log.info("multiplayer: no direct connection yet, asking the lobby for a relay")
    c.lobby:requestRelay(c.gameId, function(address)
        if self.client ~= c or not address then return end
        if c.peer then c.peer:addCandidate(address, 0) else c.peer = c.host:connectTo({ { ip = address, port = 0 } }) end
    end)
end

function S:leaveGame()
    if self.client then
        if self.client.peer then self.client.peer:disconnect() end
        self.client.host:service()
        if self.client.lobby then self.client.lobby:close() end
        self.client.host:close()
        self.client = nil
    end
    self:openJoin()            -- back to the list the join came from
end

function S:update(dt)
    music.update()
    if self.listener then self.hosts = self.listener:poll() end
    if self.browse then
        self.browse.host:service()
        local first = self.devOnline and self.browse and self.browse.lobby.games[1]
        if first then
            self.devOnline = false
            self:joinLobby(first.id, first.relay)
        end
    end
    local c = self.client
    if not c then return end
    local events = c.host:service()
    for k, e in ipairs(events) do
        if e.type == "connect" then
            c.peer = e.peer
            if c.lobby then c.lobby:stopJoining() end
            c.peer:send({ t = "join", version = net.VERSION, name = self.hero.name, race = self.hero.race,
                          hero = self.hero.hero, password = c.password ~= "" and c.password or nil,
                          content = require("src.content.mods").describe(require("src.content")) })
        elseif e.type == "receive" then
            local m = e.data
            if m.t == "joined" then
                -- the host's setup screen (read-only); what arrived with the answer goes along
                c.slot = m.slot
                self.box = nil
                c.inbox = { unpack(events, k + 1) }
                self.mode = "wait"
                screens.push(require("src.screens.mpjoin"), { hero = self.hero, client = c, parent = self,
                                                              devAuto = self.devAuto })
                return
            elseif m.t == "hold" then
                -- the host is busy with a map change or another player (PLEASE_HOLD): wait for its answer
                self.mode = "hold"
                self.box = require("src.ui.msgbox").new{ title = UI.text(284, 6) or "The host is busy",
                                                        line2 = UI.text(284, 0) or "Changing maps" }
            elseif m.t == "full" or m.t == "refused" then
                self.notice = m.t == "full" and "The game is full" or tostring(m.reason or "Refused")
                self:leaveGame()
                return
            end
        elseif e.type == "disconnect" and e.peer == c.peer and (not c.lobby or e.peer.state ~= "connecting") then
            self.notice = e.reason == "timeout" and "No answer from the host" or "Disconnected from the host"
            self:leaveGame()
            return
        end
    end
    local waited = love.timer.getTime() - c.since
    if self.mode == "connecting" and c.lobby and waited > RELAY_AFTER then self:tryRelay(c) end
    if self.mode == "connecting" and waited > (c.lobby and LOBBY_TIMEOUT or LAN_TIMEOUT) then
        self.notice = "Could not reach the host"
        self:leaveGame()
    end
end

-- Drawing ----------------------------------------------------------------------------------------------------

---@param g LobbyGame
local function gameLine(g)
    local marks = (g.password and "  [password]" or "") .. (g.started and "  [in battle]" or "")
    return ("%s   -   %s   (%d/%d)%s"):format(g.name, g.map, g.players, g.maxPlayers, marks)
end

function S:drawInternet()
    local b = self.browse
    fonts.print(2, "Lobby server (name or address, optional :port)", 130, 106)
    kit.input(self, "lobby", self.lobbyServer, 130, 124, 400, 28, self.focus == "lobby", self.sel)
    kit.button(self, "lobbyset", "Use", 550, 124, 120, 28, { disabled = self.lobbyServer == "" })
    if b then
        local games = b.lobby.games
        for i, g in ipairs(games) do
            if i > ROWS then break end
            kit.button(self, "lobbygame", gameLine(g), 120, 160 + (i - 1) * 26, 560, 24, { disabled = g.started })
            if not g.started then self.hits[#self.hits].extra = g end
        end
        if #games == 0 then fonts.print(2, "No published games", 100, 240, "center", 600) end
        if b.lobby.pageCount > 1 then
            kit.button(self, "pageprev", "<", 120, 346, 30, 22, { disabled = self.page == 0 })
            fonts.print(2, ("%d / %d"):format(self.page + 1, b.lobby.pageCount), 150, 348, "center", 60)
            kit.button(self, "pagenext", ">", 210, 346, 30, 22, { disabled = self.page + 1 >= b.lobby.pageCount })
        end
    end
    fonts.print(2, "Join code", 380, 352)
    kit.input(self, "code", self.joinCode, 380, 370, 150, 30, self.focus == "code", self.sel)
    kit.button(self, "joincode", "Join", 550, 370, 120, 30, { disabled = not tonumber(self.joinCode, 16) or not b })
    fonts.print(2, "Password", 130, 352)
    kit.input(self, "password", self.password, 130, 370, 150, 30, self.focus == "password", self.sel)
end

function S:draw()
    UI.begin()
    kit.begin(self)
    kit.backdrop(0.78)
    kit.title("Multiplayer", 14, 1)
    if not self.available then
        fonts.print(5, "Networking is not available (LuaSocket is missing).", 0, 280, "center", 800)
    elseif self.mode == "menu" then
        kit.panel(220, 110, 360, 330)
        fonts.print(5, ("Playing as %s (%s %s)"):format(self.hero and self.hero.name or "?",
            self.hero and classes.RACE_NAMES[self.hero.race] or "", self.hero and self.hero.class or ""), 220, 124, "center", 360)
        kit.button(self, "hostopts", "Host a Game", 260, 170, 280, 44)
        kit.button(self, "joinmenu", "Join a Game", 260, 230, 280, 44)
        local a = net.localAddresses()
        fonts.print(2, "Your addresses:", 220, 320, "center", 360)
        fonts.print(2, ("IPv4  %s"):format(a.v4 or "-"), 220, 340, "center", 360)
        fonts.print(2, ("IPv6  %s"):format(a.v6 or "-"), 220, 358, "center", 360)
        fonts.print(2, ("UDP port %d"):format(net.PORT), 220, 380, "center", 360)
    elseif self.mode == "hostopts" then
        kit.panel(160, 110, 480, 330)
        fonts.print(5, "Host a Game", 160, 124, "center", 480)
        kit.checkbox(self, "publish", "Publish on the internet", self.publish, 200, 170)
        if self.publish then
            kit.checkbox(self, "unlisted", "Unlisted (players need the join code)", self.unlisted, 200, 200)
            fonts.print(2, "Lobby server", 200, 236)
            kit.input(self, "lobby", self.lobbyServer, 200, 254, 400, 28, self.focus == "lobby", self.sel)
        end
        fonts.print(2, "Password (optional)", 200, 296)
        kit.input(self, "password", self.password, 200, 314, 400, 28, self.focus == "password", self.sel)
        kit.button(self, "host", "Host", 260, 380, 280, 40, { disabled = self.publish and self.lobbyServer == "" })
    elseif self.mode == "join" then
        kit.panel(100, 70, 600, 340)
        kit.button(self, "tablan", "Your network", 120, 76, 270, 24, { selected = self.tab == "lan" })
        kit.button(self, "tabinternet", "Internet", 410, 76, 270, 24, { selected = self.tab == "internet" })
        if self.tab == "internet" then
            self:drawInternet()
        else
            for i, h in ipairs(self.hosts or {}) do
                if i > ROWS then break end
                kit.button(self, "listed", ("%s   -   %s   (%d/%d)"):format(h.name or "?", h.map or "?", h.players or 1,
                    h.max or 6), 120, 108 + (i - 1) * 34, 560, 30)
                self.hits[#self.hits].extra = h
            end
            if #(self.hosts or {}) == 0 then fonts.print(2, "Searching ...", 100, 200, "center", 600) end
            fonts.print(2, "Address (IPv4, IPv6 or name, optional :port)", 130, 352)
            kit.input(self, "address", self.address, 130, 370, 400, 30, self.focus == "address", self.sel)
            kit.button(self, "connect", "Join", 550, 370, 120, 30, { disabled = self.address == "" })
        end
    elseif self.mode == "password" then
        kit.panel(200, 220, 400, 160)
        fonts.print(5, "This game needs a password", 200, 234, "center", 400)
        kit.input(self, "password", self.password, 240, 270, 320, 30, true, self.sel)
        kit.button(self, "passwordok", "Join", 300, 320, 200, 34)
    elseif self.mode == "connecting" then
        fonts.print(5, "Connecting ...", 0, 280, "center", 800)
        local c = self.client
        if c and c.relayAsked then fonts.print(2, "(through the lobby's relay)", 0, 310, "center", 800) end
    elseif self.mode == "hold" and self.box then
        self.box:draw()
    end
    if self.notice then fonts.print(5, self.notice, 0, 500, "center", 800) end
    if self.mode == "menu" or self.mode == "join" or self.mode == "hostopts" or self.mode == "password" then
        kit.button(self, "back", "Back", 50, 548, 150, 36)
    end
    UI.finish()
end

function S:act(id, extra)
    self.notice = id == "back" and self.notice or nil
    if id == "back" then
        if self.mode == "menu" then screens.pop()
        elseif self.mode == "join" then self:closeListener() self:closeBrowse() self.mode = "menu"
        elseif self.mode == "hostopts" then self.mode = "menu"
        elseif self.mode == "password" then self.mode = "join" self.pendingGame = nil
        elseif self.mode == "hold" then self.box = nil self:leaveGame()
        end
    elseif id == "hostopts" then self.mode = "hostopts"
    elseif id == "host" then self:host()
    elseif id == "publish" then self.publish = not self.publish
    elseif id == "unlisted" then self.unlisted = not self.unlisted
    elseif id == "joinmenu" then self:openJoin()
    elseif id == "tablan" then self:showTab("lan")
    elseif id == "tabinternet" then self:showTab("internet")
    elseif id == "lobbyset" then
        config.set("net", "lobby", self.lobbyServer)
        config.save()
        self:closeBrowse()
        self:showTab("internet")
    elseif id == "pageprev" or id == "pagenext" then
        self.page = math.max(0, self.page + (id == "pagenext" and 1 or -1))
        if self.browse then self.browse.lobby:list(self.page, net.VERSION) end
    elseif id == "lobbygame" then
        ---@cast extra LobbyGame
        if extra.password and self.password == "" then
            self.pendingGame, self.mode, self.focus = extra, "password", "password"
        else
            self:closeListener()
            self:joinLobby(extra.id, extra.relay)
        end
    elseif id == "passwordok" then
        local g = self.pendingGame
        self.pendingGame = nil
        if g then
            self:closeListener()
            self:joinLobby(g.id, g.relay)
        end
    elseif id == "joincode" then
        self:closeListener()
        self:joinLobby(tonumber(self.joinCode, 16) --[[@as integer]])
    elseif id == "listed" then
        self:closeListener()
        self:join(extra.ip, extra.port)
    elseif id == "connect" then
        self:closeListener()
        local ip, port = parseAddress(self.address)
        self:join(ip, port)
    elseif id == "address" or id == "lobby" or id == "code" or id == "password" then self.focus = id end
end

function S:mousepressed(x, y, button)
    if button ~= 1 then return end
    local vx, vy = UI.toVirtual(x, y)
    local id, extra = kit.click(self, vx, vy)
    self.sel = false
    if id then
        require("src.audio.sound").play("Assets/SoundFX.xcr", "NewClick.wav")
        self:act(id, extra)
    elseif self.mode ~= "password" then
        self.focus = nil
    end
end

-- The characters each field takes, and its length.
local FIELDS = {
    address = { "[^%w%.:%[%]%-_]", 64 }, lobby = { "[^%w%.:%[%]%-_]", 64 }, code = { "[^%x]", 8 },
    password = { "[%c]", 24 },
}
local FIELD_OF = { address = "address", lobby = "lobbyServer", code = "joinCode", password = "password" }

function S:textinput(t)
    local f = self.focus and FIELDS[self.focus]
    if not f then return end
    local key = FIELD_OF[self.focus]
    local text = (self.sel and "" or self[key]) .. t:gsub(f[1], "")
    self.sel = false
    self[key] = text:sub(1, f[2])
end

function S:keypressed(key)
    local field = self.focus and FIELD_OF[self.focus]
    if field then
        local f = FIELDS[self.focus]
        local text, sel, handled = kit.editKey(self[field], key, self.sel, function(t)
            return t:gsub(f[1], ""):sub(1, f[2])
        end)
        if handled then
            self[field], self.sel = text, sel
            return
        end
        if key == "backspace" then
            self[field] = kit.backspace(self[field])
            return
        elseif key == "return" then
            if self.focus == "address" and self.address ~= "" then self:act("connect")
            elseif self.focus == "lobby" and self.mode == "join" then self:act("lobbyset")
            elseif self.focus == "code" then self:act("joincode")
            elseif self.mode == "password" then self:act("passwordok") end
            return
        end
    end
    if key == "escape" then self:act("back") end
end

return S
