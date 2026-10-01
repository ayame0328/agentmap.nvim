#!/usr/bin/env python3
"""Replay a synthetic Claude Code session into an agentmap record store.

Used to record the README demo without running Claude Code. Each line of
scenario.jsonl is a hook payload (as Claude Code would send it) plus a time
offset. The payload is piped into the real bin/agentmap-collect, exactly like
a hook would, so the demo exercises the same recorder that users run.

Scenario line format:
    {"at": <seconds from start>, "p": <prompt number>, "agent": <agent id, optional>,
     "ev": {<hook payload without session_id / cwd / transcript_path / prompt_id>}}

A line may instead carry {"at": ..., "say": {"who": "ROOT" | <agent id>, "model": ...,
"text": ..., "tool": {"name": ..., "input": {...}}}}. With --claude-dir, such lines are
appended to a minimal transcript (the parent's, or the sub-agent's), so the detail view
can show the model and the progress notes; agent-<id>.meta.json is written at each
SubagentStart, as Claude Code does. Without --claude-dir none of these files are written.

Everything in the scenario is made up: the project is /home/user/work/invoices and
nothing personal is involved.

Usage:
    python3 demo/replay.py --root DIR [--claude-dir DIR] [--speed 1.0] [--scenario FILE]
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
COLLECTOR = os.path.join(REPO, "bin", "agentmap-collect")

SESSION = "d3m0d3m0-0000-4000-8000-000000000001"
CWD = "/home/user/work/invoices"
SLUG = "-home-user-work-invoices"
CLAUDE_DIR = "/home/user/.claude"


def project_dir():
    return os.path.join(CLAUDE_DIR, "projects", SLUG)


def transcript(who="ROOT"):
    if who == "ROOT":
        return os.path.join(project_dir(), SESSION + ".jsonl")
    return os.path.join(project_dir(), SESSION, "subagents", "agent-%s.jsonl" % who)


def prompt_id(n):
    return "d3m0p000-0000-4000-8000-%012d" % n


def payload(line):
    ev = dict(line["ev"])
    ev["session_id"] = SESSION
    ev["cwd"] = CWD
    ev["transcript_path"] = transcript()
    ev["prompt_id"] = prompt_id(line.get("p", 1))
    if line.get("agent"):
        ev["agent_id"] = line["agent"]
        ev.setdefault("agent_type", "general-purpose")
    if ev.get("hook_event_name") == "SubagentStop" and line.get("agent"):
        ev["agent_transcript_path"] = transcript(line["agent"])
    return ev


def say(line, seq):
    """Append one assistant message to a minimal transcript (only what agentmap reads)."""
    s = line["say"]
    content = []
    if s.get("text"):
        content.append({"type": "text", "text": s["text"]})
    if s.get("tool"):
        content.append({"type": "tool_use", "id": "toolu_demo_say_%d" % seq,
                        "name": s["tool"]["name"], "input": s["tool"].get("input", {})})
    rec = {"type": "assistant", "sessionId": SESSION, "cwd": CWD, "uuid": "d3m0u000-0000-4000-8000-%012d" % seq,
           "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
           "message": {"role": "assistant", "model": s.get("model", "claude-sonnet-4-5"), "content": content}}
    if s.get("who", "ROOT") != "ROOT":
        rec["agentId"] = s["who"]
        rec["isSidechain"] = True
    path = transcript(s.get("who", "ROOT"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def write_meta(agent_id, pre, model=None):
    """Write the agent-<id>.meta.json that Claude Code keeps next to a sub-agent transcript.
    The collector reads it at SubagentStart to link the agent to the Agent call right away."""
    ti = pre["ev"].get("tool_input") or {}
    meta = {"toolUseId": pre["ev"].get("tool_use_id"), "description": ti.get("description"),
            "agentType": ti.get("subagent_type"), "spawnDepth": 1}
    if model:
        meta["model"] = model
    path = transcript(agent_id)[:-len(".jsonl")] + ".meta.json"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", required=True, help="record store (the same as setup({ root = ... }))")
    ap.add_argument("--claude-dir", help="also write minimal transcripts under this folder "
                    "(the paths recorded in the hooks then point there)")
    ap.add_argument("--speed", type=float, default=1.0, help="2.0 plays twice as fast")
    ap.add_argument("--scenario", default=os.path.join(HERE, "scenario.jsonl"))
    ap.add_argument("--python", default=sys.executable)
    args = ap.parse_args()
    global CLAUDE_DIR
    if args.claude_dir:
        CLAUDE_DIR = os.path.abspath(args.claude_dir)

    with open(args.scenario, encoding="utf-8") as f:
        lines = [json.loads(l) for l in f if l.strip()]

    # the model each Agent call resolved to (from its PostToolUse), for the meta file
    models = {}
    for l in lines:
        tr = (l.get("ev") or {}).get("tool_response")
        if isinstance(tr, dict) and tr.get("resolvedModel"):
            models[l["ev"].get("tool_use_id")] = tr["resolvedModel"]

    os.makedirs(args.root, exist_ok=True)
    start = time.monotonic()
    pending = []  # Agent calls (PreToolUse) whose sub-agent has not started yet, oldest first
    for seq, line in enumerate(lines):
        wait = start + line["at"] / args.speed - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        if "say" in line:
            if args.claude_dir:
                say(line, seq)
            continue
        ev = line["ev"]
        if ev.get("hook_event_name") == "PreToolUse" and ev.get("tool_name") == "Agent":
            pending.append(line)
        elif ev.get("hook_event_name") == "SubagentStart" and pending:
            pre = pending.pop(0)
            if args.claude_dir:
                write_meta(ev.get("agent_id"), pre, models.get(pre["ev"].get("tool_use_id")))
        data = json.dumps(payload(line), ensure_ascii=False).encode("utf-8")
        subprocess.run([args.python, COLLECTOR, "--root", args.root], input=data, check=False)


if __name__ == "__main__":
    main()
