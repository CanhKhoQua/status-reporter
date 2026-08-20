#!/usr/bin/env bash
# Microsoft Teams adapter.
#
# Contract shared by EVERY adapter:
#   stdin              report.json (see sr_build_report in core.sh)
#   $1                 the destination's secret
#   exit 0             delivered
#   stdout (optional)  one line of detail → goes into the log
#   --validate <secret> (optional) does this secret look right for this channel?
#
# Adding a channel means adding one file next to this one that honours the
# contract above. No change to core.sh, to session-end.sh, or to any other
# adapter.
set -uo pipefail

# core.sh normally exports SR_JQ; the fallback is for direct invocation
# (--validate mode, or the test suite).
JQ="${SR_JQ:-$(command -v jq 2>/dev/null || printf '/usr/bin/jq')}"

# Secret check. This is how `sr set-secret` catches a truncated URL BEFORE
# storing it, instead of letting the user discover it minutes later through a
# baffling HTTP 400.
if [ "${1:-}" = "--validate" ]; then
  u="${2:-}"
  [ -n "$u" ] || { echo "empty"; exit 1; }
  case "$u" in https://*) ;; *) echo "does not start with https://"; exit 1 ;; esac
  printf '%s' "$u" | grep -q 'api-version=' || { echo "missing ?api-version= — the query string was cut off"; exit 1; }
  printf '%s' "$u" | grep -q 'sig='         || { echo "missing &sig= — the signature was cut off"; exit 1; }
  [ "${#u}" -ge 200 ] || { echo "only ${#u} characters, too short (a full URL is usually 250-700)"; exit 1; }
  echo "looks valid (${#u} characters)"; exit 0
fi

webhook="${1:-}"
[ -n "$webhook" ] || exit 2
report="$(cat)"
[ -n "$report" ] || exit 2

# Adaptive Card 1.5 inside the Power Automate Workflows envelope. The legacy
# MessageCard / O365 connector format is retired: send that and you get a 202
# followed by nothing — a fake success nobody sees.
payload="$(printf '%s' "$report" | "$JQ" '
  {
    type: "message",
    attachments: [{
      contentType: "application/vnd.microsoft.card.adaptive",
      content: {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        type: "AdaptiveCard",
        version: "1.5",
        body: [
          { type: "TextBlock", text: ("🔧 Development update — " + .when),
            weight: "Bolder", size: "Medium", wrap: true },
          { type: "FactSet", facts: [
              { title: "Repo",    value: .repo },
              { title: "Branch",  value: .branch },
              { title: "Commits", value: (.count | tostring) }
          ]},
          { type: "TextBlock", text: .summary, wrap: true, spacing: "Medium" },
          { type: "TextBlock",
            text: ((.commits[:15] | map("• " + .) | join("\n"))
                   + (if .count > 15 then "\n• … and " + ((.count - 15)|tostring) + " more" else "" end)),
            wrap: true, isSubtle: true, size: "Small", spacing: "Small" },
          { type: "TextBlock",
            text: (if .state == "test" then "🧪 Test message — please ignore."
                   else "⚠️ Work in progress — not yet deployed to production." end),
            wrap: true, size: "Small", color: "Warning", spacing: "Medium" }
        ]
      }
    }]
  }')"
[ -n "$payload" ] || exit 3

# Dry-run mode for the test suite: exercise the whole payload path without
# touching the network.
if [ -n "${SR_DRY_RUN_FILE:-}" ]; then
  printf '%s' "$payload" > "$SR_DRY_RUN_FILE"
  [ "${SR_DRY_RUN_FAIL:-}" = "1" ] && exit 1
  printf 'DRY 202 · run=fake'
  exit 0
fi

# curl does NOT treat 4xx/5xx as an error — check the code yourself or total
# failure is completely invisible. The error names the HTTP code, never the URL.
#
# 202 IS NOT 200. Power Automate returns 202 the moment it ACCEPTS the request
# and only then runs the flow asynchronously — the "Post card" action can fail
# afterwards and the webhook never hears about it. Record that distinction, with
# the run id for lookup, instead of reporting "sent" for something we only know
# was "received".
hdr="$(mktemp)"
trap 'rm -f "$hdr"' EXIT
code=$(printf '%s' "$payload" | curl -sS -D "$hdr" -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary @- \
  --max-time 20 "$webhook" 2>/dev/null) || code="000"
run_id=$(grep -i '^x-ms-workflow-run-id:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}')
case "$code" in
  202) printf 'HTTP 202 accepted (delivery not confirmed)%s' "${run_id:+ · run=$run_id}"; exit 0 ;;
  2*)  printf 'HTTP %s%s' "$code" "${run_id:+ · run=$run_id}"; exit 0 ;;
  *)   echo "[status-reporter] channel rejected the payload: HTTP $code" >&2; exit 1 ;;
esac
