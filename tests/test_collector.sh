#!/usr/bin/env bash
# ============================================================
#  test_collector.sh -- tests for bin/agentmap-collect (the hook recorder)
#    - 実物の hook の中身 36 件（パスは匿名化済み）を 1 件ずつ流して、終了コード 0・画面出力なし
#      （2.1.283 の 14 件＋2.1.288 の手順表 TaskCreate/TaskUpdate/TaskList の session 11 件＋修正指示の payload 4 件
#        ＋2.1.291 の親経由（SendMessage）・終わった子の再開（同じ id の 2 回目の SubagentStart）・内部 Agent の SubagentStop 7 件）
#    - 手順表（TaskCreate/TaskUpdate/TaskList）は決めた項目だけ残す（description は保存しない）
#    - --steer：未配達の修正指示を配達する（既定 mode stop＝終わり際の block だけ、deny / context、二重配達しない、記録 1 行）
#    - PostToolUse の SendMessage は to / head / summary だけ残す（DESIGN-v0.1.2-steer2 §4.5）
#    - --pause：止まれファイルがある間 hook の中で待つ（期限・--max-wait・再開・指示つき再開・SIGTERM・壊れたファイル）
#    - 保存場所（projects/<slug>/runs/<sid>/hooks.jsonl, project.json）
#    - 残す項目だけ残っているか（依頼文の全文・permission_mode などが無いこと）
#    - 空の入力・壊れた入力でも終了コード 0
#    - 書き方の決まり（日本語・英語）を brief.lua と同じ規則で読む（fixtures/convention_cases.jsonl）
#    - 保存先の決め方（--root → AGENTMAP_DIR → AGENTFLOW_DIR → XDG_DATA_HOME）
#  使い方: bash tests/test_collector.sh [--regen-fixture]
#    --regen-fixture を付けると fixtures/hooks_probe.jsonl と fixtures/hooks_tasks.jsonl を作り直す
#  本物の保存先（~/.local/share）には書かない（AGENTMAP_DIR を一時フォルダにする）
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$(cd "$HERE/.." && pwd)"
COLLECT="$CFG/bin/agentmap-collect"
RAW="${AGENTMAP_RAW:-$HERE/fixtures/hook_payloads_real.jsonl}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENTMAP_DIR="$TMP/store"
FAIL=0
ok()   { echo "  ok   $1"; }
ng()   { echo "  FAIL $1"; FAIL=1; }

[ -f "$RAW" ] || { echo "FAIL raw payloads not found: $RAW"; exit 1; }

# 1) 1 件ずつ流す
n=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  n=$((n+1))
  out="$(printf '%s' "$line" | python3 "$COLLECT" 2>"$TMP/err")"; code=$?
  [ $code -eq 0 ] || ng "payload $n exit=$code"
  [ -z "$out" ] || ng "payload $n printed to stdout"
  [ -s "$TMP/err" ] && ng "payload $n printed to stderr: $(cat "$TMP/err")"
done < "$RAW"
[ $n -eq 36 ] && ok "36 payloads fed, exit 0, silent" || ng "expected 36 payloads, got $n"

# 2) 置き場所と中身
python3 - "$AGENTMAP_DIR" "$RAW" <<'PY' || FAIL=1
import json, os, sys, glob
root, raw = sys.argv[1], sys.argv[2]
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
first = json.loads(open(raw).readline())
slug = os.path.basename(os.path.dirname(first["transcript_path"]))
run = os.path.join(root, "projects", slug, "runs", first["session_id"])
hp = os.path.join(run, "hooks.jsonl")
check(os.path.isfile(hp), "layout projects/<slug>/runs/<sid>/hooks.jsonl")
pj = os.path.join(root, "projects", slug, "project.json")
check(os.path.isfile(pj) and json.load(open(pj))["cwd"] == first["cwd"], "project.json has cwd")
check(oct(os.stat(hp).st_mode & 0o777) == "0o600", "hooks.jsonl mode 0600")
recs = [json.loads(l) for l in open(hp)]
check(len(recs) == 14, "14 records written")
text = open(hp, encoding="utf-8").read()
for forbidden in ('"prompt"', '"permission_mode"', '"outputFile"', '"background_tasks"',
                  '"session_crons"', '"last_assistant_message"', '"canReadOutputFile"'):
    check(forbidden not in text, "not stored: " + forbidden)
check(all(r.get("_v") == 1 and r.get("_src") == "claude_hook" and r.get("_ts", "").endswith("Z") for r in recs),
      "_v/_src/_ts on every record")
check(all(len(r.get("prompt_head", "")) <= 200 for r in recs), "prompt_head <= 200 chars")
check(all(len((r.get("tool_input") or {}).get("prompt_head", "")) <= 200 for r in recs), "tool_input.prompt_head <= 200")
ups = [r for r in recs if r["hook_event_name"] == "UserPromptSubmit"]
check(ups[1].get("kind") == "task_notification" and "<task-id>" in ups[1]["prompt_head"]
      and "<output-file>" not in ups[1]["prompt_head"], "task-notification reduced to task-id + status")
post = [r for r in recs if r["hook_event_name"] == "PostToolUse"]
check(all(set(r["tool_response"]) <= {"agentId", "resolvedModel", "status", "isAsync", "description"} for r in post),
      "Agent tool_response whitelisted")
check(post[0]["tool_response"]["agentId"] == "afeed000000000006" and "agent_id" not in post[0], "ROOT's Agent call has no agent_id")
check(post[1].get("agent_id") == "afeed000000000006", "child's Agent call carries agent_id")
stops = [r for r in recs if r["hook_event_name"] == "SubagentStop"]
check(stops[0].get("last_head") == "GRAND" and stops[0].get("agent_transcript_path"), "SubagentStop last_head + transcript path")
ends = [r for r in recs if r["hook_event_name"] == "SessionEnd"]
check(ends and ends[0].get("reason") == "other", "SessionEnd reason")

# 手順表（2.1.288 の TaskCreate / TaskUpdate / TaskList）。別の session に記録される
tsid = "c0ffee10-0000-4000-8000-000000000010"
tp = os.path.join(root, "projects", slug, "runs", tsid, "hooks.jsonl")
trecs = [json.loads(l) for l in open(tp)] if os.path.isfile(tp) else []
ttext = open(tp, encoding="utf-8").read() if os.path.isfile(tp) else ""
tc = [r for r in trecs if r.get("tool_name") == "TaskCreate"]
check(len(tc) == 2, "TaskCreate: 2 records")
check(tc and tc[0].get("tool_input") == {"subject": "alpha", "activeForm": "Doing alpha"}, "TaskCreate: tool_input subject + activeForm only")
check(len(tc) > 1 and tc[1].get("tool_input") == {"subject": "beta"}, "TaskCreate without activeForm: subject only")
check(tc and tc[0].get("tool_response") == {"task": {"id": "1", "subject": "alpha"}}, "TaskCreate: tool_response.task.id + subject")
check('"description"' not in ttext and '"first"' not in ttext and '"changed"' not in ttext, "Task description not stored")
tu = [r for r in trecs if r.get("tool_name") == "TaskUpdate"]
check(len(tu) == 4, "TaskUpdate: 4 records")
check(tu and tu[0].get("tool_input") == {"taskId": "1", "status": "in_progress"}, "TaskUpdate: tool_input taskId + status")
check(tu and tu[0].get("tool_response") == {"taskId": "1", "statusChange": {"from": "pending", "to": "in_progress"}},
      "TaskUpdate: statusChange from/to")
check(len(tu) > 3 and tu[3].get("tool_input") == {"taskId": "2"} and "tool_response" not in tu[3],
      "TaskUpdate without statusChange: no tool_response")
