--[[- Periodically defragments partially-filled stacks of the same item
across inventories, merging small stacks into fuller ones.

## Why this exists

Artist's `Items:insert` tries to top off existing partial stacks before
using an empty slot, but this check isn't atomic: several concurrent
inserts (e.g. a player dropping off many different items at once) can each
independently decide to fill the same partial stack before any of them has
actually committed, and end up scattering things across new slots instead.
Over time this leaves items fragmented as e.g. 30 / 27 / 12 / 12 / 2 instead
of 64 / 64 / 47.

This module doesn't prevent that race (a real fix needs a reservation
mechanism inside `Items:insert` itself, symmetric to the `reserved_stock`
already used for extraction) - it cleans up after the fact, on a timer.

## Known limitation

`Items:extract` has no way to say "pull from any inventory *except* this
one", and a compaction target inventory is itself always one of the
`sources` for the item being compacted. So occasionally this module will
ask to pull a fragment from the very chest it's topping off. Real-world
inventories no-op (or fail harmlessly) on a push-to-self, so this just
wastes a negligible amount of the compaction budget rather than causing
any incorrect behaviour - but it means a single pass won't always be
maximally efficient. It converges fine over successive passes.

## Configuration

```lua
compactor = {
  interval = 30, -- seconds between compaction passes
},
```

## Wiring in

In `src/launch.lua`, before `context:run()`:

```lua
context:require "artist.items.compactor"
```
]]

local log = require "artist.lib.log".get_logger(...)
local schema = require "artist.lib.config".schema

return function(context)
  local items = context:require "artist.core.items"

  local config = context.config
    :group("compactor", "Periodically merges fragmented stacks of the same item together")
    :define("interval", "Seconds between compaction passes", 30, schema.positive)
    :get()

  --- Scan every inventory that (according to the item cache) holds some of
  -- `hash`, and find the slot with the largest partial stack - that's our
  -- fill target for this pass. Also count how many partial slots exist in
  -- total, so we can skip items that aren't actually fragmented.
  --
  -- @tparam string hash
  -- @tparam number max_count
  -- @treturn string|nil target_inventory
  -- @treturn number target_count
  -- @treturn number partial_slot_count
  local function find_fill_target(hash, max_count)
    local best_inv, best_count = nil, -1
    local partial_slot_count = 0

    local entry = items.item_cache[hash]
    for inv_name in pairs(entry.sources) do
      local inventory = items.inventories[inv_name]
      if inventory and inventory.slots then
        for _, slot in ipairs(inventory.slots) do
          if slot.hash == hash and slot.count > 0 and slot.count < max_count then
            partial_slot_count = partial_slot_count + 1
            if slot.count > best_count then
              best_inv, best_count = inv_name, slot.count
            end
          end
        end
      end
    end

    return best_inv, best_count, partial_slot_count
  end

  local function compact_item(hash)
    local entry = items.item_cache[hash]
    if not entry or entry.count == 0 then return end

    local max_count = (entry.details and entry.details.maxCount) or 64

    local target_inv, target_count, partial_slots = find_fill_target(hash, max_count)
    -- Need at least 2 partial slots for there to be anything worth merging.
    if not target_inv or partial_slots < 2 then return end

    local room = max_count - target_count
    if room <= 0 then return end

    log("Compacting %s: topping off %s (%d/%d), %d fragmented slot(s) involved",
      hash, target_inv, target_count, max_count, partial_slots)

    items:extract(target_inv, hash, room)
  end

  context:spawn(function()
    while true do
      sleep(config.interval)

      for hash in pairs(items.item_cache) do
        compact_item(hash)
      end
    end
  end)

  log("Compactor running every %ds", config.interval)
end
