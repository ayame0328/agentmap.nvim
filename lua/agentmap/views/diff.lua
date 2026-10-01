-- agentmap/views/diff.lua ... git diff of the files an agent changed (side window).
--   場所は agent.cwd（worktree ならその中）→ 無ければ run の cwd。git に非同期で聞く。
local renderer = require("agentmap.renderer")
local t = require("agentmap.i18n").t

local M = {}

--- Build the diff view lines (pure). r = { dir, title, not_repo, error, stat, diff, files, … }.
function M.build(r)
  local b = renderer.builder()
  b:add("# AgentMap diff  " .. (r.title or ""))
  b:add(t("diff.place", { dir = tostring(r.dir or "-") }))
  if r.files and #r.files > 0 then
    b:add(t("diff.target_files", { n = #r.files }))
  elseif r.files then
    -- 書き込みの記録が無いときは、フォルダ全体の差分になる（この Agent の分とは限らない）
    b:add(t("diff.target_all"))
  end
  b:add(t("diff.keys"))
  b:add("")
  if r.loading then
    b:add(t("diff.loading"))
  elseif r.not_repo then
    b:add(t("diff.not_repo", { dir = tostring(r.dir) }))
  elseif r.error then
    b:add(t("diff.failed", { err = r.error }))
  else
    local stat = vim.split(r.stat or "", "\n", { trimempty = true })
    local diff = vim.split(r.diff or "", "\n", { trimempty = false })
    local new_diff = vim.trim(r.new_diff or "")
    local new_names = r.new_names or {}
    if #stat == 0 and vim.trim(r.diff or "") == "" and new_diff == "" and #new_names == 0 then
      b:add(t("diff.no_changes"))
    else
      for _, l in ipairs(stat) do b:add(l) end
      if #new_names > 0 then
        -- git に一度も登録していない新しいファイル。ふつうの git diff には出てこない
        b:add(t("diff.new_files", { n = #new_names }))
        for i, n in ipairs(new_names) do
          if i > 30 then b:add(t("diff.more", { n = #new_names - 30 })); break end
          b:add("  + " .. n)
        end
      end
      b:add("")
      for _, l in ipairs(diff) do b:add(l) end
      if new_diff ~= "" then
        for _, l in ipairs(vim.split(r.new_diff, "\n", { trimempty = false })) do b:add(l) end
      end
    end
  end
  return b:result()
end

local function show(buf, r)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local res = M.build(r)
  renderer.set_all(buf, res.lines, res.marks)
end

local function run_git(args, cb)
  local ok = pcall(vim.system, args, { text = true }, function(o) vim.schedule(function() cb(o) end) end)
  if not ok then cb({ code = 1, stdout = "", stderr = t("diff.git_unavailable") }) end
end

--- Show the git diff of `agent` in `buf` (filled in asynchronously).
function M.open(run, agent, buf, _opts)
  local state = run.state
  local dir = agent.worktree or agent.cwd or state.cwd
  local title = agent.id == "ROOT" and "ROOT" or ("[" .. (agent.index or "?") .. "] " .. (agent.name or agent.task or agent.id))
  vim.bo[buf].filetype = "diff"
  local r = { dir = dir, title = title, loading = true }
  show(buf, r)
  if not dir or vim.fn.isdirectory(dir) ~= 1 then
    r.loading, r.not_repo = false, true
    show(buf, r)
    return
  end
  run_git({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, function(o)
    if o.code ~= 0 then
      r.loading, r.not_repo = false, true
      return show(buf, r)
    end
    local top = vim.trim(o.stdout or "")
    -- この Agent が書いたファイルのうち、リポジトリの中にあるものだけに絞る
    local files = {}
    for _, f in ipairs(agent.files or {}) do
      if f:sub(1, #top + 1) == top .. "/" then files[#files + 1] = f end
    end
    r.files = files
    local tail = {}
    if #files > 0 then
      tail = { "--" }
      vim.list_extend(tail, files)
    end
    local stat_cmd = vim.list_extend({ "git", "-C", dir, "diff", "--stat" }, vim.deepcopy(tail))
    run_git(stat_cmd, function(s)
      local diff_cmd = vim.list_extend({ "git", "-C", dir, "diff" }, vim.deepcopy(tail))
      run_git(diff_cmd, function(d)
        if d.code ~= 0 then
          r.loading, r.error = false, vim.trim(d.stderr or "")
          return show(buf, r)
        end
        r.stat, r.diff = s.stdout, d.stdout
        -- まだ git に登録していない新しいファイルを探す（Agent は新しいファイルを作ることが多い）
        local ls = vim.list_extend({ "git", "-C", top, "ls-files", "--others", "--exclude-standard" }, vim.deepcopy(tail))
        run_git(ls, function(u)
          local names = vim.split(u.code == 0 and (u.stdout or "") or "", "\n", { trimempty = true })
          r.new_names = names
          -- この Agent が書いたファイルに絞れているときだけ、中身まで出す（多すぎると重いので 20 件まで）
          if #files == 0 or #names == 0 then
            r.loading = false
            return show(buf, r)
          end
          local chunks, i = {}, 0
          local function next_one()
            i = i + 1
            if i > #names or i > 20 then
              r.loading, r.new_diff = false, table.concat(chunks, "\n")
              return show(buf, r)
            end
            -- 差分があると終了コード 1 になるのが git diff --no-index の決まり。0 と 1 は成功として扱う
            run_git({ "git", "-C", top, "diff", "--no-index", "--", "/dev/null", names[i] }, function(o)
              if (o.code == 0 or o.code == 1) and o.stdout then chunks[#chunks + 1] = o.stdout end
              next_one()
            end)
          end
          next_one()
        end)
      end)
    end)
  end)
end

return M
