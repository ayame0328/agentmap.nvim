-- agentmap/views/transcript.lua ... an agent's transcript (conversation log) view.
--   記録の読み取りは providers/claude.lua の transcript_entries に任せる。
--   それが無いとき（まだ用意されていない等）だけ、ここの簡易版で読む。
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local H = graph.util
local t = require("agentmap.i18n").t

local M = {}

local function provider(run)
  local ok, reg = pcall(require, "agentmap.providers")
  if ok and type(reg) == "table" and type(reg.get) == "function" then
    local ok2, p = pcall(reg.get, run and run.provider or "claude")
    if ok2 and type(p) == "table" then return p end
  end
  local ok3, p = pcall(require, "agentmap.providers.claude")
  if ok3 and type(p) == "table" then return p end
  return nil
end

--- Path of the agent's transcript file, or nil.
-- transcript ファイルの場所を探す
function M.path_for(run, agent)
  local state = run.state
  if agent.id == "ROOT" then
    return state.root_transcript or agent.transcript_path
  end
  if agent.transcript_path and vim.fn.filereadable(agent.transcript_path) == 1 then
    return agent.transcript_path
  end
  local p = provider(run)
  if p and type(p.agent_transcript_path) == "function" then
    local ok, r = pcall(p.agent_transcript_path, run, agent)
    if ok and r then return r end
  end
  return agent.transcript_path
end

-- 簡易版の読み取り（providers が無いときだけ使う）
local SKIP = { attachment = true, ["queue-operation"] = true, ["atis-latch"] = true,
  ["last-prompt"] = true, ["cost-state"] = true, system = true }

