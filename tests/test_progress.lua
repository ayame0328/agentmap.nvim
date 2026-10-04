-- progress.compute の試験（DESIGN-v0.2 §2.3・§6、付録 D）。担当 W2
--   時計（now）と過去の記録（stats）は固定の値を渡す。期待値は 0.1 刻みの切り捨て。
--   a.tasks / a.steps は契約（§2.2）の形を手で書く（W1 の state.lua を待たない）。
local t = require("t")
local progress = require("agentmap.progress")

local NOW = 1790600000
local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
local STATS = { agents = { ["general-purpose|opus"] = { n = 10, median_ms = 360000 } },
  steps = {}, all = { agents = { n = 10, median_ms = 360000 }, steps = { n = 0 } } }
local CFG = { enabled = true, default_ms = 600000, min_samples = 3, no_steps = "time" }

local function opts(extra)
  local o = { now = NOW, stats = STATS, config = vim.deepcopy(CFG) }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- 手順 3 つのうち 2 つ済み、3 つ目は ago 秒前に始めた子
local function steps_agent(id, status, ago)
  return {
    id = id, index = 1, agent_type = "general-purpose", model = "claude-opus-5-5", parent_id = "ROOT",
    children = {}, status = status, started_at = iso(NOW - 900),
    steps = { source = "transcript", listed_at = iso(NOW - 900), items = {
      { n = 1, text = "Read", done_at = iso(NOW - 600) },
      { n = 2, text = "Write", done_at = iso(NOW - ago - 10) },
      { n = 3, text = "Test", started_at = iso(NOW - ago) },
    } },
  }
end

local function state_with(agents)
  local s = { run_id = "r", agents = { ROOT = { id = "ROOT", status = "RUNNING", children = {}, agent_type = "main",
    started_at = iso(NOW - 1000) } }, order = { "ROOT" } }
  for _, a in ipairs(agents) do
    s.agents[a.id] = a
    table.insert(s.agents.ROOT.children, a.id)
    table.insert(s.order, a.id)
  end
  return s
end

t.run("floor1 / label", function()
  t.eq(progress.floor1(100 * 2 / 3), 66.6, "2/3 は 66.6（四捨五入しない）")
  t.eq(progress.floor1(29.0), 29.0, "29.0 はそのまま（浮動小数の誤差で 28.9 にしない）")
  t.eq(progress.label({ pct = 62.4, estimated = true }), "~62.4%", "推定は ~ 付き")
  t.eq(progress.label({ pct = 66.6, estimated = false }), "66.6%", "事実は ~ 無し")
  t.eq(progress.label({ pct = 100, estimated = false }), "100.0%", "小数点第 1 位まで")
  t.eq(progress.label(nil), nil, "nil は nil")
end)

t.run("(a) 事実も子も無く no_steps = none → nil", function()
  local s = state_with({ { id = "x", agent_type = "general-purpose", status = "RUNNING", children = {}, started_at = iso(NOW - 10) } })
  local o = opts()
  o.config.no_steps = "none"
  t.eq(progress.compute(s, "x", o), nil, "nil")
end)

t.run("(b) steps k=2,n=3、手順 3 が 60 秒前に開始 → 83.3", function()
  local s = state_with({ steps_agent("a1", "RUNNING", 60) })
  local r = progress.compute(s, "a1", opts())
  t.eq(r.pct, 83.3, "pct")
  t.eq(r.estimated, true, "推定")
  t.eq(r.basis, "steps", "basis")
  t.eq(r.stat_basis, "type+model", "目安は種類＋モデル")
  t.eq(r.expected_ms, 120000, "d̂ = 360000 / 3")
  t.eq(r.f, 0.5, "f")
  t.eq(r.over, false, "目安を超えていない")
  t.eq({ r.n, r.k }, { 3, 2 }, "n, k")
  t.eq(progress.label(r), "~83.3%", "表示")
end)

t.run("(c) 500 秒前に開始 → f=0.99、99.6、over", function()
  local s = state_with({ steps_agent("a1", "RUNNING", 500) })
  local r = progress.compute(s, "a1", opts())
  t.eq(r.f, 0.99, "f の上限")
  t.eq(r.pct, 99.6, "pct")
  t.eq(r.over, true, "目安を超えた")
end)

t.run("(d) 手順は全部済んだが RUNNING → 99.9", function()
  local a = steps_agent("a1", "RUNNING", 60)
  a.steps.items[3].done_at = iso(NOW - 5)
  local r = progress.compute(state_with({ a }), "a1", opts())
  t.eq({ r.pct, r.estimated }, { 99.9, true }, "99.9 の推定")
end)

