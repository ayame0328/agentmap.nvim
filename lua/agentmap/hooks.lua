-- agentmap/hooks.lua ... registers the recording hooks in Claude Code's settings.json (:AgentMapInstallHooks).
--   Ours are recognised by MARK (or a legacy mark) in the command; other hooks and settings are left alone.
--   Idempotent (the second run reports "no change"). Shows a diff and asks before writing; keeps the
--   original as .bak-<timestamp>. Never runs on its own at startup.
--   Command format (DESIGN §4.2): '<python>' '<plugin>/bin/agentmap-collect' --root '<root>'
--   Steering (DESIGN-v0.2-steer §7): a second, synchronous PreToolUse hook (no matcher) guarded by a
--   shell test, so Python only starts while an instruction is pending:
--     [ -e '<root>/steer.pending' ] || exit 0; exec <record command> --steer --mode <mode>
--   SubagentStop / Stop run synchronously with "--steer --mode <mode> --at-stop --record".
local J = require("agentmap.jsonfmt")
local i18n = require("agentmap.i18n")

local M = {}

M.MARK = "agentmap-collect"
-- 改名前の名前。古い登録も「自分の分」として置き換える（残すと記録が二重になる。S3）
M.LEGACY_MARKS = { "agentflow-collect" }

-- 登録するイベントと、対象の道具（matcher）。DESIGN §2 のとおり。
--   3 つ目は { sync = 同期にする, steer = 修正指示を配達する, record = 配達と一緒に記録もする }。
--   同じイベントに自分の登録が 2 つあることがある（PreToolUse：記録用と配達用）。
--   設定（steer.enabled / at_stop）で絞った一覧は M.events() が返す。試験も M.events() を使う
M.EVENTS = {
  { "SessionStart" },
  { "UserPromptSubmit" },
  -- AskUserQuestion は HUMAN CHECK（人への確認）の記録用。質問の中身は PreToolUse で全部取れるので、
  -- 「許可の判断」を返せる PermissionRequest や、時刻しか増えない Notification は登録しない（設計書 §7.1）。
  -- PostToolUseFailure(AskUserQuestion) は Esc で取り消したとき何が来るか未確認なので、保険として登録だけする
  { "PreToolUse", "Agent|AskUserQuestion" },
  -- 修正指示の配達（全道具・同期・シェルの門番つき。未配達が無ければ約 2 ms で抜ける）
  { "PreToolUse", nil, { sync = true, steer = true } },
  -- TaskCreate / TaskUpdate / TaskList は手順表（進み具合の事実。DESIGN-v0.2 §2.2）
  { "PostToolUse", "Agent|AskUserQuestion|Write|Edit|MultiEdit|NotebookEdit|Bash|EnterWorktree|ExitWorktree|TaskCreate|TaskUpdate|TaskList" },
  { "PostToolUseFailure", "Agent|AskUserQuestion" },
  { "SubagentStart" },
  -- 記録＋配達（終わろうとした瞬間にも届けるため同期。配達しない設定なら今までの記録だけ）
  { "SubagentStop", nil, { sync = true, steer = true, record = true } },
  -- Stop と SessionEnd は配達が無くても同期（async だと Claude が先に終わって記録が取りこぼされる。
  -- claude -p で実測：Stop は 2 回中 2 回、SessionEnd は 2 回中 1 回消えた。どちらも 50ms 以内で終わる）
  { "Stop", nil, { sync = true, steer = true, record = true } },
  { "SessionEnd", nil, { sync = true } },
}

-- 配達をしないときの同期の要否（Stop は記録の取りこぼし防止で同期のまま。SubagentStop は元の async）
local SYNC_WITHOUT_STEER = { Stop = true, SessionEnd = true }

--- 修正指示の設定（config.steer が無い版でも動くように既定を補う）
local function steer_cfg(scfg)
  if scfg == nil then
    local ok, c = pcall(function() return require("agentmap.config").get().steer end)
    scfg = ok and c or nil
  end
  if scfg == false then scfg = { enabled = false } end
  if type(scfg) ~= "table" then scfg = {} end
  return {
    enabled = scfg.enabled ~= false,
    mode = scfg.mode == "context" and "context" or "deny",
    at_stop = scfg.at_stop ~= false,
  }
