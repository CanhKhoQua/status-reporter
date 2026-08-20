---
description: Load a channel's webhook key into Keychain without it ever touching the chat
---

Store the webhook key for a destination. Argument: the destination name as it
appears in `sr status`, e.g. `/status-reporter:key showroom`. If none was given,
run `sr status` and ask which destination.

Finding `sr`: try `command -v sr`; if that fails use `${CLAUDE_PLUGIN_ROOT}/bin/sr`.

## The one rule

**Never ask them to paste the webhook URL into the chat, and never run a command
that contains it.** The URL is a credential with the signature in its query
string. In the chat it is exposed to the model and it stays in the transcript
after the conversation ends.

What you **may** do is run `sr set-secret <dest>` yourself. That command carries
no URL: it reads the clipboard with `pbpaste`, validates it, and writes it
straight to Keychain. The validator prints only a character count, never the
value. So the credential goes clipboard → Keychain and never enters the
transcript.

If they offer to paste the URL, decline and explain why in one sentence, then
point them back at the copy button.

## 1. Have them copy it

Wait here until they confirm it is on the clipboard:

1. Power Automate → the flow that receives this channel's webhook
2. Trigger *"When a Teams webhook request is received"* → the **HTTP URL** field
3. Press the **copy button** next to the field

Insist on the button. Selecting the URL with the mouse cuts it off at
`?api-version=…&sig=…`, and a truncated URL is answered with HTTP 400 later,
far from the cause. `sr set-secret` catches that up front: it rejects anything
missing `api-version=` or `sig=`, or shorter than 200 characters.

## 2. Store it

`sr set-secret <dest>`

Only `keychain:` handles are supported; the command refuses anything else. It
overwrites an existing item, so this is also how a rotated key is replaced.

On rejection, do not retry blindly — the message names what was wrong. A short
character count means the copy button was not used.

## 3. Confirm

`sr status` must show `key found` for that destination. Then `sr test <dest>`,
and ask whether the *"🧪 Test message"* card **appeared in the channel** — never
infer delivery from the exit code, because `HTTP 202` only means Power Automate
accepted the request.