tl = [r for r in trecs if r.get("tool_name") == "TaskList"]
check(tl and tl[0].get("tool_response") == {"tasks": [{"id": "1", "subject": "alpha", "status": "completed"},
                                                       {"id": "2", "subject": "beta", "status": "in_progress"}]},
      "TaskList: tasks id/subject/status (blockedBy dropped)")
check(all("agent_id" not in r for r in tc + tu + tl), "Task records of ROOT have no agent_id")

# 親経由（2.1.291 の SendMessage）と終わった子の再開。別の session
rsid = "c0ffee30-0000-4000-8000-000000000030"
rp = os.path.join(root, "projects", slug, "runs", rsid, "hooks.jsonl")
rrecs = [json.loads(l) for l in open(rp)] if os.path.isfile(rp) else []
rtext = open(rp, encoding="utf-8").read() if os.path.isfile(rp) else ""
sm = [r for r in rrecs if r.get("tool_name") == "SendMessage"]
check(len(sm) == 1 and sm[0].get("tool_input") == {"to": "afeed000000000030",
      "head": "The word hello is outdated. The file a.txt must contain the word GOODBYE instead.",
      "summary": "Change a.txt content to GOODBYE"}, "SendMessage: tool_input = to / head / summary")
check(sm and "tool_response" not in sm[0] and "queued for delivery" not in rtext and '"recipient"' not in rtext and '"content"' not in rtext,
      "SendMessage: tool_response / recipient / content not stored")
check(sm and "agent_id" not in sm[0] and sm[0].get("tool_use_id") == "toolu_relay0000000000001", "SendMessage by ROOT: no agent_id, tool_use_id kept")
starts = [r for r in rrecs if r["hook_event_name"] == "SubagentStart" and r.get("agent_id") == "afeed000000000030"]
check(len(starts) == 2, "a resumed child: two SubagentStart records with the same agent_id")
check("scratchpad_dir" not in rtext, "SubagentStart: scratchpad_dir not stored")
ups = [r for r in rrecs if r["hook_event_name"] == "UserPromptSubmit"]
check(ups and ups[0].get("prompt_head", "").startswith("[AgentMap] Tell sub-agent [1] "), "relay prompt_head kept")
sys.exit(1 if bad else 0)
PY

# 3) 作った 1 行をテスト用の見本（fixture）として残す
if [ "${1:-}" = "--regen-fixture" ]; then
  python3 - "$AGENTMAP_DIR" "$HERE/fixtures" <<'PY'
import json, sys, glob, datetime, os
root, fx = sys.argv[1], sys.argv[2]
def regen(sid, out, secs, base):
    hp = glob.glob(root + "/projects/*/runs/" + sid + "/hooks.jsonl")[0]
    # meta（SubagentStart で読む agent-<id>.meta.json）は Claude のフォルダが手元にあるときしか取れない。
    # 匿名化した fixture のパス（/home/user/.claude/...）には実物が無いので、今の fixture の meta を引き継ぐ
    try:
        prev = [json.loads(l) for l in open(out, encoding="utf-8")]
    except Exception:
        prev = []
    # 実際の実行と同じくらいの間隔で時刻を振り直す（一度に流したので全部ほぼ同じ時刻になっているため）
    with open(out, "w", encoding="utf-8") as f:
        for i, l in enumerate(open(hp, encoding="utf-8")):
            r = json.loads(l)
            if "meta" not in r and i < len(prev) and prev[i].get("meta") and prev[i].get("hook_event_name") == r.get("hook_event_name"):
                r["meta"] = prev[i]["meta"]
                r = {k: r[k] for k in list(prev[i]) if k in r} | {k: v for k, v in r.items() if k not in prev[i]}
            t = base + datetime.timedelta(seconds=secs[i])
            r["_ts"] = t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
    print("  wrote " + out)
UTC = datetime.timezone.utc
# 2.1.283 の probe（ROOT → 子 → 孫）。ほかの試験が行番号で使うので、行の並びは変えない
regen("c0ffee01-0000-4000-8000-000000000001", os.path.join(fx, "hooks_probe.jsonl"),
      [0, 1, 4, 5, 5.05, 6, 7, 7.05, 10, 10.5, 15, 16, 17, 18], datetime.datetime(2026, 9, 27, 19, 23, 33, tzinfo=UTC))
# 2.1.288 の手順表（ROOT の TaskCreate ×2・TaskUpdate ×4・TaskList）
regen("c0ffee10-0000-4000-8000-000000000010", os.path.join(fx, "hooks_tasks.jsonl"),
      [0, 1, 3, 4, 5, 20, 21, 22, 25, 30, 31], datetime.datetime(2026, 10, 4, 9, 0, 0, tzinfo=UTC))
PY
fi

# 4) 空の入力・壊れた入力・その他のツール
code=0; out="$(printf '' | python3 "$COLLECT" 2>&1)" || code=$?
[ $code -eq 0 ] && [ -z "$out" ] && ok "empty stdin -> exit 0, silent" || ng "empty stdin"
code=0; out="$(printf '{not json' | python3 "$COLLECT" 2>&1)" || code=$?
[ $code -eq 0 ] && [ -z "$out" ] && ok "broken json -> exit 0, silent" || ng "broken json"
[ -f "$AGENTMAP_DIR/collector.log" ] && ok "broken json logged to collector.log" || ng "collector.log missing"

LONG="$(python3 -c 'print("/very/long/path/" + "x"*300 + "/file.lua")')"
printf '{"session_id":"s1","cwd":"/tmp/a.b","hook_event_name":"PostToolUse","tool_name":"Write","tool_use_id":"t1","tool_input":{"file_path":"%s","content":"SECRET-BODY"},"tool_response":{"filePath":"x","content":"SECRET-BODY"},"duration_ms":3}' "$LONG" | python3 "$COLLECT"
printf '{"session_id":"s1","cwd":"/tmp/a.b","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"echo hi\\nrm -rf SECRET"},"tool_response":{"stdout":"SECRET-OUT"}}' | python3 "$COLLECT"
printf '{"session_id":"s1","cwd":"/tmp/a.b","hook_event_name":"PostToolUseFailure","tool_name":"Agent","tool_use_id":"t3","error":"boom"}' | python3 "$COLLECT"
python3 - "$AGENTMAP_DIR" <<'PY' || FAIL=1
import json, sys, os
root = sys.argv[1]
p = os.path.join(root, "projects", "-tmp-a-b", "runs", "s1", "hooks.jsonl")
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
check(os.path.isfile(p), "slug fallback from cwd (/tmp/a.b -> -tmp-a-b)")
txt = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
check("SECRET" not in txt, "no tool bodies / outputs stored")
recs = [json.loads(l) for l in txt.splitlines()] if txt else [{}, {}, {}]
check(len(recs[0].get("target", "")) <= 120 and recs[0].get("target", "").startswith("…")
      and recs[0]["target"].endswith("/file.lua"), "Write target tail-trimmed to 120")
check(recs[1].get("target") == "echo hi", "Bash target = first line")
check(recs[2].get("error_head") == "boom", "PostToolUseFailure error_head")
sys.exit(1 if bad else 0)
PY

