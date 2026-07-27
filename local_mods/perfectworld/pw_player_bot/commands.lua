-- pw_player_bot/commands.lua
--
-- Administrative commands. They reuse the bridge's privilege rather than
-- inventing a second one: anyone trusted to grant a bot its senses is trusted
-- to switch its brain on, and a separate privilege would only be a second thing
-- to forget to check.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local brain = P.impl.brain
local memory = P.impl.memory
local navigation = P.impl.navigation

local ADMIN = {[bridge.ADMIN_PRIV] = true}

local function lines(rows)
  return table.concat(rows, "\n")
end

--- Write a full document to a runtime artifact, and hand back the file name
--- only. A server filesystem layout is not something to print into chat.
local function write_report(kind, value)
  local stamp = os.date("!%Y%m%d_%H%M%S")
  local file_name = string.format("pw_player_bot_%s_%s.json", kind, stamp)
  local path = minetest.get_worldpath() .. "/" .. file_name
  local ok = pcall(minetest.safe_file_write, path, canonical.encode(value))
  if not ok then return nil end
  return file_name
end

P.impl.write_report = write_report

function P.impl.write_intent_artifact(document)
  return write_report("intent", document)
end

local function test_player_name()
  return minetest.settings:get("perfectworld.test_player") or "pwbot"
end

