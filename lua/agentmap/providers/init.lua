-- ============================================================
--  agentmap/providers/init.lua ... registry of record readers per AI tool.
--    Only "claude" exists in v0.1.0 (Codex support is planned).
--
--  provider が持つ関数（どれも失敗したら {} か nil を返す。エラーは投げない）
--    normalize_hook(rec)            … hooks.jsonl の 1 行 → 整えた記録の配列
--    backfill(sid, slug)            … transcript から整えた記録の配列を作る
--    list_sessions(slug)            … transcript だけある session の一覧
--    root_model(path)               … 親（ROOT）のモデル名
--    agent_transcript_path(run, ag) … その Agent の transcript の場所
--    read_meta(run, id)             … その Agent の meta.json
--    transcript_entries(path, opts) … transcript 画面用に並べた中身
--    model_short(m)                 … 表示用の短いモデル名
-- ============================================================
local M = {}

local names = { "claude" }
local cache = {}

--- Return the provider module `name` (default "claude"), or nil when it does not exist.
function M.get(name)
  name = name or "claude"
  if cache[name] then return cache[name] end
  local ok, p = pcall(require, "agentmap.providers." .. name)
  if ok and type(p) == "table" then
    cache[name] = p
    return p
  end
  return nil
end

--- Names of the available providers.
function M.list()
  return vim.deepcopy(names)
end

return M