# 4b) Workflow の Agent：meta.json は subagents/workflows/<wf_id>/ の下。Workflow ツールの台本は保存しない
WT="$TMP/claude/projects/-tmp-w"
mkdir -p "$WT/s2/subagents/workflows/wf_x"
printf '{"agentType":"workflow-subagent","spawnDepth":1,"model":"opus","workflowPhase":"実装"}' > "$WT/s2/subagents/workflows/wf_x/agent-A1.meta.json"
printf '{"session_id":"s2","cwd":"/tmp/w","transcript_path":"%s/s2.jsonl","hook_event_name":"SubagentStart","agent_id":"A1","agent_type":""}' "$WT" | python3 "$COLLECT"
printf '{"session_id":"s2","cwd":"/tmp/w","transcript_path":"%s/s2.jsonl","hook_event_name":"PostToolUse","tool_name":"Workflow","tool_use_id":"tw","tool_input":{"script":"export const SECRET_SCRIPT = 1","description":"段の確認"},"tool_response":{"status":"async_launched","taskId":"k1","runId":"wf_x","workflowName":"demo","summary":"要約","transcriptDir":"/x","scriptPath":"/y"}}' "$WT" | python3 "$COLLECT"
python3 - "$AGENTMAP_DIR" <<'PY' || FAIL=1
import json, sys, os
root = sys.argv[1]
p = os.path.join(root, "projects", "-tmp-w", "runs", "s2", "hooks.jsonl")
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
txt = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
recs = [json.loads(l) for l in txt.splitlines()] if txt else [{}, {}]
m = recs[0].get("meta") or {}
check(m.get("wf_id") == "wf_x" and m.get("model") == "opus", "workflow meta found under workflows/<wf_id>/ (wf_id, model)")
check(m.get("workflowPhase") == "実装", "workflowPhase kept")
tr = recs[1].get("tool_response") or {}
check(tr.get("runId") == "wf_x" and tr.get("workflowName") == "demo" and tr.get("summary") == "要約", "Workflow tool_response runId/name/summary")
check((recs[1].get("tool_input") or {}).get("description") == "段の確認", "Workflow tool_input description")
check("export const" not in txt and "SECRET_SCRIPT" not in txt and "scriptPath" not in txt, "Workflow script body not stored")
sys.exit(1 if bad else 0)
PY

# 4c) HUMAN CHECK（AskUserQuestion）・任せた理由（brief）・子の報告（report）
python3 - "$COLLECT" "$AGENTMAP_DIR" "$HERE/fixtures/agent_report.jsonl" "$TMP" <<'PY' || FAIL=1
import json, sys, os, subprocess
collect, root, fixture, tmp = sys.argv[1:5]
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
TP = "/tmp/agentmap-test/claude/projects/-tmp-c/s3.jsonl"
def feed(d):
    d = dict({"session_id": "s3", "cwd": "/tmp/c", "transcript_path": TP, "permission_mode": "default"}, **d)
    r = subprocess.run(["python3", collect], input=json.dumps(d, ensure_ascii=False).encode("utf-8"), capture_output=True)
    check(r.returncode == 0 and not r.stdout and not r.stderr, "exit 0, silent: " + d["hook_event_name"] + " " + str(d.get("tool_name", "")))
hp = os.path.join(root, "projects", "-tmp-c", "runs", "s3", "hooks.jsonl")
def last():
    with open(hp, "rb") as f:
        raw = f.read().splitlines()[-1]
    return raw, json.loads(raw)

opts = [{"label": "L%d" % i, "description": ("説明%d " % i) + "x" * 300} for i in range(7)]
q = {"question": "実装：dbt model について：テストはどこまで書きますか？", "header": "実装：dbt", "multiSelect": False, "options": opts}
feed({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "tq", "tool_input": {"questions": [q]}})
raw, r = last()
qs = (r.get("tool_input") or {}).get("questions") or []
check(len(qs) == 1 and qs[0]["question"] == q["question"] and qs[0]["header"] == "実装：dbt", "AskUserQuestion: tool_input.questions kept")
check(qs and qs[0].get("multiSelect") is False, "AskUserQuestion: multiSelect kept")
check("permission_mode" not in r, "AskUserQuestion: permission_mode not stored")
check(qs and len(qs[0]["options"]) == 6, "AskUserQuestion: 7th option dropped (max 6)")
check(qs and all(len(o["description"]) <= 240 for o in qs[0]["options"]), "AskUserQuestion: description cut to 240")
check(len(raw) <= 16000, "AskUserQuestion: line <= 16000 bytes")

feed({"hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "tq", "tool_input": {"questions": [q]},
      "tool_response": {"questions": [q], "answers": {q["question"]: "L0", "複数": ["L1", "L2"]}, "annotations": {}}})
raw, r = last()
check(r.get("tool_response") == {"answers": {q["question"]: "L0", "複数": ["L1", "L2"]}}, "AskUserQuestion: answers kept (string and array), nothing else")
check(len(((r.get("tool_input") or {}).get("questions") or [{}])[0].get("options", [])) == 6, "AskUserQuestion Post: questions kept")

# 大きな質問（4 問 × 6 択 × 長い説明）でも 16000 バイトに収まる（説明から削る）
big = [{"question": "問%d " % i + "あ" * 400, "header": "h", "options": [{"label": "い" * 80, "description": "う" * 300} for _ in range(6)]} for i in range(4)]
feed({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "tb", "tool_input": {"questions": big}})
raw, r = last()
qs = (r.get("tool_input") or {}).get("questions") or []
check(len(raw) <= 16000 and len(qs) >= 1 and len(qs[0]["question"]) == 300, "big AskUserQuestion: line <= 16000, question cut to 300")

prompt = "【目的】orders を拡張する\n【任せる理由】：設計と実装を分けるため\n【期待する結果】 orders.sql とテスト\n\n本文 token=abc123"
feed({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "ta", "tool_input": {"description": "実装", "prompt": prompt}})
raw, r = last()
b = (r.get("tool_input") or {}).get("brief")
check(b == {"purpose": "orders を拡張する", "reason": "設計と実装を分けるため", "expected": "orders.sql とテスト"}, "Agent: tool_input.brief (3 items, colon dropped)")
check('"prompt"' not in raw.decode("utf-8"), "Agent: prompt full text not stored")
feed({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "tb2", "tool_input": {"description": "x", "prompt": "決まりの無い指示"}})
raw, r = last()
check("brief" not in (r.get("tool_input") or {}), "Agent without 【】: no brief key")

feed({"hook_event_name": "SubagentStop", "agent_id": "a2", "agent_transcript_path": fixture, "last_assistant_message": "I've sent the full report"})
raw, r = last()
rep = r.get("report") or ""
check(rep.startswith("## 要確認\n- 今の作業: orders.sql の拡張\n") and "  2. 結合まで → seed を作ってから実装" in rep, "SubagentStop: report = handback message, newlines kept")
check(r.get("last_head") == "I've sent the full report", "SubagentStop: last_head unchanged")

# 長い報告（2000 文字で切る）と鍵の伏せ字
lp = os.path.join(tmp, "agent-long.jsonl")
msg = "## 報告\n- やったこと: key sk-ABCDEFGHIJKLMNOP を使った\n" + "あ" * 3000
def compact(o):  # 本物の transcript と同じく区切りに空白を入れない
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))
lines = [
    compact({"type": "user", "message": {"role": "user", "content": "x"}}),
    compact({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "h1", "name": "SubagentHandback", "input": {"message": msg}}]}}),
    compact({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "h1", "content": "ok"}]}}),
]
open(lp, "w", encoding="utf-8").write("\n".join(lines) + "\n")
feed({"hook_event_name": "SubagentStop", "agent_id": "a3", "agent_transcript_path": lp})
raw, r = last()
rep = r.get("report") or ""
check(len(rep) == 2000, "SubagentStop: report cut to 2000 chars")
check("sk-ABCDEFGHIJKLMNOP" not in rep and "***" in rep, "SubagentStop: secret redacted in report")
check(len(raw) <= 16000, "SubagentStop: line <= 16000 bytes")

