-- The retinue screen (PNL_RETINUE of the original, opened by FUN_00440b40 in the 1.04 binary), in its two modes:
--
-- "select": before a battle. The army setup points are spent on regular troops (left, any number of each, shown as a
--   count) and on the hero's retinue members (right, each costs its type's setup points plus a table of its level, see
--   src/game/retinue.lua). Left click takes a troop or toggles a member, right click takes a troop back.
-- "recruit": after a battle (opened from the battle screen once the victory screen is done). The survivors that qualify
--   are on the left as new recruits; click a recruit, then a retinue slot, to swap them (a member put on a recruit's
--   place leaves the retinue when the screen is closed); click a member's name to rename it. Nothing else can be moved.
-- Both show the Graveyard button and a popup with the statistics of a unit the mouse rests on.
--
-- Built from the original's XCI panels like its refresh FUN_004417b0: PNL_RETINUE (background, titles, Continue and
-- Graveyard buttons), eight PNL_RETINUE_ARMYn (the retinue, right) and eight PNL_RETINUE_RECRUITn (the troops or new
-- recruits, left), each opened at the slot position of the tables at 0x00609288 / 0x006092c8 of the 1.04 binary. A slot
-- panel holds the picture the game draws itself (image subtype 25; medals, combat icon and points of the XCI are moved off
-- the screen by the original, the drawing code puts them at the tables read from 0x00609308), the name (STR_SMALL_180) and
-- the buttons BUTT_RETINUE_ARMY (the 90 x 90 picture) and BUTT_RETINUE_ARMY_NAME (opens the name editor
-- PNL_RETINUE_EDIT_NAME at the slot, 2 / 94 from its corner). A picked up unit is its panel moved to the cursor
-- (FUN_00440e80 event 10: cursor - 45). The statistics popup is PNL_RETINUE_POPUP at the cursor (at most 630 / 450), it
-- opens after 650 timer ticks of rest and closes on the next mouse move (handler 0x00443840). Own: the dim help line
-- at the bottom, the box behind the name editor (the XCI editor record has colours whose meaning is not known) and the
-- translucency of the cross over a slot the Charisma does not enable (FUN_00443d20 passes 4 to
-- the translucent blit FUN_00469e20).
-- The retinue's own name (BUTT_RETINUE_NAME, PNL_RETINUE_NAME) cannot be reached in the shipped game: no panel of
-- War4Int.xci holds the button (docs/todo/not-in-original.md).
--
-- enter(opts):
--   mode ("select" | "recruit"), race, graveyard (list or nil), slots (enabled retinue slots), retinue (slot -> entry
--   { code, name, level, xp, battles }), onDone(result)
--   select: points (army setup points), techLevel, noRetinue (the map allows none), campaign (the campaign state of a
--     campaign battle: the extra army points dialog and the mercenary selection open over the screen, see campaignDialogs) ->
--     result = { retinue = { { slot, code, name, level, xp } }, army = { unit codes bought }, mercs = { slot -> true } }
--   recruit: recruits (list of entries) -> result = { retinue = slot -> entry }
local screens = require("src.core.screens")
local UI = require("src.ui.interface")
local fonts = require("src.ui.fonts")
local sound = require("src.audio.sound")
local strings = require("src.game.strings")
local rules = require("src.game.rules")
local gamedata = require("src.game.gamedata")
local retinue = require("src.game.retinue")
local anims = require("src.gfx.anims")
local log = require("src.core.log")

---@class ArmySetupScreen: Screen
---@field opts table                 enter(opts), see above
---@field mode "select"|"recruit"
---@field race integer
---@field total integer              army setup points to spend (select)
---@field used integer               army setup points spent (select)
---@field enabled integer            retinue slots the Charisma enables
---@field slots table<integer, table> retinue slot -> entry { code, name, level, xp, battles }
---@field troops { code: string, cost: integer, value: integer?, combat: integer?, name: string }[] regular troops
---@field counts table<string, integer> regular troop code -> how many are taken
---@field picked table<integer, true> retinue slot -> comes along
---@field recruits table[]           recruit mode: the new recruits' entries
---@field hand { from: "recruit"|"slot", index: integer }? recruit mode: what the mouse carries
---@field edit { slot: integer, text: string }? recruit mode: the name being typed
---@field hoverT number              the last mouse move (love.timer seconds)
---@field help string                the help line at the bottom
---@field mercs table                campaign: the mercenary companies taken (campaignmercs)
---@field panel Panel?               PNL_RETINUE
---@field slotPanels RetinueSlotPanel[] all slot panels, troop and army alternating
---@field armyPanels RetinueSlotPanel[] the retinue slots (right)
---@field troopPanels RetinueSlotPanel[] the troop / recruit slots (left)
---@field popup Panel?               PNL_RETINUE_POPUP
---@field popupOpen boolean          the statistics popup is shown
---@field mx number                  mouse, virtual coordinates
---@field my number
---@field rightHit RetinueSlotPanel? the slot a right button press started on
---@field devPopup boolean?          --show armysetup:popup
local S = {}
S.helpId = 8          -- screen help: the army-points screen (9 for the recruiting mode)

