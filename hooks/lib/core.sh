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
