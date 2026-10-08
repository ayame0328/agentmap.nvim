-- agentmap/health.lua ... :checkhealth agentmap (DESIGN §8, DESIGN-v0.2 §4.2, DESIGN-v0.2-steer §8.2,
--   DESIGN-v0.1.2-pause §8.2, DESIGN-v0.1.2-steer2 §9.2, DESIGN-v0.1.2-handback §7.2).
--   Read-only except for one temp file in the record store (writability check);
--   the progress statistics are loaded without writing stats.json.
--   Never calls hooks.install().
local M = {}

--- Claude Code version the hook payloads were last verified with.
M.VERIFIED_CLAUDE_CODE = "2.1.294"

local function t(key, vars)
  return require("agentmap.i18n").t(key, vars)
end

local function first_line(s)
  return vim.trim((tostring(s or "")):match("[^\r\n]*") or "")
end

--- Run argv and return the first line of stdout/stderr, or nil when it cannot run.
local function run(argv, timeout)
  local ok, obj = pcall(function()
    return vim.system(argv, { text = true }):wait(timeout or 5000)
  end)
  if not ok or not obj or obj.code ~= 0 then return nil end
  local out = first_line(obj.stdout)
  if out == "" then out = first_line(obj.stderr) end
  return out
end

local function count_runs(root)
  local n = 0
  local projects = root .. "/projects"
  for slug, kind in vim.fs.dir(projects) do
    if kind == "directory" then
      for _, k in vim.fs.dir(projects .. "/" .. slug .. "/runs") do
        if k == "directory" then n = n + 1 end
      end
    end
  end
  return n
end

local function writable(dir)
  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if not ok or vim.fn.isdirectory(dir) == 0 then return false end
  end
  local tmp = dir .. "/.agentmap-health-" .. tostring(vim.uv.hrtime())
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write("ok")
  f:close()
  os.remove(tmp)
  return true
end

local function executable(argv)
  return type(argv) == "table" and type(argv[1]) == "string" and vim.fn.executable(argv[1]) == 1
end

