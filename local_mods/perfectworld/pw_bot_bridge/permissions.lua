-- pw_bot_bridge/permissions.lua
--
-- Who may change what.
--
-- Two rules carry the whole design:
--   1. A mode is granted by the server, never claimed by the observed player.
--   2. Being able to type a chatcommand is not authorisation. Every
--      administrative path re-checks the `pw_bot_admin` privilege against the
--      acting player, whatever channel the call arrived on.

local B = pw_bot_bridge
local permissions = {}
B.impl.permissions = permissions

permissions.PRIV = "pw_bot_admin"

-- Actor used by trusted server-side Lua callers (other mods, the test harness).
-- It can never arrive from outside: the transport and the chatcommands always
-- substitute the real player name, and validation rejects the string as a
-- player name.
permissions.SERVER_ACTOR = "@server"

minetest.register_privilege(permissions.PRIV, {
  description = "Administer PerfectWorld bot bridge registrations and modes",
  give_to_singleplayer = false,
  give_to_admin = true,
})

--- Modes this protocol version accepts.
permissions.MODES = {
  player = true,
  oracle = true,
}

-- Levels the architecture leaves room for but v1 does not accept. They are
-- listed so a client can discover that the mode namespace is not closed, and
-- so nobody silently reuses one of these names for something else.
permissions.RESERVED_MODES = {
  "oracle_local",
  "oracle_world",
  "player_debug",
}

function permissions.is_valid_mode(mode)
  return type(mode) == "string" and permissions.MODES[mode] == true
end

function permissions.list_modes()
  local out = {}
  for mode in pairs(permissions.MODES) do out[#out + 1] = mode end
  table.sort(out)
  return out
end

--- Does this player hold the bridge admin privilege?
function permissions.is_admin(player_name)
  if type(player_name) ~= "string" or player_name == "" then return false end
  local privs = minetest.get_player_privs(player_name)
  return privs and privs[permissions.PRIV] == true
end

--- Resolve an actor into {name, trusted, reason}.
--
-- `actor` is either the reserved server actor (trusted Lua caller) or a real
-- player name that must hold the privilege. Nothing else is accepted — in
-- particular an absent actor is *not* treated as the server, because a caller
-- that forgot to pass one is a bug, not an administrator.
function permissions.resolve_actor(actor)
  if actor == permissions.SERVER_ACTOR then
    return {name = permissions.SERVER_ACTOR, trusted = true}
  end
  if type(actor) ~= "string" or actor == "" then
    return {name = "", trusted = false, reason = "no_actor"}
  end
  if permissions.is_admin(actor) then
    return {name = actor, trusted = true}
  end
  return {name = actor, trusted = false, reason = "missing_priv:" .. permissions.PRIV}
end

--- May `actor` administer bot registrations?
-- Returns ok, reason.
function permissions.can_administer(actor)
  local resolved = permissions.resolve_actor(actor)
  if resolved.trusted then return true end
  return false, resolved.reason or "permission_denied"
end

--- May `actor` read oracle-grade diagnostics about `subject`?
--
-- Oracle output describes the world, not the observer, so the privilege check
-- is on the reader. A player looking at their own bot is no exception: oracle
-- data is exactly the data player mode is designed to withhold.
function permissions.can_read_oracle(actor)
  return permissions.can_administer(actor)
end

--- Guard against the one escalation that matters: a bot raising its own mode.
--
-- The protocol has no set_mode operation at all, so this is a second line of
-- defence for the Lua API, where a caller could pass the observed player as
-- the actor. Without the privilege the answer is no, and holding the privilege
-- means the caller is an administrator who merely happens to also be the bot.
function permissions.can_set_mode(player_name, actor)
  local ok, reason = permissions.can_administer(actor)
  if not ok then
    if actor == player_name then
      return false, "self_escalation_denied"
    end
    return false, reason
  end
  return true
end

return permissions
