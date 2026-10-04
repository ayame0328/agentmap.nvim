-- テスト用の小さな state（DESIGN §4 の形そのまま。SV 9 の欄を含む）
--   ROOT → [1] 調査（RUNNING。子 [3] は DONE）、[2] 実装（レビューで RETRY → 差し戻し中）
--   進み具合の事実（DESIGN-v0.2 §6 (b) と同じ値）:
--     [1] の手順表（## Steps）3 項目のうち 2 済み、3 つ目は 2026-09-28T12:52:20Z（= 試験の NOW 1790600000 の 60 秒前）に開始
--     ROOT の手順表（TaskCreate）2 項目のうち 1 済み、2 つ目が in_progress
--   修正指示：[2] に配達済み 1 件（ずっと前）と取り消し 1 件。箱の印は出ない（配達から 60 秒超・取り消し）
--   transcript_path はテスト側で差し替える（fixtures/transcript_small.jsonl）
return {
  v = 1,
  run_id = "c0ffee01-0000-4000-8000-000000000001",
  cwd = "/tmp/agentmap-test/probe/work",
  title = "AgentMap 設計の確認",
  started_at = "2026-09-28T04:23:38.000Z",
  root_transcript = nil,
  order = { "ROOT", "a1", "a2", "g1" },
  next_index = 4,
  spawn_requests = {},
  counts = { agents = 3, done = 1, running = 1, review = 0, rework = 1, failed = 0, pending = 0, unknown_parent = 0,
    steers = 2, steers_pending = 0 },
  steers = {
    ["a2-1790570000000"] = {
      id = "a2-1790570000000", agent_id = "a2", text = "テストも書くこと", via = "hook", kind = "steer",
      status = "DELIVERED", prompt_id = "c0ffee02-0000-4000-8000-000000000002", n = 1,
      requested_at = "2026-09-28T04:26:40.000Z", delivered_at = "2026-09-28T04:27:00.000Z",
      delivered_via = "PreToolUse:Write", tool_use_id = "toolu_small0001", mode = "deny",
    },
    ["a2-1790570100000"] = {
      id = "a2-1790570100000", agent_id = "a2", text = "やっぱり今のままで", via = "hook", kind = "steer",
      status = "CANCELLED", prompt_id = "c0ffee02-0000-4000-8000-000000000002", n = 2,
      requested_at = "2026-09-28T04:27:30.000Z", ended_at = "2026-09-28T04:27:40.000Z",
    },
  },
  steer_order = { "a2-1790570000000", "a2-1790570100000" },
  last_seq = 20,
  agents = {
    ROOT = {
      id = "ROOT", name = "ROOT", agent_type = "main", model = "claude-fable-5-1",
      parent_id = nil, children = { "a1", "a2" }, status = "RUNNING",
      attempts = { { n = 1, started_at = "2026-09-28T04:23:38.000Z" } }, attempt = 1,
      review_count = 0, rework_count = 0, started_at = "2026-09-28T04:23:38.000Z",
      cwd = "/tmp/agentmap-test/probe/work", tools = {}, tool_counts = {}, files = {},
      tasks = {
        order = { "1", "2" },
        items = {
          ["1"] = { id = "1", subject = "調査を任せる", active_form = "調査を任せている", status = "completed",
            created_at = "2026-09-28T04:23:39.000Z", started_at = "2026-09-28T04:23:39.000Z", done_at = "2026-09-28T04:25:10.000Z",
            prompts = { ["c0ffee02-0000-4000-8000-000000000002"] = true } },
          ["2"] = { id = "2", subject = "実装を任せる", active_form = "実装を任せている", status = "in_progress",
            created_at = "2026-09-28T04:23:39.000Z", started_at = "2026-09-28T04:25:10.000Z",
            prompts = { ["c0ffee02-0000-4000-8000-000000000002"] = true } },
        },
      },
    },
    a1 = {
      id = "a1", index = 1, name = "調査：既存設定の確認", agent_type = "general-purpose",
      model = "claude-opus-5-5", task = "既存の Neovim 設定を読んで構成をまとめる",
      prompt_head = "init.lua と lua/ 以下を読み、keymap と plugin の一覧を作る",
      parent_id = "ROOT", link_source = "post_tool_use", children = { "g1" }, status = "RUNNING",
      attempts = { { n = 1, started_at = "2026-09-28T04:23:40.000Z" } },
      attempt = 1, review_count = 0, rework_count = 0,
      started_at = "2026-09-28T04:23:40.000Z",
      steps = {
        source = "transcript", listed_at = "2026-09-28T04:23:41.000Z",
        items = {
          { n = 1, text = "init.lua を読む", done_at = "2026-09-28T04:30:00.000Z" },
          { n = 2, text = "keymap の一覧を孫に任せる", done_at = "2026-09-28T12:40:00.000Z" },
          { n = 3, text = "plugin の一覧をまとめる", started_at = "2026-09-28T12:52:20.000Z" },
        },
      },
      cwd = "/tmp/agentmap-test/probe/work",
      tools = { { ts = "2026-09-28T04:23:45.000Z", name = "Agent", target = "孫：keymap 一覧" } },
      tool_counts = { Agent = 1 }, files = {}, last_head = "調査完了。plugin は 12 個。",
    },
    g1 = {
      id = "g1", index = 3, name = "孫：keymap 一覧", agent_type = "Explore",
      model = "claude-haiku-4-5-20251001", task = "keymap を全部書き出す",
      parent_id = "a1", link_source = "post_tool_use", children = {}, status = "DONE",
      attempts = { { n = 1, started_at = "2026-09-28T04:23:46.000Z", finished_at = "2026-09-28T04:24:30.000Z" } },
      attempt = 1, review_count = 0, rework_count = 0,
      started_at = "2026-09-28T04:23:46.000Z", finished_at = "2026-09-28T04:24:30.000Z", elapsed_ms = 44000,
      tools = {}, tool_counts = {}, files = {}, last_head = "GRAND",
    },
    a2 = {
      id = "a2", index = 2, name = "実装：dbt model", agent_type = "general-purpose",
      model = "claude-opus-5-5", task = "dbt model を追加してテストを書く",
      parent_id = "ROOT", link_source = "meta", children = {}, status = "REWORK",
      attempts = {
        { n = 1, started_at = "2026-09-28T04:23:41.000Z", finished_at = "2026-09-28T04:28:00.000Z",
          submitted_at = "2026-09-28T04:28:05.000Z", verdict = "RETRY", decided_by = "user",
          reason = "テストが無い" },
      },
      attempt = 1, review_count = 1, rework_count = 1,
      started_at = "2026-09-28T04:23:41.000Z", finished_at = "2026-09-28T04:28:00.000Z",
      cwd = "/tmp/agentmap-test/wt-a2", worktree = "/tmp/agentmap-test/wt-a2",
      tools = {
        { ts = "2026-09-28T04:25:00.000Z", name = "Write", target = "/tmp/agentmap-test/wt-a2/models/orders.sql" },
        { ts = "2026-09-28T04:26:00.000Z", name = "Bash", target = "dbt run" },
      },
      tool_counts = { Write = 1, Bash = 1 }, files = { "/tmp/agentmap-test/wt-a2/models/orders.sql" },
      steers = { "a2-1790570000000", "a2-1790570100000" },
      last_head = "orders モデルを追加しました。",
    },
  },
}
