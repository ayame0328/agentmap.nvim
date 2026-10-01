-- Tiny assertion helper for the test suite (no external test framework).
--   local t = require("t")   -- tests/minimal_init.lua puts tests/ on package.path
--   t.eq(actual, expected, "what")   deep equality (vim.deep_equal)
--   t.ok(cond, "what")               truthy
--   t.matches(str, lua_pattern, "what")
--   t.run("what", fn)                calls fn; an error counts as one failure
--   t.skip("why")                    prints a SKIP line (not counted)
--   t.done()                         prints the counts and exits 1 if anything failed
local T = { passed = 0, failed = 0, name = "" }

local function fail(msg)
  T.failed = T.failed + 1
  io.stderr:write("  NG: " .. msg .. "\n")
end

local function pass()
  T.passed = T.passed + 1
end

function T.eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then return pass() end
  fail(("%s\n      expected: %s\n      actual:   %s"):format(msg or "eq", vim.inspect(expected), vim.inspect(actual)))
end

function T.ok(v, msg)
  if v then return pass() end
  fail(msg or "ok")
end

function T.matches(s, pat, msg)
  if type(s) == "string" and s:find(pat) then return pass() end
  fail(("%s\n      pattern: %s\n      string:  %s"):format(msg or "matches", pat, tostring(s):sub(1, 400)))
end

--- Run fn; an error is counted as a failure (with traceback). Returns true on success.
function T.run(msg, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then fail(msg .. " raised an error: " .. tostring(err)) end
  return ok
end

function T.skip(msg)
  io.stdout:write("  SKIP: " .. msg .. "\n")
end

--- Call last. Exit code 1 if any check failed.
function T.done()
  io.stdout:write(("  %d ok, %d NG\n"):format(T.passed, T.failed))
  io.stdout:flush()
  os.exit(T.failed == 0 and 0 or 1)
end

return T
