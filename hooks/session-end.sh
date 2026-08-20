#!/usr/bin/env bash
# End of session: gather unreported commits → build report.json → hand it to the
# destinations configured for this repo.
#
# This file does NOT know what Teams is. It stops at report.json; building the
# payload and sending it belong to lib/adapters/<type>.sh.
#
# Exit quietly whenever anything is uncertain — but always LOG the reason, so
# "why was there no message?" always has an answer.
set -uo pipefail

# Recursion guard: `claude -p` inside sr_summarize is itself a Claude Code
# session, and ending it fires this same hook.
[ "${STATUS_REPORTER_SKIP:-}" = "1" ] && exit 0

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
export SR_LIB_DIR
# shellcheck source=lib/core.sh
. "$SR_LIB_DIR/core.sh"

MAX_LINES=15

# A missing jq breaks everything, and without this check every step below just
# exits quietly — the user sees "no message" and has no way to find out why.
if ! command -v "$SR_JQ" >/dev/null 2>&1; then
  sr_log_raw "jq not found — run: sr doctor"
  exit 0
fi

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | "$SR_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

repo_path="$(sr_realpath "$cwd")"
repo_name="$(basename "$repo_path")"

# A repo with no rule in the config goes nowhere. Default DENY: staying quiet
# beats posting another project's work into a company channel.
dests="$(sr_dests_for_repo "$repo_path" session_end)"
[ -n "$dests" ] || exit 0

head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0
marker="$(sr_marker_file "$repo_path")"
mkdir -p "$(dirname "$marker")" 2>/dev/null || exit 0

# First run in this repo: set the marker and stop. "Never reported" at this
# point means the entire history of the repo, and nobody wants to read that.
if [ ! -f "$marker" ]; then
  printf '%s\n' "$head_sha" > "$marker"
  sr_log_event "$repo_name" "-" "skipped" "first run in this repo, marker set only"
  exit 0
fi

read -r last_sha < "$marker"
if [ "$last_sha" = "$head_sha" ]; then
  sr_log_event "$repo_name" "-" "skipped" "no new commits"
  exit 0
fi

commits="$(sr_unreported_commits "$last_sha")"
if [ -z "$commits" ]; then
  # HEAD moved but there are no new commits (checkout, reset). Move the marker
  # along so the next run does not re-scan.
  printf '%s\n' "$head_sha" > "$marker"
  sr_log_event "$repo_name" "-" "skipped" "HEAD moved but no new commits"
  exit 0
fi

clean="$(printf '%s\n' "$commits" | sr_clean_subject)"
summary="$(sr_summarize "$clean")"
# claude failed or timed out → fall back to the raw commit list. Rough beats
# missing.
[ -n "$summary" ] || summary="$clean"

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
report="$(sr_build_report session_end "$repo_name" "$repo_path" "$branch" "$summary" "$clean")"
[ -n "$report" ] || exit 0

# The marker moves ONLY when at least one destination accepted. Moving it first
# would lose these commits outright if every destination rejected them.
any_ok=0
while IFS= read -r dest; do
  [ -n "$dest" ] || continue
  sr_deliver "$dest" "$report" && any_ok=1
done <<< "$dests"

[ "$any_ok" = "1" ] && printf '%s\n' "$head_sha" > "$marker"
exit 0
