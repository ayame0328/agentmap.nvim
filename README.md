# agentmap.nvim

See what your Claude Code agents are doing, as a live map inside Neovim.

![agentmap.nvim: agents run, one stops to ask, the human check turns from purple to green](demo/agentmap.gif)

*The demo replays made-up records (`demo/`); no real session is shown.*

Claude Code can start sub-agents, and those can start their own. agentmap.nvim draws that
work as a map from `START` through stages to `END`: who started whom, what is running, what
has finished, and where a person is needed. It updates while Claude Code works and keeps
every run, so you can open old ones later.

[日本語の説明は README.ja.md](README.ja.md)

## What it shows

- **The map.** Parent, children and grandchildren as boxes, laid out `START ▶ stage 1 ▶ stage 2 ▶ … ▶ END`.
  Agents started together share a stage. Each box shows its status in text *and* color:
  `[PENDING]` grey, `[RUNNING]` yellow, `[WAITING]` purple, `[REVIEW]` blue, `[DONE]` green,
  `[REWORK]` / `[FAILED]` red. One map per prompt you typed.
- **Why, how and what came back.** The detail view of an agent shows why the parent delegated
  the task, the agent's progress (its short notes and the tools it used, in time order),
  the files it changed, and its final report.
- **HUMAN CHECK.** When Claude asks you a question (AskUserQuestion), a purple `[WAITING]` box
  appears in the map, linked to the agent that caused it. It turns green with your answer.
- **Review and rework.** Mark an agent's work as `PASS`, `RETRY` or `ESCALATE` with a reason.
  Reviews are kept as history, and a rerun is shown as a new attempt of the same agent.
- **Export.** Save the map of a prompt as Markdown, HTML or PDF (with a Mermaid diagram and a
  text tree), for a report or a pull request.
