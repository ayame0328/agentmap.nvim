-- ============================================================
--  agentmap/review.lua ... records reviews (submit -> verdict -> rework) and picks the verdict provider.
--    The user's final decision is the only ground truth; a provider only proposes.
--    The rubric is setup({ review = { rubric = path } }) or <plugin>/rubric/RUBRIC.md.
--
--  判定の「正解」は本人の最終判断だけ。自動の判定係（provider）は「提案」しかしない。
--  判定は 2 か所に残す：
--    - run の events.jsonl（review_result。図の色や履歴に使う）
--    - <root>/review_log.jsonl（判定ログ。提案と本人の判断が一致したかを後で集計する）
--  判定基準は setup の review.rubric、無ければ <plugin>/rubric/RUBRIC.md。
-- ============================================================
local config = require("agentmap.config")
local util = require("agentmap.util")
local store = require("agentmap.store")
local events = require("agentmap.events")
local t = require("agentmap.i18n").t

local M = {}

M.VERDICTS = { "PASS", "RETRY", "ESCALATE" }
local VALID = { PASS = true, RETRY = true, ESCALATE = true }

--- 判定係の一覧。manual（本人がその場で選ぶ）だけ最初から入っている
M.providers = {}

--- Register a verdict provider. p.evaluate(ctx, cb) calls cb({ verdict, reason, answers }) or cb(nil); optional p.available().
--- 判定係を登録する。p.evaluate(ctx, cb) は cb({verdict, reason, answers}) か cb(nil)（やめた）を呼ぶ
---   p.available() を持たせると、この PC で使えるかどうかを自分で答えられる。
---   戻り値は true、または false と理由（例：false, "jev.py が無い"）。
---   Jev のように「入っている PC と入っていない PC がある」判定係は必ず持たせること。
function M.register(name, p)
  M.providers[name] = p
end

local warned = {}

--- 使える判定係かどうか
local function usable(p)
  if not p then return false, t("review.not_registered") end
  if type(p.available) ~= "function" then return true end
  local ok, yes, why = pcall(p.available)
  if not ok then return false, t("review.check_error", { err = tostring(yes) }) end
  return yes == true, why
end

--- Choose the verdict provider: vim.g.agentmap_review_provider, then setup review.provider, then "auto".
--- いま使う判定係を決める。
---   優先順：vim.g.agentmap_review_provider（local.lua で PC ごとに決める）
---         → setup の review.provider → "auto"
---   "auto" は、manual 以外で「この PC で使える」ものがあればそれ、無ければ manual。
---   名前を指定したのにこの PC で使えないときは、知らせてから manual にする（黙って切り替えない）。
---@return string name, table provider
function M.pick()
  local want = vim.g.agentmap_review_provider
    or ((config.get().review or {}).provider)
    or "auto"
  if want == "manual" then return "manual", M.providers.manual end
  if want == "auto" then
    local names = vim.tbl_keys(M.providers)
    table.sort(names)
    for _, n in ipairs(names) do
      if n ~= "manual" and usable(M.providers[n]) then return n, M.providers[n] end
    end
    return "manual", M.providers.manual
  end
  local ok, why = usable(M.providers[want])
  if ok then return want, M.providers[want] end
  if not warned[want] then
    warned[want] = true
    vim.notify(t("review.provider_unavailable", { name = want, why = tostring(why or t("review.unknown_reason")) }),
      vim.log.levels.WARN)
  end
  return "manual", M.providers.manual
end

-- ---------- 判定基準（RUBRIC.md） ----------

--- 判定基準の場所：setup({ review = { rubric = … } }) → <plugin>/rubric/RUBRIC.md
local function rubric_path()
  local custom = (config.get().review or {}).rubric
  if type(custom) == "string" and custom ~= "" then return vim.fn.expand(custom) end
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    -- <plugin>/lua/agentmap/review.lua → <plugin>/rubric/RUBRIC.md
    local p = vim.fn.fnamemodify(src:sub(2), ":p:h:h:h") .. "/rubric/RUBRIC.md"
    if vim.uv.fs_stat(p) then return p end
  end
  return vim.api.nvim_get_runtime_file("rubric/RUBRIC.md", false)[1]
end

--- Text of the review rubric (a short notice when it cannot be read).
function M.rubric_text()
  local p = rubric_path()
  local s = p and util.read_file(p)
  return s or t("review.rubric_missing")
end

--- Version number of the rubric (the number after "version:"), 1 when absent.
function M.rubric_version()
  local v = M.rubric_text():match("version:%s*(%d+)")
  return tonumber(v) or 1
end

-- ---------- 記録 ----------

--- Append one line to review_log.jsonl.
--- 判定ログに 1 行足す
function M.log_judgment(entry)
  entry = vim.deepcopy(entry or {})
  entry.v = 1
  entry.ts = entry.ts or util.iso_now()
  entry.rubric_version = entry.rubric_version or M.rubric_version()
  return store.append_review_log(entry)
end

local function agent_of(run, id)
  return run and run.state and run.state.agents[id]
end

