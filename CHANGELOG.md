# Changelog

All notable changes are listed here. Records written by older versions stay readable: when the
state cache version changes, the cache is rebuilt from `hooks.jsonl` on the next open.

## [0.1.2] - 2026-10-09

### Added

- Pausing: `x` on a box (or `:AgentMapPause {n|id} [next|stop]`) pauses that agent at its next
  tool call or when it finishes, whichever comes first (`stop`: only when it finishes); `x` again
  (or `:AgentMapResume {n|id}`) resumes it. Nothing is cancelled: the synchronous delivery hook
  waits inside Claude Code until the pause file is removed. Resumed without an instruction, the
  agent sees nothing; `s` on a box paused before a tool call resumes it and the instruction arrives
  when it tries to finish (the main agent: the pause is lifted, then the text is typed into its
  terminal); a box paused at its end gets it on the spot. A pause left alone resumes by itself after
  `pause.auto_resume_s` (600 s); the hook keeps that deadline itself, so it holds when Neovim is
  closed or the computer sleeps (and removes the `pause.pending` flag when no pause is left).
  When a session ends, the recorder removes that run's pause files (and the flag when no pause
  is left anywhere), so a pause that never stopped its agent does not outlive the session.
- Gate: `X` (or `:AgentMapGate [on|off]`, `pause.gate` for runs you start watching) makes every
  running sub-agent of the run wait when it tries to finish. Its report can already be read;
  `x` on the box offers Pass (let it finish), Fix (write an instruction; it continues) or Keep
  waiting. Left alone it passes after 10 minutes.
- `[PAUSED]` / `[GATE]` labels and frames in orange (`AgentMapPaused`), ` ⏸` while a pause waits
  to be reached; the light on a paused agent's line stops (and flows back when an agent passes the
  gate and finishes). Notices when an agent stops, waits at the gate, resumes by itself, or
  finishes before it could stop (`pause.notify`).
- A pauses section in the detail view and `## Pauses` in exports (with a count and the gate in
  the overview).
- Relay through the main agent: `s` → "Write and relay now through the main agent" (item 2, only
  for a running direct sub-agent of the main agent when its Claude terminal is in this Neovim;
  `steer.relay = "menu"`, `"always"` puts it first, `"never"` hides it) or
  `:AgentMapSteer {n} relay [text]`. The line `[AgentMap] Tell sub-agent [3] "<name>" (agent id <id>)
  this, with SendMessage: <text>` (Japanese UI: the Japanese line) is typed into the main agent's
  terminal, and the main agent passes it on with `SendMessage`. The detail view shows SENT → READ →
  RELAYED from the records; PostToolUse now records `SendMessage` (recipient and the first 120
  characters). Notices when the main agent passed it on or ended its turn without doing so
  (` ✎!`). No parent notice is made for a relay.
- Notices when a sub-agent received an instruction at its end, and, when the map can estimate it
  from past runs, the time left until the agent is likely to finish.
- `:checkhealth agentmap`: pause registration (hook timeout) and pending pause flag rows; steering
  mode of the registered hooks, relay availability and the `SendMessage` matcher.
- Setting `pause` (also accepts `false`): `enabled`, `auto_resume_s`, `gate`,
  `release_on_exit` (default `false`: closing Neovim leaves pauses to resume by themselves),
  `notify`.
- `NOT HELD`: Claude Code caps held ends in a row (8, `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`); past
  that the hook still hands an instruction over, but the agent finishes without applying it. The
  map tells this from the main agent's records (the completion notice of a background sub-agent,
  or the return of a foreground one, with no work of that sub-agent in between): the box goes back
  to done, the instruction shows `NOT HELD` with ` ✎!` in the detail view and exports, and a
  notice says so. The main agent's own turn cannot be judged this way. In a live test on 2.1.291
  nine instructions in a row to one Haiku sub-agent were all held (README says so).

### Changed