-- top left of the 8 slots of the troops / new recruits (left) and of the retinue (right)
local TROOP_X = { 93, 191, 289, 93, 191, 93, 191, 289 }
local RETINUE_X = { 417, 515, 613, 515, 613, 417, 515, 613 }
local SLOT_Y = { 125, 125, 125, 245, 245, 365, 365, 365 }
local HOVER = 0.65            -- seconds before the statistics popup opens (the original counts 650 timer ticks)
local NAME_LENGTH = 19        -- the rename box handler (0x00442e30) keeps 19 characters
local MEDAL_X_SILVER, MEDAL_X_GOLD = 77, 65        -- relative to the slot panel (0x00609308 ..)
local MEDAL_Y_SILVER = { 1, 16, 31, 46, 61 }
local MEDAL_Y_GOLD = { 1, 16, 31 }

-- The regular troops on offer, per race (index = race number), in slot order (3 / 2 / 3). A fixed list of
-- the original (the per-race switch of FUN_00444980 in the 1.04 binary): it is not derived from what the race
-- can build, e.g. Barbarians offer a Pegasus, Dark Elves a Skeleton, Daemons a Quasit .. Daemon.
local REGULAR = {
    [0] = { "AHBX", "AAEG", "AHKX", "AHMX", "AHFX", "AHDX", "AHEX" },                    -- Knight
    { "ADBX", "ADSX", "ADIX", "ADMX", "ADJX", "ADNX", "ADLX", "ADOX" },                  -- Dwarf
    { "AUBX", "AUIX", "AUJX", "AUKX", "AUXX", "AULX", "AUMX" },                          -- Undead
    { "ABBX", "ABIX", "ABDX", "ABCX", "ABEX", "AAPE" },                                  -- Barbarian
    { "ABBX", "AMIX", "AMNX", "AMJX", "AOXX", "AMMX" },                                  -- Minotaur
    { "AOBX", "AOSX", "AOIX", "AOOX", "AOCX", "AOMX", "AOJX", "AOKX" },                  -- Orc
    { "AEBX", "AEIX", "AEMX", "AECX", "AENX", "AEOX", "AEDX" },                          -- High Elf
    { "AEBX", "AWIX", "AWMX", "AWCX", "AWNX", "AEXX", "AWJX" },                          -- Wood Elf
    { "AEBX", "AUIX", "AKIX", "AKMX", "AKCX", "AKNX", "AKJX", "AKOX" },                  -- Dark Elf
    { "AFBX", "AFJX", "AFIX", "AFMX", "AASP", "AEXX", "AEDX" },                          -- Fey
    { "AABX", "AASX", "AAIX", "AAJX", "ADNX", "ASCA", "AAMX", "AANX" },                  -- Dark Dwarf
    { "AVBX", "AAFB", "AAIM", "AVCX", "AVIX", "AVDX", "AADE" },                          -- Daemon
    { "AHBX", "AAEG", "AHIX", "APMX", "AHCX", "AHJX", "APDX" },                          -- Empire
    { "ALBX", "ALIX", "ALCX", "ALMX", "ALDX", "ALEX" },                                  -- Ssrathi
    { "ARBX", "ARJX", "AAWA", "ARMX", "ARIX", "ARCX" },                                  -- Swarm
    { "AUBX", "AGPC", "AGSL", "AGGZ", "AGSP", "AGFL", "AGHY" },                          -- Plaguelord
}