- **Progress per box.** Finished steps ÷ all steps is shown as fact; between two steps the number
  is an estimate marked `~` (from your own past runs). A light flows along the line into each
  running agent, and back to the parent for a moment when the agent reports.
  See [Progress and the light](#progress-and-the-light).
- **Steering.** Press `s` on a running agent and write what to change: a sub-agent gets it at its
  next tool call, the main agent gets it typed into its terminal.
  See [Steering a running agent](#steering-a-running-agent).
- **Pausing.** Pause a running agent from the map (`x`): it stops at its next tool call or when it
  finishes, waits for you (10 minutes at most), and takes an instruction when you resume it.
  Optional gate (`X`): every sub-agent waits at its end for your pass or fix. The box turns orange
  (`[PAUSED]` / `[GATE]`). See [Pausing an agent and the gate](#pausing-an-agent-and-the-gate).

### How is it different from other tools?

Other agent monitors for Claude Code (for example
[claude-code-hooks-multi-agent-observability](https://github.com/disler/claude-code-hooks-multi-agent-observability)
and [agents-observe](https://github.com/simple10/agents-observe)) show events in a web page
served by a local server. agentmap.nvim runs **inside Neovim**: no server, no browser, no
extra port. The map opens in a tab next to your code, `t` opens an agent's transcript and
`d` its git diff. Records are plain JSON Lines files on your disk.

## How it works

```
Claude Code ── hooks ──▶ bin/agentmap-collect ──▶ <root>/projects/<project>/runs/<session>/hooks.jsonl
 (unchanged)              (Python 3, stdlib only)                     │
                                                                      ▼
                                              Neovim: :AgentMap reads and watches the file
```

- Claude Code calls a small recorder through its [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks).
  The recorder appends one short line per event and exits. It never fails and never changes what
  Claude Code does, with one exception you start yourself: a [steering instruction](#steering-a-running-agent)
  you wrote is delivered by stopping the agent's next tool call, and a [pause](#pausing-an-agent-and-the-gate)
  you place holds the agent inside the hook until you resume it (10 minutes at most).
- Most hooks run asynchronously, so Claude Code does not wait for them. `Stop`, `SubagentStop`
  and `SessionEnd` run synchronously (a few milliseconds; asynchronous ones were lost when Claude
  Code exited, and the stop hooks also deliver steering). One more synchronous `PreToolUse` hook
  delivers steering: it is a one-line shell check for a flag file and returns in about 2 ms when
  nothing is waiting.
- Neovim reads the records. Neovim does not have to be open while Claude Code runs; you can
  look at a run afterwards.

## Requirements

| | Version |
|---|---|
| Neovim | 0.10 or newer |
| Python | 3 (standard library only). `python3`, `python` or `py -3` is used, in that order |
| Claude Code | verified with 2.1.283 – 2.1.289 (see [Compatibility](#compatibility)) |
| OS | Linux, macOS, WSL. Windows-native Neovim is **experimental** |

Optional: `git` (for the diff view), [oil.nvim](https://github.com/stevearc/oil.nvim)
(the `w` key opens the agent's folder in it), a Chromium-based browser for PDF export.
Lists use `vim.ui.select`, so snacks.nvim, telescope, fzf-lua or mini.pick are used if you have
one of them set up for it. No plugin is required.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ayame0328/agentmap.nvim",
  lazy = false,                   -- load at startup (see below)
  opts = {},                      -- lang = "ja" for Japanese
  keys = {
    { "<leader>aa", "<Cmd>AgentMap<CR>",       desc = "AgentMap: open map" },
    { "<leader>ar", "<Cmd>AgentMapRuns<CR>",   desc = "AgentMap: past runs" },
    { "<leader>ae", "<Cmd>AgentMapExport<CR>", desc = "AgentMap: export" },
  },
}
```

`setup()` is optional; the commands work without it. Keep `lazy = false`: with `keys` alone,
lazy.nvim loads the plugin only when one of those keys is pressed, and until then
`:AgentMapInstallHooks` and `:checkhealth agentmap` do not exist. Loading it costs nothing
noticeable (one small file).

Then, once:

1. Run `:AgentMapInstallHooks`. It shows the change to Claude Code's `settings.json` as a diff
   and asks before writing. Your other settings and hooks are kept, the original file is
   saved as `settings.json.bak-<timestamp>`, and running it again changes nothing.
   Run it again after updating the plugin if `:checkhealth agentmap` says the hooks are outdated.
2. Run `:checkhealth agentmap`. It checks Neovim, Python, the recorder, the Claude Code folder,
   the hooks, the record folder and the optional tools.
3. Start a new Claude Code session. Recording starts with that session.
4. Add the [writing convention](#writing-convention) to your `CLAUDE.md` (recommended).

Sessions from before the hooks were installed can be imported from Claude Code's transcripts
with `:AgentMapRuns` or `:AgentMapImport`.

### Upgrading

From 0.1.1 to 0.1.2: run `:AgentMapInstallHooks` again (the delivery hooks get `--pause` and a
630 s timeout). Until then pausing is refused; recording and steering keep working.

After upgrading from 0.1.0, run `:AgentMapInstallHooks` again. Version 0.1.1 records
TaskCreate / TaskUpdate / TaskList (the main agent's step list), adds the synchronous
`PreToolUse` guard that delivers steering, and makes `SubagentStop` synchronous.
`:checkhealth agentmap` says "outdated" until you do. Run it again as well when you change
`steer.mode` or `steer.at_stop`, because they are written into the hook command.

### Try it without Claude Code

```sh
cd ~/.local/share/nvim/lazy/agentmap.nvim      # or wherever the plugin is
python3 demo/replay.py --root /tmp/agentmap-demo --claude-dir /tmp/agentmap-demo-claude &
sleep 1; AGENTMAP_DIR=/tmp/agentmap-demo nvim -c AgentMap
```

The script plays the session from the demo above (about 30 seconds of made-up events)
through the real recorder. The `sleep 1` gives it time to write the first record; without it
`:AgentMap` can run before anything exists and say "No recorded runs" (then just run `:AgentMap` again).

## Usage

### Commands

| Command | What it does |
|---|---|
| `:AgentMap [session_id [prompt_id]]` | Open the map of the latest prompt (follows new runs) |
| `:AgentMapRuns` | Pick a past run |
| `:AgentMapAgent {n\|id}` | Details of an agent |
| `:AgentMapRefresh` | Reload |
| `:AgentMapExport [markdown\|html\|pdf] [path]` | Export the prompt shown in the map |
| `:AgentMapReview {n\|id} {PASS\|RETRY\|ESCALATE\|SUBMIT} [reason]` | Record a review |
| `:AgentMapInstallHooks [settings.json]` | Register the recording hooks in Claude Code |
| `:AgentMapImport [session_id]` | Import a run from a transcript |
| `:AgentMapSteer {n\|id} [text]` | Send a steering instruction to an agent (no text: opens the editor) |
| `:AgentMapPause {n\|id} [next\|stop]` | Pause an agent at its next tool call or when it finishes (`next`, default), or only when it finishes (`stop`) |
| `:AgentMapResume {n\|id}` | Resume a paused agent (a box waiting at the gate: let it pass) |
| `:AgentMapGate [on\|off]` | Gate of the run on screen on / off (no argument: toggle) |

### Keys in the map

All keys are local to the map buffer; nothing global is mapped unless you ask for it
(`keymaps = { global = true }` adds `<leader>aa`, `<leader>ar`, `<leader>ae`).

| Key | Action |
|---|---|
| `1`–`9` | Details of agent number n |
| `Enter` | Details of the box under the cursor (a HUMAN CHECK box shows the question) |
| `n` / `p` | Next / previous box |
| `+` / `-` | Expand / collapse children |
| `z` / `BS` | Show only this agent and below / go back up |
| `t` | Transcript of the agent |
| `d` | git diff of the agent |
| `w` | Go to the agent's working folder |
| `a` | Review (submit / PASS / RETRY / ESCALATE / rerun / name) |
| `s` | Steer: write an instruction to this agent (see [Steering](#steering-a-running-agent)) |
| `x` | Pause this agent / resume it (a box waiting at the gate: Pass / Fix menu; see [Pausing](#pausing-an-agent-and-the-gate)) |
| `X` | Gate on / off for this run: every sub-agent waits at its end for pass / fix |
| `e` | Export |
| `r` | Reload |
| `R` | Past runs |
| `v` | Switch between map and list |
| `?` | Key list |
| `q` | Close |

In the detail, transcript and diff views: `BS` goes back, `q` closes, `Enter` opens the
agent / parent / HUMAN CHECK on the line, and `t` / `d` / `w` / `a` / `s` / `x` work as in the map.

When the map is too wide for the window it opens as a list (tree) instead; `v` switches.

### Progress and the light

Each box shows how far the agent is, next to its elapsed time:

```
[RUNNING] ~62.4% 12:34      estimate: "~" in front
[REVIEW] 66.6% 12:34        fact only (2 of 3 steps finished)
[DONE] 100.0% 15:02
```

- **What is fact.** The number of finished steps divided by all steps of the agent's step list.
  The main agent keeps its list with TaskCreate / TaskUpdate (recorded by the hooks). Sub-agents
  cannot use those tools (Claude Code 2.1.288), so they write `## Steps` and `Step N done` lines
  as text; see the [writing convention](#writing-convention). The detail view lists the steps.
- **What is estimated (`~`).** Only the step that is running: elapsed time ÷ the typical time of
  similar past agents, taken from your own records (the median per agent type and model; a step's
  share of it while there are no per-step records). A parent's running step is filled in with the
  average of its running children. The value is rounded down and stays below 100 until the agent
  finishes, so it never looks further along than it is. It can go down when the agent rewrites
  its step list.
- **Boxes without a step list** are estimated from elapsed time only (elapsed ÷ typical time,
  at most 95.0%), also marked `~`. Set `progress.no_steps = "none"` to show no number for them.
- **A parent without a step list** (the main agent before it creates tasks, a Workflow box) shows
  the plain average of its children: finished children count as 100, children that have not
  started yet (`PENDING`) count as 0, so the number does not run ahead while more are still to come.
- **Typical times** come from your finished agents (`:checkhealth agentmap` shows how many). With
  no history the default is 10 minutes per agent (`progress.default_ms`). They improve as records
  accumulate; per-step times are used once v0.1.1 has recorded enough steps.
- **Every second.** While something runs, the map is redrawn once a second (only changed lines).
  With a long typical time the last digit moves only every few seconds. Nothing runs while the
  map is hidden or in another tab page. Exports show the value at the time of export.
- **The light.** In the map (box) view, a dot of light runs along the line into every
  `[RUNNING]` agent, from parent to child. When the agent finishes, the same line flows back from
  child to parent for 3 seconds (`animation.back_ms`). The line into a HUMAN CHECK that waits for
  your answer flows in purple. Only colors move; the text is never rewritten, and the timer stops
  when nothing is lit. The list (tree) view has no light. On terminals with fewer than 16 colors
  the head of the light is drawn bold and reversed.
- `progress = false` hides the numbers in the boxes (details and exports still show them);
  `animation = false` turns the light off completely.
- For checking the estimate later, one line per running box every 30 seconds and one when it
  finishes go to `<root>/progress_log.jsonl` (`progress.log = false` turns this off);
  `:checkhealth agentmap` reports the median error.

### Language

English is the default. For Japanese: `opts = { lang = "ja" }`, or `vim.g.agentmap_lang = "ja"`
before the plugin loads.

## Configuration

All options with their defaults:

```lua
require("agentmap").setup({
  lang = "en",                 -- "en" | "ja"; falls back to vim.g.agentmap_lang when not given
  root = nil,                  -- record folder; nil → $AGENTMAP_DIR → stdpath("data") .. "/agentflow"
  claude_config_dir = nil,     -- Claude Code's folder; nil → $CLAUDE_CONFIG_DIR → ~/.claude
  python = nil,                -- nil → first of "python3", "python", "py -3"; or a string / list
  open = "tab",                -- where the map opens: "tab" | "vsplit" | "current"
  aux_width = 0.45,            -- width of the side view (share of the screen)
  box_w = 26,                  -- inner width of a box
  col_gap = 7,                 -- space between boxes
  mode = "auto",               -- "box" | "tree" | "auto" (tree when the map does not fit)
  poll_ms = 1500,              -- how often files are checked for changes
  debounce_ms = 200,           -- wait before redrawing after a change
  switch_delay_ms = 15000,     -- after a prompt finishes, wait this long before following the next one
  detail = { progress_max = 40, note_chars = 120, report_chars = 4000, lead_chars = 400 },
  transcript = { max_chars = 2000, max_bytes = 5e6, notes_first_bytes = 1e6, notes_max = 400 },
  review = {
    provider = "auto",         -- "auto" | "manual" | name of a registered provider
    rubric = nil,              -- path to your RUBRIC.md; nil → the bundled rubric/RUBRIC.md
  },
  keymaps = { global = false },     -- true adds <leader>aa / <leader>ar / <leader>ae
  hooks = { settings_path = nil },  -- nil → <claude_config_dir>/settings.json
  export = {
    html_command = nil,        -- argv; Markdown on stdin, title as last argument, HTML on stdout
    pdf_command = nil,         -- argv with %{html} %{out} %{title}; nil → PDF export is off
  },
  brief = { markers = nil },   -- reserved (custom markers are planned, see Roadmap)
  progress = {                 -- false = { enabled = false }
    enabled = true,            -- show % in the boxes (false hides it there; details and exports keep it)
    tick_ms = 1000,            -- redraw interval while something runs (% and elapsed time move)
    default_ms = 600000,       -- typical time of one agent while there is no history (10 min)
    min_samples = 3,           -- finished agents needed before a type+model median is used
    no_steps = "time",         -- boxes without a step list: "time" = estimate from elapsed time (max 95.0) | "none"
    log = true,                -- write <root>/progress_log.jsonl to check the estimate later
  },
  animation = {                -- false = { enabled = false }
    enabled = true,
    frame_ms = 100,            -- one frame
    period = 6,                -- cells between two dots of light
    tail = 2,                  -- cells of tail behind the head
    back_ms = 3000,            -- how long the light flows back after an agent finishes
    max_paths = 40,            -- at most this many lit lines at once
  },
  steer = {                    -- false = { enabled = false }
    enabled = true,            -- false: no delivery hook is registered; s says it is off
    mode = "deny",             -- "deny": stop the next tool call, the reason is your text | "context": let it run, add the text
    at_stop = true,            -- also deliver when the agent tries to finish (stops it once)
    root_via = "terminal",     -- main agent: "terminal" | "hook"
    no_terminal = "hook",      -- no Claude terminal found: "hook" | "clipboard" | "none"
    submit_delay_ms = 300,     -- Enter is sent this many ms after the text (0: one write; long
                               -- lines then stay unsent in Claude Code's input box, see below)
    input = "window",          -- "window" (floating editor) | "line" (vim.ui.input)
    text_max = 4000,           -- characters
  },
  pause = {                    -- false = { enabled = false }
    enabled = true,            -- false: no pause in the hook command; x / X say it is off
    auto_resume_s = 600,       -- a pause left alone resumes by itself after this many seconds (5–86400)
    gate = false,              -- gate of a run you start watching (X turns it over per run)
    release_on_exit = false,   -- true: closing Neovim resumes every pause of the run on screen
    notify = true,             -- notices: paused, waiting at the gate, resumed by itself
  },
})
```

`steer.mode` and `steer.at_stop` are written into the hook command: run `:AgentMapInstallHooks`
again after changing them (`:checkhealth agentmap` warns when they differ).
`pause.auto_resume_s` is written into the hook command and timeout: run `:AgentMapInstallHooks`
after changing it.

The default record folder is named `agentflow` (not `agentmap`) on purpose: it keeps records
from the earlier private version readable. `$AGENTFLOW_DIR` is still read as an old name for
`$AGENTMAP_DIR`.

## Writing convention

agentmap.nvim shows *why* an agent was started and *what it reported* only when Claude writes
them in a fixed form. It does not guess: anything not written this way is shown as `(not written)`.
Paste this into your `CLAUDE.md`:

```markdown
## Delegating to agents (read by agentmap.nvim)

agentmap.nvim reads the headings and item names below mechanically and shows them in Neovim.
Items that are missing are shown as "(not written)"; nothing is guessed.

**Parent (the one that starts an Agent): the first three lines of the prompt**, in this order:

[Goal] what this is for (one line)
[Why delegate] why it is delegated instead of done directly (one line)
[Done when] what has to come back for the task to be finished (one line)

**Child (the started agent): the final report.** When returning with SubagentHandback,
write it inside the message in this form:

## Report
- Done: what was done
- Approach: how it was approached
- Why: why that approach
- Open issues: "none" if there are none

If you received a steering instruction from the user while working, say in Approach or Why
which instruction it was and what you changed because of it.

**Child: when a human decision is needed.** A sub-agent cannot ask the user directly.
Stop, and instead of the report write this and finish:

## Needs confirmation
- Working on: what was being done
- Blocked at: where it cannot continue
- Question: the question, in one sentence
- Options:
  1. Name -> what happens after choosing it
  2. Name -> what happens after choosing it

**Parent: asking the user (AskUserQuestion) because of a child's Needs confirmation**

- question: "<description given to the child>: <the child's Question>"
- header: the start of the description (up to 12 characters)
- each option's label is the child's option name, unchanged; end its description with
  "-> if chosen: <what happens next>"
- when asking on your own initiative, use the same form without the "<description>:" part
- after the answer, continue accordingly; when restarting the child, say in [Goal] that "<answer>" was chosen

**Child: step list (read as progress).** Before starting work, write `## Steps` followed by a
numbered list (3–8 steps) in your first reply. After finishing a step, write a line `Step N done`.
The main agent keeps its own list with TaskCreate / TaskUpdate (sub-agents cannot use those tools
in Claude Code 2.1.288). agentmap.nvim counts finished steps as fact and marks everything between
two steps as an estimate (`~`).
```

The exact parsing rules are in [docs/writing-convention.md](docs/writing-convention.md).
English and Japanese markers (`【目的】`, `## 報告`, … see
[docs/writing-convention.ja.md](docs/writing-convention.ja.md)) are both always accepted.

## Human checks

A HUMAN CHECK box appears when Claude calls AskUserQuestion. It is linked to the sub-agent whose
description appears in the question (the convention above writes it there), otherwise to the
agent that asked. The box is purple `[WAITING]` until you answer in the terminal, then green
`[DONE]` with your answer, or grey `[UNANSWERED]` if the turn ended without an answer.
`Enter` on the box shows the question, each option with what happens next, and the child's
`Needs confirmation` report.

## Steering a running agent

Press `s` on a box (or run `:AgentMapSteer {n|id} [text]`) and write what the agent should change.
A small window opens; `<C-s>`, `:w` or `Enter` in normal mode sends, `q` cancels. How it is
delivered depends on the box:

| Box | Route |
|---|---|
| A running sub-agent (child, grandchild, reviewer) | **Hooks.** The text waits in the run's folder. At the agent's next tool call the `PreToolUse` hook stops that call and returns your text as the reason. If the agent finishes without another tool call, `SubagentStop` stops it once and hands it the text (`steer.at_stop`). |
| The main agent (ROOT) | **Terminal.** The text is typed into the `:terminal` running `claude` in this Neovim, as `[AgentMap] <text>` followed by Enter. Claude Code reads text typed while it works at its next step; if it is idle, the text starts a new turn. |
| A finished agent (`DONE` / `REWORK` / `FAILED`) | **Redo request** to the main agent's terminal: `[AgentMap] Please redo agent [3] "<name>" (id …, finished 10:31): <text>. Use the same delegation; report what changed.` The agent itself cannot be reached any more. Nothing is marked as rework automatically; the main agent decides. |

When an instruction reaches a sub-agent, its parent is told as well, once, by the same route as
any instruction for that parent (the main agent: its terminal, else hooks; a sub-agent parent:
hooks): `[AgentMap] The user sent this instruction directly to your sub-agent [2] "<name>": <text>.
If it also affects other sub-agents or your plan, update them.` Nothing is sent when the parent
has already finished. The sub-agent is asked to mention the instruction in its report.

What to know:

- A sub-agent sees your text as one line: `PreToolUse:Write hook error: [AgentMap] Steering
  instruction from the user, typed in Neovim while you were working (this is not a tool error): …`.
  "hook error" is added by Claude Code and cannot be removed. The stopped tool call is not run;
  the agent calls it again (or something else) after reading the text. With
  `steer.mode = "context"` the tool call runs and the text is added as context instead.
- Stopping an agent at its end shows `Stop hook error occurred` in Claude Code's terminal. Claude
  Code ends the turn after 8 stops in a row (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`), so it never loops.
- An agent usually follows the instruction, but this is not guaranteed. In tests the main agent
  on Haiku ignored hook-delivered instructions (0 of 6) while Opus and Sonnet followed them;
  that is why the main agent gets it through its terminal.
- No Claude terminal (for example Claude Code runs in another terminal window): the text is
  delivered through the hooks at the main agent's next tool call (`steer.no_terminal = "hook"`),
  copied to the clipboard (`"clipboard"`), or not sent (`"none"`). The Claude terminal in the run's
  folder (or a parent folder) is used; if there are several, or only ones in other folders, you
  pick one, once per run.
  Glance at the terminal after sending: agentmap.nvim cannot see whether Claude Code is waiting at
  a different prompt (for example the folder trust question).
- Text typed into the terminal is sent as one line, and Enter follows `steer.submit_delay_ms`
  (300 ms) later. With `0` a long line (about 250 characters, the length of a parent notice) is
  treated as a paste by Claude Code 2.1.289 and stays unsent in its input box; short lines are
  submitted either way. The detail view shows `SENT` until Claude Code reads the line, then
  `DELIVERED (read by Claude Code)`, so you can tell the two apart.
- Two cases where nothing is sent and a message tells you why: the registered hooks are outdated
  (`:checkhealth agentmap` says so; `s` on a running agent asks you to run `:AgentMapInstallHooks`
  first, since the old registration has no delivery hook; the main agent's terminal route is not
  affected), and the run has ended (its session is closed; `s` on the main agent or on a finished
  agent would type into the Claude of another conversation in the same folder, so give new
  instructions in Claude Code itself).
- The box shows ` ✎1` (purple) while an instruction waits, ` ✎` (green) for a minute after it was
  delivered, and ` ✎!` (red) if the agent finished before it could be delivered (you also get a
  notice). The detail view lists every instruction with its full text (`Enter` on a line opens
  it); `s` → "Cancel pending" withdraws one that has not been delivered. Exports have a
  "Steering instructions" section.
- Files: undelivered text is in `<root>/projects/<project>/runs/<session>/steer/<agent>-<ms>.json`
  (mode 0600) and `<root>/steer.pending` is the flag the shell check looks at. Delivered ones are
  renamed to `*.delivered.json`. Any process running as your user can write these files (an
  agent's Bash included), so read the delivered text in the detail view if something looks odd.

## Pausing an agent and the gate

Press `x` on a running box (or run `:AgentMapPause {n|id}`) to pause that agent. Nothing is
cancelled: the agent stops at its next tool call, or when it tries to finish, whichever comes
first, and waits there. Press `x` again to resume it. `:AgentMapPause {n|id} stop` pauses it only
when it finishes. The main agent (ROOT) can be paused too.

How it works: the synchronous hooks that deliver steering (`PreToolUse`, `SubagentStop`, `Stop`)
look for a pause file. When they find one, the hook **waits inside Claude Code** (it checks the
file every 100 ms) instead of returning. Removing the file (`x`) lets the hook return.

- **What stops, what does not.** Only that agent. Other sub-agents keep working; a parent that
  needs the paused child's result waits for it as it would for a slow tool. Claude Code shows
  nothing for a paused sub-agent; for a paused main agent its spinner says
  `running PreToolUse hooks…`. The map is where you see it: the box turns orange,
  `[PAUSED]` (or `[GATE]`), and the light on its line stops. While a pause is placed but the
  agent has not reached it yet, the box shows ` ⏸` (`||` in terminals that draw it wide).
- **What the agent sees.** Resumed without an instruction: nothing. The held tool call simply
  runs (or the agent finishes), as if the tool had been slow. Resumed with an instruction
  (`s` on the paused box, or "Fix" at the gate): the same text as any steering instruction, with
  one more line, `(You were paused by the user for 2 min 31 s before this instruction.)`. Writing
  an instruction to a paused box always resumes it on the spot; for the main agent it then goes
  through the hook, not the terminal.
- **10 minutes at most.** A pause left alone resumes by itself after `pause.auto_resume_s`
  (600 s). The hook keeps this deadline itself, by the wall clock, so it holds when Neovim is
  closed or the computer sleeps. You get a notice when it happens.
- **Why the hook timeout is 630 s.** Claude Code stops a hook after its `timeout` (600 s when none
  is set, in 2.1.289) and then runs the tool anyway, silently. A pause that outlives the timeout
  would look paused while the agent goes on, so `:AgentMapInstallHooks` registers the delivery
  hooks with `auto_resume_s + 30` seconds. The recording hooks keep 10 s.
- **The gate.** `X` turns the gate of the run on screen on (or `:AgentMapGate on`; `pause.gate`
  is the value for runs you start watching). While it is on, every running sub-agent (children,
  grandchildren and Workflow agents; not the main agent) waits when it tries to finish. Its report
  is already recorded, so `Enter` on the `[GATE]` box shows it. `x` on that box gives:
  **Pass** (let it finish; the parent gets the report), **Fix** (write an instruction; the agent
  continues, and waits again at its next end while the gate is on; Claude Code allows 8 stops in a
  row, so 8 fixes) and **Keep waiting** (show the report). Left alone, it passes after 10 minutes.
  `X` again turns the gate off and lets every waiting agent pass. The gate is kept in the run's
  folder, so it stays on when you reopen the map.
- **Esc in Claude Code** interrupts only the main agent's turn; sub-agents (and a hook holding
  one) keep going. A pause on the main agent stays placed: it stops again at its next tool call
  (within the same 10 minutes).
- **Closing Neovim** changes nothing by default: paused agents resume by themselves at their
  deadline, and you can reopen the map to resume them earlier. With `pause.release_on_exit = true`
  closing Neovim resumes every pause of the run on screen. When Claude Code itself exits, the
  waiting hook is ended and the pause is recorded as ended.
- **Hooks.** Pausing needs the hooks registered by 0.1.2: run `:AgentMapInstallHooks` after
  upgrading. With the old registration `x` and `X` say so and do nothing; recording and steering
  keep working.
- **Cost.** With nothing paused, a tool call costs the same 1–2 ms shell check as before. While
  any pause file exists (always, while a gate is on), each tool call starts the recorder
  (about 15–20 ms). A waiting hook checks one file every 100 ms (under 1% of a CPU).
- **Files.** `<root>/projects/<project>/runs/<session>/pause/<agent>.json` is the pause (mode 0600,
  no text), `<agent>.hit.json` is written by the hook when the agent stopped (time, deadline, tool
  name), `GATE` marks a run whose gate is on, and `<root>/pause.pending` is the flag the shell check
  looks at. Like the steering files, any process running as your user can write them.

## Review and verdict providers

Press `a` on an agent (or use `:AgentMapReview`) to record `PASS`, `RETRY` or `ESCALATE` with a
reason. The verdict is always yours. Every review is written to the run's records and to
`<root>/review_log.jsonl`, together with the version of the rubric you used.
The bundled [rubric/RUBRIC.md](rubric/RUBRIC.md) has five questions; point `review.rubric` at your own.

A verdict provider can *propose* a verdict before you choose:

```lua
require("agentmap.review").register("my-judge", {
  -- optional: say whether this provider can run on this machine
  available = function() return vim.fn.executable("my-judge") == 1, "my-judge not found" end,
  -- ctx = { agent, agent_id, state, run, rubric }; call cb({ verdict = "PASS", reason = "..." }) or cb(nil)
  evaluate = function(ctx, cb) cb({ verdict = "PASS", reason = "tests pass" }) end,
})
```

With `review.provider = "auto"` the first available registered provider is used, otherwise you
choose by hand. You still make the final choice; the proposal is logged next to it.

## Export

`:AgentMapExport` (or `e` in the map) writes the prompt shown in the map: an overview, the map as a
Mermaid diagram and as a text tree, every agent with its brief and report, the human checks,
the reviews, the changed files and the tool calls.
Files go to `<root>/projects/<project>/runs/<session>/exports/` unless you give a path.

- **Markdown**: always available.
- **HTML**: a single file with inline CSS (light and dark), converted by a small converter bundled
  in Lua. Set `export.html_command` to use another converter (for example pandoc).
- **PDF**: set `export.pdf_command` to a program that prints HTML to PDF. Examples:

```lua
-- Linux
export = { pdf_command = { "google-chrome", "--headless=new", "--disable-gpu",
  "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- macOS
export = { pdf_command = { "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- Windows (Edge)
export = { pdf_command = { "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- WSL, using Chrome on Windows (paths are converted to Windows form automatically)
export = { pdf_command = { "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe",
  "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
```

## Privacy: what is stored

Records stay on your disk, in `<root>` (default `stdpath("data")/agentflow`). Nothing is sent anywhere.

Stored, per event:

- session id, prompt id, agent id and type, working folder, event name, time
- the first 200 characters of your prompt and of each Agent prompt, and the three
  convention lines (`[Goal]` `[Why delegate]` `[Done when]`, up to 300 characters each)
- agent description, type and model
- tool name and its target: the file path for Write / Edit, the first line of a Bash command (up to 120 characters)
- AskUserQuestion questions, options and answers (clipped)
- the child's final report (up to 2000 characters) and the first 200 characters of the last message
- step lists: TaskCreate subjects and `## Steps` items (up to 60 characters each) and their
  status changes; TaskCreate descriptions are not stored
- **steering instructions as you wrote them** (not redacted; up to 4000 characters), in
  `events.jsonl` and `steer/*.delivered.json`
- `progress_log.jsonl` (estimates and actual durations, no text) and `stats.json` (median durations)
- pauses: when they were placed, where the agent stopped and when it resumed (`events.jsonl`,
  `hooks.jsonl`). Pause files hold no text; `pause/<agent>.hit.json` holds the tool name and its
  `tool_use_id` while the agent waits

Not stored:

- full prompts, tool output, file contents, Read / Grep / web tool calls
- anything that looks like a secret: `api_key=…`, `token: …`, `password=…`, `Bearer …`,
  `sk-…`, `ghp_…`, `github_pat_…`, `AKIA…`, `xox…-`, `AIza…` are replaced with `***` before writing

The detail and transcript views read Claude Code's own transcript files (in `claude_config_dir`)
when you open them; they are not copied. Exports are written only when you ask.
To delete records, delete folders under `<root>/projects/`.

## Containers, WSL and Windows

- **Claude Code in a container** (devcontainer, Docker, a sandbox) and Neovim on the host:
  see [docs/containers.md](docs/containers.md). You need one folder both can see.
- **WSL**: works as on Linux when Neovim and Claude Code both run inside WSL.
- **Windows-native Neovim**: **experimental** in v0.1.0. Hook commands are written for bash
  (Claude Code runs hooks through Git Bash on Windows). Please report what does not work.

## Compatibility

Claude Code's hook input carries no version number, so compatibility is checked by recording
real hook payloads (see `tests/fixtures/`).

| Claude Code | Checked | Notes |
|---|---|---|
| 2.1.283 – 2.1.286 | 2026-10-01 | The real hook payloads in `tests/fixtures/` were captured from 2.1.283 |
| 2.1.288 | 2026-10-04 | TaskCreate / TaskUpdate / TaskList payloads; steering (deny wording, `stop_hook_active`, typing into a running `claude`) |
| 2.1.289 | 2026-10-04 | Full run through Neovim: progress, light, steering, parent notice, HUMAN CHECK, export. A long line typed into `claude` needs Enter sent separately (`steer.submit_delay_ms`, now 300) |
| 2.1.289 | 2026-10-05 | Pausing: a hook without `timeout` is stopped after 600 s; an explicit `timeout` is kept (630 s and 7200 s tested). Past the timeout Claude Code ends the hook (SIGTERM) and runs the tool, showing nothing. Esc does not stop background sub-agents; `/exit` with background work asks (stop tasks / move to background / stay). A hook that waits on the main agent's tool shows `running PreToolUse hooks…` in the spinner; on a sub-agent nothing is shown |

Hooks used: `SessionStart`, `UserPromptSubmit`, `PreToolUse` (Agent, AskUserQuestion; and every
tool for steering, synchronous), `PostToolUse` (Agent, AskUserQuestion, Write, Edit, MultiEdit,
NotebookEdit, Bash, EnterWorktree, ExitWorktree, TaskCreate, TaskUpdate, TaskList),
`PostToolUseFailure` (Agent, AskUserQuestion), `SubagentStart`, `SubagentStop`, `Stop`,
`SessionEnd`. Unknown events are ignored, so new hook types do not break it.
`PermissionRequest` is not used, so agentmap.nvim never approves anything. It denies a tool call
only to deliver a steering instruction you wrote (`steer.enabled = false` removes that hook), and
it holds a tool call or an agent's end only while you pause it (`pause.enabled = false` removes that).

Notes for 2.1.288: sub-agents cannot use TaskCreate, so they use the `## Steps` convention.
A denied tool call reaches the model as `PreToolUse:<Tool> hook error: <reason>`. The main agent
may not follow instructions delivered through hooks, depending on the model.

The record format is versioned (`_v`). Records written by older versions stay readable.

## Status and roadmap

v0.1.0 is the first public release of a tool I built for my own work; v0.1.1 adds progress,
the light and steering; v0.1.2 adds pausing and the gate. I answer issues a few times a week, without promises.

Planned:

- **Codex** support (the provider layer is ready; only Claude Code is implemented)
- **Custom markers** for the writing convention (`brief.markers`, reserved now)
- Automatic cleanup of old records
- Windows-native Neovim: leave experimental after fixes
- Per-step typical times improve as records accumulate (v0.1.1 starts recording them)

Bug reports are most useful with `:checkhealth agentmap` output and a few lines of `hooks.jsonl`
(check them for anything private first). See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
