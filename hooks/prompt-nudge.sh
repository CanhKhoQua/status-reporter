#!/usr/bin/env bash
# UserPromptSubmit: decide whether it is time to ASK about unreported commits.
#
# This hook CANNOT send. It prints at most one line, and that line lands in
# Claude's context — so the question reaches a person, and a person decides.
#
# It replaced a SessionEnd hook that sent by itself. That hook fired only on a
# tidy exit, which does not happen in the VSCode extension: two days and twelve
# commits produced not one log line. Worse, when it did fire it posted to a
# channel full of managers without anyone asking for it.
set -uo pipefail

# `claude -p` inside sr_summarize is itself a Claude Code session and its prompt
# fires this hook. Without the guard, the nag gets pasted into the summary.
[ "${STATUS_REPORTER_SKIP:-}" = "1" ] && exit 0

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)" || exit 0
export SR_LIB_DIR
# shellcheck source=lib/core.sh
. "$SR_LIB_DIR/core.sh"

# Every exit below is silent. This runs on EVERY prompt, so a hook that
# complained would be a hook that shouts all day. `sr doctor` is where an
# install gets diagnosed.
command -v "$SR_JQ" >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | "$SR_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0

repo_path="$(sr_realpath "$cwd")"
[ -n "$repo_path" ] || exit 0
( cd "$repo_path" && git rev-parse --git-dir >/dev/null 2>&1 ) || exit 0

# Same default DENY as everywhere else: a repo with no rule is none of our
# business, and asking about it would be the first step to posting it.
dests="$(sr_dests_for_repo "$repo_path" session_end)"
[ -n "$dests" ] || exit 0

count="$(sr_pending_count "$repo_path")"
[ "$count" -gt 0 ] || exit 0

# Wait for the work to settle. A commit from a minute ago belongs to the session
# still running; interrupting it to ask about a report helps nobody.
age="$(sr_head_age_min "$repo_path")" || exit 0
[ "$age" -ge "$(sr_ask_after_min)" ] || exit 0

head_sha="$( cd "$repo_path" && git rev-parse HEAD 2>/dev/null )"
[ -n "$head_sha" ] || exit 0

# Asked once about this HEAD, then quiet. Whether the answer was yes or no, the
# question has been put — repeating it every message is how a tool gets turned
# off.
nudge="$(sr_nudge_file "$repo_path")"
if [ -f "$nudge" ]; then
  read -r asked_sha < "$nudge"
  [ "$asked_sha" = "$head_sha" ] && exit 0
fi
mkdir -p "$(dirname "$nudge")" 2>/dev/null || exit 0
printf '%s\n' "$head_sha" > "$nudge"

printf '[status-reporter] %s commit(s) in %s have not been reported to %s; the newest is %s minutes old. Ask the user whether to send the report now, and run `sr send` only if they say yes. Never send without asking. If they decline, drop it — this will not be raised again until there are new commits.\n' \
  "$count" "$(basename "$repo_path")" "$(printf '%s' "$dests" | tr '\n' ' ' | sed 's/ *$//')" "$age"
exit 0
