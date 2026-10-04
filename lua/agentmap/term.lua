-- agentmap/term.lua ... find the Claude Code terminal inside this Neovim and type into it.
--   Used to steer the main agent (ROOT) and to ask it to redo a finished agent
--   (DESIGN-v0.2-steer.md §4). A candidate is a terminal buffer whose name is
--   term://<dir>//<pid>:<cmd> (:terminal, snacks.nvim and toggleterm all follow this) and whose
--   <cmd> contains the word "claude", with a job that is still running.
--   Claude Code reads text typed while it works at its next tool boundary; text + "\r" in one
--   chansend is submitted (verified with Claude Code 2.1.288).
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

--- Claude terminals, best first. score: 3 = same folder as `cwd`, 2 = a parent of `cwd`, 1 = other.
---@param cwd? string the run's folder (state.cwd); default getcwd()
---@param bufs? integer[] buffers to look at (default: all buffers; tests pass their own)
---@return table[] { { buf, job, cwd, cmd, score }, … }
function M.candidates(cwd, bufs)
  cwd = norm(cwd or vim.fn.getcwd())
  local out = {}
  for _, b in ipairs(bufs or vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
      local dir, _, cmd = M.parse_name(vim.api.nvim_buf_get_name(b))
      if dir and M.is_claude_cmd(cmd) then
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

--- The one terminal to send to: the only candidate, or the single best score.
--- When the best score is shared, returns nil and the candidates (the caller lets the user pick).
---@return table|nil cand, table[] candidates, boolean tied
function M.find(cwd, bufs)
  local list = M.candidates(cwd, bufs)
  if #list == 0 then return nil, list, false end
  if #list == 1 or list[1].score > list[2].score then return list[1], list, false end
  return nil, list, true
end

--- One line of text: control characters (CR, LF, ESC, …) become spaces.
function M.sanitize(text)
  text = tostring(text or "")
  text = text:gsub("[%c\127]", " ")
  return (vim.trim(text:gsub("  +", " ")))
end

--- Type `text` into the terminal job and press Enter.
---@param job integer terminal job id (vim.b[buf].terminal_job_id)
---@param text string
---@param opts? { submit?: boolean, delay_ms?: integer }  submit (default true) sends "\r";
---   delay_ms > 0 sends the text first and "\r" after that many milliseconds (default 0: one write)
---@return boolean ok, string|nil err
function M.send(job, text, opts)
  opts = opts or {}
  if not job_alive(job) then return false, "terminal job is not running" end
  local line = M.sanitize(text)
  if line == "" then return false, "empty" end
  local submit = opts.submit ~= false
  local delay = tonumber(opts.delay_ms) or 0
  local ok, n
  if submit and delay <= 0 then
    ok, n = pcall(vim.fn.chansend, job, line .. "\r")
  else
    ok, n = pcall(vim.fn.chansend, job, line)
    if ok and n ~= 0 and submit then
      vim.defer_fn(function()
        if job_alive(job) then pcall(vim.fn.chansend, job, "\r") end
      end, delay)
    end
  end
  if not ok or n == 0 then return false, ok and "chansend failed" or tostring(n) end
  return true
end

return M