-- settings.json に登録された hook の command を全部（読めなければ空）
local function registered_commands(path)
  local util = require("agentmap.util")
  local js = util.json_decode(util.read_file(path))
  local out = {}
  if type(js) ~= "table" or type(js.hooks) ~= "table" then return out end
  for ev, groups in pairs(js.hooks) do
    for _, g in ipairs(type(groups) == "table" and groups or {}) do
      for _, h in ipairs(type(g) == "table" and type(g.hooks) == "table" and g.hooks or {}) do
        if type(h) == "table" and type(h.command) == "string" then out[#out + 1] = { event = ev, command = h.command } end
      end
    end
  end
  return out
end

--- Whether the registered steering hooks match the steer settings (DESIGN-v0.1.2-steer2 §9.2 row 13).
--- Every delivery hook (--steer) must carry the configured --mode (none = "stop", as the collector reads it)
--- and the SubagentStop / Stop hooks must be there. Mode "deny" / "context" also needs the PreToolUse guard
--- and --at-stop on the stop hooks (mode "stop" delivers only at the end, so the guard is not required).
---@param path string settings.json
---@param scfg table config.get().steer
---@return boolean ok, string|nil registered the --mode found on the registered delivery hooks (first one)
function M.steer_registration_ok(path, scfg)
  local want = (type(scfg) == "table" and scfg.mode) or "stop"
  local guard, at_stop, mode_ok, stop_hooks, stop_at = false, false, true, 0, 0
  local registered
  for _, c in ipairs(registered_commands(path)) do
    if c.command:find("--steer", 1, true) then
      local m = c.command:match("%-%-mode%s+'?([%w_]+)") or "stop"
      registered = registered or m
      if m ~= want then mode_ok = false end
      if c.event == "PreToolUse" then
        guard = true
      elseif c.event == "SubagentStop" or c.event == "Stop" then
        stop_hooks = stop_hooks + 1
        if c.command:find("--at-stop", 1, true) then stop_at = stop_at + 1 end
      end
    end
  end
  at_stop = stop_hooks > 0 and stop_at == stop_hooks
  if not mode_ok or stop_hooks == 0 then return false, registered end
  if want == "stop" then return true, registered end
  return guard and at_stop, registered
end

--- Whether one of our PostToolUse hooks lists SendMessage in its matcher (DESIGN-v0.1.2-steer2 §9.2 row 18).
---@param path string settings.json
---@return boolean
function M.sendmessage_recorded(path)
  local util = require("agentmap.util")
  local js = util.json_decode(util.read_file(path))
  if type(js) ~= "table" or type(js.hooks) ~= "table" then return false end
  local ok_h, hooks = pcall(require, "agentmap.hooks")
  local function ours(h)
    if ok_h and type(hooks.is_ours) == "function" then
      local ok, r = pcall(hooks.is_ours, h)
      if ok then return r and true or false end
    end
    return type(h.command) == "string" and h.command:find("agentmap-collect", 1, true) ~= nil
  end
  for _, g in ipairs(type(js.hooks.PostToolUse) == "table" and js.hooks.PostToolUse or {}) do
    if type(g) == "table" and type(g.matcher) == "string" then
      local has = false
      for tool in g.matcher:gmatch("[^|]+") do
        if vim.trim(tool) == "SendMessage" then has = true end
      end
      if has then
        for _, h in ipairs(type(g.hooks) == "table" and g.hooks or {}) do
          if type(h) == "table" and ours(h) then return true end
        end
      end
    end
  end
  return false
end

--- The --handback word ("relay" | "deny") of our registered PreToolUse hook for SubagentHandback
--- (DESIGN-v0.1.2-handback §6, §7.2), or nil when it is not registered. Uses hooks.features().handback
--- when it is a string; otherwise reads the commands in settings.json.
---@param path string settings.json
---@return string|nil
function M.handback_registration(path)
  local ok_h, hooks = pcall(require, "agentmap.hooks")
  if ok_h and type(hooks.features) == "function" then
    local ok, r = pcall(hooks.features, path)
    if ok and type(r) == "table" and type(r.handback) == "string" and r.handback ~= "" then return r.handback end
  end
  for _, c in ipairs(registered_commands(path)) do
    if c.event == "PreToolUse" and c.command:find("--handback", 1, true) then
      return c.command:match("%-%-handback%s+'?([%w_]+)") or "relay"
    end
  end
  return nil
end

--- The hand-back route the settings ask for: "deny" when steer.handback = "deny" or steer.mode is
--- deny / context (those modes also hand over before tools), else "relay".
---@param scfg table config.get().steer
---@return string
function M.handback_route(scfg)
  scfg = type(scfg) == "table" and scfg or {}
  if scfg.mode == "deny" or scfg.mode == "context" or scfg.handback == "deny" then return "deny" end
  return "relay"
end

-- 図で見ている run の権限モード（state.permission_mode。W1 が足す欄。無ければ nil）
local function viewed_permission_mode()
  -- 図を開いていなければ ui は読み込まれていない（health のために読み込まない）
  local ui = package.loaded["agentmap.ui"]
  local st = type(ui) == "table" and type(ui.run) == "table" and ui.run.state or nil
  if type(st) ~= "table" then return nil end
  local m = st.permission_mode
  return (type(m) == "string" and m ~= "") and m or nil
end

-- 未配達の指示ファイル（.delivered.json と書きかけを除く）の数
local function pending_steer_files(root)
  local n = 0
  for _, f in ipairs(vim.fn.glob(root .. "/projects/*/runs/*/steer/*.json", false, true)) do
    if not f:find("%.delivered%.json$") then n = n + 1 end
  end
  return n
end

-- settings.json に登録された自分の配達用 hook（--steer）の機能語と timeout（hooks.features と同じ形）
local function registered_features(path)
  local util = require("agentmap.util")
  local js = util.json_decode(util.read_file(path))
  local out = { steer = false, pause = false }
  if type(js) ~= "table" or type(js.hooks) ~= "table" then return out end
  for ev, groups in pairs(js.hooks) do
    for _, g in ipairs(type(groups) == "table" and groups or {}) do
      for _, h in ipairs(type(g) == "table" and type(g.hooks) == "table" and g.hooks or {}) do
        local c = type(h) == "table" and h.command
        if type(c) == "string" and c:find("--steer", 1, true) then
          out.steer = true
          if c:find("--pause", 1, true) then out.pause = true end
          local mw = tonumber(c:match("%-%-max%-wait%s+'?(%d+)"))
          if mw then out.max_wait = mw end
          local to = tonumber(h.timeout)
          if ev == "PreToolUse" then
            out.guard_timeout = to
          elseif ev == "SubagentStop" or ev == "Stop" then
            if out.stop_timeout == nil or (to or 0) < out.stop_timeout then out.stop_timeout = to end
          end
        end
      end
    end
  end
  return out
end

--- Whether the registered delivery hooks carry pause support for these settings
--- (DESIGN-v0.1.2-pause §8.2 row 16): --pause on the delivery hooks and a timeout of at least
--- auto_resume_s + 30 on the guard and stop hooks. Uses hooks.features() when present.
---@return boolean ok, integer|nil timeout the smallest registered timeout of the delivery hooks
function M.pause_registration(path, pcfg)
  pcfg = type(pcfg) == "table" and pcfg or {}
  local f
  local ok_h, hooks = pcall(require, "agentmap.hooks")
  if ok_h and type(hooks.features) == "function" then
    local ok, r = pcall(hooks.features, path)
    if ok and type(r) == "table" then f = r end
  end
  f = f or registered_features(path)
  local need = (tonumber(pcfg.auto_resume_s) or 600) + 30
  local g, st = tonumber(f.guard_timeout), tonumber(f.stop_timeout)
  local timeout = (g and st) and math.min(g, st) or g or st
  local good = f.pause == true and g ~= nil and g >= need and (st == nil or st >= need)
  return good, timeout
end

-- 止まれのファイル（<run>/pause/<target>.json。.hit.json と GATE は数えない）の数
local function pause_files(root)
  local n = 0
  for _, f in ipairs(vim.fn.glob(root .. "/projects/*/runs/*/pause/*.json", false, true)) do
    if not f:find("%.hit%.json$") then n = n + 1 end
  end
  return n
end

local function fmt_ms(ms)
  if type(ms) ~= "number" then return "-" end
  return require("agentmap.util").fmt_elapsed(ms)
end

--- Entry point for :checkhealth agentmap.
function M.check()
  local h = vim.health
  local config = require("agentmap.config")
  local hooks = require("agentmap.hooks")
  local i18n = require("agentmap.i18n")
  -- 言語は setup()（無ければ plugin/ が vim.g.agentmap_lang で）決めたものをそのまま使う

  h.start("agentmap")

  -- 1. Neovim
  local v = vim.version()
  local vs = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok(t("health.nvim_ok", { version = vs }))
  else
    h.error(t("health.nvim_old", { version = vs }))
  end

  -- 2. Python
  local py = config.python()
  if py and executable(py) then
    local argv = vim.list_extend(vim.deepcopy(py), { "--version" })
    local out = run(argv)
    if out then
      h.ok(t("health.python_ok", { cmd = table.concat(py, " "), version = out }))
    else
      h.error(t("health.python_broken", { cmd = table.concat(py, " ") }))
    end
  elseif py then
    h.error(t("health.python_not_executable", { cmd = table.concat(py, " ") }))
  else
    h.error(t("health.python_missing"))
  end

  -- 3. Collector
  local collector = hooks.collector_path()
  if vim.fn.filereadable(collector) == 1 then
    h.ok(t("health.collector_ok", { path = collector }))
  else
    h.error(t("health.collector_missing", { path = collector }))
  end

  -- 4. Claude config dir
  local cdir, csrc = config.claude_config_dir(), config.claude_config_source()
  if vim.fn.isdirectory(cdir) == 0 then
    h.error(t("health.claude_dir_missing", { path = cdir, source = csrc }))
  elseif vim.fn.isdirectory(cdir .. "/projects") == 0 then
    h.warn(t("health.claude_projects_missing", { path = cdir, source = csrc }))
  else
    h.ok(t("health.claude_dir_ok", { path = cdir, source = csrc }))
  end

  -- 5. Hooks in settings.json
  local spath = config.settings_path()
  local st = hooks.status(spath)
  if st == "installed" then
    h.ok(t("health.hooks_installed", { path = spath }))
  elseif st == "outdated" then
    h.warn(t("health.hooks_outdated", { path = spath }))
  elseif st == "partial" then
    h.warn(t("health.hooks_partial", { path = spath }))
  else
    h.error(t("health.hooks_missing", { path = spath }))
  end

  -- 6. Record store
  local root, rsrc = config.root(), config.root_source()
  if rsrc == "AGENTFLOW_DIR" then
    h.warn(t("health.store_deprecated_env"))
  end
  if writable(root) then
    h.ok(t("health.store_ok", { path = root, source = rsrc, runs = count_runs(root) }))
  else
    h.warn(t("health.store_not_writable", { path = root, source = rsrc }))
  end

  -- 7. Optional tools
  if vim.fn.executable("git") == 1 then
    h.ok(t("health.git_ok"))
  else
    h.warn(t("health.git_missing"))
  end
  if package.loaded["oil"] then
    h.ok(t("health.oil_ok"))
  else
    h.warn(t("health.oil_missing"))
  end
  local ex = config.get().export or {}
  for _, name in ipairs({ "html_command", "pdf_command" }) do
    local argv = ex[name]
    if argv == nil then
      h.info(t("health." .. name .. "_unset"))
    elseif executable(argv) then
      h.ok(t("health.command_ok", { name = "export." .. name, cmd = argv[1] }))
    else
      h.warn(t("health.command_missing", { name = "export." .. name, cmd = tostring(type(argv) == "table" and argv[1] or argv) }))
    end
  end

  -- 8. Claude Code
  if vim.fn.executable("claude") == 1 then
    local out = run({ "claude", "--version" }, 10000) or "?"
    h.ok(t("health.claude_ok", { version = out, verified = M.VERIFIED_CLAUDE_CODE }))
  else
    h.warn(t("health.claude_missing", { verified = M.VERIFIED_CLAUDE_CODE }))
  end

  -- 9. Language
  local missing = i18n.missing(i18n.lang)
  if #missing == 0 then
    h.ok(t("health.lang_ok", { lang = i18n.lang }))
  else
    h.warn(t("health.lang_missing", { lang = i18n.lang, n = #missing, keys = table.concat(missing, ", ") }))
  end
  -- 10. 進み具合の履歴（DESIGN-v0.2 §4.2）
  local root10 = config.root()
  local pcfg = config.get().progress or {}
  local ok_s, S = pcall(function() return require("agentmap.stats").load(root10, { no_write = true, force = true }) end)
  if ok_s and type(S) == "table" then
    local all = S.all or {}
    local na = (all.agents and all.agents.n) or 0
    if na < (pcfg.min_samples or 3) then
      h.warn(t("health.progress_history_low", { agents = na, default = fmt_ms(pcfg.default_ms or 600000) }))
    else
      h.ok(t("health.progress_history_ok", { agents = na, runs = vim.tbl_count(S.runs or {}),
        median = fmt_ms(all.agents.median_ms), steps = (all.steps and all.steps.n) or 0 }))
    end
  else
    h.warn(t("health.progress_history_low", { agents = 0, default = fmt_ms(pcfg.default_ms or 600000) }))
  end

  -- 11. 推定の答え合わせ（影運転の記録）
  if pcfg.log == false then
    h.info(t("health.estimate_log_off"))
  else
    local ok_e, ev = pcall(function() return require("agentmap.stats").evaluate(root10) end)
    local n = ok_e and type(ev) == "table" and ev.n or 0
    if n >= 20 and ev.median_abs_err then
      h.ok(t("health.estimate_check", { err = ("%.1f"):format(ev.median_abs_err), n = n }))
    else
      h.info(t("health.estimate_check_few", { n = n }))
    end
  end

  -- 12. 光
  local acfg = config.get().animation or {}
  if acfg.enabled == false then
    h.info(t("health.anim_off"))
  else
    local low
    local ok_a, anim = pcall(require, "agentmap.anim")
    if ok_a and type(anim.low_color) == "function" then
      low = anim.low_color()
    else
      local ui = vim.api.nvim_list_uis()[1]
      low = not vim.o.termguicolors and (not ui or (tonumber(ui.term_colors) or 0) < 16)
    end
    if low then
      h.warn(t("health.anim_low_color"))
    else
      h.ok(t("health.anim_on", { ms = acfg.frame_ms or 100, tgc = vim.o.termguicolors and "on" or "off" }))
    end
  end

  -- 13. 修正指示の登録（DESIGN-v0.1.2-steer2 §9.2）
  local scfg = config.get().steer or {}
  local smode = scfg.mode or "stop"
  if scfg.enabled == false then
    h.info(t("health.steer_off"))
  else
    if M.steer_registration_ok(spath, scfg) then
      h.ok(t("health.steer_on", { mode = smode }))
    else
      h.warn(t("health.steer_outdated"))
    end
    if smode == "deny" or smode == "context" then
      h.info(t("health.steer_mode_tool_result", { mode = smode }))
    end
  end
  if type(config.steer_at_stop_given) == "function" and config.steer_at_stop_given() then
    h.info(t("health.steer_at_stop_ignored"))
  end

  -- 13b. 報告を SubagentHandback で返す子への経路と、その登録（DESIGN-v0.1.2-handback §7.2）
  local pz_on = (config.get().pause or {}).enabled ~= false
  local hb_route = M.handback_route(scfg)
  if scfg.enabled ~= false then
    h.info(t(hb_route == "deny" and "health.handback_deny" or "health.handback_relay"))
  end
  -- 登録が要るのは、止まれ（関門・stop）を使うとき、または deny で渡すとき（relay で止まれも無効なら登録しない）
  local hb_need = pz_on or (scfg.enabled ~= false and hb_route == "deny")
  if hb_need then
    local reg = M.handback_registration(spath)
    if reg and (reg == hb_route or scfg.enabled == false) then
      h.ok(t("health.handback_hook_ok", { mode = reg }))
    else
      h.warn(t("health.handback_hook_missing"))
    end
  end
  local pmode = viewed_permission_mode()
  if pmode == "auto" then
    h.info(t("health.run_auto"))
  elseif pmode then
    h.info(t("health.run_not_auto", { mode = pmode }))
  end

  -- 14. 未配達の印（health は書かないので、古い印も消さない）
  if vim.uv.fs_stat(root10 .. "/steer.pending") then
    local n = pending_steer_files(root10)
    if n == 0 then
      h.warn(t("health.steer_flag_stale"))
    else
      h.info(t("health.steer_flag_pending", { n = n }))
    end
  else
    h.ok(t("health.steer_flag_ok"))
  end

  -- 15. Claude の端末
  local ok_t, term = pcall(require, "agentmap.term")
  if not ok_t or type(term) ~= "table" or type(term.find) ~= "function" then
    h.info(t("health.term_missing"))
  else
    local ok_f, cand, list = pcall(term.find, vim.fn.getcwd())
    cand = ok_f and (cand or (type(list) == "table" and list[1])) or nil
    if cand then
      h.ok(t("health.term_ok", { buf = cand.buf, cwd = cand.cwd or "-" }))
    else
      h.info(t("health.term_none"))
    end
  end

  -- 16. 一時停止の登録（DESIGN-v0.1.2-pause §8.2）
  local pzcfg = config.get().pause or {}
  if pzcfg.enabled == false then
    h.info(t("health.pause_off"))
  else
    local ok16, timeout = M.pause_registration(spath, pzcfg)
    if ok16 then
      h.ok(t("health.pause_on", { s = pzcfg.auto_resume_s or 600, timeout = timeout or "-" }))
    else
      h.warn(t("health.pause_outdated"))
    end
  end

  -- 17. 止まれの印（health は消さない）
  if vim.uv.fs_stat(root10 .. "/pause.pending") then
    local n = pause_files(root10)
    if n == 0 then
      h.warn(t("health.pause_flag_stale"))
    else
      h.info(t("health.pause_flag_pending", { n = n }))
    end
  else
    h.ok(t("health.pause_flag_ok"))
  end

  -- 18. SendMessage の記録（親経由の確認。DESIGN-v0.1.2-steer2 §9.2）
  if M.sendmessage_recorded(spath) then
    h.ok(t("health.sendmessage_ok"))
  else
    h.warn(t("health.sendmessage_missing"))
  end
end

return M