local function block_text(c)
  if type(c) == "string" then return c end
  if type(c) == "table" then
    local out = {}
    for _, b in ipairs(c) do
      if type(b) == "table" and b.type == "text" then out[#out + 1] = b.text end
    end
    return table.concat(out, "\n")
  end
  return ""
end

--- Minimal transcript reader used when the provider has none.
function M.parse_fallback(path, max_bytes)
  local f = io.open(path, "r")
  if not f then return nil end
  local size = f:seek("end")
  local notice = nil
  if max_bytes and size > max_bytes then
    f:seek("set", size - max_bytes)
    f:read("*l") -- 途中の行は捨てる
    notice = t("transcript.tail_only", { mb = math.floor(max_bytes / 1e6) })
  else
    f:seek("set", 0)
  end
  local entries = {}
  if notice then entries[1] = { kind = "notice", text = notice } end
  for line in f:lines() do
    local ok, d = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(d) == "table" and not SKIP[d.type] and type(d.message) == "table" then
      local msg = d.message
      if d.type == "user" then
        if type(msg.content) == "string" then
          entries[#entries + 1] = { kind = "user", ts = d.timestamp, text = msg.content }
        elseif type(msg.content) == "table" then
          for _, b in ipairs(msg.content) do
            if b.type == "tool_result" then
              entries[#entries + 1] = { kind = "tool_result", ts = d.timestamp, text = block_text(b.content) }
            elseif b.type == "text" then
              entries[#entries + 1] = { kind = "user", ts = d.timestamp, text = b.text }
            end
          end
        end
      elseif d.type == "assistant" and type(msg.content) == "table" then
        for _, b in ipairs(msg.content) do
          if b.type == "text" then
            entries[#entries + 1] = { kind = "assistant", ts = d.timestamp, model = msg.model, text = b.text }
          elseif b.type == "thinking" then
            entries[#entries + 1] = { kind = "thinking", ts = d.timestamp }
          elseif b.type == "tool_use" then
            local inp = b.input or {}
            entries[#entries + 1] = { kind = "tool_use", ts = d.timestamp, tool = b.name,
              target = inp.description or inp.file_path or inp.notebook_path or inp.command or inp.pattern }
          end
        end
      end
    end
  end
  f:close()
  return entries
end

-- 表示幅 w で折り返す
local function wrap(text, w)
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local cur, used = {}, 0
      for _, c in ipairs(H.chars(para)) do
        local cw = H.dw(c)
        if used + cw > w and used > 0 then
          out[#out + 1] = table.concat(cur)
          cur, used = {}, 0
        end
        cur[#cur + 1] = c
        used = used + cw
      end
      out[#out + 1] = table.concat(cur)
    end
  end
  return out
end

local function cap(text, max_chars)
  text = text or ""
  local n = vim.fn.strchars(text)
  if n > max_chars then
    return vim.fn.strcharpart(text, 0, max_chars) .. t("transcript.more_chars", { n = n - max_chars })
  end
  return text
end

--- Build the transcript view lines from entries (pure). opts = { width, max_chars, title, path }.
function M.build(entries, opts)
  opts = opts or {}
  local w = math.max(20, (opts.width or 80) - 4)
  local max_chars = opts.max_chars or 2000
  local b = renderer.builder()
  b:add({ { "■ transcript  " .. (opts.title or ""), "AgentMapHeader" } })
  if opts.path then b:add({ { "  " .. opts.path, "AgentMapDim" } }) end
  b:add({ { t("transcript.keys"), "AgentMapDim" } })
  b:add("")
  for _, e in ipairs(entries or {}) do
    if e.kind == "notice" then
      b:add({ { e.text, "AgentMapDim" } })
    elseif e.kind == "user" then
      b:add({ { "▶ USER " .. H.fmt_clock(e.ts), "Title" } })
      for _, l in ipairs(wrap(cap(e.text, max_chars), w)) do b:add("  " .. l) end
    elseif e.kind == "assistant" then
      b:add({ { "◀ ASSISTANT " .. (H.model_short(e.model) or "") .. " " .. H.fmt_clock(e.ts), "Title" } })
      for _, l in ipairs(wrap(cap(e.text, max_chars), w)) do b:add("  " .. l) end
    elseif e.kind == "tool_use" then
      b:add({ { "  ⚙ " .. (e.tool or "?") .. "  " .. H.truncate(e.target or "", w - 10), "AgentMapDim" } })
    elseif e.kind == "tool_result" then
      b:add({ { "  ↳ result: " .. H.truncate(H.oneline(e.text or ""), 200), "AgentMapDim" } })
    elseif e.kind == "thinking" then
      b:add({ { "  (thinking …)", "AgentMapDim" } })
    end
  end
  if not entries or #entries == 0 then b:add({ { t("transcript.empty"), "AgentMapDim" } }) end
  return b:result()
end

--- Render the transcript of `agent` into `buf`.
function M.open(run, agent, buf, opts)
  opts = opts or {}
  local cfg = H.config()
  local tcfg = cfg.transcript or {}
  local path = M.path_for(run, agent)
  local title = agent.id == "ROOT" and "ROOT" or ("[" .. (agent.index or "?") .. "] " .. (agent.name or agent.task or agent.id))
  local res
  if not path or vim.fn.filereadable(path) ~= 1 then
    local b = renderer.builder()
    b:add({ { "■ transcript  " .. title, "AgentMapHeader" } })
    b:add("")
    b:add(t("transcript.not_found"))
    b:add({ { t("transcript.location", { path = tostring(path or t("transcript.no_record")) }), "AgentMapDim" } })
    b:add({ { t("transcript.not_found_hint"), "AgentMapDim" } })
    b:add("")
    b:add({ { t("transcript.keys_short"), "AgentMapDim" } })
    res = b:result()
  else
    local entries
    local p = provider(run)
    if p and type(p.transcript_entries) == "function" then
      local ok, r = pcall(p.transcript_entries, path, { max_bytes = tcfg.max_bytes or 5e6 })
      if ok and type(r) == "table" then entries = r end
    end
    entries = entries or M.parse_fallback(path, tcfg.max_bytes or 5e6) or {}
    res = M.build(entries, { width = opts.width, max_chars = tcfg.max_chars or 2000, title = title, path = path })
  end
  renderer.set_all(buf, res.lines, res.marks)
  return res
end

return M