-- A slot panel: PNL_RETINUE_ARMYn / PNL_RETINUE_RECRUITn and what this screen keeps on it.
---@class RetinueSlotPanel: Panel
---@field kind "army"|"troop"
---@field index integer              slot number 1..8
---@field homeX number               the slot position (x, y move while the panel is carried)
---@field homeY number
---@field nameItem PanelItem?
---@field button PanelItem
---@field nameButton PanelItem?
---@field cell { cost: integer?, ticked: boolean?, crossed: boolean?, plain: boolean? }? what the picture shows
---@field slotOff boolean?           a retinue slot the Charisma does not enable
---@field entry table?               the unit shown
---@field carried boolean?           drawn at the cursor

local function T(id, sub, fallback) return UI.text(id, sub) or fallback end

local function regularTroops(race)
    local out = {}
    for _, code in ipairs(REGULAR[race] or {}) do
        local t = gamedata.army(code)
        if t then
            out[#out + 1] = { code = code, cost = t.setupPoints or 0, value = t.unitValue,
                              combat = t.combat, name = rules.unitName(code, t) }
        else
            log.warn("army setup: no unit type %s", code)
        end
    end
    return out
end

local function copy(e)
    local c = {}
    for k, v in pairs(e) do c[k] = v end
    return c
end

local function displayName(e)
    return (e.name and e.name ~= "") and e.name or rules.unitName(e.code, gamedata.army(e.code))
end

-- A piece of a bitmap of the interface definition (the medals, icons and crosses are strips of one picture).
local quads = {}
local function drawPiece(id, sx, sy, w, h, x, y, alpha)
    local img = UI.bitmap(id)
    if not img then return end
    local key = id .. ":" .. sx .. ":" .. sy .. ":" .. w .. ":" .. h
    local q = quads[key]
    if not q then
        q = love.graphics.newQuad(sx, sy, w, h, img:getDimensions())
        quads[key] = q
    end
    love.graphics.setColor(1, 1, 1, alpha or 1)
    love.graphics.draw(img, q, x, y)
    love.graphics.setColor(1, 1, 1)
end

-- The medals of a unit level: a gold one per five levels, the level mod 5 + 1 silver ones (FUN_00443d20 / FUN_00444330).
local function drawMedals(x, y, level)
    level = math.max(0, math.min(19, level or 0))
    local gold, silver = math.floor(level / 5), level % 5 + 1
    for i = 1, gold do drawPiece(395, 10, 0, 16, 15, x + MEDAL_X_GOLD, y + MEDAL_Y_GOLD[i]) end
    for i = 1, silver do drawPiece(395, 0, 0, 11, 14, x + MEDAL_X_SILVER, y + MEDAL_Y_SILVER[i]) end
end

---@param opts table?
function S:enter(opts)
    opts = opts or self:sample()
    self.opts = opts
    self.mode = opts.mode or "select"
    self.helpId = self.mode == "recruit" and 9 or 8
    self.race = opts.race or 0
    self.total = opts.points or 10
    self.enabled = opts.slots or retinue.SLOTS
    self.slots = {}
    for i = 1, retinue.SLOTS do
        local e = (opts.retinue or {})[i]
        if e then self.slots[i] = copy(e) end
    end
    self.troops = regularTroops(self.race)
    for i = #self.troops, 9, -1 do self.troops[i] = nil end
    self.counts = {}                       -- regular troop code -> how many are taken
    self.picked = {}                       -- retinue slot -> comes along
    self.used = 0
    self.recruits = {}
    for i, e in ipairs(opts.recruits or {}) do
        if i > retinue.RECRUITS then break end
        self.recruits[i] = copy(e)
    end
    self.hand = nil                        -- recruit mode: what the mouse carries { from = "recruit" | "slot", index }
    self.edit = nil                        -- recruit mode: the name being typed { slot, text }
    self.hoverT = love.timer.getTime()     -- the last mouse move (the popup opens after a rest)
    self.help = ""
    self.mercs = {}
    -- FUN_00440b40: a campaign battle opens the extra points / mercenary dialogs instead of the screen help
    self.noFirstHelp = (opts.campaign and self.mode == "select") or nil
    self:buildPanel()
    if opts.campaign and self.mode == "select" then self:campaignDialogs() end
end