minetest.register_chatcommand("pw_player_bot_status", {
  params = "[player]",
  description = "Show what the bot knows, wants and has decided",
  privs = ADMIN,
  func = function(_, param)
    local target = param:match("^(%S+)$")
    if not target then
      local names = P.list()
      if #names == 0 then return true, "no bot is thinking" end
      local rows = {string.format("thinking for %d bot(s), tick=%.2fs profile=%s",
        #names, settings.tick_interval, settings.observation_profile)}
      for _, name in ipairs(names) do
        local status = P.get_status(name)
        rows[#rows + 1] = string.format("  %s ticks=%d cells=%d features=%d goal=%s",
          name, status.ticks, status.memory.cells, status.memory.features,
          status.last_intent ~= canonical.NULL and status.last_intent.goal or "-")
      end
      return true, lines(rows)
    end

    local status = P.get_status(target)
    if not status then return false, target .. " is not thinking" end
    local rows = {
      string.format("%s thinking=%s ticks=%d last_tick=%dus",
        target, tostring(status.thinking), status.ticks, status.last_elapsed_us),
      string.format("memory cells=%d features=%d entities=%d visited=%d contradictions=%d",
        status.memory.cells, status.memory.features, status.memory.entities,
        status.memory.visited, status.memory.stats.contradictions),
    }
    if status.beliefs ~= canonical.NULL then
      rows[#rows + 1] = string.format("beliefs traversable=%d frontier=%d hazards=%d water=%d",
        status.beliefs.traversable_cells, status.beliefs.frontier_cells,
        status.beliefs.hazard_cells, status.beliefs.water_cells)
    end
    if status.drives ~= canonical.NULL then
      local parts = {}
      for _, name in ipairs(P.impl.needs.NAMES) do
        parts[#parts + 1] = string.format("%s=%.2f", name, status.drives[name] or 0)
      end
      rows[#rows + 1] = "drives " .. table.concat(parts, " ")
    end
    if status.last_intent ~= canonical.NULL then
      rows[#rows + 1] = string.format("intent %s goal=%s score=%.2f route=%d age=%d",
        status.last_intent.intent_id, status.last_intent.goal,
        status.last_intent.score, status.last_intent.route_length, status.intent_age)
    end
    rows[#rows + 1] = string.format("stuck=%d failed_routes=%d observation_failures=%d",
      status.history.stuck_ticks, status.history.failed_routes,
      status.stats.observation_failures)
    if status.last_error ~= canonical.NULL then
      rows[#rows + 1] = "last_error=" .. tostring(status.last_error)
    end
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_player_bot_start", {
  params = "<player>",
  description = "Start thinking for a bot already registered with pw_bot_bridge",
  privs = ADMIN,
  func = function(name, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_player_bot_start <player>" end
    local mind, code, reason = P.start(target, name)
    if not mind then
      return false, string.format("refused: %s (%s)", tostring(code), tostring(reason))
    end
    return true, string.format("thinking for %s, memory has %d cells",
      target, mind.memory.cell_count)
  end,
})

minetest.register_chatcommand("pw_player_bot_stop", {
  params = "<player>",
  description = "Stop thinking for a bot and save its memory",
  privs = ADMIN,
  func = function(name, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_player_bot_stop <player>" end
    local ok, code = P.stop(target, name)
    if not ok then return false, "refused: " .. tostring(code) end
    return true, "stopped and saved " .. target
  end,
})

minetest.register_chatcommand("pw_player_bot_think", {
  params = "<player>",
  description = "Run one decision now and summarise it",
  privs = ADMIN,
  func = function(name, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_player_bot_think <player>" end
    local document, info, detail = P.think(target, name)
    if not document then
      return false, string.format("refused: %s (%s)", tostring(info), tostring(detail))
    end
    local file_name = write_report("intent", document)
    local rows = {
      string.format("goal=%s score=%.2f route=%d steps=%d",
        document.goal.kind, document.goal.score,
        document.plan.route_length, #(document.plan.steps == canonical.EMPTY_ARRAY and {} or document.plan.steps)),
    }
    if type(info) == "table" and info.drives then
      local parts = {}
      for _, need in ipairs(P.impl.needs.NAMES) do
        parts[#parts + 1] = string.format("%s=%.2f", need, info.drives[need] or 0)
      end
      rows[#rows + 1] = "drives " .. table.concat(parts, " ")
    end
    if type(info) == "table" and info.reused then
      rows[#rows + 1] = "intent reused, age=" .. tostring(info.age)
    end
    if type(info) == "table" and info.rejected and #info.rejected > 0 then
      rows[#rows + 1] = "unplannable: " .. table.concat(info.rejected, ",")
    end
    for index, reason in ipairs(document.rationale == canonical.EMPTY_ARRAY and {} or document.rationale) do
      if index <= 6 then rows[#rows + 1] = "  " .. reason end
    end
    rows[#rows + 1] = file_name and ("intent: " .. file_name) or "intent could not be written"
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_player_bot_explain", {
  params = "<player>",
  description = "Show the full scoring table without deciding anything",
  privs = ADMIN,
  func = function(_, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_player_bot_explain <player>" end
    local explanation, reason = P.explain(target)
    if not explanation then return false, "unavailable: " .. tostring(reason) end
    local file_name = write_report("explain", explanation)
    local rows = {"dominant=" .. explanation.dominant}
    for index, entry in ipairs(explanation.candidates) do
      if index <= 8 then
        rows[#rows + 1] = string.format("  %.3f %s", entry.score, entry.label)
      end
    end
    rows[#rows + 1] = file_name and ("full table: " .. file_name) or "table could not be written"
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_player_bot_route", {
  params = "<player> <x> <y> <z>",
  description = "Plan a route to a position using only what the bot remembers",
  privs = ADMIN,
  func = function(_, param)
    local target, x, y, z = param:match("^(%S+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)$")
    if not target then return false, "Usage: /pw_player_bot_route <player> <x> <y> <z>" end
    local mind = brain.get(target)
    if not mind then return false, target .. " is not thinking" end
    if not mind.memory.last_position then return false, "the bot has no position yet" end
    local route, reason, info = P.plan_route(target,
      mind.memory.last_position, {x = tonumber(x), y = tonumber(y), z = tonumber(z)})
    if not route then
      return true, string.format("no route: %s (expansions=%d)",
        tostring(reason), (info and info.expansions) or 0)
    end
    local simplified = navigation.simplify(route)
    return true, string.format("route %d cells (%d waypoints), expansions=%d, cost=%.1f",
      #route, #simplified, (info and info.expansions) or 0, (info and info.cost) or 0)
  end,
})

minetest.register_chatcommand("pw_player_bot_memory", {
  params = "<player> [forget]",
  description = "Summarise or wipe what a bot has learned",
  privs = ADMIN,
  func = function(name, param)
    local target, action = param:match("^(%S+)%s+(%S+)$")
    if not target then target = param:match("^(%S+)$") end
    if not target then return false, "Usage: /pw_player_bot_memory <player> [forget]" end

    if action == "forget" then
      local ok, code = P.forget(target, name)
      if not ok then return false, "refused: " .. tostring(code) end
      return true, target .. " has forgotten everything"
    end

    local summary = P.get_memory_summary(target)
    if not summary then return false, target .. " is not thinking" end
    local file_name = write_report("memory", summary)
    return true, lines({
      string.format("%s tick=%d cells=%d/%d features=%d/%d entities=%d/%d",
        target, summary.tick, summary.cells, summary.limits.max_cells,
        summary.features, summary.limits.max_features,
        summary.entities, summary.limits.max_entities),
      string.format("visited=%d observations=%d evicted=%d contradictions=%d",
        summary.visited, summary.stats.observations,
        summary.stats.cells_evicted, summary.stats.contradictions),
      file_name and ("full summary: " .. file_name) or "summary could not be written",
    })
  end,
})

minetest.register_chatcommand("pw_player_bot_capabilities", {
  params = "",
  description = "Summarise what the bot brain can do and save the full document",
  privs = ADMIN,
  func = function()
    local doc = P.get_capabilities()
    local file_name = write_report("capabilities", doc)
    return true, lines({
      string.format("capability=%s impl=%s requires bridge=%s in %s mode",
        doc.capability, doc.implementation_version,
        doc.requires.bridge, doc.requires.bridge_mode),
      "goals: " .. table.concat(doc.goal_kinds, ","),
      "needs: " .. table.concat(doc.needs, ","),
      "actions: " .. table.concat(doc.actions, ","),
      file_name and ("full document: " .. file_name) or "document could not be written",
    })
  end,
})

minetest.register_chatcommand("pw_player_bot_transport", {
  params = "<status|start|stop>",
  description = "Control the intent spool an external runtime reads",
  privs = ADMIN,
  func = function(name, param)
    local action = param:match("^(%S+)$") or "status"
    if action == "start" then
      local ok, code, detail = P.start_transport(name)
      if not ok then
        return false, string.format("refused: %s (%s)", tostring(code),
          type(detail) == "table" and table.concat(detail, ",") or tostring(detail))
      end
    elseif action == "stop" then
      local ok, code = P.stop_transport(name)
      if not ok then return false, "refused: " .. tostring(code) end
    elseif action ~= "status" then
      return false, "Usage: /pw_player_bot_transport <status|start|stop>"
    end

    local status = P.get_transport_status()
    local rows = {
      string.format("setting=%s running=%s available=%s poll=%.2fs",
        tostring(status.setting), tostring(status.running),
        tostring(status.available), status.poll_interval),
      "root: " .. status.root,
    }
    if status.missing ~= canonical.EMPTY_ARRAY and #status.missing > 0 then
      rows[#rows + 1] = "missing: " .. table.concat(status.missing, ",")
    end
    return true, lines(rows)
  end,
})

--- The shortcut for the project's own test player: register with the bridge if
--- needed, start thinking, and take one step.
minetest.register_chatcommand("pwbot_brain", {
  params = "[think|status|stop]",
  description = "Brain shortcut for the configured PerfectWorld test player",
  privs = ADMIN,
  func = function(name, param)
    local target = test_player_name()
    local action = param:match("^(%S+)$") or "status"

    if not bridge.get_bot(target) then
      local bot = bridge.register_bot(target, {mode = "player"}, name)
      if not bot then return false, "could not register " .. target .. " with the bridge" end
    end
    if action == "stop" then
      return minetest.registered_chatcommands["pw_player_bot_stop"].func(name, target)
    end
    if not brain.get(target) then
      local mind, code = P.start(target, name)
      if not mind then return false, "could not start: " .. tostring(code) end
    end
    if action == "think" then
      return minetest.registered_chatcommands["pw_player_bot_think"].func(name, target)
    end
    return minetest.registered_chatcommands["pw_player_bot_status"].func(name, target)
  end,
})

minetest.log("action", "[pw_player_bot] commands loaded")