--- Submit an agent for review (status REVIEW).
--- レビューに出す（状態を REVIEW にする）
function M.submit(run, id, note)
  local a = agent_of(run, id)
  if not a then return nil end
  return events.emit(run, {
    event = "review_submitted", agent_id = id, attempt = a.attempt, note = note, by = "user",
  })
end

--- Record a verdict (PASS / RETRY / ESCALATE) in events.jsonl and review_log.jsonl.
--- 判定を記録する
--- @param extra table|nil { escalate_to, proposed_by, proposed_verdict, proposed_reason, answers }
function M.record(run, id, verdict, reason, decided_by, extra)
  extra = extra or {}
  verdict = type(verdict) == "string" and verdict:upper() or verdict
  if not VALID[verdict] then return nil, t("review.invalid_verdict") end
  local a = agent_of(run, id)
  if not a then return nil, t("review.agent_not_found", { id = tostring(id) }) end
  decided_by = decided_by or "user"
  local rv = M.rubric_version()
  local ev = events.emit(run, {
    event = "review_result", agent_id = id, verdict = verdict, decided_by = decided_by,
    attempt = a.attempt, reason = reason, escalate_to = extra.escalate_to,
    proposed_by = extra.proposed_by, proposed_verdict = extra.proposed_verdict,
    rubric_version = rv,
  })
  local agreed = nil
  if extra.proposed_verdict then agreed = (extra.proposed_verdict == verdict) end
  M.log_judgment({
    run_id = run.sid or run.state.run_id, agent_id = id, attempt = a.attempt,
    rubric_version = rv, provider = extra.proposed_by or "manual",
    proposed = extra.proposed_verdict or vim.NIL, proposed_reason = extra.proposed_reason or vim.NIL,
    final = verdict, decided_by = decided_by, reason = reason or vim.NIL,
    agreed = (agreed == nil) and vim.NIL or agreed, answers = extra.answers,
  })
  return ev
end

--- Record that `new_id` redoes `old_id` (draws a retry edge).
--- 「new_id は old_id のやり直し」と記録する（図に retry の線が出る）
function M.mark_retry_of(run, new_id, old_id)
  if not agent_of(run, new_id) then return nil end
  return events.emit(run, {
    event = "rework_started", agent_id = new_id,
    retry_of = (old_id ~= new_id) and old_id or nil, trigger = "user",
  })
end

-- ---------- 判定の流れ ----------

--- Get a verdict (proposal from the provider, decision by the user) and record it; cb(ev | nil).
--- 判定を決めて記録する。cb(ev|nil) で結果を返す
---   manual：本人が選んだものがそのまま最終判断
---   それ以外：provider の提案を見せたうえで、本人が最終判断を選ぶ
function M.evaluate(run, agent_id, cb)
  cb = cb or function() end
  local a = agent_of(run, agent_id)
  if not a then
    cb(nil)
    return
  end
  local name, p = M.pick()
  local ctx = { run = run, state = run.state, agent = a, agent_id = agent_id, rubric = M.rubric_text() }

  if p == M.providers.manual then
    p.evaluate(ctx, function(res)
      if not res then return cb(nil) end
      cb(M.record(run, agent_id, res.verdict, res.reason, "user", { answers = res.answers }))
    end)
    return
  end

  local ok, err = pcall(p.evaluate, ctx, function(prop)
    ctx.proposal = prop
    M.providers.manual.evaluate(ctx, function(res)
      if not res then return cb(nil) end
      cb(M.record(run, agent_id, res.verdict, res.reason, "user", {
        answers = res.answers or (prop and prop.answers),
        proposed_by = "provider:" .. name,
        proposed_verdict = prop and prop.verdict,
        proposed_reason = prop and prop.reason,
      }))
    end)
  end)
  if not ok then
    -- 判定係が失敗しても、レビューそのものは取り消さない。提案なしで本人に選んでもらう
    vim.notify(t("review.provider_error", { name = name, err = tostring(err) }), vim.log.levels.WARN)
    ctx.proposal = nil
    M.providers.manual.evaluate(ctx, function(res)
      if not res then return cb(nil) end
      cb(M.record(run, agent_id, res.verdict, res.reason, "user", { answers = res.answers }))
    end)
  end
end

-- 本人がその場で選ぶ判定係
M.register("manual", {
  evaluate = function(ctx, cb)
    local cancel = t("review.cancel")
    local items = { "PASS", "RETRY", "ESCALATE", cancel }
    local label = ctx.agent and (ctx.agent.name or ctx.agent.id) or "?"
    local prompt = t("review.verdict_prompt", { index = tostring(ctx.agent and ctx.agent.index or "?"), label = label })
    if ctx.proposal and ctx.proposal.verdict then
      prompt = prompt .. t("review.proposal", { verdict = ctx.proposal.verdict })
    end
    vim.ui.select(items, { prompt = prompt }, function(choice)
      if not choice or choice == cancel then return cb(nil) end
      vim.ui.input({ prompt = t("review.reason_prompt", { verdict = choice }) }, function(reason)
        if reason == nil then return cb(nil) end
        cb({ verdict = choice, reason = reason ~= "" and reason or nil })
      end)
    end)
  end,
})

return M