feed({"hook_event_name": "SubagentStop", "agent_id": "a4", "agent_transcript_path": os.path.join(tmp, "missing.jsonl"),
      "last_assistant_message": "## 報告\n- やったこと: x"})
raw, r = last()
check(r.get("report") == "## 報告\n- やったこと: x", "SubagentStop without transcript: report = last_assistant_message")
sys.exit(1 if bad else 0)
PY

# 4d) 書き方の決まり：Lua（brief.lua）と同じ規則で読むか（tests/fixtures/convention_cases.jsonl を両方で流す）
python3 - "$COLLECT" "$HERE/fixtures/convention_cases.jsonl" <<'PY' || FAIL=1
import json, sys, importlib.machinery, importlib.util
collect, cases = sys.argv[1], sys.argv[2]
sys.dont_write_bytecode = True  # bin/__pycache__ を作らない
loader =importlib.machinery.SourceFileLoader("collector", collect)
spec = importlib.util.spec_from_loader("collector", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
bad = []
n = 0
for line in open(cases, encoding="utf-8"):
    if not line.strip():
        continue
    c = json.loads(line)
    n += 1
    got = mod.parse_brief(c["prompt"])
    if got != c["brief"]:
        bad.append(c["name"])
        print("  FAIL parity %s: got %r want %r" % (c["name"], got, c["brief"]))
print(("  ok   " if not bad and n >= 15 else "  FAIL ") + "parse_brief parity: %d convention cases" % n)
sys.exit(1 if bad or n < 15 else 0)
PY

# 4e) 英語の書き方の決まり（Agent の指示）が brief に入る
python3 - "$COLLECT" "$AGENTMAP_DIR" <<'PY' || FAIL=1
import json, sys, os, subprocess
collect, root = sys.argv[1:3]
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
prompt = "[Goal] Extend orders\n[Why delegate]: split design and build\n[done when] orders.sql and tests\n\nBody password=hunter2"
d = {"session_id": "s5", "cwd": "/tmp/e", "transcript_path": "/tmp/agentmap-test/claude/projects/-tmp-e/s5.jsonl",
     "hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "te",
     "tool_input": {"description": "impl", "prompt": prompt}}
r = subprocess.run(["python3", collect], input=json.dumps(d).encode("utf-8"), capture_output=True)
check(r.returncode == 0 and not r.stdout and not r.stderr, "English brief: exit 0, silent")
hp = os.path.join(root, "projects", "-tmp-e", "runs", "s5", "hooks.jsonl")
recs = open(hp, encoding="utf-8").read().splitlines() if os.path.isfile(hp) else ["{}"]
rec = json.loads(recs[-1])
check((rec.get("tool_input") or {}).get("brief") == {"purpose": "Extend orders", "reason": "split design and build",
      "expected": "orders.sql and tests"}, "English brief: tool_input.brief (3 items, case-insensitive, colon dropped)")
check("hunter2" not in json.dumps(rec), "English brief: prompt body (with a secret) not stored")
sys.exit(1 if bad else 0)
PY

# 4f) 保存先の決め方：--root → AGENTMAP_DIR → AGENTFLOW_DIR（旧名）→ XDG。知らない引数は無視
ONE='{"session_id":"s6","cwd":"/tmp/r","hook_event_name":"SessionStart","source":"startup"}'
stored() { [ -f "$1/projects/-tmp-r/runs/s6/hooks.jsonl" ]; }
printf '%s' "$ONE" | AGENTMAP_DIR="$TMP/env" python3 "$COLLECT" --root "$TMP/r1"
stored "$TMP/r1" && ! stored "$TMP/env" && ok "--root DIR wins over AGENTMAP_DIR" || ng "--root DIR"
printf '%s' "$ONE" | AGENTMAP_DIR="$TMP/env" python3 "$COLLECT" --root="$TMP/r2"
stored "$TMP/r2" && ok "--root=DIR" || ng "--root=DIR"
printf '%s' "$ONE" | env -u AGENTMAP_DIR AGENTFLOW_DIR="$TMP/r3" python3 "$COLLECT"
stored "$TMP/r3" && ok "AGENTFLOW_DIR (deprecated) used when AGENTMAP_DIR is unset" || ng "AGENTFLOW_DIR fallback"
printf '%s' "$ONE" | AGENTMAP_DIR="$TMP/r4" AGENTFLOW_DIR="$TMP/r5" python3 "$COLLECT"
stored "$TMP/r4" && ! stored "$TMP/r5" && ok "AGENTMAP_DIR wins over AGENTFLOW_DIR" || ng "AGENTMAP_DIR before AGENTFLOW_DIR"
code=0; out="$(printf '%s' "$ONE" | AGENTMAP_DIR="$TMP/unk" python3 "$COLLECT" --bogus x --root 2>&1)" || code=$?
[ $code -eq 0 ] && [ -z "$out" ] && stored "$TMP/unk" && ok "unknown args and a dangling --root are ignored" || ng "unknown args"
code=0; out="$(printf '%s' "$ONE" | env -u AGENTMAP_DIR -u AGENTFLOW_DIR XDG_DATA_HOME="$TMP/xdg" python3 "$COLLECT" 2>&1)" || code=$?
[ $code -eq 0 ] && [ -z "$out" ] && stored "$TMP/xdg/nvim/agentflow" && ok "default: XDG_DATA_HOME/nvim/agentflow" || ng "XDG default"

# 4g) --steer：未配達の修正指示を配達する（DESIGN-v0.2-steer §3.2）
python3 - "$COLLECT" "$TMP/steer" "$RAW" <<'PY' || FAIL=1
import json, sys, os, subprocess
collect, root, raw = sys.argv[1:4]
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
pl = [json.loads(l) for l in open(raw, encoding="utf-8") if l.strip()]
st = [d for d in pl if d["session_id"].startswith("c0ffee20")]
pre_child, pre_root, stop_first, stop_again = st
CH = pre_child["agent_id"]
slug = os.path.basename(os.path.dirname(pre_child["transcript_path"]))
run = os.path.join(root, "projects", slug, "runs", pre_child["session_id"])
sdir = os.path.join(run, "steer")
hp = os.path.join(run, "hooks.jsonl")
def put(name, text, raw_body=None):
    os.makedirs(sdir, exist_ok=True)
    with open(os.path.join(sdir, name), "w", encoding="utf-8") as f:
        f.write(raw_body if raw_body is not None else json.dumps({"id": name[:-5], "agent_id": CH, "text": text}, ensure_ascii=False))
def call(d, *args):
    r = subprocess.run(["python3", collect, "--root", root] + list(args), input=json.dumps(d).encode("utf-8"), capture_output=True)
    return r.returncode, r.stdout.decode("utf-8"), r.stderr.decode("utf-8")
def lines():
    return [json.loads(l) for l in open(hp, encoding="utf-8")] if os.path.isfile(hp) else []

code, out, err = call(pre_child, "--steer", "--mode", "deny")
check(code == 0 and out == "" and err == "", "--steer, nothing pending: exit 0, silent")
check(not os.path.exists(run), "--steer, nothing pending: no run folder created")

put(CH + "-1791100000001.json", "docs/v3 を読むこと。v2 は古い。")
code, out, err = call(pre_child, "--steer", "--mode", "deny")
check(code == 0 and err == "", "--steer deny: exit 0, no stderr")
o = json.loads(out) if out else {}
h = o.get("hookSpecificOutput") or {}
check(h.get("hookEventName") == "PreToolUse" and h.get("permissionDecision") == "deny", "--steer deny: permissionDecision deny")
reason = h.get("permissionDecisionReason") or ""
check(reason.startswith("[AgentMap] Steering instruction from the user, typed in Neovim (AgentMap) while you were working:\n"),
      "--steer deny: reason starts with the fixed English header")
check("docs/v3 を読むこと。v2 は古い。" in reason and reason.endswith("Follow it from now on, then continue your task. "
      "Mention this instruction and what you changed because of it in your final report."),
      "--steer deny: body + fixed tail + (to a sub-agent) mention it in the final report")
# 文に「疑うな」の類（tool error ではない・試験ではない・本当に利用者だ）を書かない（DESIGN-v0.1.2-steer2 §3.3・§10）
for phrase in ("not a tool error", "treat this as a test", "really from", "trust", "genuine", "do not ignore"):
    check(phrase not in reason.lower(), "--steer deny: no reassurance wording (%r)" % phrase)
check(os.path.exists(os.path.join(sdir, CH + "-1791100000001.delivered.json")) and not os.path.exists(os.path.join(sdir, CH + "-1791100000001.json")),
      "--steer deny: file renamed to .delivered.json")
ls = lines()
check(len(ls) == 1 and ls[0].get("steer") == {"ids": [CH + "-1791100000001"], "mode": "deny", "target": CH}, "--steer: one hooks.jsonl line with steer ids/mode/target")
check(ls and ls[0].get("tool_name") == "Write" and ls[0].get("tool_use_id") == pre_child["tool_use_id"] and ls[0].get("_src") == "claude_hook",
      "--steer: the line carries tool_name / tool_use_id / _src")
check(ls and "tool_input" not in ls[0] and "permission_mode" not in ls[0], "--steer: tool_input not stored")
code, out, err = call(pre_child, "--steer", "--mode", "deny")
check(code == 0 and out == "" and len(lines()) == 1, "--steer: delivered once (second call finds nothing)")

# 2 件まとめて（ms の順）・別の宛先・形の違う名前・大きすぎるもの・壊れたもの
put(CH + "-1791100000003.json", "second")
put(CH + "-1791100000002.json", "first")
put("ROOT-1791100000004.json", "for root")
put("other-1791100000005.json", "for someone else")
put(CH + "-x.json", "bad name")
put(CH + "-1791100000006.json", "big" + "x" * 20000)
put(CH + "-1791100000007.json", None, raw_body="{not json")
code, out, err = call(pre_child, "--steer", "--mode", "context")
h = (json.loads(out) if out else {}).get("hookSpecificOutput") or {}
check(h.get("permissionDecision") == "allow" and "additionalContext" in h, "--mode context: allow + additionalContext")
ctx = h.get("additionalContext") or ""
check(ctx.find("first") >= 0 and ctx.find("second") > ctx.find("first") and "\n\nsecond" in ctx, "two pending: one message, ms order, blank line between")
check("for root" not in ctx and "for someone else" not in ctx and "bad name" not in ctx and "bigxxx" not in ctx, "other targets / bad names / too big are not delivered")
check(os.path.exists(os.path.join(sdir, CH + "-1791100000006.json")), "too big: left in place (expired later by Neovim)")
check(os.path.exists(os.path.join(sdir, CH + "-1791100000007.broken.json")), "broken JSON: renamed to .broken.json, not delivered")
check(lines()[-1].get("steer", {}).get("ids") == [CH + "-1791100000002", CH + "-1791100000003"], "two pending: both ids in one line")

# ROOT 宛て（agent_id の無い payload）
code, out, err = call(pre_root, "--steer", "--mode", "deny")
check("for root" in ((json.loads(out) if out else {}).get("hookSpecificOutput") or {}).get("permissionDecisionReason", ""), "ROOT target: agent_id-less payload gets ROOT-<ms>.json")
check(lines()[-1].get("steer", {}).get("target") == "ROOT" and "agent_id" not in lines()[-1], "ROOT target: steer.target = ROOT")
check(out and "final report" not in out and out.rstrip().endswith('Follow it from now on, then continue your task."}}'), "ROOT target: no final-report sentence")

# 終わりで止める（SubagentStop）
put(CH + "-1791100000008.json", "also write c.txt")
n0 = len(lines())
code, out, err = call(stop_first, "--steer", "--mode", "deny")
check(code == 0 and out == "" and len(lines()) == n0, "SubagentStop without --at-stop: nothing delivered")
code, out, err = call(stop_first, "--steer", "--mode", "deny", "--at-stop")
o = json.loads(out) if out else {}
check(o.get("decision") == "block" and "also write c.txt" in (o.get("reason") or ""), "SubagentStop --at-stop: decision block + reason")
check((o.get("reason") or "").endswith("in your final report."), "SubagentStop: the child is asked to mention it in the final report")
check(lines()[-1].get("steer", {}).get("mode") == "block" and lines()[-1].get("hook_event_name") == "SubagentStop", "SubagentStop: steer line mode = block")
put(CH + "-1791100000009.json", "one more")
n1 = len(lines())
code, out, err = call(stop_again, "--steer", "--mode", "deny", "--at-stop", "--record")
o = json.loads(out) if out else {}
check(o.get("decision") == "block" and "one more" in (o.get("reason") or ""), "stop_hook_active true: still delivers a new instruction")
new = lines()[n1:]
check(len(new) == 2 and new[0].get("last_head") == "GOODBYE written to b.txt." and "steer" not in new[0] and new[1].get("steer"),
      "--steer --record: the ordinary SubagentStop record, then the steer line")
check(new and all(k not in json.dumps(new[0]) for k in ("background_tasks", "session_crons", "stop_hook_active")), "--record: new SubagentStop keys not stored")
code, out, err = call(stop_again, "--steer", "--mode", "deny", "--at-stop")
check(out == "", "Stop with nothing pending: no answer (the turn ends normally)")

# 本文は 4000 文字で切る
put(CH + "-1791100000010.json", "あ" * 5000)
code, out, err = call(pre_child, "--steer", "--mode", "deny")
r = ((json.loads(out) if out else {}).get("hookSpecificOutput") or {}).get("permissionDecisionReason", "")
check(r.count("あ") == 4000, "text cut to 4000 chars")

# mode stop（0.1.2 の既定。DESIGN-v0.1.2-steer2 §3.2・§3.3）
STOP_HEAD = ("[AgentMap] Instruction from the user, typed in Neovim (AgentMap) while you were working. "
             "It reaches you now, just before you finish:\n")
STOP_TAIL = "Apply it now, continue your task, then finish again."
CHILD_TAIL = " Mention this instruction and what you changed because of it in your final report."
for args, label in ((["--steer"], "no --mode (default stop)"), (["--steer", "--mode", "stop"], "--mode stop"),
                    (["--steer", "--mode", "bogus"], "unknown --mode (stop)")):
    sid = CH + "-17911000001%02d" % len(lines())
    put(sid + ".json", "write b.txt, not a.txt")
    n0 = len(lines())
    code, out, err = call(pre_child, *args)
    check(code == 0 and out == "" and err == "" and len(lines()) == n0 and os.path.exists(os.path.join(sdir, sid + ".json")),
          "%s, PreToolUse: stdout empty, file kept, no steer line" % label)
    code, out, err = call(stop_first, *args)
    o = json.loads(out) if out else {}
    r = o.get("reason") or ""
    check(o.get("decision") == "block" and r == STOP_HEAD + "write b.txt, not a.txt\n" + STOP_TAIL + CHILD_TAIL,
          "%s, SubagentStop (no --at-stop): block with the at-its-end text + final-report sentence" % label)
    check("this is not a tool error" not in r and "Do not treat this as a test" not in r, "%s: no tool-error wording at the stop" % label)
    check(lines()[-1].get("steer") == {"ids": [sid], "mode": "block", "target": CH}, "%s: steer line mode block" % label)
# ROOT の Stop（agent_id 無し）→ 同じ文で末尾の頼みは無し
stop_root = {k: v for k, v in stop_first.items() if k not in ("agent_id", "agent_type", "agent_transcript_path")}
stop_root["hook_event_name"] = "Stop"
put("ROOT-1791100000200.json", "for root at its end")
code, out, err = call(stop_root, "--steer", "--mode", "stop")
o = json.loads(out) if out else {}
check(o.get("decision") == "block" and o.get("reason") == STOP_HEAD + "for root at its end\n" + STOP_TAIL,
      "--mode stop, ROOT's Stop: block, at-its-end text, no final-report sentence")
# v0.1.1 の登録（--mode deny --at-stop）でも終わり際は block（文は終わり際用）
put(CH + "-1791100000201.json", "old registration")
code, out, err = call(stop_first, "--steer", "--mode", "deny", "--at-stop")
o = json.loads(out) if out else {}
check(o.get("decision") == "block" and (o.get("reason") or "").startswith(STOP_HEAD) and "old registration" in o.get("reason", ""),
      "--mode deny --at-stop (v0.1.1 words): block with the at-its-end text")
# 2 件は空行で区切って 1 通
put(CH + "-1791100000202.json", "one")
put(CH + "-1791100000203.json", "two")
code, out, err = call(stop_again, "--steer")
r = (json.loads(out) if out else {}).get("reason") or ""
check(r == STOP_HEAD + "one\n\ntwo\n" + STOP_TAIL + CHILD_TAIL, "--mode stop: two pending at the stop, one message, blank line between")
sys.exit(1 if bad else 0)
PY

# 4h) --pause：止まれファイルがある間 hook の中で待つ（DESIGN-v0.1.2-pause §3.2、§10 の (a)〜(j)）
python3 - "$COLLECT" "$TMP/pause" "$RAW" <<'PY' || FAIL=1
import json, sys, os, subprocess, time, threading, shutil
collect, root, raw = sys.argv[1:4]
bad = []
def check(c, msg):
    print(("  ok   " if c else "  FAIL ") + msg)
    if not c: bad.append(msg)
pl = [json.loads(l) for l in open(raw, encoding="utf-8") if l.strip()]
pre_child, pre_root, stop_first, stop_again = [d for d in pl if d["session_id"].startswith("c0ffee20")]
CH = pre_child["agent_id"]
slug = os.path.basename(os.path.dirname(pre_child["transcript_path"]))
run = os.path.join(root, "projects", slug, "runs", pre_child["session_id"])
pdir, sdir, hp = os.path.join(run, "pause"), os.path.join(run, "steer"), os.path.join(run, "hooks.jsonl")
PF, SIDE = os.path.join(pdir, CH + ".json"), os.path.join(pdir, CH + ".hit.json")
ARGS = ["--steer", "--mode", "deny", "--pause"]
n_pause = [0]
def put_pause(at="next", kind="pause", auto=600, target=CH, raw_body=None):
    os.makedirs(pdir, exist_ok=True)
    n_pause[0] += 1
    pid = "%s-17912000%05d" % (target, n_pause[0])
    with open(os.path.join(pdir, target + ".json"), "w", encoding="utf-8") as f:
        f.write(raw_body if raw_body is not None else json.dumps(
            {"id": pid, "agent_id": target, "at": at, "kind": kind, "auto_resume_s": auto,
             "created_at": "2026-10-05T12:00:00.123Z", "by": "nvim", "lang": "en"}))
    return pid
def put_steer(text, ms):
    os.makedirs(sdir, exist_ok=True)
    sid = "%s-%d" % (CH, ms)
    with open(os.path.join(sdir, sid + ".json"), "w", encoding="utf-8") as f:
        json.dump({"id": sid, "agent_id": CH, "text": text}, f)
    return sid
def start(d, *args):
    return subprocess.Popen(["python3", collect, "--root", root] + list(args), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
def call(d, *args, later=None, timeout=20):
    p = start(d, *args)
    if later:
        threading.Timer(later[0], later[1]).start()
    t0 = time.time()
    out, err = p.communicate(json.dumps(d).encode("utf-8"), timeout=timeout)
    return p.returncode, out.decode("utf-8"), err.decode("utf-8"), time.time() - t0
def lines():
    return [json.loads(l) for l in open(hp, encoding="utf-8")] if os.path.isfile(hp) else []
def pause_lines(since=0):
    return [l["pause"] for l in lines()[since:] if "pause" in l]
def rm(p):
    return lambda: os.path.exists(p) and os.remove(p)

# (a) 止まれ無し → 今までどおり（何も出さない・hit 行無し・run も作らない）
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "5")
check(code == 0 and out == "" and err == "" and not os.path.exists(run), "(a) no pause file: exit 0, silent, nothing written")

# (b) --max-wait 1・期限は遠い → 約 1 秒で max_wait、ファイルと .hit.json が消える
pid = put_pause()
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "1")
ps = pause_lines()
check(code == 0 and out == "" and err == "", "(b) exit 0, stdout empty")
check(0.9 <= dt < 2.5, "(b) waited about 1 s (%.2f s)" % dt)
check([p["phase"] for p in ps] == ["hit", "released"], "(b) one hit line, then one released line")
check(ps and ps[0] == {"id": pid, "phase": "hit", "kind": "pause", "at": "next", "target": CH, "deadline": ps[0].get("deadline")}
      and ps[0]["deadline"].endswith("Z"), "(b) hit line: id / kind / at / target / deadline (ISO)")
