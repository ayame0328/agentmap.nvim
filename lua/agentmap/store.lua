-- ============================================================
--  agentmap/store.lua … 記録ファイルの読み書き（ファイルに触るのはここだけ）
--
--  <root>/projects/<slug>/project.json
--  <root>/projects/<slug>/runs/<session_id>/hooks.jsonl   … collector が書く（生の記録）
--  <root>/projects/<slug>/runs/<session_id>/events.jsonl  … Neovim が書く（整えた記録）
--  <root>/projects/<slug>/runs/<session_id>/state.json    … 集計結果の控え（消してもよい）
--
--  いずれ SQLite に替えるときも、このファイルだけ直せば済むようにしてある。
-- ============================================================
local config = require("agentmap.config")
local util = require("agentmap.util")

local M = {}
local uv = vim.uv or vim.loop

--- 1 つの run（= Claude の 1 セッション）の置き場所
function M.run_dir(slug, sid)
  return config.root() .. "/projects/" .. slug .. "/runs/" .. sid
end

--- フォルダを作っておく
function M.ensure(run_dir)
  vim.fn.mkdir(run_dir, "p")
  return run_dir
end

local function list_dir(dir)
  local out = {}
  local h = uv.fs_scandir(dir)
  if not h then return out end
  while true do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    out[#out + 1] = { name = name, type = typ }
  end
  return out
end

--- 記録があるプロジェクトの一覧 { {slug, dir}, ... }
function M.project_dirs()
  local base = config.root() .. "/projects"
  local out = {}
  for _, e in ipairs(list_dir(base)) do
    if e.type == "directory" then
      out[#out + 1] = { slug = e.name, dir = base .. "/" .. e.name }
    end
  end
  table.sort(out, function(a, b) return a.slug < b.slug end)
  return out
end

--- project.json を読む（無ければ nil）
function M.read_project(slug)
  return util.json_decode(util.read_file(config.root() .. "/projects/" .. slug .. "/project.json"))
end

local function mtime_of(p)
  local st = uv.fs_stat(p)
  if not st then return nil end
  return st.mtime.sec + (st.mtime.nsec or 0) / 1e9
end

--- あるプロジェクトの run 一覧（新しい順）
--- { {sid, dir, mtime, source = "hooks"|"transcript"|"empty"} }
function M.runs(slug)
  local base = config.root() .. "/projects/" .. slug .. "/runs"
  local out = {}
  for _, e in ipairs(list_dir(base)) do
    if e.type == "directory" then
      local dir = base .. "/" .. e.name
      local mh = mtime_of(dir .. "/hooks.jsonl")
      local me = mtime_of(dir .. "/events.jsonl")
      local source = mh and "hooks" or (me and "transcript" or "empty")
      out[#out + 1] = { sid = e.name, dir = dir, mtime = math.max(mh or 0, me or 0), source = source }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

--- 今のフォルダ（cwd）に対応するプロジェクトの slug。無ければ nil
function M.project_for_cwd(cwd)
  cwd = cwd or vim.fn.getcwd()
  local base = config.root() .. "/projects/"
  local s = util.slug(cwd)
  if uv.fs_stat(base .. s) then return s end
  -- 名札が一致しないときは project.json の cwd で探す（親フォルダも可）
  local best, best_len = nil, -1
  for _, p in ipairs(M.project_dirs()) do
    local pj = M.read_project(p.slug)
    local pc = pj and pj.cwd
    if type(pc) == "string" and pc ~= "" then
      if cwd == pc or cwd:sub(1, #pc + 1) == pc .. "/" then
        if #pc > best_len then best, best_len = p.slug, #pc end
      end
    end
  end
  return best
end

--- name（"hooks.jsonl" / "events.jsonl"）の off バイト目以降を読む → objs, new_off
function M.read_new(run_dir, name, off)
  return util.json_lines(run_dir .. "/" .. name, off or 0)
end

--- 整えた記録を 1 件追記
function M.append_event(run_dir, ev)
  local s = util.json_encode(ev)
  if not s then return false end
  return util.append_line(run_dir .. "/events.jsonl", s)
end

--- 整えた記録をまとめて追記（取り込み用）
function M.append_events(run_dir, evs)
  if #evs == 0 then return true end
  local parts = {}
  for _, ev in ipairs(evs) do
    local s = util.json_encode(ev)
    if s then parts[#parts + 1] = s end
  end
  return util.append_line(run_dir .. "/events.jsonl", table.concat(parts, "\n"))
end

--- 集計結果の控えを書く
function M.write_state(run_dir, state)
  local s = util.json_encode(state)
  if not s then return false end
  return util.write_atomic(run_dir .. "/state.json", s)
end

--- 集計結果の控えを読む（無い・壊れている → nil）
function M.read_state(run_dir)
  return util.json_decode(util.read_file(run_dir .. "/state.json"))
end

--- ファイルの大きさ（無ければ 0）
function M.size(run_dir, name)
  local st = uv.fs_stat(run_dir .. "/" .. name)
  return st and st.size or 0
end

--- review_log.jsonl（判定ログ）に 1 行
function M.append_review_log(entry)
  local s = util.json_encode(entry)
  if not s then return false end
  return util.append_line(config.root() .. "/review_log.jsonl", s)
end

return M
