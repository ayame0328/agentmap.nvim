-- Opening the map right after a prompt, before its first Agent call, shows the whole session
-- (no flow yet). When the first Agent starts, that flow is adopted quietly: it is not a "new flow",
-- so neither "A new flow has started" nor "Switched to a new prompt" is shown.
-- (Found in the final check before v0.1.0: :AgentMap opened a second after typing the prompt
--  produced both notices although the run had only one prompt.)
local t = require("t")
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture missing"); t.done() end
local af = require("agentmap")
require("agentmap.config").get().poll_ms = 200
require("agentmap.config").get().debounce_ms = 50

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local proj = root .. "/projects/" .. slug
vim.fn.mkdir(proj, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, proj .. "/project.json")

local A = "aaaaaaaa-0000-0000-0000-000000000001"
local function make_run(upto)
  local out = {}
  for i = 1, upto do
    local d = vim.json.decode(lines[i]); d.session_id = A
    out[#out + 1] = vim.json.encode(d)
  end
  vim.fn.mkdir(proj .. "/runs/" .. A, "p")
  vim.fn.writefile(out, proj .. "/runs/" .. A .. "/hooks.jsonl")
end

-- 1. SessionStart + UserPromptSubmit only: the prompt exists, no Agent yet
make_run(2)
af.open(nil, { follow = true })
local ui = require("agentmap.ui")
t.eq(ui.run and ui.run.sid, A, "opened the run")
t.eq(ui.flow_id, nil, "no flow with agents yet: session view")
local header = vim.api.nvim_buf_get_lines(ui.buf, 0, 1, false)[1] or ""
t.ok(not header:find("prompt 1/1", 1, true), "header has no prompt segment in the session view")

-- 2. The first Agent starts (and more): the flow is adopted without a notice
make_run(9)
vim.wait(3000, function() return ui.flow_id ~= nil end, 50)
vim.wait(300)
local st = require("agentmap.state")
t.eq(ui.flow_id, st.latest_flow_id(ui.run.state), "the first flow was adopted")
header = vim.api.nvim_buf_get_lines(ui.buf, 0, 1, false)[1] or ""
t.ok(header:find("prompt 1/1", 1, true) ~= nil, "header now shows prompt 1/1: " .. header)
t.ok(not vim.iter(notes):any(function(m) return m:find("A new flow has started", 1, true) end),
  "no 'new flow' notice: " .. table.concat(notes, " | "))
t.ok(not vim.iter(notes):any(function(m) return m:find("Switched to a new prompt", 1, true) end),
  "no 'switched' notice: " .. table.concat(notes, " | "))
-- (switching between two real prompts, with its notice, is covered by test_follow.lua / test_flows.lua)

t.done()
