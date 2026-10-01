# Review rubric

version: 1

This rubric is used when you review the work of a delegated agent (the `a` key in the map,
or `:AgentMapReview`). The verdict is always yours. A verdict provider registered with
`require("agentmap.review").register(...)` may *propose* a verdict; it never decides.

To use your own rubric, point `setup({ review = { rubric = "/path/to/RUBRIC.md" } })` at it.
Raise the `version:` number whenever you change the questions, so that old and new
judgments can be told apart in the log.

## The five questions

Answer each question with yes / no / unsure before choosing a verdict.

1. **Goal** — Did the agent do what the prompt asked for (the `[Goal]` line), and not something else?
2. **Done when** — Is the result that the prompt expected (the `[Done when]` line) actually there?
   Check the files or the output, not only the report.
3. **Report** — Does the report say what was done, the approach, why, and what is left
   (`## Report` with `Done:` `Approach:` `Why:` `Open issues:`), and does it match the changes?
4. **Scope** — Did the agent stay inside its task? No unrelated files changed, nothing deleted
   or overwritten that it was not asked to touch.
5. **Open questions** — Did the agent stop and ask (`## Needs confirmation`) where a decision
   was needed, instead of guessing?

## The three verdicts

| Verdict | When | What happens next |
|---|---|---|
| `PASS` | All five questions are "yes" (or "unsure" on something that does not matter for the next step). | The work moves on to the next stage. |
| `RETRY` | The task was right but the result is wrong or incomplete, and the same agent can fix it with a clearer instruction. | The same task is run again (record which agent redoes it with "This agent reruns [n]"). |
| `ESCALATE` | The agent cannot fix it alone: the task itself was unclear, a decision is needed from the parent or from you, or it went out of scope. | The question goes up to the parent agent (or to you). |

Write a one-line reason with every verdict. The reason is what makes the log useful later.

## Which mistake costs more

Two mistakes are possible, and they do not cost the same:

- **Passing bad work** (a `PASS` that should have been `RETRY` or `ESCALATE`) is usually the
  expensive one. The next stages build on it, and the problem is found late, if at all.
- **Sending good work back** (a `RETRY` that should have been `PASS`) costs one more run.

When you are unsure, prefer `RETRY` or `ESCALATE` over `PASS`. If you later find that a verdict
was wrong, do not edit the log; record a new review instead.

## Log line format

Every verdict is appended as one JSON object per line to `<record store>/review_log.jsonl`:

```json
{"v":1,"ts":"2026-10-01T12:34:56Z","run_id":"<session id>","agent_id":"<agent id>","attempt":1,"rubric_version":1,"provider":"manual","proposed":null,"proposed_reason":null,"final":"RETRY","decided_by":"user","reason":"tests were not run","agreed":null}
```

| Field | Meaning |
|---|---|
| `v` | Format version of the log line (1). |
| `ts` | When the verdict was recorded (UTC). |
| `run_id`, `agent_id`, `attempt` | Which agent and which attempt was reviewed. |
| `rubric_version` | The `version:` of this file at the time. |
| `provider` | Who proposed a verdict (`manual` when nobody did). |
| `proposed`, `proposed_reason` | The provider's proposal, or `null`. |
| `final`, `decided_by`, `reason` | Your verdict, who decided (`user`), and why. |
| `agreed` | `true` / `false` when there was a proposal and it matched / did not match your verdict; `null` otherwise. |
| `answers` | Optional answers to the five questions, when a provider supplies them. |
