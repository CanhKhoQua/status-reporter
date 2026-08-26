# status-reporter

When the work has settled, Claude asks whether to report it. Say yes and the
commits that have not been reported yet are collected, summarised in a few plain
sentences, and posted as **one** message to a chat channel.

Nothing is ever sent on its own. The question arrives once per new commit;
`sr send` does the same thing whenever you want it.

The point: a manager can see what is being worked on without reading a git log,
and without getting thirty messages a day.

## What it is not

This is not a deployment notification. The message describes code on a
developer's machine — possibly unpushed, certainly not merged, definitely not in
production. Every card carries
`⚠️ Work in progress — not yet deployed to production.` Do not remove that line.

## First-time setup

Inside Claude Code, one command:

```
/status-reporter:setup
```

Three more, for after the first install:

```
/status-reporter:add-project   # one more repo, with its own channel
/status-reporter:key <dest>    # load or rotate a channel key
/status-reporter:why-quiet     # the channel is silent — find out which exit was taken
```

It runs `sr doctor`, builds the config, walks you through loading the channel
key, sends a test, and tells you about the two easy misunderstandings below.

By hand:

```bash
cd <repo to report on>
sr init                  # detects the git repo here, asks for a destination name
# copy the webhook URL to the clipboard
sr set-secret <dest>     # validates it, then stores it in the Keychain
sr doctor                # must print "No problems found."
sr test <dest>
```

`sr init` never asks you to hand-edit JSON, and it **refuses** a channel type with
no adapter — a typo there is the hardest-to-trace cause of "it silently sends
nothing".

## Two easy misunderstandings

Stated up front, because they cost new users the most time:

1. **The hook loads on the NEXT Claude Code session**, not the one open now.
2. **The first report in each repo only sets a marker and sends nothing.** Until
   there is a marker, "unreported" means the entire history of the repo.

Both are deliberate. `sr test` reprints them after every successful send. If the
channel stays quiet, run `/status-reporter:why-quiet`. Note that `sr history`
does **not** explain everything: a skipped report logs its reason, but a repo
with no matching rule, no commits yet, or a missing key exits without writing a
log line at all.

## Architecture

```
  Collect                  Route                 Adapters
  core.sh: sr_report_repo  core.sh               lib/adapters/
┌──────────────────┐    ┌──────────────┐    ┌──────────────┐
│ git log since    │    │ which repo → │    │ teams.sh     │
│ marker           │───▶│ which dest   │───▶│ (slack.sh)   │
│ → summarise      │    │ + logging    │    │ (discord.sh) │
│ → report.json    │    └──────────────┘    └──────────────┘
└──────────────────┘
```

The boundary is **`report.json`**, a channel-neutral document:

```json
{ "event": "session_end", "repo": "tnm-dms", "branch": "main",
  "commits": ["fix the login rate limit", "add missing indexes"], "count": 2,
  "summary": "Worked on the login rate limit…",
  "state": "work_in_progress", "at": "2026-08-19T21:14:00+0700" }
```

The collector stops there; it does not know what an Adaptive Card is. **Adding a
channel means adding one file in `lib/adapters/`** and changing nothing else. A
test builds a fake adapter to prove exactly that.

Adapter contract:

| | |
|---|---|
| stdin | `report.json` |
| `$1` | the destination's secret |
| exit 0 | delivered |
| stdout | *(optional)* one line of detail → goes into the log |
| `--validate <secret>` | *(optional)* does this secret look right for this channel? |

`--validate` is what lets `sr set-secret` catch a truncated URL **before** storing
it, instead of letting you discover it minutes later through a baffling HTTP 400.

## Config

`~/.config/status-reporter/config.json`:

```json
{
  "destinations": {
    "tnm-team": { "type": "teams", "secret": "keychain:tnm-team" }
  },
  "rules": [
    { "repo": "~/path/to/repo", "on": "session_end", "to": ["tnm-team"] }
  ]
}
```

A repo with **no rule** goes nowhere. The default is deny: staying quiet beats
posting another project's work into a company channel.

## Secrets

`secret` is a **handle, never a value**:

| Handle | Source |
|---|---|
| `keychain:name` | macOS Keychain, service `status-reporter`, account `name` |
| `env:VAR_NAME` | environment variable (for CI and tests) |

That is what makes `config.json` an ordinary file: commit it, share it, paste it
in chat — nothing leaks.

**Three invariants**, enforced by the code rather than promised by its author:

1. a secret value never reaches stdout or stderr
2. it never reaches the log
3. errors name the HTTP code and the destination, never the URL

Five tests guard them.

### Use a dedicated webhook

Do not reuse the credential your production app posts with. Create a second
Power Automate flow into the same channel: it can be revoked independently, you
can tell which system posted what, and a leak only costs you one channel's
posting rights.

The URL is a **Power Automate Workflow** trigger of type *"When a Teams webhook
request is received"*. The legacy Office 365 Connector / MessageCard format is
retired — send that and you get a 202 followed by nothing.

## Control panel

```bash
sr doctor          # check preconditions — run this FIRST when it goes quiet
sr status          # destinations, enabled repos, 7-day counts
sr history [n]     # last n log lines
sr test <dest>     # send a test message, clearly labelled as one
sr set-secret <d>  # load a secret from the clipboard, validated first
sr init            # create the config
```

The log exists to answer the question that gets asked most: *"why was there no
message today?"*. The tool exits quietly in several places, and each one records
why.

