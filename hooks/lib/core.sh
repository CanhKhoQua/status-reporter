#!/usr/bin/env bash
# Core layer: config, secrets, routing, logging.
#
# NOTHING here knows what Teams is. Payload construction lives in
# lib/adapters/<type>.sh — adding a channel means adding one file there, never
# touching this one.
#
# INVARIANT: a secret value never reaches stdout/stderr, never reaches the log,
# never appears in an error message. Errors name the HTTP code and the
# destination, never the URL. This is a property of the code, not a promise from
# whoever wrote it.

# Never hardcode jq's path. macOS 15 is the first to ship /usr/bin/jq; older
# macs and Linux put it elsewhere. A hardcoded path means the tool breaks
# silently on another machine — nothing sent, nothing said.
SR_JQ="${SR_JQ:-$(command -v jq 2>/dev/null || printf '/usr/bin/jq')}"
export SR_JQ

# shasum exists on macOS and most Linux distros, but not everywhere; sha1sum is
# the common Linux spelling.
SR_SHA="${SR_SHA:-$(command -v shasum 2>/dev/null || command -v sha1sum 2>/dev/null || printf 'shasum')}"
export SR_SHA

# Timestamps are pinned to one timezone on purpose. When the developer and the
# readers live in different zones, a machine-local clock puts the wrong date on
# the report. Override with SR_TZ.
SR_TZ="${SR_TZ:-Asia/Ho_Chi_Minh}"
export SR_TZ

sr_config_file() { printf '%s' "${SR_CONFIG:-$HOME/.config/status-reporter/config.json}"; }
sr_state_dir()   { printf '%s' "${SR_STATE_DIR:-$HOME/.local/state/status-reporter}"; }
sr_log_file()    { printf '%s' "$(sr_state_dir)/log.jsonl"; }

sr_config() {
  local f; f="$(sr_config_file)"
  [ -f "$f" ] || return 1
  "$SR_JQ" -e . "$f" 2>/dev/null
}

# Secrets are referenced by HANDLE and never stored in the config. That is what
# makes config.json an ordinary file: commit it, share it, paste it in chat —
# nothing leaks.
#
#   keychain:name  → macOS Keychain, service status-reporter, account <name>
#   env:VAR_NAME   → environment variable (for CI and tests)
sr_resolve_secret() {
  local handle="$1"
  case "$handle" in
    keychain:*)
      security find-generic-password -s status-reporter -a "${handle#keychain:}" -w 2>/dev/null
      ;;
    env:*)
      eval "printf '%s' \"\${${handle#env:}:-}\""
      ;;
    *) return 1 ;;
  esac
}

# Answers "is the secret there?" WITHOUT printing it. `sr status` and `sr doctor`
# need this, and it is the only way to ask without leaking.
sr_secret_present() {
  local v; v="$(sr_resolve_secret "$1")" || return 1
  [ -n "$v" ]
}

sr_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null; }