-- The end of the opener FUN_00440b40 for a campaign battle: when the hero has 10 crowns the extra army points dialog opens
-- (the 1.04 binary `FUN_005a8330` returns 0 below that), its Continue buys the package and opens the mercenary selection
-- when a company waits in a slot; without the crowns the selection opens at once. After either, no setup points left
-- closes the screen as if OK was pressed (points left, FUN_004457d0, <= 0: FUN_004457e0 sends OK to FUN_00440e80).
function S:campaignDialogs()
    local st = self.opts.campaign
    local run = require("src.game.campaignrun")
    local function finish()
        if self.total <= 0 then self:done() end
    end
    local function mercenaries()
        if #st.mercs == 0 then return finish() end
        local D = require("src.game.campaigndata").load()
        local companies = {}
        for i, id in ipairs(st.mercs) do companies[i] = D.mercenaries[id] end
        screens.push(require("src.screens.campaignmercs"), {
            companies = companies, onDone = function(selected)
                self.mercs = selected
                finish()
            end })
    end
    if run.extraPointsAvailable(st) then
        screens.push(require("src.screens.campaignextra"), {
            points = self.total, crowns = st.crowns, techLevel = self.opts.techLevel,
            onDone = function(option)
                self.total = self.total + run.buyExtraPoints(st, option)
                mercenaries()
            end })
    else
        mercenaries()
    end
end

-- A sample for --show armysetup[:recruit].
function S:sample()
    local o = { race = 5, points = 20, slots = 8, retinue = {
        { code = "AOSX", level = 3, xp = 40, name = "Gorak" }, { code = "AOIX", level = 1, xp = 5 },
        [4] = { code = "AOOX", level = 6, xp = 110, battles = 3 } } }
    return o
end

function S:cost(e) return retinue.cost(e.code, e.level) end