There is deliberately **no web dashboard**. For a single-user tool on a laptop it
would need a server, auth, and uptime, in exchange for something one command
already does. A web UI earns its keep only when several people need to view and
configure it.

## Requirements

`jq`, `git`, `curl`. `claude` is optional — without it the message is a raw commit
list instead of a summary.

jq's path is **not** hardcoded; the tool resolves it through `PATH`. macOS 15 is
the first to ship `/usr/bin/jq`; older macs and Linux put it elsewhere, and a
hardcoded path means silent breakage — nothing sent, nothing said. If jq really
is missing, the hook **writes to the log** instead of exiting quietly.

Run `sr doctor` to see what a machine is missing.

### macOS only, for now

`keychain:` needs `security`, and `sr set-secret` needs `pbpaste` — both are
macOS. On Linux/WSL only `env:` handles work today. `sr doctor` says so plainly
rather than failing halfway.

Full support needs a pluggable secret backend (`pass:`, `file:`) following the
same shape as the channel adapters. Not built yet: no real user has needed it.

## Install

```
/plugin marketplace add <owner>/status-reporter
/plugin install status-reporter@status-reporter
```

or from a terminal:

```bash
claude plugin marketplace add <owner>/status-reporter
claude plugin install status-reporter@status-reporter
```

For the `sr` command, add a wrapper that resolves the installed copy rather than
symlinking a versioned path — the version directory changes on every update, and
a stale symlink would run different code than the hook:

```bash
cat > ~/.local/bin/sr <<'EOF'
#!/usr/bin/env bash
P="$(jq -r '.plugins["status-reporter@status-reporter"][0].installPath // empty' \
      "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null)"
[ -n "$P" ] && [ -x "$P/bin/sr" ] || { echo "status-reporter is not installed" >&2; exit 1; }
exec "$P/bin/sr" "$@"
EOF
chmod +x ~/.local/bin/sr
```

### Developing on it

Symlink the checkout into the skills directory instead, and Claude Code
auto-loads it every session as `status-reporter@skills-dir`. Edits then take
effect on the next session — no install step, no `plugin update`, no commit.

```bash
claude plugin uninstall status-reporter@status-reporter
ln -s ~/Developer/status-reporter ~/.claude/skills/status-reporter
```

**Never do both.** Two copies loaded means the hook fires twice and the channel
gets two identical messages per session. `sr doctor` reports this as an error.

### Releasing

```bash
# bump "version" in BOTH .claude-plugin/plugin.json and marketplace.json
git commit -am "..." && git push
claude plugin tag --push          # validates that the two versions agree
claude plugin update status-reporter@status-reporter
```

Because the installed copy is pinned to a commit, edits in your checkout do
nothing until you push and run `plugin update`. That is the trade for having real
versions and a one-command install.

## How it works

One hook, `UserPromptSubmit`, and one command, `sr send`. The hook **cannot
send** — it prints a single line into Claude's context saying how many commits
are waiting, and Claude asks you. Sending happens only after you say yes.

The hook stays quiet until all three are true: the repo has a rule, it has
commits past its marker, and the newest of them has sat still for
`ask_after_minutes` (default 30, override with `SR_ASK_AFTER_MIN`). A commit
from a minute ago belongs to the session still running; asking then interrupts
the work that is producing the commits. Once asked about a given HEAD it stays
quiet until there are new commits — whatever the answer was.

### Why not SessionEnd

The first version sent by itself when a session ended. Two problems, both real:
it fired only on a tidy exit, which never happens in the VSCode extension (two
days and twelve commits produced not one log line, 2026-08-25), and when it did
fire it posted to a channel full of managers without anyone asking for it. A
tool that writes to other people should write when a person says so.

"How far have we reported" is remembered **per repo**, not per session, in
`~/.local/state/status-reporter/markers/<hash>`. A killed session, a crashed
machine, or installing the tool halfway through a day therefore loses no commits.

### Four things that are easy to get wrong

**Recursion.** `claude -p` is itself a Claude Code session, and its prompt fires
this same `UserPromptSubmit` hook. Guarded by `STATUS_REPORTER_SKIP=1`, set when
invoking it; both the hook and `sr_report_repo` exit if they see the flag.
Without it the summariser gets the nag pasted into its own input.

**The marker moves only on success.** Moving it before sending would lose those
commits outright if the channel rejected the payload.

**Branch switches.** Use `git log HEAD --not <marker>`, not an `a..b` range: the
former stays correct when the marker is no longer an ancestor of HEAD (checkout,
rebase). `--since=7 days` keeps a checkout of an old branch from dumping last
month's history into the channel.

**curl does not treat 4xx/5xx as an error.** Check the code yourself or total
failure is completely invisible.

**202 is not 200.** Power Automate returns 202 the moment it *accepts* the
request and only then runs the flow asynchronously — the "Post card" action can
fail afterwards and the webhook never hears about it. The log records
`HTTP 202 accepted (delivery not confirmed)` together with the
`x-ms-workflow-run-id` for lookup, rather than claiming "sent" for something only
known to be "received".

## Known limits

A tool running on a laptop has a ceiling on assurance: any process running as the
same user can read that Keychain item. If this reporting ever becomes team
infrastructure, the right answer is to move it **server-side** — CI/CD posts, the
secret lives in GitHub Actions secrets or a vault, and no copy sits on a personal
machine.

## Tests

```bash
bash tests/run-tests.sh
```

Nothing touches the network, the chat channel, or the real Keychain: the adapter
writes its payload to a file instead of calling `curl`, `claude` is a stub, and
secrets come from `env:` handles.

## Licence

MIT
