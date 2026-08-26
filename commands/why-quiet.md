---
description: The channel is silent — find out which of the quiet exits was taken
---

Every failure path in this tool ends in silence, so "no message" is the symptom
for a dozen different causes. Work down this list in order; do not guess.

**First, the obvious one:** nothing sends by itself. The hook only asks; a report
goes out when someone runs `sr send`. "The channel is quiet" may simply mean
nobody said yes. `sr send` right now settles it.

Finding `sr`: try `command -v sr`; if that fails use `${CLAUDE_PLUGIN_ROOT}/bin/sr`.

## 1. Collect the evidence first

Run all three before drawing any conclusion:

- `sr doctor` — tools, config validity, whether the hook is installed
- `sr status` — which repo routes to which destination, key present, marker set
- `sr history 25` — what actually happened, with reasons

## 2. The two non-faults — check these before debugging anything

Both look exactly like a broken install:

- **The hook loads on the next Claude Code session.** It is read at startup, so
  a session that was already open when the plugin was installed never fires it.
- **The first report in a repo sets a marker and sends nothing.** By design:
  "never reported" would otherwise mean the repo's entire history. `sr status`
  shows `no marker` until that has happened.
- **The nudge waits for the work to settle.** It says nothing until the newest
  unreported commit has sat still for `ask_after_minutes` (default 30). Commit
  and keep working, and it will not ask at all — that is deliberate. It also
  asks only once per HEAD: answer no, and it stays quiet until the next commit.
  `sr send` ignores all of this and reports on demand.

If either applies, nothing is wrong. Say so plainly and stop.

## 3. Skips that DO leave a log line

`sr history` names these outright:

| Log line | Meaning |
|---|---|
| `first run in this repo, marker set only` | Non-fault, see above |
| `no new commits` | Nothing was committed since the last report |
| `HEAD moved but no new commits` | Rebase, amend, or branch switch — no new work |
| `jq not found — run: sr doctor` | Install `jq`; nothing can work without it |

## 4. Silent exits that leave NO log line at all

This is where a genuinely broken setup hides. `sr history` shows **nothing** for
any of these, so the absence of a log line is evidence, not reassurance:

- **The repo has no rule.** Default is DENY — an unlisted repo goes nowhere.
  Confirm the repo appears under `ENABLED REPOS` in `sr status`.
- **The rule's path does not match.** The hook resolves the working directory
  with `cd && pwd -P`, then compares it literally against the rule's `repo`
  (only a leading `~` is expanded). A relative path, a trailing slash, or a
  symlinked path matches nothing. Verify:
  `cd <repo> && pwd -P` and diff it against `jq -r '.rules[].repo' config.json`.
- **The repo has no commits yet.** `git rev-parse HEAD` fails in a fresh
  `git init`, so the hook exits before it even sets a marker. Check with
  `git rev-parse HEAD`. The repo needs one commit before the marker clock
  starts — only then does the next session set the marker.
- **The destination has no key.** `sr status` prints `NO KEY`. Fix with
  `/status-reporter:key <dest>`.
- **`STATUS_REPORTER_SKIP=1` is set** — the recursion guard. Check the
  environment.
- **The session had no `cwd`, or it was not a git directory.**

## 5. Sent, but the channel is still empty

If `sr history` shows `→` and `HTTP 202 accepted (delivery not confirmed)`, this
tool did its job and the fault is in the flow. `202` means Power Automate
**accepted** the request, not that it **posted** it.

Take the `run=…` value from the log line and have them open it in the flow's Run
history in Power Automate. A retired MessageCard / O365 connector payload is the
usual culprit: it answers 202 and posts nothing.

## 6. Report honestly

Name the specific exit that was taken and the evidence for it. If the evidence
does not single one out, say which ones remain rather than picking the likeliest
and presenting it as the answer.
