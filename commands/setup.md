---
description: Set up status-reporter from scratch — config, channel key, checks, and a test message
---

Walk the user through installing `status-reporter` until it actually works. Go in
order, and **stop and wait** at every step that needs them to do something.

Finding `sr`: try `command -v sr`; if that fails use `${CLAUDE_PLUGIN_ROOT}/bin/sr`.

## 1. Check the machine first

Run `sr doctor`. If `jq`, `git`, or `curl` is missing, stop and have them install
it. Do not continue.

## 2. Config

If `sr doctor` reports no config, run `sr init --repo <repo> --dest <name>`.

- `<repo>`: the git directory they want reported on. Guess it from the working
  directory, then **confirm with them**.
- `<name>`: a name for the channel that receives reports, e.g. `tnm-team`.

## 3. The channel key — DO NOT do this for them

**Never** ask them to paste the webhook URL into the chat, and never run a
command containing it yourself. The URL is a credential: in the chat it is
exposed to the model and it stays in the transcript.

Have them do it in a terminal:

1. Power Automate → open the flow that receives the channel's webhook
2. Trigger *"When a Teams webhook request is received"* → the **HTTP URL** field
3. Press the **copy button** next to it — selecting it with the mouse cuts off
   `?api-version=…&sig=…`, and the channel will answer HTTP 400
4. `sr set-secret <name>`

Then run `sr doctor` and confirm it says `key found`.

## 4. Send a test

`sr test <name>`. The card is labelled *"🧪 Test message"*. Ask them whether they
**see it in the channel** — do not infer it from the exit code.

If `sr test` succeeds but the channel is empty, the problem is in the flow, not
in this tool. `HTTP 202` only means Power Automate **accepted** the request, not
that it **posted**. Take the `run=…` value from `sr history` and have them look
it up in the flow's Run history.

## 5. Say these two things — required

Both misunderstandings are guaranteed if you skip them:

- The hook loads on the **next Claude Code session**, not the one open now.
- The first session in each repo **only sets a marker and sends nothing**. The
  first real message arrives from the second session onwards.

Close with: if the channel stays quiet, run `sr history` — every skip logs its
reason.
