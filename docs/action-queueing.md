# Action queueing (Shift / Alt + right-click)

How the original queues orders, and how openwbc3 reproduces it. Behaviour was read from the
shipped game binary with Ghidra — every rule below comes from the decompiled functions.

## The order queue (original)

The original keeps a doubly linked list of order records per unit. The **head** of the queue is the
order the unit is carrying out right now; the records behind it are the waiting orders. The queue
supports these operations:

- append an order to the **tail** (behind everything);
- insert an order at the **head** (in front of the running order);
- drop the running (head) order when it finishes, so the next becomes the head;
- rotate patrol legs: the finished leg moves to the tail;
- remove all orders, or all but the first (End / Shift+Esc).

Order kinds carried in the queue: move, attack, convert, patrol, build, search (shrine/quest), shop,
work-in-mine, resume-building, garrison, cast-spell, an appended (deferred) convert, and board-ship.

## The three queue modes

Every order-taking path takes a queue-mode argument:

```
immediate  0   plain right-click
insert     1   Alt + right-click
queued     2   Shift + right-click
```

There is also a separate order-priority notion (no-diversion / diversion / overridable) that says how
much a *system* order may deviate from a player order; it is not used for the player's own Shift/Alt,
which always issue a plain player order.

### Mode 0 — immediate (right-click)

With a player order and immediate mode, the unit drops the running order, throws away the whole queue
(running + waiting + patrol), and appends the new order — the new order becomes the only one.

### Mode 2 — queued (Shift)

The new order is only appended to the tail: it goes behind the running order and the waiting ones.
Nothing is removed.

### Mode 1 — insert (Alt)

The new order is inserted at the **head**, so it starts immediately, and the order that was running
stays in the list right behind it and resumes when the new order finishes. The waiting orders keep
their place after that. This is the "do it first, then resume the rest" behaviour.

The insert path for a move first checks whether the new order equals the current head (same kind,
destination and pace); if so it keeps the current order and does nothing, otherwise it inserts at the
head and marks the unit changed. The insert path for an attack has the same shape.

## Alt + right-click per action (tactical-map mouse handler)

The mouse handler maps the modifier keys to an action, then the action dispatcher calls the order path
with the matching mode. The Alt flag is the Alt key. The insert variants:

| right-click on | Alt does | order path |
|---|---|---|
| ground / own unit (move) | insert move | move-all, insert mode |
| enemy / attack | insert attack | fight, insert mode |
| walk-and-assess | insert walk-and-assess | move-all, insert mode, as-quickly-as-possible off |
| abandoned construction (resume) | insert resume-building | resume-building, queued mode |
| mine (work) | insert work-in-mine | work-in-mine, queued mode |
| shrine / quest | insert search | search, queued mode |
| shop | insert shop | shop, queued mode |
| place building (build) | insert place-building | build, queued mode |
| allied unit | insert move (Shift is Guard) | move-all, insert mode |

Notable exceptions (verified in the binary):
- **Garrison has no insert mode.** The garrison action stays a plain garrison even when Alt is held, and
  the garrison order path only has immediate and queued modes (no insert case). Alt falls back to the
  plain immediate garrison.
- **Board transport has no insert mode** — the insert variant is left commented out in the handler.
- **Patrol has no insert mode**: only Shift adds waypoints.

## Stopping a running conversion on Alt

The insert move, insert attack, insert as-quickly-as-possible and the walk-and-assess inserts first loop
over the selected armies and stop any conversion in progress. The stop clears the unit's converting flag
and removes a head order of type convert / appended-convert. So Alt interrupts a conversion in progress;
the convert order is not preserved.

The convert button handler (the `Ctrl+C` button) reads the same modifiers: Alt -> insert mode, Shift ->
append mode. Setting up a conversion in insert mode inserts the convert order at the head and acts on it
immediately. When an appended (deferred) convert finishes, the act-on path re-inserts the insert-mode
convert, which is how Shift-queued conversions chain.

## Empty queue

Every insert/queued path starts by falling back to immediate mode when there is no running order: with
nothing running and nothing queued, Alt/Shift behave like a plain right-click — there is nothing to
preserve.

## Duplicate orders

The insert and queued paths skip the order when it equals the current head (same kind, destination and
pace) — the order is treated as already done, "keep doing the current order". Re-issuing the same queued
move does not add a second copy.

## openwbc3 mapping

- `Unit:enqueue` (unit.lua) = append (Shift).
- `Unit:insertOrder` (added here) = insert at the head + the insert path: capture the running order
  (the live `task` / `target` / `goalX`, mirroring `savegame.lua` `saveOrders`) and push it to the front
  of the waiting queue, stop a running conversion, then run the new order. Patrol and the waiting queue
  are kept; auto-orders (`roaming`, `autoChase`) are not re-queued.
- `Unit:clearOrders` = remove all orders (plain right-click).
- `commands.lua` `give` picks enqueue / insertOrder / clearOrders from `cmd.queue` / `cmd.interrupt`.
- `battle.lua` `S:command` reads `lshift`/`rshift` -> `queue`, `lalt`/`ralt` -> `interrupt`, matching the
  original's shift / Alt flags.

## The order display (original)

The original draws the queue so the player can see *what* will run *in which order*. The order display
is switched on for 500 ms after an order is issued (and while orders are pending), which is why the retail
game flashes the path briefly whenever you right-click.

The display is built per selected army: the running (head) order first, then each waiting order chained
end to end. A **single** army gets the whole chain of lines; **multiple** armies get end boxes only — no
lines, so a group doesn't produce a tangle of paths. Patrol waypoints and a building's rally point are
drawn the same way.

Per link the display draws:

- a **dashed line** in pure green (0,255,0), produced by walking the segment with Bresenham and plotting
  every 8th pixel;
- an **end box** whose colour depends on the order kind:
  - move / patrol: a green box pulsing brighter/darker (base green 191, plus a per-frame offset);
  - attack: red;
  - build: cyan (0,128,~127);
  - convert: cyan (0,~127,~127).
- the animation counter cycles over 16 frames at 100 ms each, and the value used is a triangle wave
  (rising for the first 8 frames then falling), so the box breathes between 2 and 10 px and the plus marks
  along the line march.

## openwbc3 order display

`battle.lua` `S:drawOrderDisplay` + `orderPoint` reproduce this: chain = `currentOrder()` then `queue`,
so the chain reads running-first and shows the execution order (Shift appends behind, Alt inserts in
front — the same order the queue itself is built in). Colours follow the retail build above. A single
selected unit gets the dashed chain, a group gets end boxes only.

## openwbc3 order display

`battle.lua` `S:drawOrderDisplay` + `orderPoint` reproduce this: chain = `currentOrder()`
then `queue`, so the chain reads running-first and shows the execution order (Shift appends
behind, Alt inserts in front — the same order the queue itself is built in). Colours follow
the retail build above. A single selected unit gets the dashed chain, a group gets end boxes
only.

Simplifications, openwbc3's own choices (not from the original):
- the display is drawn whenever selected units hold orders, rather than only for the 500 ms
  window after an order is issued;
- the dashes are stepped along the segment in an 8 px period with a phase-shifted plus mark
  (`drawDashedLine`) instead of the original's Bresenham walk — this build of LÖVE has
  neither `setDash` (added in 11.x, absent here) nor `setLineStipple` (removed in 0.8.0), so
  the marks are plotted directly.