# Which destinations receive this repo's report. Rules match on absolute path,
# so a repo with no rule goes nowhere. The default is DENY: staying quiet beats
# posting another project's work into a company channel.
sr_dests_for_repo() {
  local repo="$1" event="$2" cfg
  cfg="$(sr_config)" || return 0
  printf '%s' "$cfg" | "$SR_JQ" -r --arg repo "$repo" --arg ev "$event" '
    (.rules // [])
    | map(select((.repo | sub("^~"; env.HOME)) == $repo and ((.on // "session_end") == $ev)))
    | map(.to // []) | flatten | unique | .[]'
}

sr_dest_field() {
  local name="$1" field="$2" cfg
  cfg="$(sr_config)" || return 1
  printf '%s' "$cfg" | "$SR_JQ" -r --arg n "$name" --arg f "$field" \
    '.destinations[$n][$f] // empty'
}

# "How far have we reported" is remembered PER REPO, not per session. A killed
# session, a crashed machine, or installing the tool halfway through a day
# therefore loses no commits.
sr_marker_file() {
  local key; key=$(printf '%s' "$1" | "$SR_SHA" | cut -c1-16)
  printf '%s/markers/%s' "$(sr_state_dir)" "$key"
}

# The log exists to answer the question that gets asked most: "why was there no
# message today?". Without it every silent exit looks identical.
sr_log() {
  local f; f="$(sr_log_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$f" 2>/dev/null || true
}

# Logging that does not need jq. Used for exactly one case: reporting that jq is
# missing. If this needed jq, that failure would be silent — the very thing we
# are trying to kill.
sr_log_raw() {
  local msg="$1" f; f="$(sr_log_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '{"at":"%s","repo":"?","dest":"-","status":"error","detail":"%s","count":0}\n' \
    "$(sr_iso_now)" "$msg" >> "$f" 2>/dev/null || true
}

sr_log_event() {
  local repo="$1" dest="$2" status="$3" detail="$4" count="${5:-0}"
  sr_log "$("$SR_JQ" -nc --arg at "$(sr_iso_now)" --arg repo "$repo" --arg dest "$dest" \
    --arg status "$status" --arg detail "$detail" --argjson count "$count" \
    '{at:$at, repo:$repo, dest:$dest, status:$status, detail:$detail, count:$count}')"
}

sr_iso_now() { TZ="$SR_TZ" date '+%Y-%m-%dT%H:%M:%S%z'; }
sr_local_time() { TZ="$SR_TZ" date '+%d %b %Y, %H:%M'; }

# Strip the conventional-commit prefix. "fix(auth):" means nothing to a manager;
# the part after the colon is the sentence written for a human.
sr_clean_subject() { sed -E 's/^[a-z]+(\([^)]*\))?!?: *//'; }

# Unreported commits: everything HEAD reaches that the marker does not.
#
# `--not <sha>` stays correct across branch switches and rebases — unlike an
# `a..b` range, it does not require the marker to be an ancestor of HEAD. The
# --since guard keeps a checkout of an old branch from dumping last month's
# history into the channel.
sr_unreported_commits() {
  local last="$1"
  [ -n "$last" ] && git cat-file -e "${last}^{commit}" 2>/dev/null || return 0
  git log --no-merges --format='%s' --since="7 days ago" HEAD --not "$last" 2>/dev/null
}

# STATUS_REPORTER_SKIP=1 is the recursion guard: `claude -p` below is itself a
# Claude Code session, and ending it fires this same hook. Without the guard the
# script forks copies of itself until someone kills the process tree.
sr_summarize() {
  local commits="$1" bin out
  bin="${SR_CLAUDE_BIN:-claude}"
  command -v "$bin" >/dev/null 2>&1 || return 0
  out=$(STATUS_REPORTER_SKIP=1 "$bin" -p --model haiku "$(cat <<PROMPT
Below are git commit subjects from one development session. Write 2-3 short
sentences in plain English describing what was worked on, for a non-technical
manager.

Rules:
- Describe ONLY what the commits state. Never infer impact, cause, or status.
- No jargon, no file names, no commit hashes.
- Do not claim anything is deployed, released, live, or verified.
- Plain sentences. No bullets, no headings, no preamble.

Commits:
$commits
PROMPT
)" 2>/dev/null) || return 0
  printf '%s' "$out" | tr -d '\r'
}

# The channel-neutral document. THIS is the boundary that makes the system
# extensible: adapters consume this JSON, not a bag of loose variables. Adding
# Slack means adding one file that reads exactly this.
sr_build_report() {
  local event="$1" repo_name="$2" repo_path="$3" branch="$4" summary="$5" commits="$6"
  "$SR_JQ" -n \
    --arg event "$event" --arg repo "$repo_name" --arg path "$repo_path" \
    --arg branch "$branch" --arg summary "$summary" --arg at "$(sr_iso_now)" \
    --arg when "$(sr_local_time)" --arg commits "$commits" '
    {
      event: $event, repo: $repo, repo_path: $path, branch: $branch,
      commits: ($commits | split("\n") | map(select(length > 0))),
      summary: $summary, at: $at, when: $when,
      state: "work_in_progress"
    } | .count = (.commits | length)'
}

# Deliver one report to one destination: look up the type, call its adapter, log
# the outcome. This function knows nothing about Teams, Slack, or any channel.
sr_deliver() {
  local dest="$1" report="$2" type secret_handle secret adapter rc repo count detail
  repo="$(printf '%s' "$report" | "$SR_JQ" -r .repo)"
  count="$(printf '%s' "$report" | "$SR_JQ" -r .count)"
  type="$(sr_dest_field "$dest" type)"
  secret_handle="$(sr_dest_field "$dest" secret)"
  if [ -z "$type" ] || [ -z "$secret_handle" ]; then
    sr_log_event "$repo" "$dest" "error" "destination is not fully configured"; return 1
  fi
  adapter="${SR_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/adapters/${type}.sh"
  if [ ! -f "$adapter" ]; then
    sr_log_event "$repo" "$dest" "error" "no adapter for type '$type'"; return 1
  fi
  secret="$(sr_resolve_secret "$secret_handle")"
  if [ -z "$secret" ]; then
    sr_log_event "$repo" "$dest" "error" "could not read the key from $secret_handle"; return 1
  fi
  # The URL goes straight into the adapter as an argument, never through a
  # variable that anything prints.
  #
  # An adapter may print ONE line of detail to stdout (HTTP code, run id...) and
  # it lands in the log. That is the extension to the adapter contract that lets
  # `sr history` say more than just success/failure.
  detail="$(printf '%s' "$report" | bash "$adapter" "$secret")"
  rc=$?
  if [ $rc -eq 0 ]; then sr_log_event "$repo" "$dest" "sent" "$detail" "$count"
  else sr_log_event "$repo" "$dest" "failed" "${detail:-adapter exited $rc}" "$count"; fi
  return $rc
}

# How long the work must sit still before it is worth asking about. A commit
# that landed a minute ago belongs to the session still in progress; asking then
# interrupts the very work that is producing the commits.
#
# Env beats config so the number can be tried out without a release.
sr_ask_after_min() {
  local v
  v="${SR_ASK_AFTER_MIN:-}"
  [ -n "$v" ] || v="$(sr_config 2>/dev/null | "$SR_JQ" -r '.ask_after_minutes // empty' 2>/dev/null)"
  case "$v" in (''|*[!0-9]*) v=30 ;; esac
  printf '%s' "$v"
}

# Remembering which HEAD was already asked about is what keeps one question from
# becoming a nag on every message of the day. Separate from the marker: the
# marker means "reported", this means "asked".
sr_nudge_file() {
  local key; key=$(printf '%s' "$1" | "$SR_SHA" | cut -c1-16)
  printf '%s/nudges/%s' "$(sr_state_dir)" "$key"
}

# How many commits are waiting. Zero when the repo has no marker yet: without
# one, "unreported" means the entire history, which is not something to ask
# about on day one.
sr_pending_count() {
  local repo_path="$1" marker last_sha n
  marker="$(sr_marker_file "$repo_path")"
  [ -f "$marker" ] || { printf '0'; return 0; }
  read -r last_sha < "$marker"
  n=$( ( cd "$repo_path" 2>/dev/null && sr_unreported_commits "$last_sha" ) | grep -c . 2>/dev/null )
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Minutes since the newest commit. Fails (non-zero) for a repo with no commits.
sr_head_age_min() {
  local ct now
  ct=$( cd "$1" 2>/dev/null && git log -1 --format=%ct HEAD 2>/dev/null )
  [ -n "$ct" ] || return 1
  now=$(date +%s)
  printf '%s' $(( (now - ct) / 60 ))
}

# The whole act of reporting: which commits, summarised how, sent where, and
# when the marker may move.
#
# This used to live in a SessionEnd hook, which meant the only way to report was
# to end a session tidily — and in the VSCode extension that never happens.
# Sending is now something a person asks for, so the body lives here where any
# caller can reach it.
#
# Prints one human line saying what happened. Returns 0 only when a destination
# accepted the report; "nothing to send" is 1, because nothing left the machine.
sr_report_repo() {
  local repo_path="$1" event="${2:-session_end}"
  local repo_name dests head_sha marker last_sha commits clean summary branch report any_ok dest

  if [ "${STATUS_REPORTER_SKIP:-}" = "1" ]; then
    printf 'skipped: already running inside status-reporter\n'; return 1
  fi
  if ! command -v "$SR_JQ" >/dev/null 2>&1; then
    sr_log_raw "jq not found — run: sr doctor"
    printf 'jq not found — run: sr doctor\n'; return 1
  fi

  cd "$repo_path" 2>/dev/null || { printf 'no such directory: %s\n' "$repo_path"; return 1; }
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'not a git repo: %s\n' "$repo_path"; return 1; }
  repo_name="$(basename "$repo_path")"

  dests="$(sr_dests_for_repo "$repo_path" "$event")"
  if [ -z "$dests" ]; then
    printf 'no rule for this repo — add one with: sr init  (or /status-reporter:add-project)\n'; return 1
  fi

  head_sha=$(git rev-parse HEAD 2>/dev/null) || { printf 'no commits yet\n'; return 1; }
  marker="$(sr_marker_file "$repo_path")"
  mkdir -p "$(dirname "$marker")" 2>/dev/null || { printf 'cannot write the marker\n'; return 1; }

  # First time for this repo: "never reported" means the whole history, and
  # nobody wants to read that.
  if [ ! -f "$marker" ]; then
    printf '%s\n' "$head_sha" > "$marker"
    sr_log_event "$repo_name" "-" "skipped" "first run in this repo, marker set only"
    printf 'first report for %s — marker set at %s, nothing sent\n' "$repo_name" "${head_sha:0:7}"
    return 1
  fi

  read -r last_sha < "$marker"
  if [ "$last_sha" = "$head_sha" ]; then
    sr_log_event "$repo_name" "-" "skipped" "no new commits"
    printf 'nothing new since the last report\n'; return 1
  fi

  commits="$(sr_unreported_commits "$last_sha")"
  if [ -z "$commits" ]; then
    printf '%s\n' "$head_sha" > "$marker"
    sr_log_event "$repo_name" "-" "skipped" "HEAD moved but no new commits"
    printf 'HEAD moved but there are no new commits\n'; return 1
  fi

  clean="$(printf '%s\n' "$commits" | sr_clean_subject)"
  summary="$(sr_summarize "$clean")"
  # claude failed or timed out → fall back to the raw commit list. Rough beats
  # missing.
  [ -n "$summary" ] || summary="$clean"

  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  report="$(sr_build_report "$event" "$repo_name" "$repo_path" "$branch" "$summary" "$clean")"
  [ -n "$report" ] || { printf 'could not build the report\n'; return 1; }

  # The marker moves ONLY when at least one destination accepted. Moving it
  # first would lose these commits outright if every destination rejected them.
  any_ok=0
  while IFS= read -r dest; do
    [ -n "$dest" ] || continue
    sr_deliver "$dest" "$report" && any_ok=1
  done <<< "$dests"

  if [ "$any_ok" = "1" ]; then
    printf '%s\n' "$head_sha" > "$marker"
    printf 'sent %s commit(s) from %s to %s\n' "$(printf '%s\n' "$clean" | grep -c .)" "$repo_name" "$(printf '%s' "$dests" | tr '\n' ' ')"
    return 0
  fi
  printf 'nothing was accepted — the marker stayed put, run `sr history` for the reason\n'
  return 1
}
