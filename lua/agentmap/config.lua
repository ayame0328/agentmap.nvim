-- ============================================================
--  agentmap/config.lua ... user options and the lookups derived from them.
--    setup(opts) merges opts over the defaults; every other module only reads
--    through get() and the accessors below. Nothing else reads environment
--    variables for paths (DESIGN §4.1).
-- ============================================================
local M = {}

M.defaults = {
  lang = "en",               -- "en" | "ja"。setup() に lang が無いときだけ vim.g.agentmap_lang を見る（S6）
  root = nil,                -- 記録の保存先。nil → $AGENTMAP_DIR → $AGENTFLOW_DIR（旧名）→ stdpath("data").."/agentflow"
  claude_config_dir = nil,   -- Claude の設定フォルダ。nil → $CLAUDE_CONFIG_DIR → ~/.claude（P5）
  python = nil,              -- nil → python3 / python / py -3 のうち最初に見つかったもの（P8）。文字列か argv の表
  open = "tab",              -- 図を開く場所 "tab" | "vsplit" | "current"
  aux_width = 0.45,          -- 右側の詳細ウィンドウの幅（画面に対する割合）
  box_w = 26,                -- 箱の内側の幅（文字数）
  col_gap = 7,               -- 箱と箱の横のすき間
  mode = "auto",             -- "box" | "tree" | "auto"（入らなければ木表示）
  poll_ms = 1500,            -- ファイルの変化を見に行く間隔
  debounce_ms = 200,         -- 変化が続いたとき、まとめて描き直すまでの待ち時間
  switch_delay_ms = 15000,   -- 見ている流れが全部終わってから、次の流れへ切り替えるまでの間（終わった様子を見届けるため）
  -- 詳細画面：作業の経過の表示件数／1 件の文字数／報告の原文の上限／親の直前の発言の上限
  detail = { progress_max = 40, note_chars = 120, report_chars = 4000, lead_chars = 400 },
  -- notes_first_bytes：作業の経過を初めて読むとき、transcript の末尾からこれだけ読む（親は 10MB を超えることがあるため）
  -- notes_max：作業の経過を覚えておく件数（古いものから捨てる）
  transcript = { max_chars = 2000, max_bytes = 5e6, notes_first_bytes = 1e6, notes_max = 400 },
  review = {
    provider = "auto",       -- auto：この PC で使える判定係があればそれ、無ければ手動
    rubric = nil,            -- RUBRIC.md の場所。nil → <plugin>/rubric/RUBRIC.md
  },
  keymaps = { global = false },     -- true で <leader>aa / <leader>ar / <leader>ae を足す（P11）
  hooks = { settings_path = nil },  -- nil → claude_config_dir() .. "/settings.json"
  export = {
    html_command = nil,      -- argv。標準入力に Markdown、最後の引数に題名、標準出力に HTML（S12）。nil → 同梱の md.lua
    pdf_command = nil,       -- argv。%{html} %{out} %{title} を置き換える（S13）。nil → PDF は無効
  },
  brief = { markers = nil }, -- 予約のみ。v0.1.0 では効果なし（S7）
}

local current = vim.deepcopy(M.defaults)
local lang_given = false

local function nonempty(s)
  return type(s) == "string" and s ~= ""
end

local function env(name)
  local v = vim.env[name]
  if nonempty(v) then return v end
  return nil
end

--- Apply user options over the defaults. May be called any number of times;
--- each call starts again from the defaults.
---@param opts? table see M.defaults
---@return table the effective configuration
function M.setup(opts)
  opts = opts or {}
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  lang_given = opts.lang ~= nil
  if not lang_given and nonempty(vim.g.agentmap_lang) then
    current.lang = vim.g.agentmap_lang
  end
  return current
end

--- The effective configuration table (read only by convention).
---@return table
function M.get()
  return current
end

--- Record store root. Order: setup root → $AGENTMAP_DIR → $AGENTFLOW_DIR (deprecated)
--- → stdpath("data") .. "/agentflow" (folder name kept for existing records, D1).
---@return string
function M.root()
  local r = M.root_source()
  if r == "setup" then return vim.fn.expand(current.root) end
  if r == "AGENTMAP_DIR" or r == "AGENTFLOW_DIR" then return env(r) end
  return vim.fn.stdpath("data") .. "/agentflow"
end

--- Where root() came from: "setup" | "AGENTMAP_DIR" | "AGENTFLOW_DIR" | "default".
---@return string
function M.root_source()
  if nonempty(current.root) then return "setup" end
  if env("AGENTMAP_DIR") then return "AGENTMAP_DIR" end
  if env("AGENTFLOW_DIR") then return "AGENTFLOW_DIR" end
  return "default"
end

--- Claude Code config dir (parent of projects/ and settings.json).
--- Order: setup claude_config_dir → $CLAUDE_CONFIG_DIR → ~/.claude (P5).
---@return string
function M.claude_config_dir()
  local s = M.claude_config_source()
  local dir
  if s == "setup" then
    dir = vim.fn.expand(current.claude_config_dir)
  elseif s == "CLAUDE_CONFIG_DIR" then
    dir = env("CLAUDE_CONFIG_DIR")
  else
    dir = vim.fn.expand("~/.claude")
  end
  return (dir:gsub("[/\\]+$", ""))
end

--- Where claude_config_dir() came from: "setup" | "CLAUDE_CONFIG_DIR" | "default".
---@return string
function M.claude_config_source()
  if nonempty(current.claude_config_dir) then return "setup" end
  if env("CLAUDE_CONFIG_DIR") then return "CLAUDE_CONFIG_DIR" end
  return "default"
end

--- settings.json that :AgentMapInstallHooks edits by default.
---@return string
function M.settings_path()
  local p = current.hooks and current.hooks.settings_path
  if nonempty(p) then return vim.fn.expand(p) end
  return M.claude_config_dir() .. "/settings.json"
end

--- Python command as an argv list (e.g. { "python3" } or { "py", "-3" }), or nil when none is found.
--- setup python (string split on spaces, or a list) wins and is returned even if not executable,
--- so :checkhealth can report it; otherwise the first of python3 / python / py -3 whose first word is executable() (P8).
---@return string[]|nil
function M.python()
  local p = current.python
  if type(p) == "table" and #p > 0 then return vim.deepcopy(p) end
  if nonempty(p) then return vim.split(vim.trim(p), "%s+") end
  for _, cand in ipairs({ { "python3" }, { "python" }, { "py", "-3" } }) do
    if vim.fn.executable(cand[1]) == 1 then return cand end
  end
  return nil
end

return M