check(len(ps) > 1 and ps[1].get("reason") == "max_wait" and 900 <= ps[1].get("waited_ms", 0) < 2500 and "steer_ids" not in ps[1],
      "(b) released reason = max_wait, waited_ms ~1000, no steer_ids")
check(not os.path.exists(PF) and not os.path.exists(SIDE), "(b) pause file and .hit.json removed")
hl = [l for l in lines() if "pause" in l]
check(hl and hl[0].get("tool_name") == "Write" and hl[0].get("agent_id") == CH and hl[0].get("_src") == "claude_hook"
      and "tool_input" not in hl[0], "(b) the line carries tool_name / agent_id / _src, no tool_input")

# (c) 0.3 秒後に rm → 0.6 秒以内に抜けて reason = user
put_pause()
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10", later=(0.3, rm(PF)))
ps = pause_lines(n0)
check(out == "" and dt < 0.9 and ps and ps[-1].get("reason") == "user", "(c) removed after 0.3 s: released by user (%.2f s), stdout empty" % dt)
check(not os.path.exists(SIDE), "(c) .hit.json removed")

# (d) .hit.json の期限が過去 → すぐ auto、止まれファイルは消える、hit 行は書かない
pid = put_pause()
with open(SIDE, "w") as f:
    json.dump({"id": pid, "hit_at": "2026-10-05T12:00:00.000Z", "deadline": int(time.time()) - 5}, f)
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10")
ps = pause_lines(n0)
check(dt < 0.8 and [p["phase"] for p in ps] == ["released"] and ps[0]["reason"] == "auto", "(d) past deadline: released at once, reason auto")
check(not os.path.exists(PF) and not os.path.exists(SIDE), "(d) the hook removed the pause file itself")
# (d2) 期限で解いた hook は、ほかに止まれが無ければ <root>/pause.pending も消す（Neovim が閉じていても遅いままにしない）。
#      ほかの run に止まれがあれば残す
FLAGP = os.path.join(root, "pause.pending")
other = os.path.join(root, "projects", "-other", "runs", "s9", "pause")
os.makedirs(other, exist_ok=True)
open(os.path.join(other, "ROOT.hit.json"), "w").close()  # .hit.json は数えない
for keep in (False, True):
    if keep:
        open(os.path.join(other, "ROOT.json"), "w").close()
    pid = put_pause()
    open(FLAGP, "w").close()
    with open(SIDE, "w") as f:
        json.dump({"id": pid, "deadline": int(time.time()) - 5}, f)
    call(pre_child, *ARGS, "--max-wait", "10")
    if keep:
        check(os.path.exists(FLAGP), "(d2) auto release keeps pause.pending while another run has a pause file")
    else:
        check(not os.path.exists(FLAGP), "(d2) auto release removes pause.pending when no pause file is left")