function S:done()
    local result
    if self.mode == "recruit" then
        result = { retinue = self.slots }
    else
        result = { retinue = {}, army = {}, mercs = self.mercs }
        for i = 1, retinue.SLOTS do
            local e = self.slots[i]
            if e and self.picked[i] then
                result.retinue[#result.retinue + 1] = { slot = i, code = e.code, name = e.name, level = e.level, xp = e.xp }
            end
        end
        for _, t in ipairs(self.troops) do
            for _ = 1, self.counts[t.code] or 0 do result.army[#result.army + 1] = t.code end
        end
    end
    -- closed first: onDone starts the battle (a screen pushed on top of this one) or the multiplayer start
    screens.pop()
    if self.opts.onDone then self.opts.onDone(result) end
end

local function team(self) return self.opts.team or 1 end

-- Panels --------------------------------------------------------------------------------------------------------

-- One PNL_RETINUE_ARMYn (kind "army", the retinue) or PNL_RETINUE_RECRUITn (kind "troop") at its slot.
---@param kind "army"|"troop"
---@param k integer
---@return RetinueSlotPanel?
function S:slotPanel(kind, k)
    local army = kind == "army"
    local p
    p = UI.panel((army and "PNL_RETINUE_ARMY" or "PNL_RETINUE_RECRUIT") .. k, {
        x = (army and RETINUE_X or TROOP_X)[k], y = SLOT_Y[k],
        onButton = function(name) self:slotButton(p, name, 1) end }) --[[@as RetinueSlotPanel?]]
    if not p then return nil end
    p.kind, p.index, p.homeX, p.homeY = kind, k, p.x, p.y
    -- the original sets every medal and the combat icon to (1000, 1000) and the two texts to "": the drawing code
    -- of the picture does all of it
    for _, n in ipairs({ "IM_RETINUE_MEDAL", "IM_RETINUE_ICON_COMBAT", "STR_SMALL24", "STR_MEDIUM30" }) do
        for _, it in ipairs(p:all(n)) do p:hideItem(it) end
    end
    p.nameItem = p:find("STR_SMALL_180")
    p.align[p.nameItem] = "center"
    p.button, p.nameButton = p:find("BUTT_RETINUE_ARMY") --[[@as PanelItem]], p:find("BUTT_RETINUE_ARMY_NAME")
    for _, it in ipairs({ p.button, p.nameButton or p.button }) do
        p:hideArt(it)
        p.itemStrings[it] = ""
    end
    p:setOwnerDraw(p:find(army and "IM_RETINUE_PICTURE_ARMY" or "IM_RETINUE_PICTURE_RECRUIT") --[[@as PanelItem]],
        function(x, y) self:drawPicture(p) end)
    return p
end

function S:buildPanel()
    local p = UI.panel("PNL_RETINUE", { x = 0, y = 0, onButton = function(name)
        if self.edit then return end
        if name == "BUTT_OKAY_STARTUP" then self:act("done")
        elseif name == "BUTT_RETINUE_GRAVEYARD" then self:act("graveyard") end
    end })
    self.panel = p
    self.slotPanels, self.armyPanels, self.troopPanels = {}, {}, {}
    for k = 1, retinue.SLOTS do
        local troop, army = self:slotPanel("troop", k), self:slotPanel("army", k)
        self.troopPanels[k], self.armyPanels[k] = troop, army
        self.slotPanels[#self.slotPanels + 1] = troop
        self.slotPanels[#self.slotPanels + 1] = army
    end
    self.popup = UI.panel("PNL_RETINUE_POPUP", { x = 0, y = 0 })
    if self.popup then
        for _, it in ipairs(self.popup:all("IM_RETINUE_MEDAL")) do self.popup:hideItem(it) end
        self.popup.align[self.popup:find("STR_MEDIUM120")] = "center"
        local labels = self.popup:all("STR_SMALL80")
        local gs = { "0258", "0259", "0260", "0261", "0755" }               -- Game.txt: Combat, Hits, Speed, Damage, Range
        for i, it in ipairs(labels) do
            self.popup.align[it] = "right"
            self.popup.itemStrings[it] = gs[i] and strings.get("Game.txt", gs[i]) or ""
        end
    end
    if not p then return end
    local function text(name, x, y, s) local it = p:setTextAt(name, x, y, s) if it then p.align[it] = "center" end end
    local recruit = self.mode == "recruit"
    text("STR_LARGE332", 70, 67, recruit and T(168, 1, "New Recruits") or T(168, 4, "Regular Troops"))
    text("STR_LARGE332", 397, 67, T(168, 0, "Your Retinue"))
    if recruit then
        text("STR_SMALL_180", 310, 250, "")
        text("STR_SMALL_180", 310, 313, "")
        text("STR_MEDIUM500", 150, 495, T(168, 2, "Select units from the new recruits"))
        text("STR_MEDIUM500", 150, 513, T(168, 3, "and add them to your retinue."))
        for i, it in ipairs(p:all("STR_MEDIUM200")) do
            p.itemStrings[it] = T(168, 4 + i, "")
            p.align[it] = "center"
        end
    else
        text("STR_SMALL_180", 310, 250, T(171, 2, "Army Setup Points"))
        text("STR_MEDIUM500", 150, 495, T(164, 2, "Use Left Click to select units"))
        text("STR_MEDIUM500", 150, 513, T(164, 3, "Use Right Click to deselect units"))
        for _, it in ipairs(p:all("STR_MEDIUM200")) do p:hideItem(it) end
    end
    p:setString("BUTT_OKAY_STARTUP", "")
    p:setString("BUTT_RETINUE_GRAVEYARD", "")
    p:hide("BUTT_RETINUE_GRAVEYARD", not self.opts.graveyard)
    for _, n in ipairs({ "STR_MEDIUM200", "STR_LARGE200" }) do
        for _, it in ipairs(p:all(n)) do p.align[it] = "center" end
    end
end

-- What a slot panel shows: the entry, the label, and the state of its buttons (refresh routine FUN_004417b0).
function S:syncSlot(p)
    local k, army = p.index, p.kind == "army"
    local select = self.mode == "select"
    local e, label, usable = nil, "", true
    p.cell = nil
    if army then
        local enabled = k <= self.enabled
        e = enabled and self.slots[k] or nil
        if e then
            label = displayName(e)
            if select then
                e.cost = self:cost(e)
                usable = self.picked[k] or (not self.opts.noRetinue and self.used + e.cost <= self.total)
                p.cell = { cost = e.cost, ticked = self.picked[k], crossed = not usable }
            else
                p.cell = {}
            end
        end
        p:setItemDisabled(p.button, not enabled or (select and (not e or not usable)))
        p:setItemDisabled(p.nameButton, select or not e or not enabled or self.hand ~= nil or self.edit ~= nil)
        p.slotOff = not enabled
    elseif select then
        local t = self.troops[k]
        if t then
            local n = self.counts[t.code] or 0
            e = { code = t.code, level = 0, combat = t.combat, plain = true, cost = t.cost }
            label = n > 0 and ("%s (%d)"):format(t.name, n) or t.name
            p.cell = { cost = t.cost, crossed = self.used + t.cost > self.total, plain = true }
        end
        p:setItemDisabled(p.button, false)
    else
        e = self.recruits[k]
        if e then label = displayName(e) p.cell = {} end
        p:setItemDisabled(p.button, false)
    end
    p.entry = e
    p.itemStrings[p.nameItem] = (self.edit and self.edit.slot == k and army) and "" or label
end

-- The picture of a slot (FUN_00443d20 / FUN_00444330): the unit's interface picture 2 px in, the
-- setup points top left (select mode), a tick / cross, the medals and the combat icon with the combat skill.
function S:drawPicture(p)
    local g = love.graphics
    local e, c = p.entry, p.cell
    local x, y = p.x, p.y
    if not e then
        -- a recruiting screen shows the slots the Charisma does not enable crossed out
        if p.kind == "army" and p.slotOff and self.mode == "recruit" then drawPiece(400, 132, 0, 132, 109, x - 21, y - 10, 0.5) end
        return
    end
    local set = anims.get(e.code)
    if set then set:drawInterface(3, x + 2, y + 2, team(self)) end
    if c.cost and c.cost > 0 and self.mode == "select" and not p.carried then
        -- the setup points, top left (TXT_GRAVEYARD 6 / 7)
        fonts.print(5, (c.cost == 1 and T(169, 6, "%d pt") or T(169, 7, "%d pts")):format(c.cost), x + 4, y + 5)
    end
    if not p.carried and self.mode == "select" then
        if p.kind == "army" then
            if c.crossed then drawPiece(400, 132, 0, 132, 109, x - 11, y - 2)
            elseif c.ticked then drawPiece(400, 0, 0, 132, 109, x - 11, y - 2) end
        elseif c.crossed and c.cost and c.cost > 0 then
            drawPiece(401, 0, 0, 20, 22, x + 64, y + 4)
        end
    end
    if not c.plain then drawMedals(x, y, e.level) end        -- regular troops have no levels
    drawPiece(396, 0, 0, 12, 12, x + 4, y + 79)             -- IM_RETINUE_ICON_COMBAT, the number is the combat skill
    fonts.print(2, tostring(e.combat or retinue.stats(e.code, e.level).combat), x + 22, y + 80)
end

-- The statistics popup (FUN_004431c0): the unit's name and its combat, hits, speed, damage and range.
function S:openPopup(e)
    local p = self.popup
    if not p then return end
    local st = retinue.stats(e.code, e.level)
    p.x, p.y = math.min(self.mx, 630), math.min(self.my, 450)
    p.itemStrings[p:find("STR_MEDIUM120")] = rules.unitName(e.code, gamedata.army(e.code))
    local values = p:all("STR_SMALL50")
    local list = { st.combat, st.hits, st.speed, st.damage, st.range }
    for i, it in ipairs(values) do p.itemStrings[it] = list[i] and tostring(list[i]) or "" end
    p:draw()
end

-- The slot whose picture is under the point (whatever the state of its button: the popup also opens on greyed units).
function S:slotAt(vx, vy)
    for _, sp in ipairs(self.slotPanels) do
        local b = sp.button
        local x, y = sp.homeX + b.e.x, sp.homeY + b.e.y
        if vx >= x and vx < x + b.ob.w and vy >= y and vy < y + b.ob.h then return sp end
    end
end

function S:draw()
    UI.begin()
    local mx, my = love.mouse.getPosition()
    self.mx, self.my = UI.toVirtual(mx, my)
    self.popupOpen = false
    local p = self.panel
    local select = self.mode == "select"
    if p then
        if select then
            local tech = self.opts.techLevel or 0
            local it = p:setTextAt("STR_SMALL_180", 310, 313, tech == 0 and T(174, 0, "No Building") or T(174, 5, "Building Level %d"):format(tech))
            if it then p.align[it] = "center" end
            local sep = (self.used > 20 or self.total > 20) and "%d/%d" or "%d / %d"
            it = p:setTextAt("STR_LARGE200", 300, 270, sep:format(self.used, self.total))
            if it then p.align[it] = "center" end
        end
        p:draw()
    end
    local over = p and p:over(self.mx, self.my) or false
    local carried
    for _, sp in ipairs(self.slotPanels) do
        self:syncSlot(sp)
        over = over or sp:over(self.mx, self.my)
        local from = self.hand and (self.hand.from == "slot" and "army" or "troop")
        if from == sp.kind and self.hand.index == sp.index and sp.entry then
            carried = sp                     -- drawn last, at the cursor
        else
            sp.carried = false
            sp:draw()
        end
    end
    if carried then
        carried.carried = true
        carried.x, carried.y = self.mx - 45, self.my - 45
        carried:draw()
        carried.x, carried.y = carried.homeX, carried.homeY
    end
    -- the editor of a name (PNL_RETINUE_EDIT_NAME) opens on the name of the slot
    if self.edit then
        local sp = self.armyPanels[self.edit.slot]
        local ob = UI.ui.objByName.EDIT_RETINUE_ARMY_NAME
        local x, y = sp.homeX + 2, sp.homeY + 94
        love.graphics.setColor(0, 0, 0, 0.7)
        love.graphics.rectangle("fill", x, y, ob.w, ob.h)
        love.graphics.setColor(1, 1, 1)
        local s = self.edit.text .. ((love.timer.getTime() % 1 < 0.5) and "|" or "")
        fonts.print(ob.font or 2, s, x + 2, y + 1)
    end
    UI.panelOver = over and true or nil
    -- hover: the help line, and the popup once the mouse has rested on a unit
    self.help = ""
    local sp = self:slotAt(self.mx, self.my)
    if sp and sp.entry and sp.cell then
        local e = sp.entry
        ---@cast e -nil
        if select and sp.kind == "army" then
            self.help = ("%s, level %d: %d army setup points."):format(displayName(e), (e.level or 0) + 1, e.cost or 0)
        elseif select then
            self.help = ("%s: %d army setup point%s."):format(rules.unitName(e.code, gamedata.army(e.code)), e.cost,
                e.cost == 1 and "" or "s")
        end
        if not self.hand and not self.edit and love.timer.getTime() - (self.hoverT or 0) > HOVER then
            self.popupOpen = true
            self:openPopup(e)
        end
    end
    if self.devPopup and self.slots[1] then       -- --show armysetup:popup
        self.mx, self.my = 470, 140
        self:openPopup(self.slots[1])
    end
    fonts.print(5, self.help, 15, 578 + fonts.middleY(5, 20), "center", 770)
    UI.finish()
end

-- Recruit mode: swaps what is on a recruit place with what is in a retinue slot. A recruit that enters a slot counts
-- its first battle (the original's fresh record).
function S:swap(recruitIndex, slot)
    local r, m = self.recruits[recruitIndex], self.slots[slot]
    self.recruits[recruitIndex], self.slots[slot] = m, r
    if r then r.battles = r.battles or 1 end
end

-- A click on a button of a slot panel (button-up event of the slot handlers at 0x004427d0 / 0x00443890): button 1 is
-- the left mouse button.
function S:slotButton(sp, name, button)
    if self.edit then return end
    if name == "BUTT_RETINUE_ARMY_NAME" then self:act("name", sp.index)
    elseif sp.kind == "army" then self:act("retinue", sp.index)
    else self:act(self.mode == "select" and "take" or "recruit", sp.index, button) end
end

---@param id string                  "done", "graveyard", "take", "retinue", "name" or "recruit"
---@param extra integer?             the slot (every id but "done" and "graveyard")
---@param button integer?            mouse button (take)
function S:act(id, extra, button)
    if id == "done" then self:done() return end
    if id == "graveyard" then screens.push(require("src.screens.graveyard"), self.opts.graveyard) return end
    ---@cast extra -nil
    if self.mode == "select" then
        if id == "take" then
            local t = self.troops[extra]
            if not t then return end
            if button == 1 then
                if self.used + t.cost <= self.total then
                    self.used = self.used + t.cost
                    self.counts[t.code] = (self.counts[t.code] or 0) + 1
                end
            elseif (self.counts[t.code] or 0) > 0 then
                self.counts[t.code] = self.counts[t.code] - 1
                self.used = self.used - t.cost
            end
        elseif id == "retinue" then
            local e = self.slots[extra]
            if not e or extra > self.enabled or self.opts.noRetinue then return end
            if self.picked[extra] then
                self.picked[extra] = nil
                self.used = self.used - self:cost(e)
            elseif self.used + self:cost(e) <= self.total then
                self.picked[extra] = true
                self.used = self.used + self:cost(e)
            end
        end
        return
    end
    -- recruit mode
    local hand = self.hand
    if id == "name" then
        local e = self.slots[extra]
        if e and not hand then
            -- the edit box text setter FUN_0045daf0 refuses a text longer than the editor's limit (the XCI record:
            -- 11), so the editor then starts empty
            local ob = UI.ui.objByName.EDIT_RETINUE_ARMY_NAME
            local name = e.name or ""
            if #name > (ob.maxLen or 11) then name = "" end
            self.edit = { slot = extra, text = name }
        end
    elseif id == "recruit" then
        if hand then
            if hand.from == "slot" then
                self:swap(extra, hand.index)
                self.hand = nil
            elseif hand.index == extra then
                self.hand = nil
            end
        elseif self.recruits[extra] then
            self.hand = { from = "recruit", index = extra }
        end
    elseif id == "retinue" then
        if extra > self.enabled then return end
        if hand then
            if hand.from == "recruit" then
                self:swap(hand.index, extra)
                self.hand = nil
            elseif hand.index == extra then
                self.hand = nil
            end
        elseif self.slots[extra] then
            self.hand = { from = "slot", index = extra }
        end
    end
end

function S:mousemoved(x, y)
    -- a move closes the popup and starts the rest timer again (mouse-move event of the popup handler at 0x00443840)
    self.hoverT = love.timer.getTime()
    self.popupOpen = false
    local vx, vy = UI.toVirtual(x, y)
    if self.panel then self.panel:mousemoved(vx, vy) end
    for _, sp in ipairs(self.slotPanels or {}) do sp:mousemoved(vx, vy) end
end

function S:allPanels()
    local list = { self.panel }
    for _, sp in ipairs(self.slotPanels) do list[#list + 1] = sp end
    return list
end

function S:mousepressed(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if self.edit then
        local sp = self.armyPanels[self.edit.slot]
        local ob = UI.ui.objByName.EDIT_RETINUE_ARMY_NAME
        local ex, ey = sp.homeX + 2, sp.homeY + 94
        if not (vx >= ex and vx < ex + ob.w and vy >= ey and vy < ey + ob.h) then self:finishEdit(true) end
        return
    end
    if self.popupOpen then return end          -- input is off while the popup is open
    self.rightHit = nil
    if button == 2 then
        self.rightHit = self:slotAt(vx, vy)
        return
    end
    for _, panel in ipairs(self:allPanels()) do
        if panel and panel:hit(vx, vy) then panel:mousepressed(vx, vy, button) return end
    end
end

function S:mousereleased(x, y, button)
    local vx, vy = UI.toVirtual(x, y)
    if button == 2 then
        local r = self.rightHit
        self.rightHit = nil
        if r and not self.edit and self:slotAt(vx, vy) == r then
            sound.play("Assets/SoundFX.xcr", "NewClick.wav")
            self:slotButton(r, "BUTT_RETINUE_ARMY", 2)
        end
        return
    end
    for _, panel in ipairs(self:allPanels()) do
        if panel then panel:mousereleased(vx, vy, button) end
    end
end

function S:finishEdit(accept)
    local ed = self.edit
    self.edit = nil
    if accept and ed and self.slots[ed.slot] then
        local name = retinue.cleanName(ed.text)
        self.slots[ed.slot].name = name ~= "" and name or nil
    end
end

function S:textinput(t)
    local ob = UI.ui.objByName.EDIT_RETINUE_ARMY_NAME
    if self.edit and #self.edit.text < math.min(ob.maxLen or 11, NAME_LENGTH) and not t:match("%c") then
        self.edit.text = self.edit.text .. t
    end
end

function S:keypressed(key)
    if self.edit then
        if key == "backspace" then
            local o = require("utf8").offset(self.edit.text, -1)
            if o then self.edit.text = self.edit.text:sub(1, o - 1) end
        elseif key == "return" or key == "kpenter" then self:finishEdit(true)
        elseif key == "escape" then self:finishEdit(false) end
        return
    end
    if key == "return" or key == "escape" then
        if self.hand then self.hand = nil else self:done() end
    end
end

-- developer aid: --show armysetup[:<race>|recruit|edit|popup]
function S:dev(sub)
    if sub == "recruit" or sub == "edit" or sub == "popup" then
        self:enter({ mode = "recruit", race = 5, slots = 5, graveyard = {}, retinue = { { code = "AOSX", level = 3, xp = 40, name = "Gorak", battles = 2 },
            [3] = { code = "AOOX", level = 6, xp = 110, battles = 3 } },
            recruits = { { code = "AOIX", level = 2, xp = 12, name = "Urg" }, { code = "AOJX", level = 5, xp = 90, name = "Snaga" },
                         { code = "AOMX", level = 0, xp = 1, name = "Oruk", general = true } } })
        if sub == "edit" then self:act("name", 1) self.edit.text = "Gora" end
        if sub == "popup" then self.devPopup = true end
    elseif tonumber(sub) then
        self:enter({ race = tonumber(sub), points = 11, graveyard = {} })
    end
end

return S
