-- agentmap/term.lua ... find the Claude Code terminal inside this Neovim and type into it.
--   Used to steer the main agent (ROOT), to ask it to redo a finished agent
--   (DESIGN-v0.2-steer.md §4) and to relay an instruction to one of its sub-agents, which it passes
--   on with SendMessage (DESIGN-v0.1.2-steer2 §4). A candidate is a terminal buffer whose name is
--   term://<dir>//<pid>:<cmd> (:terminal, snacks.nvim and toggleterm all follow this) and whose
--   <cmd> contains the word "claude", or whose shell has Claude Code running under it (started
--   through an alias such as `claude-personal`), with a job that is still running.
--   Claude Code reads text typed while it works at its next tool boundary. A short line with "\r"
--   in one chansend is submitted, but a long line (about 250 characters, the length of a notice to
--   the parent) arriving in one write is treated as a paste and stays in the input box unsent;
--   sending "\r" 150 ms or more later submits it (measured with Claude Code 2.1.289), hence
--   steer.submit_delay_ms = 300 by default.
local M = {}

local function norm(p)
  if type(p) ~= "string" or p == "" then return nil end
  p = vim.fn.fnamemodify(vim.fn.expand(p), ":p")
  p = p:gsub("[/\\]+$", "")
  return p == "" and "/" or p
end