shutil.rmtree(os.path.join(root, "projects", "-other"))
if os.path.exists(FLAGP):
    os.remove(FLAGP)

# (e) at = stop は PreToolUse では止めない。SubagentStop では止まる
pid = put_pause(at="stop", kind="gate")
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "5")
check(out == "" and dt < 0.8 and pause_lines(n0) == [] and os.path.exists(PF), "(e) at=stop: PreToolUse ignores it (no hit line, file kept)")
code, out, err, dt = call(stop_first, *ARGS, "--max-wait", "5", later=(0.3, rm(PF)))
ps = pause_lines(n0)
check(out == "" and [p["phase"] for p in ps] == ["hit", "released"] and ps[0]["kind"] == "gate" and ps[0]["at"] == "stop",
      "(e) at=stop: SubagentStop waits (gate hit + released), nothing printed")
check(lines()[-1].get("hook_event_name") == "SubagentStop", "(e) the lines are SubagentStop's")

# (f) .hit.json が既にある（同じ止まれ）→ 2 回目は hit 行を書かず、期限を引き継ぐ
pid = put_pause()
dl = int(time.time()) + 1
with open(SIDE, "w") as f:
    json.dump({"id": pid, "hit_at": "2026-10-05T12:00:00.000Z", "deadline": dl}, f)
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10")
ps = pause_lines(n0)
check([p["phase"] for p in ps] == ["released"] and ps[0]["reason"] == "auto" and dt < 2.2,
      "(f) existing .hit.json: no second hit line, its deadline is kept (auto after %.2f s)" % dt)
