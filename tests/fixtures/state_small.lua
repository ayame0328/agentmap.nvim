-- テスト用の小さな state（DESIGN §4 の形そのまま）
--   ROOT → [1] 調査（子 [3] あり）、[2] 実装（レビューで RETRY → 差し戻し中）
--   ROOT の進捗は 子2人中 DONE 1人 → ~50%
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
  counts = { agents = 3, done = 2, running = 0, review = 0, rework = 1, failed = 0, pending = 0, unknown_parent = 0 },
  last_seq = 20,
  agents = {
    ROOT = {
      id = "ROOT", name = "ROOT", agent_type = "main", model = "claude-fable-5-1",
      parent_id = nil, children = { "a1", "a2" }, status = "RUNNING",
      attempts = { { n = 1, started_at = "2026-09-28T04:23:38.000Z" } }, attempt = 1,
      review_count = 0, rework_count = 0, started_at = "2026-09-28T04:23:38.000Z",
      cwd = "/tmp/agentmap-test/probe/work", tools = {}, tool_counts = {}, files = {},
    },
    a1 = {
      id = "a1", index = 1, name = "調査：既存設定の確認", agent_type = "general-purpose",
      model = "claude-opus-5-5", task = "既存の Neovim 設定を読んで構成をまとめる",
      prompt_head = "init.lua と lua/ 以下を読み、keymap と plugin の一覧を作る",
      parent_id = "ROOT", link_source = "post_tool_use", children = { "g1" }, status = "DONE",
      attempts = { { n = 1, started_at = "2026-09-28T04:23:40.000Z", finished_at = "2026-09-28T04:25:10.000Z" } },
      attempt = 1, review_count = 0, rework_count = 0,
      started_at = "2026-09-28T04:23:40.000Z", finished_at = "2026-09-28T04:25:10.000Z", elapsed_ms = 90000,
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
      last_head = "orders モデルを追加しました。",
    },
  },
}