--- Parse a terminal buffer name. Returns dir, pid, cmd (or nil when it is not term://).
---@param name string
function M.parse_name(name)
  if type(name) ~= "string" then return nil end
  local dir, pid, cmd = name:match("^term://(.-)//(%d+):(.*)$")
  if not dir then return nil end
  return dir, tonumber(pid), cmd
end

--- True when the command of a terminal name looks like Claude Code ("claude" as a word,
--- also with environment variables in front: `CLAUDE_CONFIG_DIR=… claude`).
function M.is_claude_cmd(cmd)
  if type(cmd) ~= "string" then return false end
  local lc = cmd:lower()
  -- 環境変数の名前（CLAUDE_CONFIG_DIR=）だけの一致は数えない
  lc = lc:gsub("[%w_]+=%S*", " ")
  for word in lc:gmatch("[^%s/\\'\"]+") do
    if word == "claude" or word:match("^claude[%.%-]") or word:match("^claude$") then return true end
  end
  return false
end

local function job_alive(job)
  if type(job) ~= "number" or job <= 0 then return false end
  local ok, r = pcall(vim.fn.jobwait, { job }, 0)
  return ok and r[1] == -1
end

--- True when Claude Code runs as a descendant of process `pid` (a shell started by :terminal, with
--- Claude typed into it, e.g. through an alias such as `claude-personal`). The buffer name then
--- ends in the shell (":/bin/bash"), so the name alone cannot tell.
--- Uses nvim_get_proc_children / nvim_get_proc, which work on Linux, macOS and Windows.
---@param pid integer
---@param depth? integer how many levels to look down (default 3)
function M.runs_claude(pid, depth)
  if type(pid) ~= "number" or pid <= 0 then return false end
  depth = depth or 3
  local ok, kids = pcall(vim.api.nvim_get_proc_children, pid)
  if not ok or type(kids) ~= "table" then return false end
  for _, k in ipairs(kids) do
    local okp, info = pcall(vim.api.nvim_get_proc, k)
    if okp and type(info) == "table" and M.is_claude_cmd(tostring(info.name or "")) then return true end
    -- 名前で分からないとき（macOS では台本や中継のプロセスの名前が sh などになる）は起動したときのコマンドを見る
    if M.is_claude_cmd(M.proc_command(k) or "") then return true end
    if depth > 1 and M.runs_claude(k, depth - 1) then return true end
  end
  return false
end

--- The command line a process was started with (`ps -o command=`), or nil on Windows / failure.
---@param pid integer
function M.proc_command(pid)
  if type(pid) ~= "number" or pid <= 0 or vim.fn.has("win32") == 1 then return nil end
  local ok, out = pcall(vim.fn.system, { "ps", "-o", "command=", "-p", tostring(pid) })
  if not ok or vim.v.shell_error ~= 0 or type(out) ~= "string" then return nil end
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

--- Claude terminals, best first. score: 3 = same folder as `cwd`, 2 = a parent of `cwd`, 1 = other.
---@param cwd? string the run's folder (state.cwd); default getcwd()
---@param bufs? integer[] buffers to look at (default: all buffers; tests pass their own)
---@return table[] { { buf, job, cwd, cmd, score }, … }
function M.candidates(cwd, bufs)
  cwd = norm(cwd or vim.fn.getcwd())
  local out = {}
  for _, b in ipairs(bufs or vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
      local dir, pid, cmd = M.parse_name(vim.api.nvim_buf_get_name(b))
      -- 名前に claude が無くても（シェルの中で別名から起動した claude）、子のプロセスに claude がいれば数える
      if dir and (M.is_claude_cmd(cmd) or M.runs_claude(vim.b[b].terminal_job_pid or pid)) then
        local job = vim.b[b].terminal_job_id
        if job_alive(job) then
          local d = norm(dir)
          local score = 1
          if d and cwd and d == cwd then
            score = 3
          elseif d and cwd and (cwd:sub(1, #d + 1) == d .. "/" or d == "/") then
            score = 2
          end
          out[#out + 1] = { buf = b, job = job, cwd = d, cmd = cmd, score = score }
        end
      end
    end
  end
  table.sort(out, function(x, y)
    if x.score ~= y.score then return x.score > y.score end
    return x.buf > y.buf -- 同点なら新しいバッファを先に
  end)
  return out
end

--- The one terminal to send to: the single best score, when it is the run's folder (3) or a parent of it (2).
--- When the best score is shared, or the best is only "another folder" (1: most likely the Claude of a
--- different project), returns nil and the candidates (the caller lets the user pick, or falls back).
---@return table|nil cand, table[] candidates, boolean tied
function M.find(cwd, bufs)
  local list = M.candidates(cwd, bufs)
  if #list == 0 then return nil, list, false end
  -- 別のフォルダの Claude には黙って送らない（別プロジェクトの Claude に指示が入るのを防ぐ）
  if list[1].score < 2 then return nil, list, true end
  if #list == 1 or list[1].score > list[2].score then return list[1], list, false end
  return nil, list, true
end

--- One line of text: control characters (CR, LF, ESC, …) become spaces. A trailing backslash gets a
--- space after it: Claude Code reads "\" + Enter as "new line" instead of "submit", so the line would
--- stay in its input box and the next one sent would be glued to it (measured with 2.1.291).
function M.sanitize(text)
  text = tostring(text or "")
  text = text:gsub("[%c\127]", " ")
  text = vim.trim(text:gsub("  +", " "))
  if text:sub(-1) == "\\" then text = text .. " " end
  return text
end

-- Lines whose Enter is delayed are sent one at a time per terminal job: text, "\r" after the
-- delay, then the same gap before the next line. Without this, two lines sent within the delay
-- (for example two notices to the parent in the same tick) would land in Claude Code's input box
-- as one line.
local queues = {} -- [job] = { items = { { line, submit, delay }, … }, busy = boolean }

local function pump(job)
  local q = queues[job]
  if not q or q.busy then return end
  local it = table.remove(q.items, 1)
  if not it or not job_alive(job) then
    queues[job] = nil
    return
  end
  q.busy = true
  pcall(vim.fn.chansend, job, it.line)
  vim.defer_fn(function()
    if it.submit and job_alive(job) then pcall(vim.fn.chansend, job, "\r") end
    vim.defer_fn(function()
      q.busy = false
      pump(job)
    end, it.delay)
  end, it.delay)
end

--- Lines still queued or in flight for `job` (0 when idle). Tests wait on this.
---@param job integer
---@return integer
function M.pending(job)
  local q = queues[job]
  if not q then return 0 end
  return #q.items + (q.busy and 1 or 0)
end

--- Type `text` into the terminal job and press Enter.
---@param job integer terminal job id (vim.b[buf].terminal_job_id)
---@param text string
---@param opts? { submit?: boolean, delay_ms?: integer }  submit (default true) sends "\r";
---   delay_ms > 0 sends the text first and "\r" after that many milliseconds (default 0: one
---   write). Delayed lines to the same job are queued and sent one after another.
---@return boolean ok, string|nil err
function M.send(job, text, opts)
  opts = opts or {}
  if not job_alive(job) then return false, "terminal job is not running" end
  local line = M.sanitize(text)
  if line == "" then return false, "empty" end
  local submit = opts.submit ~= false
  local delay = tonumber(opts.delay_ms) or 0
  if submit and delay <= 0 and not queues[job] then
    local ok, n = pcall(vim.fn.chansend, job, line .. "\r")
    if not ok or n == 0 then return false, ok and "chansend failed" or tostring(n) end
    return true
  end
  queues[job] = queues[job] or { items = {}, busy = false }
  table.insert(queues[job].items, { line = line, submit = submit, delay = math.max(0, delay) })
  pump(job)
  return true
end

return M