end

--- The events to register for the given steering settings (default: config.get().steer).
---   steer.enabled = false drops the delivery hook and puts SubagentStop / Stop back to recording only;
---   at_stop = false does the same for SubagentStop / Stop only.
---@param scfg? table|false
---@return table[] list of { event, matcher?, opts? }
function M.events(scfg)
  local c = steer_cfg(scfg)
  local out = {}
  for _, e in ipairs(M.EVENTS) do
    local o = e[3] or {}
    if not o.steer then
      out[#out + 1] = e
    elseif o.record then
      if c.enabled and c.at_stop then
        out[#out + 1] = e
      else
        out[#out + 1] = { e[1], e[2], { sync = SYNC_WITHOUT_STEER[e[1]] or nil } }
      end
    elseif c.enabled then
      out[#out + 1] = e
    end
  end
  return out
end

local function notify(msg, lvl)
  vim.notify("AgentMap: " .. msg, lvl or vim.log.levels.INFO)
end

local function config()
  return require("agentmap.config")
end

--- Plugin root directory (forward slashes), derived from this file's location (P7).
---@return string
function M.plugin_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return (vim.fn.fnamemodify(src, ":p:h:h:h"):gsub("\\", "/"):gsub("/+$", ""))
end

--- settings.json edited by default (config.settings_path()).
---@return string
function M.default_path()
  return config().settings_path()
end

--- Absolute path of the bundled collector (<plugin>/bin/agentmap-collect).
---@return string
function M.collector_path()
  return M.plugin_dir() .. "/bin/agentmap-collect"
end

--- Quote one word for bash, POSIX style, on every OS (S14). Words made only of
--- safe characters stay bare; anything else is wrapped in single quotes ('  →  '\'').
---@param s string
---@return string
function M.quote(s)
  s = tostring(s)
  if s ~= "" and not s:find("[^%w@%%+=:,./_-]") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function slashes(p)
  return (tostring(p):gsub("\\", "/"))
end

--- Command string written into settings.json.
---@param opts? { root?: string|false, python?: string[] }  root: nil → config.root(); false → no --root
---@return string|nil cmd, string|nil err  err = "python" when no Python was found
function M.default_cmd(opts)
  opts = opts or {}
  local py = opts.python or config().python()
  if not py or #py == 0 then return nil, "python" end
  local words = {}
  for _, w in ipairs(py) do words[#words + 1] = M.quote(w) end
  words[#words + 1] = M.quote(slashes(M.collector_path()))
  local root = opts.root
  if root == nil then root = config().root() end
  if root ~= false then
    words[#words + 1] = "--root"
    words[#words + 1] = M.quote(slashes(root))
  end
  return table.concat(words, " ")
end

--- Commands of the steering hooks, built from the recording command.
---   guard: [ -e '<root>/steer.pending' ] || exit 0; exec <record> --steer --mode <mode>   (PreToolUse)
---   stop:  <record> --steer --mode <mode> [--at-stop] --record                           (SubagentStop / Stop)
---@param opts? { record?: string, root?: string|false, mode?: string, at_stop?: boolean, python?: string[] }
---   record   the recording command (default: default_cmd({ root = opts.root, python = opts.python }))
---   root     record root whose steer.pending flag the guard tests (nil or false → config.root())
---   mode / at_stop  default: config.get().steer
---@return string|nil guard, string|nil stop   nil when no Python was found
function M.steer_cmd(opts)
  opts = opts or {}
  local record = opts.record
  if not record then
    record = M.default_cmd({ root = opts.root, python = opts.python })
    if not record then return nil, nil end
  end
  local c = steer_cfg(nil)
  local mode = opts.mode or c.mode
  local at_stop = c.at_stop
  if opts.at_stop ~= nil then at_stop = opts.at_stop end
  local root = opts.root
  if not root then root = config().root() end
  local flag = M.quote(slashes(root) .. "/steer.pending")
  local guard = "[ -e " .. flag .. " ] || exit 0; exec " .. record .. " --steer --mode " .. mode
  local stop = record .. " --steer --mode " .. mode .. (at_stop and " --at-stop" or "") .. " --record"
  return guard, stop
end

--- 登録したい hooks の中身（settings.json の "hooks" の値）。
---   cmd は記録用の command（文字列）。配達用の command はそこから作る（M.steer_cmd）。
---   opts = { root = 門番が見る記録の保存先（nil/false → config.root()）, steer = 設定（既定 config.get().steer） }
---   同じイベントに組が 2 つ並ぶことがある（PreToolUse：記録用 → 配達用の順）
function M.desired(cmd, opts)
  opts = opts or {}
  local c = steer_cfg(opts.steer)
  local guard, stop = M.steer_cmd({ record = cmd, root = opts.root, mode = c.mode, at_stop = c.at_stop })
  local hooks = J.object()
  for _, e in ipairs(M.events(opts.steer)) do
    local o = e[3] or {}
    local command = cmd
    if o.steer then command = o.record and stop or guard end
    local h = J.obj({ { "type", "command" }, { "command", command }, { "async", not o.sync }, { "timeout", 10 } })
    local group = J.object()
    if e[2] then J.set(group, "matcher", e[2]) end
    J.set(group, "hooks", J.array({ h }))
    if hooks[e[1]] == nil then J.set(hooks, e[1], J.array()) end
    local list = hooks[e[1]]
    list[#list + 1] = group
  end
  return hooks
end

--- True when a hook entry is one of ours (MARK or any LEGACY_MARKS in its command, S3).
---@param h table
---@return boolean
function M.is_ours(h)
  if type(h) ~= "table" or type(h.command) ~= "string" then return false end
  if h.command:find(M.MARK, 1, true) then return true end
  for _, m in ipairs(M.LEGACY_MARKS) do
    if h.command:find(m, 1, true) then return true end
  end
  return false
end
local is_ours = M.is_ours

--- 1 つのイベントの一覧から、自分の分だけを取り除く。
---@return table list, integer removed
local function strip(list)
  local out, removed = J.array(), 0
  for _, group in ipairs(list) do
    if type(group) == "table" and type(group.hooks) == "table" then
      local keep = J.array()
      for _, h in ipairs(group.hooks) do
        if is_ours(h) then removed = removed + 1 else keep[#keep + 1] = h end
      end
      if #keep > 0 then
        if #keep ~= #group.hooks then
          local g = J.copy(group)
          g.hooks = keep
          out[#out + 1] = g
        else
          out[#out + 1] = group
        end
      end
    else
      out[#out + 1] = group
    end
  end
  return out, removed
end

--- 今の設定に、登録したい hooks を混ぜる。元の表は変えない。
---@param existing table settings.json 全体（jsonfmt.decode したもの）
---@param desired  table M.desired() の戻り値
---@return table merged, boolean changed
function M.merge(existing, desired)
  local merged = J.copy(existing or J.object())
  if type(merged.hooks) ~= "table" then J.set(merged, "hooks", J.object()) end
  local hooks = merged.hooks

  -- 登録対象でなくなったイベントに残っている自分の分は消す
  for _, ev in ipairs(J.keys(hooks)) do
    if desired[ev] == nil and type(hooks[ev]) == "table" then
      local list, removed = strip(hooks[ev])
      if removed > 0 then
        if #list == 0 then J.del(hooks, ev) else hooks[ev] = list end
      end
    end
  end

  for _, ev in ipairs(J.keys(desired)) do
    local wants = desired[ev] -- そのイベントに置きたい自分の組（1 つか 2 つ）
    local list = hooks[ev]
    if type(list) ~= "table" then
      J.set(hooks, ev, J.copy(wants))
    else
      -- 自分の分がちょうど #wants 個あり、どれも置きたい組と全く同じなら、そのまま（並びも動かさない）
      local ours = 0
      for _, group in ipairs(list) do
        if type(group) == "table" and type(group.hooks) == "table" then
          for _, h in ipairs(group.hooks) do
            if is_ours(h) then ours = ours + 1 end
          end
        end
      end
      local all = true
      for _, want in ipairs(wants) do
        local found = false
        for _, group in ipairs(list) do
          if type(group) == "table" and J.equal(group, want) then found = true break end
        end
        if not found then all = false break end
      end
      if not (ours == #wants and all) then
        local stripped = strip(list)
        for _, want in ipairs(wants) do stripped[#stripped + 1] = J.copy(want) end
        hooks[ev] = stripped
      end
    end
  end

  return merged, not J.equal(existing or J.object(), merged)
end

--- Unified diff between the old and new settings text, with a two-line header.
---@return string
function M.diff_text(a, b, name)
  local d = vim.diff(a or "", b or "", { result_type = "unified", ctxlen = 3 })
  name = name or "settings.json"
  return "--- " .. i18n.t("hooks.diff_before", { name = name }) .. "\n+++ "
    .. i18n.t("hooks.diff_after", { name = name }) .. "\n" .. (d or "")
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_atomic(path, text)
  local tmp = path .. ".agentmap-tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  f:write(text)
  f:close()
  local st = vim.uv.fs_stat(path)
  if st then vim.uv.fs_chmod(tmp, st.mode % 4096) end
  local ok, rerr = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

--- 差分を下の窓に出して、書き換えてよいか聞く
local function confirm_with_diff(diff, path)
  local win_before = vim.api.nvim_get_current_win()
  vim.cmd("botright new")
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(diff, "\n", { plain = true }))
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "agentmap://hooks-diff")
  vim.cmd("redraw")
  local ans = vim.fn.confirm(i18n.t("hooks.confirm", { path = path }), i18n.t("hooks.confirm_choices"), 2)
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if vim.api.nvim_win_is_valid(win_before) then pcall(vim.api.nvim_set_current_win, win_before) end
  return ans == 1
end

--- Register the recording hooks in settings.json.
---@param opts? { path?: string, cmd?: string, root?: string|false, yes?: boolean, dry_run?: boolean, quiet?: boolean }
---   path    settings.json to edit (default: default_path())
---   cmd     full command override (default: default_cmd({ root = opts.root }))
---   root    record root passed as --root: string → that value, false → no --root (env var used instead), nil → config.root()
---   yes     skip the confirmation (tests)
---   dry_run return the diff without writing
---   quiet   no notifications
---@return boolean ok, table info { changed, path, backup?, diff?, text? }
function M.install(opts)
  opts = opts or {}
  local say = opts.quiet and function() end or notify
  if vim.g.agentmap_test and not opts.path then
    error(i18n.t("hooks.test_guard"))
  end
  local path = opts.path or M.default_path()
  -- シンボリックリンクなら、その先のファイルを書き換える
  local real = vim.uv.fs_realpath(path) or path

  local cmd = opts.cmd
  if not cmd then
    local collector = M.collector_path()
    if not vim.uv.fs_stat(collector) then
      say(i18n.t("hooks.collector_missing", { path = collector }), vim.log.levels.ERROR)
      return false, { changed = false, path = path }
    end
    local err
    cmd, err = M.default_cmd({ root = opts.root })
    if not cmd then
      say(i18n.t("hooks.python_missing"), vim.log.levels.ERROR)
      return false, { changed = false, path = path, err = err }
    end
  end

  local old = read(real)
  local existing
  if old and old:match("%S") then
    local ok, v = pcall(J.decode, old)
    if not ok or type(v) ~= "table" then
      say(i18n.t("hooks.settings_unreadable", { err = tostring(v) }), vim.log.levels.ERROR)
      return false, { changed = false, path = path }
    end
    existing = v
  else
    existing = J.object()
  end

  local merged, changed = M.merge(existing, M.desired(cmd, { root = opts.root }))
  if not changed then
    say(i18n.t("hooks.no_change", { path = path }))
    return true, { changed = false, path = path }
  end

  local new = J.encode(merged) .. "\n"
  local diff = M.diff_text(old or "", new, vim.fn.fnamemodify(path, ":t"))
  if opts.dry_run then
    return true, { changed = true, path = path, diff = diff, text = new }
  end

  if not opts.yes and not confirm_with_diff(diff, path) then
    say(i18n.t("hooks.cancelled"))
    return false, { changed = false, path = path }
  end

  -- 控えを取ってから書き換える
  local backup
  if old then
    backup = real .. ".bak-" .. os.date("%Y%m%d-%H%M%S")
    local n = 1
    while vim.uv.fs_stat(backup) do
      n = n + 1
      backup = real .. ".bak-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. n
    end
    local ok, err = vim.uv.fs_copyfile(real, backup)
    if not ok then
      say(i18n.t("hooks.backup_failed", { err = tostring(err) }), vim.log.levels.ERROR)
      return false, { changed = false, path = path }
    end
  else
    local dir = vim.fn.fnamemodify(real, ":h")
    if vim.fn.isdirectory(dir) == 0 then
      say(i18n.t("hooks.dir_missing", { dir = dir }), vim.log.levels.ERROR)
      return false, { changed = false, path = path }
    end
  end

  local ok, err = write_atomic(real, new)
  if not ok then
    say(i18n.t("hooks.write_failed", { err = tostring(err) }), vim.log.levels.ERROR)
    return false, { changed = false, path = path, backup = backup }
  end
  local lines = { i18n.t("hooks.installed", { path = path }) }
  if backup then lines[#lines + 1] = i18n.t("hooks.installed_backup", { backup = vim.fn.fnamemodify(backup, ":t") }) end
  lines[#lines + 1] = i18n.t("hooks.installed_next")
  say(table.concat(lines, "\n"))
  return true, { changed = true, path = path, backup = backup, diff = diff }
end

--- Registration state of settings.json:
---   "installed" the (event, matcher) pairs of ours equal those of M.events()
---   "outdated"  every event has one of ours, but the (event, matcher) pairs differ from M.events()
---               (e.g. registered by v0.1.0: no TaskCreate matcher and no steering hook)
---   "partial"   some events have ours, some not
---   "missing"   none (or no / unreadable file)
--- The command text is not compared.
---@param path? string default: default_path()
---@param scfg? table|false steering settings (default: config.get().steer)
---@return string
function M.status(path, scfg)
  path = path or M.default_path()
  local text = read(vim.uv.fs_realpath(path) or path)
  if not text then return "missing" end
  local ok, v = pcall(J.decode, text)
  if not ok or type(v) ~= "table" or type(v.hooks) ~= "table" then return "missing" end
  -- 登録されている自分の分の (イベント, matcher) の組と、自分の分があるイベント
  local have, have_ev = {}, {}
  for ev, list in pairs(v.hooks) do
    if type(list) == "table" then
      for _, group in ipairs(list) do
        if type(group) == "table" and type(group.hooks) == "table" then
          for _, h in ipairs(group.hooks) do
            if is_ours(h) then
              have[ev .. "\0" .. tostring(group.matcher or "")] = true
              have_ev[ev] = true
            end
          end
        end
      end
    end
  end
  local want, want_ev, n_ev, found = {}, {}, 0, 0
  for _, e in ipairs(M.events(scfg)) do
    want[e[1] .. "\0" .. (e[2] or "")] = true
    if not want_ev[e[1]] then
      want_ev[e[1]] = true
      n_ev = n_ev + 1
      if have_ev[e[1]] then found = found + 1 end
    end
  end
  if found == 0 then return "missing" end
  if found < n_ev then return "partial" end
  for k in pairs(have) do
    if not want[k] then return "outdated" end
  end
  for k in pairs(want) do
    if not have[k] then return "outdated" end
  end
  return "installed"
end

return M
