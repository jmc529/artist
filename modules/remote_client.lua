--[[- Standalone pocket-computer client for the Artist remote server
(see remote_server.lua).

This is NOT an Artist module - it's a plain program meant to be run
directly on a pocket computer with a wireless modem. It never touches an
inventory peripheral itself; every command is just a rednet round-trip to
the server, which does the actual item movement.

## Setup

1. Wire an ender chest into your Artist network (it can just be a normal
   attached inventory - no special config needed on the server side beyond
   making sure it's not ignored).
2. Pair a second ender chest to it, and carry that one with you.
3. Edit DESTINATION below to the *networked* ender chest's peripheral name
   (run `peripheral.getName(peripheral.find("ender_storage"))` near it, or
   check `/rom` peripheral listing, to find this).
4. Put a wireless modem on your pocket computer and copy this file to it.
5. Run it. `pull <item>` will make the item appear in the ender chest
   you're carrying, wherever you are.
]]

local PROTOCOL = "artist-remote"
local HOSTNAME = "artist" -- must match config.remote.hostname on the server

-- EDIT ME: peripheral name of the networked ender chest paired with the
-- one you're carrying.
local DESTINATION = "minecraft:ender_chest_0"

local modem = peripheral.find("modem")
if not modem then error("No modem attached to this computer", 0) end
rednet.open(peripheral.getName(modem))

print("Looking for Artist server '" .. HOSTNAME .. "'...")
local server_id = rednet.lookup(PROTOCOL, HOSTNAME)
if not server_id then
  error("Could not find an Artist server advertising as '" .. HOSTNAME .. "'", 0)
end

local function request(msg, timeout)
  rednet.send(server_id, msg, PROTOCOL)
  local sender, reply = rednet.receive(PROTOCOL, timeout or 5)
  if sender ~= server_id then return nil, "No response from server" end
  return reply
end

local function cmd_list(query)
  local reply, err = request { action = "list", query = query, limit = 15 }
  if not reply then print("Error: " .. err) return end
  if not reply.ok then print("Error: " .. reply.error) return end

  if #reply.items == 0 then
    print("No matching items.")
    return
  end

  for _, item in ipairs(reply.items) do
    print(("%4dx %s"):format(item.count, item.name))
  end
end

local function cmd_pull(query, amount)
  local reply, err = request {
    action = "pull",
    query = query,
    amount = amount,
    destination = DESTINATION,
  }
  if not reply then print("Error: " .. err) return end
  if not reply.ok then print("Error: " .. reply.error) return end

  print(("Pulled %dx %s -> your ender chest"):format(reply.extracted, reply.name))
end

print("Connected to Artist server (computer id " .. server_id .. ")")
print("Commands:")
print("  list [query]")
print("  pull <query> <amount|stack|all>")
print("  exit")

while true do
  write("> ")
  local line = read()
  if not line then break end

  local cmd, rest = line:match("^(%S+)%s*(.-)$")
  if cmd == "exit" then
    break
  elseif cmd == "list" then
    cmd_list(rest ~= "" and rest or nil)
  elseif cmd == "pull" then
    local query, amount = rest:match("^(.-)%s+(%S+)$")
    if not query or query == "" then
      print("Usage: pull <query> <amount|stack|all>")
    else
      cmd_pull(query, amount)
    end
  elseif cmd and cmd ~= "" then
    print("Unknown command: " .. cmd)
  end
end
