-- 新しい実行（run）が始まったときの切り替えの試験。
--   Space a a（最新を開く）で開いていたら、動いている途中でも新しい run に切り替える。
--   一覧から選んだ・ID を指定して開いた run は切り替えず、知らせるだけ。
local t = require("t")
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture が無い"); t.done() end
local af = require("agentmap")
require("agentmap.config").get().poll_ms = 200
require("agentmap.config").get().switch_delay_ms = 1500   -- 試験なので短く     -- 試験なので見に行く間隔を短く
require("agentmap.config").get().debounce_ms = 50

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local proj = root .. "/projects/" .. slug
vim.fn.mkdir(proj, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, proj .. "/project.json")

local util = require("agentmap.util")
--- 時刻を dt 秒ずらす
local function shift(ts, dt)
  local sec = util.parse_iso(ts) + dt
  local whole = math.floor(sec)
  return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. (".%03dZ"):format(math.floor((sec - whole) * 1000 + 0.5))
end

--- session_id を差し替えた run を作る。upto 行目まで（既定は 9 行目＝子はまだ動いている）。dt 秒あとの出来事にする
local function make_run(sid, dt, upto)
  local out = {}
  for i = 1, upto or 9 do
    local d = vim.json.decode(lines[i]); d.session_id = sid
    if d._ts then d._ts = shift(d._ts, dt or 0) end
    out[#out + 1] = vim.json.encode(d)
  end
  vim.fn.mkdir(proj .. "/runs/" .. sid, "p")
  vim.fn.writefile(out, proj .. "/runs/" .. sid .. "/hooks.jsonl")
end

local A = "aaaaaaaa-0000-0000-0000-000000000001"
local B = "bbbbbbbb-0000-0000-0000-000000000002"
local C = "cccccccc-0000-0000-0000-000000000003"
make_run(A)

-- 1. 最新を追う開き方：動いている途中でも切り替わる
af.open(A, { follow = true })
local ui = require("agentmap.ui")
t.eq(ui.run and ui.run.sid, A, "A を開いた")
t.ok(af._following(), "最新を追う状態")
t.eq(ui.run.state.agents["afeed000000000006"].status, "RUNNING", "A の子はまだ動いている")
make_run(B, 60)
vim.wait(2500, function() return #notes > 0 end, 50)
vim.wait(300)
t.eq(ui.run and ui.run.sid, A, "A が動いている間は B に切り替えない")
t.ok(vim.iter(notes):any(function(m) return m:find("Switching once the current flow finishes", 1, true) end), "新しい run があることは知らせた")
make_run(A, 0, #lines)   -- A が最後まで終わる
vim.wait(5000, function() return ui.run and ui.run.sid == B end, 50)
t.eq(ui.run and ui.run.sid, B, "A が終わったら新しい run B に自動で切り替わった")
t.ok(af._following(), "切り替えたあとも追い続ける")
t.ok(vim.iter(notes):any(function(m) return m:find("Switched to a new run", 1, true) end), "切り替えたことを知らせた")

-- 2. ID を指定して開いた（＝わざわざこの run を見ている）ときは切り替えない
notes = {}
af.open(B)
t.ok(not af._following(), "ID 指定で開いたら固定")
make_run(C, 120)
vim.wait(2500, function() return #notes > 0 end, 50)
vim.wait(300)
t.eq(ui.run and ui.run.sid, B, "固定なので B のまま")
t.ok(vim.iter(notes):any(function(m) return m:find("A new run has started", 1, true) end), "新しい run があることは知らせた")

-- 3. 引数なしの :AgentMap は追う側に戻る
af.open(nil, { follow = true })
t.ok(af._following(), "Space a a（最新を開く）は追う")

t.done()