- Steering reaches a sub-agent when it tries to finish (`SubagentStop` `decision: "block"`; Claude
  Code adds it as `Stop hook feedback`, a user-side line), and the main agent at the end of its
  turn when it has no terminal here (`Stop`). `steer.mode` defaults to `"stop"`; `"deny"` /
  `"context"` stay as options that also deliver at the next tool call, but current models may
  ignore text delivered as a tool result. The `PreToolUse` guard stays for pausing and, in mode
  stop, tests only `pause.pending`. The text for the end says where it comes from and that it
  arrives just before the agent finishes; until then the agent works on the old plan.
- `steer.at_stop` is removed (always on; a value in your setup is ignored and `:checkhealth`
  says so). `steer.no_terminal = "hook"` is now `"stop"` (the old name still works).
- With hooks registered by 0.1.1 (`--mode deny`) or with another `steer.mode` than the setting,
  `s` on a sub-agent refuses and asks for `:AgentMapInstallHooks` (the old guard would hand the
  file over at the next tool call, leaving nothing for the agent's end); the terminal routes (main
  agent, redo, relay) still work.
- The delivery hooks (`PreToolUse` guard, `SubagentStop`, `Stop`) carry `--pause --max-wait N`
  and a `timeout` of `auto_resume_s + 30` (630 s). Run `:AgentMapInstallHooks` again after
  upgrading; until then `x`, `X` and `s` on a sub-agent are refused, while recording and the
  terminal routes keep working.
- `hooks.status()` now also checks the feature words and the timeout of its own hook commands
  (still not their paths), so the 0.1.1 registration is reported as outdated.
- The state cache version is 11 (the cache is rebuilt once from the records). A second
  `SubagentStart` for the same agent id (a finished sub-agent started again by `SendMessage`) opens a
  new attempt and sets the box back to running.
