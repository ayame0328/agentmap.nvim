#!/usr/bin/env bash
# ============================================================
#  test_collector.sh -- tests for bin/agentmap-collect (the hook recorder)
#    - 実物の hook の中身 14 件（パスは匿名化済み）を 1 件ずつ流して、終了コード 0・画面出力なし
#    - 保存場所（projects/<slug>/runs/<sid>/hooks.jsonl, project.json）
#    - 残す項目だけ残っているか（依頼文の全文・permission_mode などが無いこと）
#    - 空の入力・壊れた入力でも終了コード 0
#    - 書き方の決まり（日本語・英語）を brief.lua と同じ規則で読む（fixtures/convention_cases.jsonl）
#    - 保存先の決め方（--root → AGENTMAP_DIR → AGENTFLOW_DIR → XDG_DATA_HOME）
#  使い方: bash tests/test_collector.sh [--regen-fixture]
#    --regen-fixture を付けると fixtures/hooks_probe.jsonl を作り直す
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
[ $n -eq 14 ] && ok "14 payloads fed, exit 0, silent" || ng "expected 14 payloads, got $n"

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
sys.exit(1 if bad else 0)
PY

# 3) 作った 1 行をテスト用の見本（fixture）として残す
if [ "${1:-}" = "--regen-fixture" ]; then
  python3 - "$AGENTMAP_DIR" "$HERE/fixtures/hooks_probe.jsonl" <<'PY'
import json, sys, glob, datetime
root, out = sys.argv[1], sys.argv[2]
hp = glob.glob(root + "/projects/*/runs/*/hooks.jsonl")[0]
# meta（SubagentStart で読む agent-<id>.meta.json）は Claude のフォルダが手元にあるときしか取れない。
# 匿名化した fixture のパス（/home/user/.claude/...）には実物が無いので、今の fixture の meta を引き継ぐ
try:
    prev = [json.loads(l) for l in open(out, encoding="utf-8")]
except Exception:
    prev = []
# 実際の実行と同じくらいの間隔で時刻を振り直す（一度に流したので全部ほぼ同じ時刻になっているため）
secs = [0, 1, 4, 5, 5.05, 6, 7, 7.05, 10, 10.5, 15, 16, 17, 18]
base = datetime.datetime(2026, 9, 27, 19, 23, 33, tzinfo=datetime.timezone.utc)
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

# 5) 速さ（目安: 1 回 150ms 未満。WSL の python 起動込み）
start=$(date +%s%N)
for i in 1 2 3 4 5; do head -n 5 "$RAW" | tail -n 1 | python3 "$COLLECT"; done
ms=$(( ($(date +%s%N) - start) / 5000000 ))
[ $ms -lt 150 ] && ok "avg ${ms}ms per call" || ng "slow: avg ${ms}ms per call"

if [ $FAIL -eq 0 ]; then echo "PASS test_collector.sh"; else echo "FAIL test_collector.sh"; exit 1; fi
