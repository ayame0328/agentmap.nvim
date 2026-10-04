# Writing convention

agentmap.nvim shows *why* an agent was started, *what it reported* and *what it asked you*.
It does not guess: it reads a few fixed markers that you ask Claude to write. Anything that is
not written this way is shown as `(not written)`.

The convention has four parts:

1. The parent's prompt to a sub-agent starts with three lines: `[Goal]`, `[Why delegate]`, `[Done when]`.
2. The sub-agent ends with a `## Report` (or, when it needs you, a `## Needs confirmation`).
3. When Claude asks you a question (AskUserQuestion) because of a sub-agent, the question names that
   sub-agent and each option says what happens next (`-> if chosen: ...`).
4. The sub-agent writes a `## Steps` list first and `Step N done` after each step; this is the fact
   behind the progress shown in its box (the main agent uses TaskCreate / TaskUpdate instead).

English and Japanese markers are both accepted, always, in any mix
(Japanese: see [writing-convention.ja.md](writing-convention.ja.md)).

## Paste this into your CLAUDE.md

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

## Rules the parser follows

These rules are implemented twice with the same behaviour: in Lua (`lua/agentmap/brief.lua`, used for display
and for importing transcripts) and in Python (`bin/agentmap-collect`, used while recording hooks). The test
fixture `tests/fixtures/convention_cases.jsonl` is run through both.

### Parent prompt

| Field | English marker | Japanese marker |
|---|---|---|
| purpose | `[Goal]` | `【目的】` |
| reason | `[Why delegate]` | `【任せる理由】` |
| expected | `[Done when]` | `【期待する結果】` |

- English markers are case-insensitive (`[goal]`, `[DONE WHEN]` work).
- A marker may appear anywhere in the prompt. If a field appears more than once, the first
  occurrence (of either language) wins.
- The value runs from the marker to the next newline, the next `【`, or the next English marker,
  whichever comes first. So all three may also be written on one line.
- A `:` or `：` directly after the marker is dropped; surrounding whitespace is trimmed.
- Each value is clipped to 300 characters.
- If none of the three is written (or all are empty), the prompt has no brief.

### Child report

| | English | Japanese |
|---|---|---|
| Report heading | `## Report` | `## 報告` |
| Items | `Done` / `Approach` / `Why` / `Open issues` | `やったこと` / `方向` / `理由` / `残った課題` |
| Needs-confirmation heading | `## Needs confirmation` | `## 要確認` |
| Items | `Working on` / `Blocked at` / `Question` / `Options` | `今の作業` / `止まっている所` / `確認したいこと` / `選択肢` |

- Heading: two or three `#`, the word, then end of line, a space, `(` / `（` or `:` / `：`.
  `## Reports`, `## Reporting`, `# Report` and `#### Report` are not headings.
- Item: optional `-`, `*` or `・`, optional `**bold**`, the name, then `:` or `：`.
  `Done when:` is not `Done:`.
- English headings and item names are case-insensitive. Item names of either language are accepted
  under either heading.
- An item's text continues on the following lines until the next item; two blank lines end the section.
- If both headings appear, the later one wins.
- Options: `1. Name -> next`, `1. Name → next`, `1) Name -> next`, or full-width `１．`. The part after the
  arrow is the next step (optional).

### Step list (progress)

Read only by Lua, from the agent's own transcript (only the text blocks of assistant messages;
tool calls, tool results and user lines are not read). The main agent's TaskCreate / TaskUpdate are
recorded by the hooks instead; when an agent has both, the tool list wins.

| | English | Japanese |
|---|---|---|
| Heading | `## Steps` | `## 手順` |
| Item | `1. text` | `1. 本文` |
| Step finished | `Step 2 done` | `手順 2 完了` |
| Step started (optional) | `Step 3 start` | `手順 3 開始` |

- Heading: `##` or `###`, then the word (English case-insensitive); a following `:`, `：`, `(` or `（`
  is allowed.
- Items: optional leading spaces, a number of one or two digits, then `. `, `)` or `．`, then the text.
  Numbers start at 1 and go up by 1; a list whose numbers skip, or that has more than 20 items, is
  ignored. A blank line ends the list. Each item is clipped to 60 characters.
- Marks: at the start of a line (after an optional `- `, `* `, `・` or `**`), the word, the number,
  then `done` / `完了` (or `start` / `開始`). Case-insensitive.
- When a list appears again, the later list wins (re-planning is allowed); marks are kept by
  number, and marks beyond the new list's length are dropped. Marks before the first list are ignored.
- Without a start mark, a step is taken to start when the previous one was marked done.

### Human check (AskUserQuestion)

- Option description: `body -> if chosen: next` or `body → 選んだら: next`. Both arrows work with both
  words (`→ if chosen:`, `-> 選んだら:`); `if chosen` is case-insensitive. An arrow that is not followed by
  the word belongs to the body.
- The question is linked to the sub-agent whose description it contains (language independent).
  For display, a leading `<description>: ` / `<description>について：` is removed.

## What is stored

The recorder stores only the parsed brief (`purpose`, `reason`, `expected`), the first 200 characters of the
prompt and the child's report text (up to 2000 characters, secrets redacted). Full prompts are not stored.
Step text is kept up to 60 characters per step; the `description` of TaskCreate is not stored.
