-- ============================================================
--  test_backfill.lua -- rebuilding a run from Claude Code transcripts when there are no hooks
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_backfill.lua
--  Claude のフォルダは fixtures/claude_config（合成した probe：ROOT → 子 → 孫、履歴だけの session、
--  Workflow の session）を一時フォルダに写したものを使う。本物の ~/.claude などは読まない。
--  写した Claude のフォルダは読むだけ（前後で中身と更新時刻を比べる）。書き込むのは一時の保存先だけ。
-- ============================================================
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
local cfg = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(cfg)

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
vim.env.AGENTMAP_DIR = TMP .. "/store"

local fails, passes = 0, 0
local function ok(c, msg)
  if c then passes = passes + 1 print("  ok   " .. msg) else fails = fails + 1 print("  FAIL " .. msg) end
end
local function eq(a, b, msg) ok(a == b, msg .. (a == b and "" or ("  (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")"))) end

local SID = "c0ffee01-0000-4000-8000-000000000001"
local HIST = "0a1b2c3d-0000-4000-8000-000000000001"
local CHILD, GRAND = "afeed000000000006", "afeed000000000007"
local slug = "-home-user-work-demo"

-- fixtures/claude_config を一時フォルダへ写す（更新時刻を決めるため。git は更新時刻を残さない）
local cdir = TMP .. "/claude"
local function copy_tree(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, typ in vim.fs.dir(src) do
    if typ == "directory" then
      copy_tree(src .. "/" .. name, dst .. "/" .. name)
    else
      vim.fn.writefile(vim.fn.readfile(src .. "/" .. name, "b"), dst .. "/" .. name, "b")
    end
  end
end
copy_tree(here .. "/fixtures/claude_config", cdir)
-- probe の session を新しく、履歴だけの session を古くする（list_sessions は新しい順）
local now = os.time()
vim.uv.fs_utime(cdir .. "/projects/" .. slug .. "/" .. HIST .. ".jsonl", now - 86400, now - 86400)
vim.uv.fs_utime(cdir .. "/projects/" .. slug .. "/" .. SID .. ".jsonl", now - 60, now - 60)

require("agentmap.config").setup({ claude_config_dir = cdir })
local claude = require("agentmap.providers.claude")
local state = require("agentmap.state")
local events = require("agentmap.events")
local uv = vim.uv

-- Claude のフォルダに何も書かないことの確認用（前後で中身と更新時刻を比べる）
local function snapshot(dir)
  local out = {}
  for _, p in ipairs(vim.fn.glob(dir .. "/**", true, true)) do
    local st = uv.fs_stat(p)
    out[#out + 1] = p .. "|" .. (st and (st.size .. ":" .. st.mtime.sec .. "." .. st.mtime.nsec) or "?")
  end
  table.sort(out)
  return table.concat(out, "\n")
end
local pdir = cdir .. "/projects/" .. slug
local before = snapshot(pdir)

print("[1] backfill the synthetic probe session (ROOT -> child -> grandchild)")
local t0 = uv.hrtime()
local evs = claude.backfill(SID, slug)
local ms = (uv.hrtime() - t0) / 1e6
ok(#evs > 0, "backfill returned " .. #evs .. " events in " .. string.format("%.1f", ms) .. "ms")
local all_tr = true
for _, ev in ipairs(evs) do if ev.src ~= "transcript" or ev.v ~= 1 or ev.run_id ~= SID then all_tr = false end end
ok(all_tr, "all events src=transcript, v=1, run_id")
local s = state.reduce(evs)
local c, g = s.agents[CHILD], s.agents[GRAND]
ok(c and g, "child and grandchild exist")
eq(c and c.parent_id, "ROOT", "child parent = ROOT (ROOT transcript's Agent call returned it)")
eq(g and g.parent_id, CHILD, "grandchild parent = child (child transcript's Agent call returned it)")
eq(c and c.index, 1, "child [1]")
eq(g and g.index, 2, "grandchild [2]")
eq(c and c.status, "DONE", "child DONE")
eq(g and g.status, "DONE", "grandchild DONE")
eq(g and g.last_head, "GRAND", "grandchild last_head")
eq(s.agents.ROOT.model, "claude-haiku-4-5-20251001", "ROOT model from transcript")
eq(c and c.model, "claude-haiku-4-5-20251001", "child model")
eq(s.agents.ROOT.branch, "master", "ROOT branch from gitBranch")
eq(s.agents.ROOT.last_head, "PARENT-DONE", "ROOT last text")
ok(s.title and s.title:find("Use the Agent tool", 1, true) == 1, "title from first user prompt")
eq(s.counts.unknown_parent, 0, "no UNKNOWN_PARENT")
eq(s.counts.agents, 2, "exactly 2 agents (placeholders merged)")
eq(state.progress(s, "ROOT").pct, 100, "ROOT progress 100")
ok(c and type(c.batch) == "string" and c.batch:find("^msg_") ~= nil, "child batch = message.id of the parent's Agent call")
ok(g and type(g.batch) == "string" and g.batch ~= c.batch, "grandchild batch from the child's own transcript")
local bi = claude.agent_batches(cdir .. "/projects/" .. slug .. "/" .. SID .. ".jsonl")
ok(c and bi.map[c.tool_use_id] == c.batch, "agent_batches (hooks runs) agrees with backfill")

print("[2] helpers on transcript files")
eq(claude.root_model(cdir .. "/projects/" .. slug .. "/" .. SID .. ".jsonl"), "claude-haiku-4-5-20251001", "root_model")
eq(claude.root_model("/nonexistent/x.jsonl"), nil, "root_model unreadable -> nil")
local run = { sid = SID, slug = slug, state = s }
local tp = claude.agent_transcript_path(run, g)
ok(tp and tp:find("agent%-" .. GRAND .. "%.jsonl$") ~= nil, "agent_transcript_path")
local meta = claude.read_meta(run, GRAND)
eq(meta and meta.parentAgentId, CHILD, "read_meta parentAgentId")
local ents = claude.transcript_entries(cdir .. "/projects/" .. slug .. "/" .. SID .. ".jsonl", {})
local kinds = {}
for _, e in ipairs(ents) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
ok(kinds.user and kinds.assistant and kinds.tool_use and kinds.tool_result and kinds.thinking,
  "transcript_entries kinds: " .. vim.inspect(kinds):gsub("%s+", " "))
local small = claude.transcript_entries(cdir .. "/projects/" .. slug .. "/" .. SID .. ".jsonl", { max_bytes = 2000 })
eq(small[1] and small[1].kind, "notice", "max_bytes -> notice first")
local sess = claude.list_sessions(slug)
ok(#sess >= 1 and sess[1].session_id == SID, "list_sessions")

print("[3] import into temp store (events.jsonl written once)")
local r1 = events.import_transcript(SID, slug)
ok(r1 and r1.source == "transcript", "import_transcript -> source transcript")
eq(r1 and r1.state.agents[GRAND].parent_id, CHILD, "imported state exact")
local size1 = uv.fs_stat(r1.dir .. "/events.jsonl").size
local r2 = events.open_run(SID)
eq(uv.fs_stat(r2.dir .. "/events.jsonl").size, size1, "second open does not re-import")
ok(r1.dir:sub(1, #TMP) == TMP, "store under temp AGENTMAP_DIR")
local list = events.list_runs()
local found_tr, hist_src = false, nil
for _, x in ipairs(list) do
  if x.sid == SID and x.source == "transcript" then found_tr = true end
  if x.sid == HIST then hist_src = x.source end
end
ok(found_tr, "list_runs shows imported run")
-- 保存する値は言語に依らない符号（DESIGN S9 / §5.3）："history"
eq(hist_src, "history", "list_runs shows the transcript-only session with source = \"history\"")

print("[4] a workflow session (subagents/workflows/**) backfills without error")
local wslug, wsid = "-home-user-work-flows", "9f8e7d6c-0000-4000-8000-000000000002"
local wbefore = snapshot(cdir .. "/projects/" .. wslug)
t0 = uv.hrtime()
local wevs = claude.backfill(wsid, wslug)
local ws = state.reduce(wevs)
ms = (uv.hrtime() - t0) / 1e6
eq(ws.counts.agents, 3, string.format("workflow session: 3 agents (%.0fms)", ms))
eq(ws.counts.unknown_parent, 0, "workflow session: every agent has a parent (Workflow node or ROOT)")
local W = ws.agents["wf:wf_5e1f0a2b-c3d"]
ok(W and W.kind == "workflow" and W.parent_id == "ROOT", "workflow node under ROOT")
eq(ws.agents.aw1 and ws.agents.aw1.parent_id, "wf:wf_5e1f0a2b-c3d", "workflow agent under the workflow node")
eq(ws.agents.aw3 and ws.agents.aw3.phase, "summary", "workflowPhase from meta.json")
eq(ws.agents.aw2 and ws.agents.aw2.task, "review:store", "task from meta.json description")
eq(snapshot(cdir .. "/projects/" .. wslug), wbefore, "workflow session files untouched")

eq(snapshot(pdir), before, "Claude project folder untouched (read-only)")
vim.fn.delete(TMP, "rf")
print(string.format("%d passed, %d failed", passes, fails))
print(fails == 0 and "PASS test_backfill.lua" or "FAIL test_backfill.lua")
if fails > 0 then os.exit(1) end
