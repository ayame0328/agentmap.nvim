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
  -- 箱ごとの進み具合（%）。DESIGN-v0.2 §4.1。false を渡すと { enabled = false }
  progress = {
    enabled = true,          -- 箱に % を出す（false: 箱だけ消す。詳細・書き出しには出る）
    tick_ms = 1000,          -- 動いているものがある間、図を描き直す間隔（% と経過時間が動く）
    default_ms = 600000,     -- 過去の記録が無いときの Agent 1 件の目安（10 分）
    min_samples = 3,         -- 種類・モデルごとの中央値を使うのに要る件数
    no_steps = "time",       -- 手順表の無い RUNNING の箱: "time" = 経過時間÷目安の推定（上限 95.0）| "none" = 出さない
    log = true,              -- <root>/progress_log.jsonl に推定の記録を残す（答え合わせ用）
  },
  -- 矢印の上を流れる光。false を渡すと { enabled = false }
  animation = {
    enabled = true,
    frame_ms = 100,          -- 1 フレームの長さ
    period = 6,              -- 光の点の間隔（セル）
    tail = 2,                -- 頭の後ろの尾の長さ（セル）
    back_ms = 3000,          -- 子が終わったあと、子→親へ流す時間
    max_paths = 40,          -- 同時に光らせる線の上限
  },
  -- 動いている Agent への修正指示（DESIGN-v0.2-steer §8.1、DESIGN-v0.1.2-steer2 §9.1）。false を渡すと { enabled = false }
  steer = {
    enabled = true,          -- false: hooks に配達の登録を足さない。s は「無効」と知らせる
    -- "stop": Agent が終わろうとした瞬間に届ける（SubagentStop / Stop の block。既定）。
    -- "deny" / "context": 次の道具の直前にも届ける（止める／添える）。今のモデルは無視することがある。
    -- 変えたら :AgentMapInstallHooks。at_stop は 0.1.2 で廃止（常に on。書いても無視し、health が知らせる）
    mode = "stop",
    relay = "menu",          -- 親経由: "menu"（ROOT の端末があれば s のメニューに出す）| "never" | "always"（先に出す）
    root_via = "terminal",   -- ROOT への経路 "terminal" | "hook"
    no_terminal = "stop",    -- 端末が無いとき "stop"（ROOT の番の終わりに block）| "clipboard" | "none"。"hook" は "stop" の別名
    -- 本文を送ってから Enter を送るまでの間（ms）。0 なら 1 回で送る。
    -- Claude Code 2.1.289 の実測：長い 1 行（親への知らせの長さ、約 250 文字）を Enter ごと 1 回で送ると
    -- 貼り付け扱いになって送信されず入力欄に残る。150 ms 以上空けると送信される（短い行はどちらでも送信される）
    submit_delay_ms = 300,
    input = "window",        -- "window" | "line"
    text_max = 4000,
    -- 報告を SubagentHandback で返す子（Claude Code の auto モード）への届け方（DESIGN-v0.1.2-handback §3.4）。
    -- この子の終わり際の block は Claude Code が捨てるので、終わり際には届かない。
    -- "relay": 親経由（ROOT の端末があるとき。動いていれば次の道具、終わっていれば再開して届く）。
    --          親経由できないときは置くだけにして、届かない見込みを正直に知らせる（既定）
    -- "deny" : 加えて、親経由できないときは報告の直前（PreToolUse:SubagentHandback）にツールの結果として渡す
    --          （sonnet は従った 2/2、haiku は 0/2。変えたら :AgentMapInstallHooks）
    handback = "relay",
    -- 終わり際に置いて届かなかった（skipped）指示を、親の端末があれば自動で親経由に回す（Q26）
    handback_reroute = true,
  },
  -- 動いている Agent の一時停止と、終わる前に待たせる関門（DESIGN-v0.1.2-pause §8.1）。false を渡すと { enabled = false }
  pause = {
    enabled = true,          -- false: hooks に止まれの登録を足さない。x / X は「無効」と知らせる
    auto_resume_s = 600,     -- 止めたまま放置したとき、hook が自分で再開するまでの秒数（5〜86400）。変えたら :AgentMapInstallHooks
    gate = false,            -- 新しく見始める run の関門の初期値（X で run ごとに反転）
    release_on_exit = false, -- true: Neovim を閉じるとき、この run の止まれを全部解く（false: 自動再開に任せる）
    notify = true,           -- 止まった・再開した・通ったの通知
  },
}

local STEER_MODES = { stop = true, deny = true, context = true }
local STEER_RELAY = { menu = true, never = true, always = true }
local STEER_HANDBACK = { relay = true, deny = true }
local at_stop_given = false -- setup() の steer に at_stop があったか（0.1.2 で廃止。health 13 行目）

-- setup({ progress = false }) / { progress = true } を表に直す（animation / steer / pause も同じ）
local SWITCHABLE = { "progress", "animation", "steer", "pause" }
local function normalize(opts)
  local out = vim.deepcopy(opts)
  for _, k in ipairs(SWITCHABLE) do
    if out[k] == false then
      out[k] = { enabled = false }
    elseif out[k] == true then
      out[k] = { enabled = true }
    end
  end
  -- 修正指示（DESIGN-v0.1.2-steer2 §9.1）: at_stop は廃止（覚えておいて health で知らせる）、
  -- no_terminal = "hook" は "stop" の別名、知らない mode / relay は既定に戻す
  if type(out.steer) == "table" then
    if out.steer.at_stop ~= nil then
      at_stop_given = true
      out.steer.at_stop = nil
    end
    if out.steer.no_terminal == "hook" then out.steer.no_terminal = "stop" end
    if out.steer.mode ~= nil and not STEER_MODES[out.steer.mode] then out.steer.mode = nil end
    if out.steer.relay ~= nil and not STEER_RELAY[out.steer.relay] then out.steer.relay = nil end
    -- handback（DESIGN-v0.1.2-handback §7.1）: 知らない値は既定 "relay"。handback_reroute は boolean に直す
    if out.steer.handback ~= nil and not STEER_HANDBACK[out.steer.handback] then out.steer.handback = nil end
    if out.steer.handback_reroute ~= nil and type(out.steer.handback_reroute) ~= "boolean" then
      local v = out.steer.handback_reroute
      out.steer.handback_reroute = not (v == 0 or v == "false" or v == "no" or v == "off")
    end
  end
  -- 自動再開の秒数は hook と同じ範囲（5〜86400）に収める。数でなければ既定に戻す
  if type(out.pause) == "table" and out.pause.auto_resume_s ~= nil then
    local n = tonumber(out.pause.auto_resume_s)
    if not n then
      out.pause.auto_resume_s = nil
    else
      out.pause.auto_resume_s = math.max(5, math.min(86400, math.floor(n)))
    end
  end
  return out
end

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
--- each call starts again from the defaults. `progress`, `animation`, `steer` and `pause` also accept
--- false / true, normalized to { enabled = false } / { enabled = true }.
---@param opts? table see M.defaults
---@return table the effective configuration
function M.setup(opts)
  opts = opts or {}
  at_stop_given = false
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), normalize(opts))
  lang_given = opts.lang ~= nil
  if not lang_given and nonempty(vim.g.agentmap_lang) then
    current.lang = vim.g.agentmap_lang
  end
  return current
end

--- True when the last setup() passed steer.at_stop, which is ignored since 0.1.2 (always on).
---@return boolean
function M.steer_at_stop_given()
  return at_stop_given
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