t.run("(e) DONE → 100.0（事実）", function()
  local r = progress.compute(state_with({ steps_agent("a1", "DONE", 60) }), "a1", opts())
  t.eq({ r.pct, r.estimated, r.basis }, { 100.0, false, "done" }, "100.0")
end)

t.run("(f) FAILED k=2,n=3 → 66.6、事実無しなら nil", function()
  local r = progress.compute(state_with({ steps_agent("a1", "FAILED", 60) }), "a1", opts())
  t.eq({ r.pct, r.estimated, r.basis }, { 66.6, false, "failed" }, "66.6")
  local s = state_with({ { id = "z", status = "FAILED", children = {} } })
  t.eq(progress.compute(s, "z", opts()), nil, "事実が無い FAILED は nil")
end)

t.run("(g) 2/3 ちょうど（実行中の手順に開始時刻が無い REVIEW）→ 66.6、事実", function()
  local r = progress.compute(state_with({ steps_agent("a1", "REVIEW", 60) }), "a1", opts())
  t.eq({ r.pct, r.estimated }, { 66.6, false }, "REVIEW は k/n だけ")
  local a = steps_agent("a1", "RUNNING", 60)
  a.steps.items[3].started_at = nil
  a.steps.items[2].done_at = iso(NOW) -- 今ちょうど 2 つ目が済んだ
  local r2 = progress.compute(state_with({ a }), "a1", opts())
  t.eq({ r2.pct, r2.estimated }, { 66.6, false }, "f = 0 なら ~ を付けない")
end)

t.run("(h) ROOT: tasks k=1,n=2、動いている子 40.0 と 60.0 → 75.0", function()
  local c1 = steps_agent("c1", "RUNNING", 0)
  local c2 = steps_agent("c2", "RUNNING", 0)
  -- 子の値を 40.0 / 60.0 にする：n=5 の手順で k=2 と k=3（f=0）
  c1.steps.items = { { n = 1, done_at = iso(NOW - 9) }, { n = 2, done_at = iso(NOW) }, { n = 3 }, { n = 4 }, { n = 5 } }
  c2.steps.items = { { n = 1, done_at = iso(NOW - 9) }, { n = 2, done_at = iso(NOW - 5) }, { n = 3, done_at = iso(NOW) }, { n = 4 }, { n = 5 } }
  local s = state_with({ c1, c2 })
  t.eq(progress.compute(s, "c1", opts()).pct, 40.0, "子 1 = 40.0")
  t.eq(progress.compute(s, "c2", opts()).pct, 60.0, "子 2 = 60.0")
  s.agents.ROOT.tasks = { order = { "1", "2" }, items = {
    ["1"] = { id = "1", subject = "plan", status = "completed", created_at = iso(NOW - 900), done_at = iso(NOW - 800) },
    ["2"] = { id = "2", subject = "delegate", status = "in_progress", started_at = iso(NOW - 700) },
  } }
  local r = progress.compute(s, "ROOT", opts())
  t.eq(r.pct, 75.0, "(1 + 0.5) / 2")
  t.eq(r.basis, "tasks", "basis は自分の出どころ")
  t.eq(r.n_children, 2, "子 2 つの平均で補った")
  t.eq(r.estimated, true, "推定")
end)