# 前の止まれの印の残り（id が違う）は作り直して hit を書く
put_pause()
with open(SIDE, "w") as f:
    json.dump({"id": "stale-1", "deadline": int(time.time()) - 100}, f)
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "0.3")
ps = pause_lines(n0)
check([p["phase"] for p in ps] == ["hit", "released"] and ps[1]["reason"] == "max_wait", "(f) a stale .hit.json of another pause is replaced (fresh hit)")

# (g) 止まれ＋未配達の指示、0.3 秒後に rm → deny＋止まっていた時間の 1 行、released の steer_ids
put_pause()
sid = put_steer("use docs/v3", 1791300000001)
n0 = len(lines())
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10", later=(0.3, rm(PF)))
h = (json.loads(out) if out else {}).get("hookSpecificOutput") or {}
r = h.get("permissionDecisionReason") or ""
check(h.get("permissionDecision") == "deny", "(g) resumed with an instruction: deny")
check(r.startswith("[AgentMap] Steering instruction from the user, typed in Neovim (AgentMap) while you were working:\n"
                   "(You were paused by the user for 0 s before this instruction.)\nuse docs/v3\n"),
      "(g) the reason has the paused-for line after the header")
check(r.endswith("in your final report."), "(g) the fixed tail is unchanged")
new = lines()[n0:]
check([("pause" in l and l["pause"]["phase"]) or ("steer" in l and "steer") for l in new] == ["hit", "released", "steer"],
      "(g) lines: hit, released, steer")
check(len(new) == 3 and new[1]["pause"].get("steer_ids") == [sid] and new[2]["steer"]["ids"] == [sid], "(g) released.steer_ids = the delivered id")
# 止まれ無しで配達するとき（今までどおり）は 1 行を足さない
sid2 = put_steer("plain", 1791300000002)
code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10")
r = ((json.loads(out) if out else {}).get("hookSpecificOutput") or {}).get("permissionDecisionReason", "")
check("plain" in r and "You were paused" not in r, "(g) no pause: no paused-for line")

# (h) SubagentStop ＋ --record → 記録 → hit → released の順。--at-stop 無しでも、止まれから解けた指示は block で届く
put_pause(at="stop", kind="gate")
sid3 = put_steer("also write c.txt", 1791300000003)
n0 = len(lines())
code, out, err, dt = call(stop_first, *ARGS, "--max-wait", "10", "--record", later=(0.3, rm(PF)))
new = lines()[n0:]
kinds = [("pause" in l and l["pause"]["phase"]) or ("steer" in l and "steer") or "record" for l in new]
check(kinds == ["record", "hit", "released", "steer"], "(h) --record: record, hit, released, steer (%s)" % kinds)
o = json.loads(out) if out else {}
check(o.get("decision") == "block" and "also write c.txt" in o.get("reason", "") and "You were paused" in o.get("reason", ""),
      "(h) gate fix without --at-stop: decision block + instruction")
check(new and new[0].get("last_head") == "b.txt written." and "pause" not in new[0], "(h) the ordinary SubagentStop record is written before waiting")
# 止まれ無し・--at-stop 無しなら終わりでは届けない（今までどおり）
sid4 = put_steer("not at stop", 1791300000004)
code, out, err, dt = call(stop_first, *ARGS, "--max-wait", "10")
check(out == "" and os.path.exists(os.path.join(sdir, sid4 + ".json")), "(h) no pause, no --at-stop: nothing delivered at the stop")
os.remove(os.path.join(sdir, sid4 + ".json"))

# (i) 0.3 秒後に SIGTERM → aborted 行、exit 0、何も出さない、プロセスは残らない
put_pause()
n0 = len(lines())
p = start(pre_child, *ARGS, "--max-wait", "10")
p.stdin.write(json.dumps(pre_child).encode("utf-8")); p.stdin.close()
time.sleep(0.4)
p.terminate()
try:
    rc = p.wait(timeout=3)
except subprocess.TimeoutExpired:
    p.kill(); rc = "hung"
out = p.stdout.read().decode("utf-8")
ps = pause_lines(n0)
check(rc == 0 and out == "", "(i) SIGTERM: exit 0, nothing printed")
check([x["phase"] for x in ps] == ["hit", "aborted"] and ps[1].get("waited_ms", 0) >= 300, "(i) SIGTERM: hit then aborted (waited_ms)")
check(os.path.exists(PF) and not os.path.exists(SIDE), "(i) pause file kept (Neovim cleans it), .hit.json removed")
os.remove(PF)

# (j) 4 KB 超・壊れた JSON・id の無いもの → 待たずに普通に進む（未配達の指示はいつもどおり届く）
for name, body in (("too big", json.dumps({"id": "x", "pad": "x" * 5000})), ("broken JSON", "{nope"), ("no id", '{"at":"next"}')):
    put_pause(raw_body=body)
    sid5 = put_steer("after " + name, 1791300000010 + len(name))
    n0 = len(lines())
    code, out, err, dt = call(pre_child, *ARGS, "--max-wait", "10")
    r = ((json.loads(out) if out else {}).get("hookSpecificOutput") or {}).get("permissionDecisionReason", "")
    check(code == 0 and dt < 0.8 and pause_lines(n0) == [] and ("after " + name) in r and "You were paused" not in r,
          "(j) %s pause file: ignored, the instruction is delivered as usual" % name)
    os.remove(PF)
log = os.path.join(root, "collector.log")
check(os.path.isfile(log) and "pause file too big" in open(log).read(), "(j) the reason goes to collector.log")

