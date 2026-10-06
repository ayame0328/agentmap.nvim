-- agentmap/keymaps.lua ... buffer-local key mappings for the map buffer and the side (aux) buffers.
--   Every mapping is buffer-local, so it never collides with the user's global mappings.
--   Help texts and descriptions are i18n keys, translated when shown.
local M = {}

local function ui()
  return require("agentmap.ui")
end

local function t(key, vars)
  return require("agentmap.i18n").t(key, vars)
end

-- ? で出す一覧（表の順がそのまま表示順）。{ キー, 説明の i18n キー }。キー名の列も i18n キーなら訳す
M.MAP_KEYS = {
  { "keymaps.key_1_9", "keymaps.help_index" },
  { "Enter", "keymaps.help_enter" },
  { "n / p", "keymaps.help_move" },
  { "+ / -", "keymaps.help_fold" },
  { "t", "keymaps.help_transcript" },
  { "d", "keymaps.help_diff" },
  { "w", "keymaps.help_worktree" },
  { "r", "keymaps.help_reload" },
  { "e", "keymaps.help_export" },
  { "BS", "keymaps.help_back" },
  { "z", "keymaps.help_zoom" },
  { "a", "keymaps.help_review" },
  { "s", "keymaps.help_steer" },
  { "x", "keymaps.help_pause" },
  { "X", "keymaps.help_gate" },
  { "v", "keymaps.help_mode" },
  { "R", "keymaps.help_runs" },
  { "?", "keymaps.help_help" },
  { "q", "keymaps.help_close_map" },
}

M.AUX_KEYS = {
  { "BS", "keymaps.help_aux_back" },
  { "q", "keymaps.help_aux_close" },
  { "Enter", "keymaps.help_aux_enter" },
  { "t / d / w / a / s / x", "keymaps.help_aux_tdwa" },
  { "keymaps.key_check_view", "keymaps.help_aux_check" },
}