- `?` and the detail views list `x` / `X`.
- A line typed into a Claude terminal that ends in `\` gets a space after it: Claude Code reads
  `\` + Enter as a new line, so the line stayed unsent and the next one was glued to it.
- Relay is not offered while the main agent is paused (a pause placed or reached): the line would
  wait in its terminal until it resumes, and the map does not resume a main agent you stopped.
  The `s` menu says why; the route at its end stays available.
- The text handed over at the next tool call (`steer.mode = "deny"` / `"context"`) no longer
  says that it is not a tool error or a test; like the text at the end, it only says where it
  comes from and what to do with it.
- The `s` menu no longer ends in a `Press ENTER` prompt with the built-in `vim.ui.select`; while
  that prompt waited, the Enter typed into the Claude terminal after a relay or a redo request
  was held back too, so the line sat unsent in Claude Code's input box.
- The unused text `ui.steer_relay_resume` is gone from the language tables.
- Sub-agents that report through `SubagentHandback` (Claude Code's auto mode) cannot be held at
  their end: the block is discarded by Claude Code. For them the text goes through the main agent
  (at its next tool call, or it starts again after finishing): `s` offers the relay first when the
  main agent's terminal is here; otherwise the text is placed and the notice says it cannot reach
  the agent at its end. The collector records `skipped (handback)` instead of claiming delivery,
  and an instruction skipped that way is relayed automatically when the main agent's terminal is
  here (`steer.handback_reroute`, default true; the original shows `CANCELLED (rerouted)`).
  `steer.handback = "deny"` hands the text over just before the hand-back as a tool result
  (optional; may be ignored). The gate and `:AgentMapPause … stop` hold such a sub-agent just
  before it hands back, with its report readable; Pass lets the report go, Fix lets it go and
  relays the text (the agent starts again after reporting). Records of 0.1.2 hooks before this
  change settle as `NOT HELD (hand-back)` from the parent's hand-back notice. The recorder keeps
  `permission_mode` and the report about to be handed back. Hooks: a `PreToolUse` hook for
  `SubagentHandback`; run `:AgentMapInstallHooks` again. State cache 12.

### Notes

- Claude Code 2.1.289 facts behind the design: a hook without `timeout` is stopped after 600 s;
  an explicit `timeout` is kept (630 s and 7200 s tested); past the timeout the hook is ended
  (SIGTERM) and the tool runs, with nothing shown; Esc interrupts only the main agent's turn
  (background sub-agents and their waiting hooks go on); when Claude Code exits, a waiting hook
  is ended and nothing is left running.
- Claude Code 2.1.291 facts behind the steering change: an instruction handed over with
  `SubagentStop` / `Stop` `decision: "block"` was followed by Haiku and Sonnet sub-agents 17 times
  out of 17 and by the main agent 9 out of 9; a Sonnet sub-agent ignored the same text in a
  `PreToolUse` deny and said it came from a tool result, not the user; the main agent called
  `SendMessage` with the text unchanged 5–8 s after a relay line was typed (7 of 7), and the
  sub-agent got it at its next tool round (followed: Sonnet 1 of 1, Haiku 3 of 5); a message to a
  finished sub-agent started it again with the same id; a sub-agent the main agent waits for in
  the foreground gets a relay only after it finishes; the Agent tool runs in the background by
  default; in interactive mode hidden helper agents send a `SubagentStop` without a start (no box
  is made). The delay until an instruction arrives at the end is the rest of the agent's work
  (14–17 s for six more tool calls in tests).
- Claude Code 2.1.294 facts behind the hand-back change (the author's own settings, a Sonnet main
  model): in auto mode sub-agents (not forks) are told to report through `SubagentHandback`, whose
  result carries `toolEndsTurn`; auto mode is the default permission mode even with
  `--setting-sources project` (a Haiku 5.5 main model keeps it; Haiku 4.5 on 2.1.292 turned it
  off; `--permission-mode default` gives sub-agents that report with plain text), and
  `CLAUDE_CODE_SENDMESSAGE_HANDBACK` is not read in this version. After the hand-back, `Stop` /
  `SubagentStop` / `PostToolUse` blocks are discarded (`[end-turn] Stop hook block discarded (turn
  ended by tool result, no model re-invoke)`). A deny of `SubagentHandback` with the text was
  followed by Sonnet 2 of 2 and Haiku 0 of 2. Relay was followed by a running sub-agent (Haiku 2 of
  2, Sonnet 1 of 1) and by a finished one, which started again under the same id and reported
  again (Haiku 3 of 3, Sonnet 1 of 1); a hook can hold at `PreToolUse:SubagentHandback`, and a
  relay sent while it holds arrives after the report, when the agent starts again. Hook payloads
  carry `permission_mode`; the parent gets `<agent-message from="<id>">[Subagent hand-back]`.

### Fixed

- The Claude terminal is found when Claude Code was started inside a shell (for example through an
  alias such as `claude-personal`): the terminal buffer is then named after the shell, so relaying
  and steering the main agent found no terminal. A `claude` process under the terminal's job now
  counts too.

## [0.1.1] - 2026-10-05

### Added

- Progress per box: finished steps ÷ all steps as fact; the running step is estimated from the
  typical time of similar past agents (median of your own records per agent type and model) and
  marked `~` (`[RUNNING] ~62.4%`). Boxes without a step list are estimated from elapsed time only
  (at most 95.0%); a parent without a step list shows the plain average of its children (finished
  = 100, not started yet = 0). The detail view lists the steps; exports show the value at export time.
- Step lists: the main agent's TaskCreate / TaskUpdate / TaskList are recorded; sub-agents write
  `## Steps` and `Step N done` (`## 手順` / `手順 N 完了`), read from their transcript.
  The writing convention has a new paragraph for it.
- The map is redrawn once a second while something runs (progress and elapsed time move);
  it stops while the map is hidden or in another tab page.
- A light flows along the line into each running agent (parent → child), back to the parent for
  3 seconds when the agent finishes, and in purple into a HUMAN CHECK that waits for an answer.
  Highlight-only (`AgentMapFlow*`, `AgentMapFlowBack*`, `AgentMapFlowWait*`); no timer runs when
  nothing is lit.
- Steering: `s` on a box or `:AgentMapSteer {n|id} [text]`. Running sub-agents get the text at
  their next tool call (a synchronous `PreToolUse` hook denies it with the text as the reason) or
  when they try to finish (`SubagentStop`); the main agent gets it typed into its `:terminal`;
  a finished agent becomes a redo request to the main agent. When an instruction reaches a
  sub-agent, its parent is told once by the same route (also when two Neovims show the same run:
  the records are checked before a notice is written). Marks `✎n` / `✎` / `✎!` in the
  box, a steering section in the detail view and in exports. Nothing is sent, with a message,
  when the registered hooks are outdated (hooks route only) or when the run has ended (terminal
  route: the Claude in that folder would be another conversation).
