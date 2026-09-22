--[[- Generic "export bus" for Artist.

Unlike a dropoff chest (which pulls items INTO the system), an export bus
pushes items OUT of the system into a target inventory, keeping it stocked
to configured levels. Useful for feeding crafters, dispensers, or a manual
pickup chest without ever opening the Artist UI.

## Configuration

Add to your `.artist.d/config.lua` (or let this module write the defaults
on first run), under `export_bus.buses`:

```lua
export_bus = {
  buses = {
    {
      target = "minecraft:chest_12",     -- inventory to keep stocked
      interval = 5,                       -- seconds between checks
      items = {                           -- item id -> desired count
        ["minecraft:redstone"] = 64,
        ["minecraft:gold_ingot"] = 64,
      },
    },
    -- additional buses...
  },
},
```

## Wiring in

In `src/launch.lua`, before `context:run()`:

```lua
context:require "artist.items.export_bus"
```

## Known limitations

Stock levels are matched by item id/name only (via the target inventory's
raw `.list()`), not by NBT hash - if you need to stock a specific enchanted
or named variant, extend `has_matching_item` below to compare NBT.
]]

local log = require "artist.lib.log".get_logger(...)
local schema = require "artist.lib.config".schema

return function(context)
  local items = context:require "artist.core.items"
  local inventories = context:require "artist.items.inventories"

  local config = context.config
    :group("export_bus", "Automatically keep specific inventories stocked with configured items")
    :define("buses", "List of export bus definitions: { target, interval, items }", {}, schema.list(schema.table))
    :get()

  if #config.buses == 0 then return end

  for i, bus in ipairs(config.buses) do
    local target = bus.target
    local whitelist = bus.items or {}
    local interval = bus.interval or 5

    if not target then
      log("Export bus #%d has no target configured, skipping", i)
    elseif next(whitelist) == nil then
      log("Export bus #%d (%s) has no items configured, skipping", i, target)
    else
      -- The target is a destination we manage, not general storage - don't
      -- let the rest of the system treat it as part of the shared pool.
      inventories:add_ignored_name(target)

      context:spawn(function()
        while true do
          local contents = peripheral.call(target, "list")
          if contents then
            local have = {}
            for _, slot in pairs(contents) do
              have[slot.name] = (have[slot.name] or 0) + slot.count
            end

            for hash, desired in pairs(whitelist) do
              local current = have[hash] or 0
              local needed = desired - current

              if needed > 0 then
                local item = items:get_item(hash)
                if item.count > 0 then
                  local to_send = math.min(needed, item.count)
                  log("Export bus %s: sending %d x %s", target, to_send, hash)
                  items:extract(target, hash, to_send)
                end
              end
            end
          else
            log("Export bus target %s is not reachable, will retry", target)
          end

          sleep(interval)
        end
      end)

      log("Export bus started for %s (%d item(s) configured)", target, (function()
        local n = 0
        for _ in pairs(whitelist) do n = n + 1 end
        return n
      end)())
    end
  end
end
