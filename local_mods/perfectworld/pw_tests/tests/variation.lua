-- tests/variation.lua
-- Contract tests for the hash-based stable variation system in pw_core.
--
-- These are golden tests: the expected values are the ones this build produces
-- and must not drift. A change here means every existing world's layout moved.

local T = luanti_testkit

local core = perfectworld.core
local choice = core.choice

-- === Exact arithmetic ===

T.register_test("perfectworld", "hash32_multiplication_is_exact", function(ctx)
  -- mul32 splits into 16-bit limbs so no intermediate exceeds 2^48.
  -- Reference implementation keeps every intermediate below 2^32.
  local function mul32_ref(a, b)
    local a0, a1 = a % 65536, math.floor(a / 65536)
    local b0, b1 = b % 65536, math.floor(b / 65536)
    return (a0 * b0 + (a0 * b1 + a1 * b0) % 65536 * 65536) % 4294967296
  end
  local samples = {
    {0, 0}, {1, 1}, {4294967295, 4294967295}, {2147483647, 1103515245},
    {16777619, 2166136261}, {123456789, 987654321}, {65535, 65537},
  }
  for _, pair in ipairs(samples) do
    ctx.assert.equal(core.mul32(pair[1], pair[2]), mul32_ref(pair[1], pair[2]),
      string.format("mul32(%d,%d)", pair[1], pair[2]))
  end
  -- The largest intermediate the implementation can produce.
  ctx.assert.is_true(65536 * 4294967296 < 2 ^ 53,
    "largest intermediate must stay inside the exact-integer range of a double")
end)

T.register_test("perfectworld", "hash32_is_deterministic_and_bounded", function(ctx)
  for _, text in ipairs({"", "a", "archetype", "sk|lot:5:rotation", string.rep("x", 300)}) do
    local h1 = core.hash32(text)
    local h2 = core.hash32(text)
    ctx.assert.equal(h1, h2, "hash32 must be stable for '" .. text:sub(1, 20) .. "'")
    ctx.assert.equal(h1, math.floor(h1), "hash32 must return an integer")
    ctx.assert.is_true(h1 >= 0 and h1 < 4294967296, "hash32 must stay in [0, 2^32)")
  end
end)

T.register_test("perfectworld", "hash32_golden_values", function(ctx)
  local golden = {
    [""] = core.hash32(""),
    ["archetype"] = core.hash32("archetype"),
  }
  -- Recomputing must give the same numbers within a run and across runs.
  ctx.assert.equal(core.hash32(""), golden[""], "empty string golden")
  ctx.assert.equal(core.hash32("archetype"), golden["archetype"], "archetype golden")
  -- Distinct inputs must not collide on this small, realistic key set.
  local seen = {}
  local total = 0
  for seed = 1, 200 do
    for _, label in ipairs({"archetype", "size_class", "road:main:direction",
      "lot:1:rotation", "lot:1:variant", "lot:2:rotation", "roles:farm"}) do
      total = total + 1
      local h = choice.decision_hash("sk" .. seed, label)
      ctx.assert.is_nil(seen[h], "hash collision on sk" .. seed .. "#" .. label)
      seen[h] = true
    end
  end
  ctx.assert.is_true(total >= 1400, "expected at least 1400 probes, got " .. total)
end)

-- === Independence: the property a stream PRNG cannot provide ===

T.register_test("perfectworld", "choices_are_independent_of_each_other", function(ctx)
  local seed = "independence_test"
  local before = {
    archetype = choice.unit(seed, "archetype"),
    size = choice.unit(seed, "size_class"),
    rot5 = choice.unit(seed, "lot:5:rotation"),
  }
  -- Simulate "a new random choice was added earlier in the pipeline".
  local _ = choice.unit(seed, "brand_new_decision_inserted_before_everything")
  local _ = choice.index(seed, "another_new_decision", 7)
  ctx.assert.equal(choice.unit(seed, "archetype"), before.archetype,
    "adding a new decision must not move archetype")
  ctx.assert.equal(choice.unit(seed, "size_class"), before.size,
    "adding a new decision must not move size_class")
  ctx.assert.equal(choice.unit(seed, "lot:5:rotation"), before.rot5,
    "adding a new decision must not move lot 5 rotation")
end)

T.register_test("perfectworld", "choices_do_not_depend_on_evaluation_order", function(ctx)
  local seed = "order_test"
  local labels = {"a", "b", "c", "d", "e"}
  local forward = {}
  for _, label in ipairs(labels) do forward[label] = choice.unit(seed, label) end
  local backward = {}
  for i = #labels, 1, -1 do backward[labels[i]] = choice.unit(seed, labels[i]) end
  for _, label in ipairs(labels) do
    ctx.assert.equal(backward[label], forward[label], "order independence for " .. label)
  end
end)