- Settings `progress`, `animation` and `steer` (each also accepts `false`).
- `:checkhealth agentmap`: progress history, estimate check, light, steering hook, pending
  steering flag and Claude terminal rows.
- `<root>/progress_log.jsonl` (estimate vs. actual duration, for checking the estimate) and
  `<root>/stats.json` (cached medians).

### Changed

- The `~50%` in a box (finished children ÷ children) is replaced by the new progress value.
- State cache version `SV` 9 (the cache is rebuilt; records are unchanged, `_v` stays 1).
- Hooks: new PostToolUse matcher (TaskCreate, TaskUpdate, TaskList), a second synchronous
  `PreToolUse` registration (a shell guard that returns in about 2 ms when nothing is pending),
  and `SubagentStop` is now synchronous. Existing registrations show as outdated: run
  `:AgentMapInstallHooks` again.
- Verified with Claude Code 2.1.288 and 2.1.289.

### Notes

- In Claude Code 2.1.288 sub-agents cannot use TaskCreate / TaskUpdate; they use the
  `## Steps` convention.
- Steering through hooks is shown to the model as `PreToolUse:<Tool> hook error: …`; stopping an
  agent at its end shows `Stop hook error occurred` in Claude Code's terminal. The main agent may
  ignore hook-delivered instructions depending on the model, so it is steered through its terminal.
- Steering text is stored as written (not redacted).
- `steer.submit_delay_ms` defaults to 300: Claude Code 2.1.289 treats a long line (about 250
  characters, the length of a parent notice) arriving in one write as a paste and leaves it unsent
  in its input box; Enter sent 150 ms or more later submits it. Short lines submit either way.
  Lines to the same terminal are sent one after another, so two instructions in the same second
  do not end up as one line.
- A sub-agent's transcript does not exist until its first message; the step list is now looked for
  again after 2 seconds (was 10), so `## Steps` shows up a few seconds after the agent starts.

## [0.1.0] - 2026-10-02

First public release.

### Added

- Live map of Claude Code agents inside Neovim: parent, children and grandchildren laid out as
  `START ▶ stage ▶ … ▶ END`, one map per prompt, updated while Claude Code works. Status in text
  and color: `PENDING`, `RUNNING`, `WAITING`, `REVIEW`, `DONE`, `REWORK`, `FAILED`.
- List (tree) view, switched with `v`, used automatically when the map does not fit.
- Detail view per agent: why it was delegated (`[Goal]` / `[Why delegate]` / `[Done when]`),
  progress notes and tools from its transcript, changed files, final report or "Needs confirmation".
- HUMAN CHECK boxes for AskUserQuestion: purple while waiting for your answer, green when answered,
  linked to the sub-agent that needed the decision.
- Review records (`PASS` / `RETRY` / `ESCALATE`) with history and reruns; a generic rubric
  (`rubric/RUBRIC.md`) and an entry point for verdict providers (`require("agentmap.review").register`).
- Export of a prompt's map to Markdown, HTML (bundled converter, no external tool) and PDF
  (through a command you configure, e.g. headless Chrome or Edge).
- Recorder `bin/agentmap-collect` (Python 3, standard library only) and `:AgentMapInstallHooks`,
  which registers it in Claude Code's `settings.json` after showing a diff; idempotent, keeps a backup.
- Import of sessions recorded before the hooks were installed, from Claude Code's transcripts.
- `:checkhealth agentmap`.
- English and Japanese user interface (`lang = "en" | "ja"`); the writing convention is read in
  both languages, always.
- Transcript (`t`), git diff (`d`) and working-folder (`w`) views for an agent.

### Notes

- Verified with Claude Code 2.1.283 – 2.1.286.
- Windows-native Neovim is experimental.
- The default record folder is `stdpath("data")/agentflow`, and `$AGENTFLOW_DIR` is read as a
  deprecated name for `$AGENTMAP_DIR`, so records from the earlier private version ("AgentFlow")
  keep working. Hooks registered by that version are replaced by `:AgentMapInstallHooks`.
