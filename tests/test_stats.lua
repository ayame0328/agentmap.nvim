-- stats.lua の試験（DESIGN-v0.2 §2.5・§6）。担当 W2
--   一時フォルダに state.json を 3 run 分書いて load：鍵ごとの件数と中央値、目安の落ち方、
--   控え（mtime が同じなら読み直さない）、影運転の記録（log）と答え合わせ（evaluate）。
local t = require("t")
local stats = require("agentmap.stats")
local util = require("agentmap.util")

local root = vim.fn.tempname() .. "-stats"
local NOW = 1790600000
local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end

local function done(id, atype, model, ms, extra)
  local a = { id = id, agent_type = atype, model = model, status = "DONE", elapsed_ms = ms }
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end

local function write_run(sid, agents, mtime)
  local dir = root .. "/projects/-home-user-work/runs/" .. sid
  vim.fn.mkdir(dir, "p")
  local tbl = {}
  for _, a in ipairs(agents) do tbl[a.id] = a end
  util.write_atomic(dir .. "/state.json", vim.json.encode({ v = 1, agents = tbl }))
  if mtime then vim.uv.fs_utime(dir .. "/state.json", mtime, mtime) end
  return dir
end

t.run("family / key", function()
  t.eq(stats.family("claude-opus-4-1-20250805"), "opus", "opus")
  t.eq(stats.family("claude-fable-5-1"), "fable", "fable")
  t.eq(stats.family("haiku-4-5"), "haiku", "haiku")
  t.eq(stats.family("opus"), "opus", "別名はそのまま")
  t.eq(stats.family(nil), "?", "無ければ ?")
  t.eq(stats.key("general-purpose", "claude-opus-5-5"), "general-purpose|opus", "鍵")
  t.eq(stats.key(nil, nil), "?|?", "何も無い鍵")
end)

-- 3 run：general-purpose×opus が 4 件（中央値 = (500+600)/2）、Explore×haiku が 1 件、手順の標本 2 件
write_run("r1", {
  done("a", "general-purpose", "claude-opus-5-5", 400000),
  done("b", "general-purpose", "claude-opus-5-5", 500000),
  done("w", "general-purpose", "claude-opus-5-5", 999999, { kind = "workflow" }),
  done("p", "general-purpose", "claude-opus-5-5", 999999, { placeholder = true }),
  { id = "r", agent_type = "general-purpose", model = "claude-opus-5-5", status = "RUNNING", elapsed_ms = 1 },
}, NOW - 300)
write_run("r2", {
  done("c", "general-purpose", "claude-opus-5-5", 600000),
  done("d", "general-purpose", "opus", 700000),
  done("e", "Explore", "claude-haiku-4-5", 30000, { steps = { listed_at = iso(NOW - 100), items = {
    { n = 1, done_at = iso(NOW - 90) },                          -- 10 s（一覧を出した時刻から）
    { n = 2, started_at = iso(NOW - 80), done_at = iso(NOW - 50) }, -- 30 s
    { n = 3 },
  } } }),
}, NOW - 200)
write_run("r3", {
  done("ROOT", nil, "claude-fable-5-1", 50000, { tasks = { order = { "1" }, items = {
    ["1"] = { id = "1", status = "completed", started_at = iso(NOW - 70), done_at = iso(NOW - 10) }, -- 60 s
  } } }),
}, NOW - 100)

stats.reset()
local S = stats.load(root, { now = NOW })
t.run("load: 鍵ごとの件数と中央値", function()
  t.eq(S.agents["general-purpose|opus"], { n = 4, median_ms = 550000 }, "general-purpose|opus（workflow・placeholder・RUNNING は除く）")
  t.eq(S.agents["Explore|haiku"], { n = 1, median_ms = 30000 }, "Explore|haiku")
  t.eq(S.agents["main|fable"], { n = 1, median_ms = 50000 }, "ROOT は main")
  t.eq(S.agents["general-purpose|*"].n, 4, "種類だけの集計")
  t.eq(S.all.agents, { n = 6, median_ms = 450000 }, "全体（30000 50000 400000 500000 600000 700000）")
  t.eq(S.steps["Explore|haiku"], { n = 2, median_ms = 20000 }, "手順（10 s と 30 s）")
  t.eq(S.steps["main|fable"], { n = 1, median_ms = 60000 }, "TaskCreate の手順")
  t.eq(S.all.steps.n, 3, "手順の標本 3 件")
  t.eq(vim.tbl_count(S.runs), 3, "読んだ run は 3 つ")
  t.eq(stats._reads, 3, "state.json を 3 回読んだ")
  t.ok(vim.uv.fs_stat(root .. "/stats.json") ~= nil, "控え stats.json を書いた")
end)