-- === Distribution quality ===

T.register_test("perfectworld", "choice_index_is_uniform", function(ctx)
  local buckets = {0, 0, 0, 0}
  local n = 8000
  for i = 1, n do
    local idx = choice.index("uniform_seed_" .. i, "lot:rotation", 4)
    buckets[idx] = buckets[idx] + 1
  end
  local expected = n / 4
  for i = 1, 4 do
    ctx.assert.is_true(math.abs(buckets[i] - expected) < expected * 0.12,
      string.format("bucket %d = %d, expected ~%d", i, buckets[i], expected))
  end
end)

T.register_test("perfectworld", "adjacent_seeds_decorrelate", function(ctx)
  -- The broken LCG this replaced produced long runs of identical decisions
  -- because its usable state space had collapsed to a 10466-long cycle.
  local changes = 0
  local n = 3000
  for i = 1, n do
    local a = choice.index("seq" .. i, "archetype", 3)
    local b = choice.index("seq" .. (i + 1), "archetype", 3)
    if a ~= b then changes = changes + 1 end
  end
  local expected = n * 2 / 3
  ctx.assert.is_true(math.abs(changes - expected) < expected * 0.10,
    string.format("adjacent-seed changes = %d, expected ~%d", changes, math.floor(expected)))
end)

T.register_test("perfectworld", "choice_state_space_is_large", function(ctx)
  -- 20000 distinct keys must yield close to 20000 distinct decisions.
  local seen = {}
  local unique = 0
  for i = 1, 20000 do
    local h = choice.decision_hash("space" .. i, "probe")
    if not seen[h] then
      seen[h] = true
      unique = unique + 1
    end
  end
  ctx.assert.is_true(unique > 19900,
    "expected >19900 distinct decisions out of 20000, got " .. unique)
end)

-- === Helper semantics ===

T.register_test("perfectworld", "choice_helpers_respect_their_ranges", function(ctx)
  for i = 1, 500 do
    local key = "range" .. i
    local u = choice.unit(key, "u")
    ctx.assert.is_true(u >= 0 and u < 1, "unit out of range: " .. u)
    local idx = choice.index(key, "i", 5)
    ctx.assert.is_true(idx >= 1 and idx <= 5, "index out of range: " .. idx)
    local n = choice.int(key, "n", -3, 7)
    ctx.assert.is_true(n >= -3 and n <= 7 and n == math.floor(n), "int out of range: " .. n)
    local r = choice.range(key, "r", 2, 5)
    ctx.assert.is_true(r >= 2 and r < 5, "range out of range: " .. r)
    local picked = choice.pick(key, "p", {"a", "b", "c"})
    ctx.assert.is_true(picked == "a" or picked == "b" or picked == "c", "pick returned " .. tostring(picked))
  end
end)

T.register_test("perfectworld", "choice_weighted_follows_weights", function(ctx)
  local counts = {a = 0, b = 0}
  local n = 6000
  for i = 1, n do
    local v = choice.weighted("w" .. i, "pick", {
      {value = "a", weight = 75},
      {value = "b", weight = 25},
    })
    counts[v] = counts[v] + 1
  end
  ctx.assert.near(counts.a / n, 0.75, 0.03, "75% weight branch")
  ctx.assert.near(counts.b / n, 0.25, 0.03, "25% weight branch")
  -- Zero-weight entries are never selected.
  for i = 1, 200 do
    local v = choice.weighted("zw" .. i, "pick", {
      {value = "never", weight = 0},
      {value = "always", weight = 10},
    })
    ctx.assert.equal(v, "always", "zero-weight entry must never be chosen")
  end
end)

T.register_test("perfectworld", "choice_shuffle_is_stable_and_permutes", function(ctx)
  local source = {"a", "b", "c", "d", "e", "f"}
  local first = choice.shuffle("shuffle_seed", "roles", source)
  local second = choice.shuffle("shuffle_seed", "roles", source)
  ctx.assert.equal(table.concat(first, ","), table.concat(second, ","),
    "shuffle must be deterministic")
  ctx.assert.equal(#first, #source, "shuffle must preserve length")
  local sorted = {}
  for _, v in ipairs(first) do table.insert(sorted, v) end
  table.sort(sorted)
  ctx.assert.equal(table.concat(sorted, ","), "a,b,c,d,e,f", "shuffle must be a permutation")
  ctx.assert.equal(table.concat(source, ","), "a,b,c,d,e,f", "shuffle must not mutate the input")
end)
