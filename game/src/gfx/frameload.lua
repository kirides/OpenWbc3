-- The original's frame-rate throttle (the frame-problem counter DAT_00a38c94, 0 .. 20): when the game draws fewer than 13 frames a second it
-- cuts back on particles, lights and decals until it has caught up again.
--
-- Verified in the 1.04 binary: the meter is the tail of the view's draw function `FUN_0048fb80` (DAT_00a38c94 is the
-- counter, DAT_0060e130 the frame rate): every draw adds `1000 / (ms since the last draw)` (integer division, at least 1 ms;
-- the very first draw counts as 10 ms) to a sum; the sum of every eleventh draw is divided by ten (a quirk of the original)
-- and kept as the frame rate; after every draw, a rate below 13 adds one to the counter (at most 20) and below 7 sets it to 20,
-- anything else takes one off (at least 0). The users of the counter: new particle bursts (`FUN_0058c0d0`: none from 12 on, a
-- quarter of the size and no respawns from 8 on, half the size and no respawns from 4 on), new light flashes (`FUN_0058c2e0`:
-- none from 4 on), new decals (`FUN_00479a10`: none from 8 on), drawing the decals (`FUN_00479e80`: none from 12 on) and the PFX
-- display items (`FUN_0058c220`, none from 12 on). The levels below (0, 4, 8, 12, 16, 20) are openwbc3's names for the
-- counter values those users test.
--
-- openwbc3's own: the original measures its 25 ms game ticks, openwbc3 its drawn frames; a frame that took more than half
-- a second (a dialog, a stall, the window being dragged) is not counted at all.
--
-- Presentation only: nothing here touches the simulation.
local M = {}

M.NO, M.SOME, M.MODERATE, M.BAD, M.EXTREME, M.MAX = 0, 4, 8, 12, 16, 20
M.problems = 0
M.fps = 60

local last, sum, count = nil, 0, 0

function M.reset() last, sum, count, M.problems, M.fps = nil, 0, 0, 0, 60 end

-- Called once per drawn frame with the wall clock in milliseconds.
---@param ms number
function M.frame(ms)
    local elapsed = 10
    if last then
        elapsed = ms - last
        if elapsed > 500 then last = ms; return end
        if elapsed < 1 then elapsed = 1 end
    end
    last = ms
    sum = sum + math.floor(1000 / elapsed)
    count = count + 1
    if count > 10 then
        count = 0
        M.fps = math.floor(sum / 10)
        sum = 0
    end
    if M.fps < 13 then
        if M.problems < M.MAX then M.problems = M.problems + 1 end
        if M.fps < 7 then M.problems = M.MAX end
    elseif M.problems > 0 then
        M.problems = M.problems - 1
    end
end

return M