t.run("expected_ms / step_ms の落ち方", function()
  local cfg = { default_ms = 600000, min_samples = 3 }
  t.eq({ stats.expected_ms(S, "general-purpose", "claude-opus-5-5", cfg) }, { 550000, "type+model", 4 }, "種類＋モデル")
  t.eq({ stats.expected_ms(S, "general-purpose", "claude-sonnet-4-5", cfg) }, { 550000, "type", 4 }, "モデルが違えば種類だけ")
  t.eq({ stats.expected_ms(S, "Explore", "claude-haiku-4-5", cfg) }, { 450000, "all", 6 }, "件数が足りなければ全体")
  t.eq({ stats.expected_ms(nil, "Explore", "x", cfg) }, { 600000, "default", 0 }, "記録が無ければ既定")
  t.eq({ stats.expected_ms(S, "x", "y", { default_ms = 1000, min_samples = 10 }) }, { 1000, "default", 0 }, "min_samples を満たさなければ既定")
  t.eq({ stats.step_ms(S, "general-purpose", "claude-opus-5-5", 5, cfg) }, { 110000, "type+model", 4 }, "手順の記録が無ければ Agent の中央値 ÷ 手順数")
  t.eq({ stats.step_ms(S, "Explore", "claude-haiku-4-5", 3, { default_ms = 600000, min_samples = 2 }) },
    { 20000, "type+model", 2 }, "手順の中央値があればそれ")
  t.eq({ stats.step_ms(S, "Plan", "claude-haiku-4-5", 3, { default_ms = 600000, min_samples = 3 }) },
    { 30000, "all", 3 }, "全体の手順の中央値（10 s・30 s・60 s → 30 s）")
end)

t.run("2 回目の load は控えを使う", function()
  local before = stats._reads
  local S2 = stats.load(root, { now = NOW + 10 })
  t.eq(stats._reads, before, "recheck_s の間は一覧も見ない")
  t.ok(S2 == S, "同じ表")
  local S3 = stats.load(root, { now = NOW + 120 })
  t.eq(stats._reads, before, "mtime が同じなら読み直さない")
  t.eq(S3.agents["general-purpose|opus"].n, 4, "中身は同じ")
  -- 新しい Neovim（メモリの控え無し）でも stats.json から読み直さずに済む
  stats.reset()
  local S4 = stats.load(root, { now = NOW })
  t.eq(stats._reads, 0, "stats.json の控えがあれば state.json を読まない")
  t.eq(S4.agents["general-purpose|opus"].n, 4, "控えから復元")
  -- 1 つ書き換えると、その run だけ読み直す
  write_run("r1", { done("a", "general-purpose", "claude-opus-5-5", 400000) }, NOW - 5)
  local S5 = stats.load(root, { now = NOW + 1000 })
  t.eq(stats._reads, 1, "変わった run だけ読み直す")
  t.eq(S5.agents["general-purpose|opus"].n, 3, "r1 の b が減った")
  -- いま開いている run は読まない
  write_run("r4", { done("z", "Plan", "opus", 1) }, NOW)
  local S6 = stats.load(root, { now = NOW + 2000, skip_dir = root .. "/projects/-home-user-work/runs/r4" })
  t.eq(S6.agents["Plan|opus"], nil, "skip_dir は読まない")
end)

t.run("log と evaluate", function()
  local lr = vim.fn.tempname() .. "-log"
  vim.fn.mkdir(lr, "p")
  -- 3 本：開始 T0、終了 T0+100 s。真の進み 50 の時点で 60 / 40 / 50 を出していた → 誤差 10 10 0、中央値 10
  local T0 = NOW
  local rows = {
    { a = "x", pct = 60 }, { a = "y", pct = 40 }, { a = "z", pct = 50 },
  }
  for _, r in ipairs(rows) do
    t.ok(stats.log(lr, { ts = iso(T0 + 50), run = "R", agent = r.a, basis = "steps", n = 2, k = 1, f = 0.5,
      pct = r.pct, d_hat_ms = 50000 }), "log が書ける")
    stats.log(lr, { ts = iso(T0 + 100), run = "R", agent = r.a, final = true, elapsed_ms = 100000, n = 2, k = 2 })
  end
  -- x は 95 を出してから 40 s で終わった（残りの目安 = (2-1-0.9)*50 s = 5 s の 2 倍を超える → 遅れ）
  stats.log(lr, { ts = iso(T0 + 60), run = "R", agent = "x", pct = 95, n = 2, k = 1, f = 0.9, d_hat_ms = 50000 })
  local lines = vim.fn.readfile(lr .. "/progress_log.jsonl")
  t.eq(#lines, 7, "1 回 1 行")
  t.ok(lines[1]:find('"ts":', 1, true) ~= nil, "ts が入る")
  local ev = stats.evaluate(lr)
  t.eq(ev.n, 3, "終わった Agent 3 件")
  -- 誤差：x 10 と 35（95 - 60）、y 10、z 0 → 0 10 10 35 → 中央値 10
  t.eq(ev.median_abs_err, 10, "誤差の中央値")
  t.eq(ev.over90_late_ratio, 1, "90 以上を出したのは x だけで、遅れた")
  local auto = vim.fn.tempname()
  vim.fn.mkdir(auto, "p")
  stats.log(auto, { run = "R", agent = "q", pct = 1 })
  local one = vim.json.decode(vim.fn.readfile(auto .. "/progress_log.jsonl")[1])
  t.matches(one.ts, "^%d%d%d%d%-%d%d%-%d%dT", "ts は自動で付く")
  t.eq(stats.evaluate(auto), { n = 0 }, "終わりの記録が無ければ 0 件")
end)

vim.fn.delete(root, "rf")
t.done()
