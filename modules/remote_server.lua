--[[- Exposes Artist's item store over rednet, so a wireless computer
elsewhere (a pocket computer, for instance) can list, search for, and pull
items without a wired connection to the server.

## The ender chest pattern

Pair an ender chest to one wired into your Artist network. Configure a
pocket computer with a wireless modem, running the matching
`remote_client.lua`, with `DESTINATION` set to that ender chest's
peripheral name. Pulling an item sends it to the ender chest on the
network side - which, because it's paired, makes it appear instantly in
whichever ender chest you're carrying, wherever you physically are. The
pocket computer itself never touches an inventory peripheral; it's purely
a remote control.

## Configuration

```lua
remote = {
  enabled = true,
  modem = "back",       -- side/name of the wireless modem to open
  hostname = "artist",  -- must match HOSTNAME in remote_client.lua
  whitelist = {},        -- computer IDs allowed to connect; empty = allow all
},
```

## Wiring in

In `src/launch.lua`, before `context:run()`:

```lua
context:require "artist.net.remote"
```
]]

local expect = require "cc.expect".expect
local log = require "artist.lib.log".get_logger(...)
local schema = require "artist.lib.config".schema
local fuzzy = require "metis.string.fuzzy"

local PROTOCOL = "artist-remote"

return function(context)
  local items = context:require "artist.core.items"

  local config = context.config
    :group("remote", "Options for exposing Artist over rednet to remote computers")
    :define("enabled", "Whether to accept remote commands over rednet", false, schema.boolean)
    :define("modem", "The side (or name) of the wireless modem to open", "back", schema.peripheral)
    :define("hostname", "The rednet hostname to advertise this server under", "artist", schema.string)
    :define("whitelist", "Computer IDs allowed to issue commands. Empty means allow all.", {}, schema.list(schema.number))
    :get()

  if not config.enabled then return end

  rednet.open(config.modem)
  rednet.host(PROTOCOL, config.hostname)

  local allowed = nil
  if #config.whitelist > 0 then
    allowed = {}
    for _, id in ipairs(config.whitelist) do allowed[id] = true end
  end

  local function is_allowed(id)
    return allowed == nil or allowed[id] == true
  end

  --- Fuzzy-search the whole item pool for the best match to a query.
  local function find_item(query)
    local best, best_score
    for hash, entry in pairs(items.item_cache) do
      if entry.count > 0 then
        local name = (entry.details and entry.details.displayName) or hash
        local score = fuzzy(name, query)
        if score and (not best_score or score > best_score) then
          best, best_score = entry, score
        end
      end
    end
    return best
  end

  local handlers = {}

  function handlers.list(sender, msg)
    local out, limit, query = {}, msg.limit or 100, msg.query

    for hash, entry in pairs(items.item_cache) do
      if entry.count > 0 then
        local name = (entry.details and entry.details.displayName) or hash
        if not query or fuzzy(name, query) or name:lower():find(query:lower(), 1, true) then
          out[#out + 1] = { hash = hash, name = name, count = entry.count }
        end
      end
    end

    table.sort(out, function(a, b) return a.count > b.count end)
    while #out > limit do table.remove(out) end

    rednet.send(sender, { ok = true, items = out }, PROTOCOL)
  end

  function handlers.pull(sender, msg)
    if type(msg.query) ~= "string" then
      rednet.send(sender, { ok = false, error = "Missing query" }, PROTOCOL)
      return
    end

    local entry = find_item(msg.query)
    if not entry then
      rednet.send(sender, { ok = false, error = "No matching item found" }, PROTOCOL)
      return
    end

    local amount = msg.amount
    if amount == "all" then
      amount = entry.count
    elseif amount == "stack" then
      amount = (entry.details and entry.details.maxCount) or 64
    else
      amount = tonumber(amount)
    end

    if not amount or amount <= 0 then
      rednet.send(sender, { ok = false, error = "Invalid amount" }, PROTOCOL)
      return
    end

    if not msg.destination then
      rednet.send(sender, { ok = false, error = "No destination inventory given" }, PROTOCOL)
      return
    end

    items:extract(msg.destination, entry.hash, amount, nil, function(extracted)
      rednet.send(sender, {
        ok = true,
        extracted = extracted,
        hash = entry.hash,
        name = (entry.details and entry.details.displayName) or entry.hash,
      }, PROTOCOL)
    end)
  end

  function handlers.details(sender, msg)
    if type(msg.query) ~= "string" then
      rednet.send(sender, { ok = false, error = "Missing query" }, PROTOCOL)
      return
    end

    local entry = find_item(msg.query)
    if not entry then
      rednet.send(sender, { ok = false, error = "No matching item found" }, PROTOCOL)
      return
    end

    rednet.send(sender, { ok = true, count = entry.count, details = entry.details }, PROTOCOL)
  end

  context:spawn(function()
    log("Remote server listening as '%s' (protocol %s)", config.hostname, PROTOCOL)

    while true do
      local sender, msg = rednet.receive(PROTOCOL)

      if type(msg) == "table" and type(msg.action) == "string" then
        if not is_allowed(sender) then
          rednet.send(sender, { ok = false, error = "Not authorized" }, PROTOCOL)
        else
          local handler = handlers[msg.action]
          if not handler then
            rednet.send(sender, { ok = false, error = "Unknown action: " .. msg.action }, PROTOCOL)
          else
            local ok, err = pcall(handler, sender, msg)
            if not ok then
              log("ERROR handling '%s' from %d: %s", msg.action, sender, tostring(err))
              rednet.send(sender, { ok = false, error = "Internal error" }, PROTOCOL)
            end
          end
        end
      end
    end
  end)
end