# (g') mode stop（既定）：止まれ＋未配達、PreToolUse で 0.3 秒後に rm → 何も出さず抜ける（道具の直前には配達しない）。
#      released に steer_ids は無く、ファイルは残る → 続く SubagentStop で block＋steer 行（止まっていた時間の行は無し）
SARGS = ["--steer", "--mode", "stop", "--pause"]
put_pause()
sid6 = put_steer("write b.txt instead", 1791300000020)
n0 = len(lines())
code, out, err, dt = call(pre_child, *SARGS, "--max-wait", "10", later=(0.3, rm(PF)))
new = lines()[n0:]
check(code == 0 and out == "" and err == "" and dt < 0.9, "(g') mode stop: resumed at PreToolUse, stdout empty (%.2f s)" % dt)
check([l["pause"]["phase"] for l in new if "pause" in l] == ["hit", "released"] and not any("steer" in l for l in new),
      "(g') mode stop: hit + released, no steer line")
check(new and "steer_ids" not in new[-1].get("pause", {}) and new[-1]["pause"].get("reason") == "user", "(g') released: reason user, no steer_ids")
check(os.path.exists(os.path.join(sdir, sid6 + ".json")), "(g') the instruction file stays for the stop")
n0 = len(lines())
code, out, err, dt = call(stop_first, *SARGS, "--max-wait", "10", "--record")
o = json.loads(out) if out else {}
new = lines()[n0:]
check(o.get("decision") == "block" and "write b.txt instead" in o.get("reason", "") and "You were paused" not in o.get("reason", ""),
      "(g') then SubagentStop: block, no paused-for line (this hook did not wait)")
check([("steer" in l and "steer") or ("pause" in l and "pause") or "record" for l in new] == ["record", "steer"]
      and new[-1]["steer"]["ids"] == [sid6], "(g') SubagentStop: record, then the steer line")
# 関門（SubagentStop で待つ）＋未配達、mode stop → rm でその場で block＋止まっていた時間の行
put_pause(at="stop", kind="gate")
sid7 = put_steer("fix the tests too", 1791300000021)
n0 = len(lines())
code, out, err, dt = call(stop_first, *SARGS, "--max-wait", "10", "--record", later=(0.3, rm(PF)))
o = json.loads(out) if out else {}
r = o.get("reason") or ""
new = lines()[n0:]
check(o.get("decision") == "block" and r.startswith("[AgentMap] Instruction from the user, typed in Neovim (AgentMap) while you were working. "
      "It reaches you now, just before you finish:\n(You were paused by the user for 0 s before this instruction.)\nfix the tests too\n"),
      "(gate) mode stop: the gate fix arrives at once, at-its-end text with the paused-for line")
check([("pause" in l and l["pause"]["phase"]) or ("steer" in l and "steer") or "record" for l in new] == ["record", "hit", "released", "steer"]
      and new[2]["pause"].get("steer_ids") == [sid7], "(gate) record, hit, released (steer_ids), steer")

# ROOT 宛て（agent_id の無い payload）は ROOT.json を見る
os.makedirs(pdir, exist_ok=True)
put_pause(target="ROOT")
n0 = len(lines())
code, out, err, dt = call(pre_root, *ARGS, "--max-wait", "0.3")
ps = pause_lines(n0)
check([x["phase"] for x in ps] == ["hit", "released"] and ps[0]["target"] == "ROOT", "ROOT: payload without agent_id waits on ROOT.json")
# --pause 無しなら止まれがあっても待たない（v0.1.1 の登録のまま）
put_pause()
n0 = len(lines())
code, out, err, dt = call(pre_child, "--steer", "--mode", "deny")
check(out == "" and dt < 0.8 and pause_lines(n0) == [], "without --pause: a pause file is ignored (v0.1.1 registration)")
os.remove(PF)

# (k) SessionEnd（記録係、--steer 無し＝v0.1.1 の登録でも同じ command）：この run の止まれファイルと .hit.json を片付け、
#     ほかに止まれが無ければ pause.pending も消す。GATE は残す。記録の 1 行は今までどおり。ほかの記録では片付けない
end_ev = {k: v for k, v in pre_child.items() if k not in ("agent_id", "tool_name", "tool_use_id", "tool_input")}
end_ev.update({"hook_event_name": "SessionEnd", "reason": "prompt_input_exit"})
ROOTF, GATE = os.path.join(pdir, "ROOT.json"), os.path.join(pdir, "GATE")
other = os.path.join(root, "projects", "-other", "runs", "s9", "pause")
os.makedirs(other, exist_ok=True)
def stage(keep_other):
    put_pause(); put_pause(target="ROOT")
    with open(SIDE, "w") as f:
        json.dump({"id": "x", "deadline": int(time.time()) + 600}, f)
    open(GATE, "w").close()
    open(FLAGP, "w").close()
    if keep_other:
        open(os.path.join(other, "ROOT.json"), "w").close()
stage(keep_other=True)
n0 = len(lines())
code, out, err, dt = call(stop_first)  # 普通の記録（SubagentStop）では片付けない
check(code == 0 and out == "" and os.path.exists(PF) and os.path.exists(ROOTF) and os.path.exists(SIDE) and os.path.exists(FLAGP),
      "(k) an ordinary record (SubagentStop) leaves the pause files and the flag alone")
code, out, err, dt = call(end_ev)
rec = lines()[-1]
check(code == 0 and out == "" and err == "", "(k) SessionEnd: exit 0, silent")
check(rec.get("hook_event_name") == "SessionEnd" and rec.get("reason") == "prompt_input_exit" and "pause" not in rec,
      "(k) SessionEnd: the ordinary record is written as before")
check(not os.path.exists(PF) and not os.path.exists(ROOTF) and not os.path.exists(SIDE),
      "(k) SessionEnd: the run's pause files and .hit.json are removed")
check(os.path.exists(GATE), "(k) SessionEnd: GATE (Neovim's mark) is kept")
check(os.path.exists(FLAGP) and os.path.exists(os.path.join(other, "ROOT.json")),
      "(k) SessionEnd: pause.pending stays while another run still has a pause file")
os.remove(os.path.join(other, "ROOT.json"))
stage(keep_other=False)
code, out, err, dt = call(end_ev)
check(code == 0 and out == "" and not os.path.exists(PF) and not os.path.exists(FLAGP),
      "(k) SessionEnd: pause.pending is removed when no pause file is left anywhere")
# run フォルダに pause/ が無くても・印が無くても、何も起きずに記録だけ
code, out, err, dt = call(end_ev)
check(code == 0 and out == "" and err == "" and lines()[-1].get("hook_event_name") == "SessionEnd",
      "(k) SessionEnd without pause files: record only, no error")
check(not os.path.isfile(os.path.join(root, "collector.log")) or "SessionEnd" not in open(os.path.join(root, "collector.log")).read(),
      "(k) SessionEnd: nothing logged to collector.log")
shutil.rmtree(os.path.join(root, "projects", "-other"))
sys.exit(1 if bad else 0)
PY

# 5) 速さ（目安: 1 回 150ms 未満。WSL の python 起動込み）
start=$(date +%s%N)
for i in 1 2 3 4 5; do head -n 5 "$RAW" | tail -n 1 | python3 "$COLLECT"; done
ms=$(( ($(date +%s%N) - start) / 5000000 ))
[ $ms -lt 150 ] && ok "avg ${ms}ms per call" || ng "slow: avg ${ms}ms per call"

if [ $FAIL -eq 0 ]; then echo "PASS test_collector.sh"; else echo "FAIL test_collector.sh"; exit 1; fi