--- Lines of the `?` help window, in the current language.
function M.help_lines()
  local function key(k) return (k:find("^keymaps%.") and t(k)) or k end
  -- 表示幅で揃える（日本語は 1 文字 2 桁）
  local function pad(k, w)
    k = key(k)
    return k .. string.rep(" ", math.max(1, w - vim.fn.strdisplaywidth(k)))
  end
  local out = { t("keymaps.help_title"), "" }
  for _, k in ipairs(M.MAP_KEYS) do
    out[#out + 1] = "  " .. pad(k[1], 9) .. t(k[2])
  end
  out[#out + 1] = ""
  out[#out + 1] = t("keymaps.help_aux_title")
  out[#out + 1] = ""
  for _, k in ipairs(M.AUX_KEYS) do
    out[#out + 1] = "  " .. pad(k[1], 23) .. t(k[2])
  end
  out[#out + 1] = ""
  out[#out + 1] = t("keymaps.help_close")
  return out
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, function()
    local ok, err = pcall(fn)
    if not ok then vim.notify("AgentMap: " .. tostring(err), vim.log.levels.WARN) end
  end, { buffer = buf, nowait = true, noremap = true, silent = true, desc = "AgentMap: " .. desc })
end

-- カーソルの Agent（門なら元の Agent、HUMAN CHECK なら箱が付いている Agent）を返す。無ければ知らせて nil
local function cur_agent()
  local id = ui().resolve_agent(ui().current_id())
  if not id or id == "UNKNOWN_PARENT" then
    vim.notify(t("keymaps.no_agent_at_cursor"), vim.log.levels.INFO)
    return nil
  end
  return id
end

--- Attach the map-buffer mappings to `buf`.
function M.attach_map(buf)
  for n = 1, 9 do
    map(buf, tostring(n), function() ui().open_index(n) end, t("keymaps.desc_index", { n = n }))
  end
  map(buf, "<CR>", function()
    local id = ui().current_id()
    if not id then vim.notify(t("keymaps.no_agent_at_cursor")) return end
    -- 畳んだ箱（[+n]）なら子も図に戻す。終わった流れの子を見に行くときの入口になる
    local u = ui()
    local aid = u.resolve_agent and u.resolve_agent(id) or id
    if aid and u.view.collapsed[aid] then u.toggle(aid, true) end
    u.open_detail(id)
  end, t("keymaps.desc_detail"))
  map(buf, "n", function() ui().move(1) end, t("keymaps.desc_next"))
  map(buf, "p", function() ui().move(-1) end, t("keymaps.desc_prev"))
  map(buf, "+", function()
    local id = ui().current_id()
    if id then ui().toggle(id, true) end
  end, t("keymaps.desc_expand"))
  map(buf, "-", function()
    local id = ui().current_id()
    if id then
      ui().toggle(id, false)
      vim.notify("AgentMap: " .. t("keymaps.collapsed"))
    end
  end, t("keymaps.desc_collapse"))
  map(buf, "t", function()
    local id = cur_agent()
    if id then ui().open_transcript(id) end
  end, "transcript")
  map(buf, "d", function()
    local id = cur_agent()
    if id then ui().open_diff(id) end
  end, "diff")
  map(buf, "w", function()
    local id = cur_agent()
    if id then ui().jump_worktree(id) end
  end, "worktree")
  map(buf, "r", function() ui().refresh({ reload = true }) end, t("keymaps.desc_reload"))
  map(buf, "e", function() ui().export_menu() end, t("keymaps.desc_export"))
  map(buf, "<BS>", function() ui().back() end, t("keymaps.desc_up"))
  map(buf, "q", function() ui().close() end, t("keymaps.desc_close"))
  map(buf, "a", function()
    local id = cur_agent()
    if id then ui().review_menu(id) end
  end, t("keymaps.desc_review"))
  map(buf, "s", function()
    -- 門なら元の Agent。HUMAN CHECK・まとめ役などは steer_menu が知らせて断る
    local id = ui().current_id()
    if not id then vim.notify(t("keymaps.no_agent_at_cursor")) return end
    ui().steer_menu(id)
  end, t("keymaps.desc_steer"))
  -- x：止める／再開（関門で待っている箱だけ「通す／直す」のメニュー）。HUMAN CHECK・まとめ役は pause_toggle が断る
  map(buf, "x", function()
    local id = ui().current_id()
    if not id then vim.notify(t("keymaps.no_agent_at_cursor")) return end
    ui().pause_toggle(id)
  end, t("keymaps.desc_pause"))
  -- X：見ている run の関門の入／切
  map(buf, "X", function() ui().toggle_gate() end, t("keymaps.desc_gate"))
  map(buf, "z", function()
    local id = ui().current_id()
    if id and id:sub(1, 5) == "gate:" then id = id:sub(6) end
    if id then ui().set_root(id) end -- HUMAN CHECK の箱は set_root が知らせて断る
  end, t("keymaps.desc_zoom"))
  map(buf, "v", function() ui().toggle_mode() end, t("keymaps.desc_mode"))
  map(buf, "R", function() ui().runs() end, t("keymaps.desc_runs"))
  map(buf, "?", function() ui().help() end, t("keymaps.desc_help"))
end

--- Attach the side-view mappings to `buf`; kind = "detail" | "check" | "transcript" | "diff".
-- kind = "detail" | "check" | "transcript" | "diff"
--   t / d / w / a / s は Agent にしか意味が無いので、HUMAN CHECK の画面では箱が付いている Agent に向ける
function M.attach_aux(buf, kind)
  local function target() return ui().resolve_agent(ui().current_id()) end
  map(buf, "<BS>", function() ui().back() end, t("keymaps.desc_back"))
  map(buf, "q", function() ui().close_aux() end, t("keymaps.desc_close"))
  map(buf, "t", function()
    -- 確認の画面では、質問した側（たいてい ROOT）の transcript。
    -- 質問を出す前後のやり取りは聞いた側の記録にしか無い（箱が付いている子の記録には質問が無い）
    local id = kind == "check" and ui().check_asker(ui().current_id()) or target()
    if id then ui().open_transcript(id) end
  end, "transcript")
  map(buf, "d", function()
    local id = target()
    if id then ui().open_diff(id) end
  end, "diff")
  map(buf, "w", function()
    local id = target()
    if id then ui().jump_worktree(id) end
  end, "worktree")
  map(buf, "a", function()
    local id = target()
    if id then ui().review_menu(id) end
  end, t("keymaps.desc_review"))
  map(buf, "s", function()
    local id = target()
    if id then ui().steer_menu(id) end
  end, t("keymaps.desc_steer"))
  map(buf, "x", function()
    -- 確認の画面（HUMAN CHECK）では断る（図と同じ）。id はそのまま渡す
    local id = ui().current_id()
    if id then ui().pause_toggle(id) end
  end, t("keymaps.desc_pause"))
  map(buf, "?", function() ui().help() end, t("keymaps.desc_help"))
  if kind == "detail" or kind == "check" then
    map(buf, "<CR>", function() ui().follow_link() end, t("keymaps.desc_follow"))
  end
end

return M