t.run("(i) 手順表の無い ROOT：子 DONE・RUNNING(50.0)・PENDING(0) → 50.0", function()
  local done = steps_agent("d", "DONE", 0)
  local half = steps_agent("h", "RUNNING", 0)
  half.steps.items = { { n = 1, done_at = iso(NOW) }, { n = 2 } }
  local none = { id = "p", status = "PENDING", children = {} }
  local s = state_with({ done, half, none })
  local r = progress.compute(s, "ROOT", opts())
  t.eq({ r.pct, r.basis, r.estimated }, { 50.0, "children", false },
    "単純平均。まだ始まっていない子は除かず 0 として入れる（2026-10-04 本人の決定）")
  t.eq(r.n_children, 3, "PENDING の子も数に入る")
  -- 起動待ちの仮の箱（placeholder）も「まだ始まっていない子」
  local s0 = state_with({ steps_agent("d", "DONE", 0), { id = "pending:toolu_1", placeholder = true, status = "PENDING", children = {} } })
  t.eq(progress.compute(s0, "ROOT", opts()).pct, 50.0, "DONE 100 と仮の箱 0 → 50.0")
  -- REVIEW で事実の無い子は今までどおり除く（進みを測れない）
  local s6 = state_with({ steps_agent("d", "DONE", 0), { id = "rv", status = "REVIEW", children = {} } })
  t.eq(progress.compute(s6, "ROOT", opts()).pct, 99.9, "事実の無い REVIEW の子は除く → DONE だけ → 子が動いている間の上限 99.9")
  -- 子が全部終わっても、自分が動いている間は 99.9 の推定
  local s2 = state_with({ steps_agent("d", "DONE", 0) })
  local r2 = progress.compute(s2, "ROOT", opts())
  t.eq({ r2.pct, r2.estimated }, { 95.0, true }, "子が全員終わっても RUNNING の親は上限 95.0（本人の決定 2026-10-04）")
  t.eq(r2.children_done, true, "子は全員終わっている")
  -- 95.0 未満なら子の平均のまま（FAILED の子が 66.6 と DONE の子 100 → 83.3）
  local fl = steps_agent("fl", "FAILED", 0)
  fl.steps.items[3].done_at = nil
  local s4 = state_with({ steps_agent("d", "DONE", 0), fl })
  local r4 = progress.compute(s4, "ROOT", opts())
  t.eq({ r4.pct, r4.estimated }, { 83.3, false }, "子が全員終わっても 95.0 未満なら平均そのまま")
  -- 子がまだ動いていれば上限は 99.9（95 を超えてよい）
  local hi = steps_agent("hi", "RUNNING", 0)
  hi.steps.items = {}
  for n = 1, 20 do hi.steps.items[n] = { n = n, done_at = n < 20 and iso(NOW) or nil } end
  local s5 = state_with({ steps_agent("d", "DONE", 0), hi })
  t.eq(progress.compute(s5, "hi", opts()).pct, 95.0, "動いている子は 19/20 = 95.0")
  t.eq(progress.compute(s5, "ROOT", opts()).pct, 97.5, "子が動いている間は 95.0 を超えてよい（上限 99.9）")
  -- FAILED で事実の無い子は 100 として数える
  local s3 = state_with({ half, { id = "f", status = "FAILED", children = {} } })
  t.eq(progress.compute(s3, "ROOT", opts()).pct, 75.0, "FAILED の子は 100")
end)

t.run("(j) no_steps = time（既定）：経過 300 s・目安 600 s → 50.0、2000 s → 95.0", function()
  local a = { id = "x", agent_type = "Explore", model = "claude-haiku-4-5", status = "RUNNING", children = {},
    started_at = iso(NOW - 300) }
  local o = opts({ stats = { agents = {}, steps = {}, all = { agents = { n = 0 }, steps = { n = 0 } } } })
  local r = progress.compute(state_with({ a }), "x", o)
  t.eq({ r.pct, r.basis, r.estimated, r.stat_basis }, { 50.0, "time", true, "default" }, "50.0")
  t.eq(r.expected_ms, 600000, "T̂ = 既定 10 分")
  a.started_at = iso(NOW - 2000)
  local r2 = progress.compute(state_with({ a }), "x", o)
  t.eq({ r2.pct, r2.over }, { 95.0, true }, "上限 95.0")
  t.eq(require("agentmap.config").get().progress.no_steps, "time", "既定は time（付録 D）")
end)

t.run("(k) stats 無し → default、d̂ = 600000 / n", function()
  local r = progress.compute(state_with({ steps_agent("a1", "RUNNING", 60) }), "a1", opts({ stats = false }))
  t.eq(r.stat_basis, "default", "default")
  t.eq(r.expected_ms, 200000, "600000 / 3")
  t.eq(r.pct, 76.6, "(2 + 60/200) / 3 = 76.66… → 76.6")
end)

t.run("tasks: in_progress の開始・複数の in_progress は早いほう", function()
  local s = state_with({})
  s.agents.ROOT.model = "claude-fable-5-1"
  s.agents.ROOT.tasks = { order = { "1", "2", "3" }, items = {
    ["1"] = { id = "1", status = "completed", created_at = iso(NOW - 300), done_at = iso(NOW - 200) },
    ["2"] = { id = "2", status = "in_progress", started_at = iso(NOW - 100) },
    ["3"] = { id = "3", status = "in_progress", started_at = iso(NOW - 50) },
  } }
  local f = progress._local_facts(s, "ROOT")
  t.eq({ f.source, f.n, f.k, f.cur.started_at }, { "tasks", 3, 1, iso(NOW - 100) }, "facts")
  local r = progress.compute(s, "ROOT", opts())
  -- 目安：main|fable の記録は無い → all の agents 360000 / 3 = 120000。f = 100/120
  t.eq(r.stat_basis, "all", "全体の中央値に落ちる")
  t.eq(r.pct, 61.1, "(1 + 0.8333) / 3")
end)

t.run("placeholder・知らない id", function()
  local s = state_with({ { id = "pending:x", placeholder = true, status = "PENDING", children = {} } })
  t.eq(progress.compute(s, "pending:x", opts()), nil, "起動待ちは nil")
  t.eq(progress.compute(s, "nope", opts()), nil, "無い id は nil")
end)

t.done()
