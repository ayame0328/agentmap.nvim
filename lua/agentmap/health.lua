-- agentmap/health.lua ... :checkhealth agentmap (DESIGN §8).
--   Read-only except for one temp file in the record store (writability check).
--   Never calls hooks.install().
local M = {}

--- Claude Code version the hook payloads were last verified with.
M.VERIFIED_CLAUDE_CODE = "2.1.286"

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
end

return M
