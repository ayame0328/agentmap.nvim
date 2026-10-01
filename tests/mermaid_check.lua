-- Test helper: checks the shape of the Mermaid flowchart that export.lua writes, without Mermaid itself.
--   blocks(md) extracts ```mermaid blocks, check(src) returns (errors, declared ids), mmdc(src) runs the
--   real mermaid-cli when it is installed (nil otherwise).
--   本物の mermaid が無くても壊れ方の大半を見つけられるように、書き出す形を厳しく決めて照らし合わせる。
local M = {}

local ID = "[%a][%w_]*"

--- ```mermaid … ``` の中身を全部取り出す
function M.blocks(md)
  local out, cur = {}, nil
  local opened = 0
  for line in (md .. "\n"):gmatch("(.-)\n") do
    if cur then
      if line == "```" then
        out[#out + 1] = table.concat(cur, "\n")
        cur = nil
      else
        cur[#cur + 1] = line
      end
    elseif line == "```mermaid" then
      opened = opened + 1
      cur = {}
    end
  end
  return out, cur ~= nil
end

local function check_label(label, where, errs)
  local stripped = label:gsub("<br/>", "")
  if stripped:find('"', 1, true) then errs[#errs + 1] = where .. ": ラベルに生の \" がある" end
  if stripped:find("[%[%]{}<>|`]") then errs[#errs + 1] = where .. ": ラベルに生の記号がある: " .. label end
  -- & や # で始まる文字コードは #名前; の形だけ
  for ent in stripped:gmatch("#[^;]*;?") do
    if not ent:match("^#%w+;$") then errs[#errs + 1] = where .. ": 文字コードの形が崩れている: " .. ent end
  end
end

function M.check(src)
  local errs, declared, refs = {}, {}, {}
  local depth, sgs = 0, {} -- subgraph の入れ子の深さと、subgraph の名前
  local lines = vim.split(src, "\n", { plain = true })
  local first = true
  for i, line in ipairs(lines) do
    local where = ("%d 行目"):format(i)
    if line:match("^%s*$") then goto continue end
    if first then
      if not line:match("^flowchart LR$") then errs[#errs + 1] = where .. ": 1 行目が flowchart LR ではない" end
      first = false
      goto continue
    end
    do
      local sid, slabel = line:match("^%s+subgraph (" .. ID .. ')%["(.*)"%]$')
      if sid then
        if declared[sid] or sgs[sid] then errs[#errs + 1] = where .. ": 同じ名前が 2 回宣言されている: " .. sid end
        sgs[sid] = true
        check_label(slabel, where, errs)
        depth = depth + 1
        goto continue
      end
      if line:match("^%s+end$") then
        depth = depth - 1
        if depth < 0 then
          errs[#errs + 1] = where .. ": subgraph の無い end"
          depth = 0
        end
        goto continue
      end
      local id, label = line:match("^%s+(" .. ID .. ')%["(.*)"%]$')
      if not id then id, label = line:match("^%s+(" .. ID .. '){{"(.*)"}}$') end
      if id then
        if declared[id] then errs[#errs + 1] = where .. ": 同じ名前が 2 回宣言されている: " .. id end
        declared[id] = true
        check_label(label, where, errs)
        goto continue
      end
      local a, arrow, rest = line:match("^%s+(" .. ID .. ") (%-%.?%->)(.*)$")
      if not a then a, arrow, rest = line:match("^%s+(" .. ID .. ") (==>)(.*)$") end
      if a then
        local lab, b = rest:match("^|(%u+)| (" .. ID .. ")$")
        if not lab then b = rest:match("^ (" .. ID .. ")$") end
        if not b then
          errs[#errs + 1] = where .. ": 矢印の形が崩れている: " .. line
        else
          if lab and not (lab == "RETRY" or lab == "ESCALATE" or lab == "PASS") then
            errs[#errs + 1] = where .. ": 知らない矢印ラベル: " .. lab
          end
          refs[#refs + 1] = { a, where }
          refs[#refs + 1] = { b, where }
        end
        goto continue
      end
      if line:match("^%s+classDef %a+ [%w:#,%-%.]+$") then goto continue end
      local cid, cls = line:match("^%s+class (" .. ID .. ") (%a+)$")
      if cid then
        refs[#refs + 1] = { cid, where }
        goto continue
      end
      errs[#errs + 1] = where .. ": 読めない行: " .. line
    end
    ::continue::
  end
  if first then errs[#errs + 1] = "中身が空" end
  if depth ~= 0 then errs[#errs + 1] = "subgraph と end の数が合わない" end
  for _, r in ipairs(refs) do
    if not declared[r[1]] then errs[#errs + 1] = r[2] .. ": 宣言されていない名前を使っている: " .. r[1] end
  end
  -- mermaid の予約語を名前にしていない
  for _, set in ipairs({ declared, sgs }) do
    for id in pairs(set) do
      if id == "end" or id == "graph" or id == "subgraph" or id == "flowchart" then
        errs[#errs + 1] = "予約語を名前にしている: " .. id
      end
    end
  end
  return errs, declared
end

--- mermaid-cli（mmdc）が手元にあれば、本物でも確かめる。無ければ nil
--   AGENTMAP_MERMAID_PARSE に「node で動く確認用スクリプト（引数に .mmd）」を指定しても使える
function M.mmdc(src)
  local js = vim.env.AGENTMAP_MERMAID_PARSE
  local use_js = js and js ~= "" and vim.uv.fs_stat(js) and vim.fn.executable("node") == 1
  if not use_js and vim.fn.executable("mmdc") ~= 1 then return nil end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(src, "\n"), dir .. "/in.mmd")
  local argv = use_js and { "node", js, dir .. "/in.mmd" }
    or { "mmdc", "-i", dir .. "/in.mmd", "-o", dir .. "/out.svg" }
  local r = vim.system(argv, { text = true, cwd = use_js and vim.fn.fnamemodify(js, ":h") or nil }):wait()
  vim.fn.delete(dir, "rf")
  return r.code == 0, (r.stdout or "") .. (r.stderr or "")
end

return M
