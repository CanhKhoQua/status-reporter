---
description: Add a repo and its own channel — destination, rule, key, and the two things that go wrong
---

Add one more reported repo to `status-reporter`. Most projects want **their own
channel**, not a shared one: `sr_dests_for_repo` matches a rule by absolute repo
path and returns only that rule's `to`, so isolation is the design, not a
workaround. Go in order and **stop and wait** where it says to.

Finding `sr`: try `command -v sr`; if that fails use `${CLAUDE_PLUGIN_ROOT}/bin/sr`.

## 1. Which repo

Guess it from the working directory, then **confirm with them** — never assume.
Run `git rev-parse --show-toplevel` in it.

If it is **not a git repository**, stop. This tool reports commits, so a non-git
directory can never produce a report. Offer `git init` and wait for an answer;
do not run it unasked. An empty directory is worth mentioning too — there is
nothing to report yet, only a marker to set.

## 2. Which channel

Ask whether this repo posts to an **existing** destination or a **new** one.
Default to a new one and say why: a rule sends this repo's commits to every
destination it lists, and a shared channel means one project's work shows up in
another team's feed.

For a new destination, agree on a short name — it is what they will type in
`sr set-secret <name>`, so keep it the repo's name.

## 3. Edit the config

Back it up first: `cp config.json config.json.bak`. Find the path with
`sr doctor`.

Add the destination and the rule with `jq`, never by hand:

```
jq --arg repo "<absolute-path>" \
  '.destinations["<name>"] = {type: "teams", secret: "keychain:<name>"}
   | .rules += [{repo: $repo, on: "session_end", to: ["<name>"]}]' \
  config.json > config.json.tmp && mv config.json.tmp config.json
```

`repo` may start with `~` — the resolver expands it. Anything else must be
absolute: a relative path matches nothing and fails silently.

Then run `sr status` and check the new repo shows `→ <name>`.

## 4. The channel key — DO NOT ask for the URL

**Never** ask them to paste the webhook URL into the chat. It is a credential:
in the chat it is exposed to the model and it stays in the transcript forever.

You may run `sr set-secret <name>` yourself — that command contains no URL, it
reads the clipboard via `pbpaste` and stores it in Keychain. Have them copy it
first:

1. Power Automate → the flow that receives the new channel's webhook
2. Trigger *"When a Teams webhook request is received"* → the **HTTP URL** field
3. Press the **copy button** — selecting it with the mouse cuts off
   `?api-version=…&sig=…`, and the channel answers HTTP 400

`sr status` must then show `key found` for the new destination.

## 5. Test, then ask what they SEE

`sr test <name>`. Ask whether the *"🧪 Test message"* card **appeared in the
channel** — do not infer it from the exit code. `HTTP 202` means Power Automate
**accepted** the request, not that it **posted**. If the channel is empty the
fault is in the flow: take `run=…` from `sr history` and have them look it up in
the flow's Run history.

## 6. Say these two things — required

- The hook loads on the **next Claude Code session**, not the one open now.
- The first session in this repo **only sets a marker and sends nothing**. The
  first real message arrives from the second session onwards. `sr status` shows
  it as `no marker` until then.

Close with: if the channel stays quiet, run `/status-reporter:why-quiet`.
