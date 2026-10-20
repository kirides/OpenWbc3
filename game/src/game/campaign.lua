-- Story cut scenes (<Lang>/Campaign/EpisodeN.xml, Intro.xml): narration and timed text lines.
-- The campaign itself lives in campaigndata.lua / campaignstate.lua / campaignrun.lua.
local config = require("src.core.config")
local fs = require("src.core.fs")
local text = require("src.core.text")

local M = {}

-- Cut scenes (<Lang>/Campaign/EpisodeN.xml): { voice = path, lines = { {text, ms} } }
---@param name string
---@return {voice: string?, delay: number, lines: {text: string, ms: number?}[]}?
function M.cutscene(name)
    local path = config.gamedir .. "/" .. config.language .. "/Campaign/" .. name .. ".xml"
    local data = fs.read(path) or fs.read(config.gamedir .. "/English/Campaign/" .. name .. ".xml")
    if not data then return nil end
    -- the XML is Windows-1252 like every other text file in the game data (docs/localization.md)
    data = text.fromCP1252(data)
    local scene = { lines = {}, voice = nil }
    local voice = data:match('voice="([^"]+)"')
    if voice then
        local file = voice:gsub("\\", "/")
        scene.voice = config.gamedir .. "/" .. file
    end
    scene.delay = tonumber(data:match('voicedelay="(%d+)"')) or 0
    for ms, line in data:gmatch('<Text time="(%d+)">(.-)</Text>') do
        line = line:gsub("&apos;", "'"):gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        scene.lines[#scene.lines + 1] = { text = line, ms = tonumber(ms) }
    end
    return scene
end

return M
