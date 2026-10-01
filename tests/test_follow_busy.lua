-- 見ている流れにまだ動いているエージェントがいる間は、別の流れへ自動で切り替えない試験。
--   別のセッションで新しい流れが始まっても、見ている流れが終わるまでは知らせるだけ。
--   終わったら最新へ切り替わる。
local t = require("t")
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture が無い"); t.done() end
local af = require("agentmap")
require("agentmap.config").get().poll_ms = 200
require("agentmap.config").get().switch_delay_ms = 1500   -- 試験なので短く
require("agentmap.config").get().debounce_ms = 50
local root = vim.env.AGENTMAP_DIR
local lines = vim.fn.readfile(fixture)

--- 別のプロジェクトとして run を作る。upto 行目まで書く
local util = require("agentmap.util")
local function shift(ts, dt)
  local sec = util.parse_iso(ts) + dt
  local whole = math.floor(sec)
  return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. (".%03dZ"):format(math.floor((sec - whole) * 1000 + 0.5))
end

local function make_run(sid, slug, upto, dt)
  local proj = root .. "/projects/" .. slug
  vim.fn.mkdir(proj .. "/runs/" .. sid, "p")
  vim.fn.writefile({ vim.json.encode({ cwd = "/tmp/" .. slug, slug = slug }) }, proj .. "/project.json")
  local out = {}
  for i = 1, upto do
    local d = vim.json.decode(lines[i])
    d.session_id = sid
    d.cwd = "/tmp/" .. slug
    d.transcript_path = "/x/projects/" .. slug .. "/" .. sid .. ".jsonl"
    if d._ts then d._ts = shift(d._ts, dt or 0) end
    out[#out + 1] = vim.json.encode(d)
  end
  vim.fn.writefile(out, proj .. "/runs/" .. sid .. "/hooks.jsonl")
end

local A, B = "aaaaaaaa-1111-0000-0000-000000000001", "bbbbbbbb-2222-0000-0000-000000000002"
make_run(A, "-tmp-projA", 9)          -- 子はまだ動いている
af.open(nil, { follow = true })
local ui = require("agentmap.ui")
t.eq(ui.run and ui.run.sid, A, "A（動いている）を開いた")

vim.wait(400)
make_run(B, "-tmp-projB", 9, 60)          -- 別のプロジェクトで新しい流れ
vim.wait(2500, function() return #notes > 0 end, 50)
vim.wait(500)
t.eq(ui.run and ui.run.sid, A, "A が動いている間は B に切り替えない")
t.ok(vim.iter(notes):any(function(m) return m:find("Switching once the current flow finishes", 1, true) end), "新しい流れがあることは知らせた")

-- A を最後まで書く（子も孫も終わり、ターンも終わる）
make_run(A, "-tmp-projA", #lines)
vim.wait(800)
t.eq(ui.run and ui.run.sid, A, "全部終わった直後は、まだ A のまま（終わった様子を見せる）")
vim.wait(6000, function() return ui.run and ui.run.sid == B end, 50)
t.eq(ui.run and ui.run.sid, B, "A が終わったら最新の B に切り替わった")

t.done()
