#!/usr/bin/env bash
# Run: bash tests/run-tests.sh
#
# Nothing touches the network, the chat channel, or the real Keychain:
#   - the adapter writes its payload to SR_DRY_RUN_FILE instead of calling curl
#   - `claude` is a stub script
#   - secrets come from env: handles, not keychain:
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/session-end.sh"
SRBIN="$ROOT/bin/sr"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; }

mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho "Worked on the login rate limit and added database indexes."\n' > "$WORK/bin/claude-ok"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/claude-fail"
chmod +x "$WORK/bin/"*

export SR_STATE_DIR="$WORK/state"
export SR_CONFIG="$WORK/config.json"
export SR_WEBHOOK_FOR_TEST="https://fake.invalid/hook"

new_repo() {
  local d="$WORK/repo-$1"; mkdir -p "$d"; cd "$d"
  git init -q .; git config user.email t@t.t; git config user.name T
  echo a > a.txt; git add -A; git commit -qm "chore: initial"
  printf '%s' "$(pwd -P)"
}

write_config() {  # $1=repo path, $2=type (default teams)
  /usr/bin/jq -n --arg repo "$1" --arg type "${2:-teams}" '
    { destinations: { d1: { type: $type, secret: "env:SR_WEBHOOK_FOR_TEST" } },
      rules: [ { repo: $repo, on: "session_end", to: ["d1"] } ] }' > "$SR_CONFIG"
}

run_end() {
  local repo="$1" tag="$2"; shift 2
  local out="$WORK/payload-$tag.json"
  ( cd "$repo" && printf '{"cwd":"%s"}' "$repo" | \
      env SR_DRY_RUN_FILE="$out" "$@" bash "$HOOK" ) >/dev/null 2>&1
  [ -f "$out" ] && printf '%s' "$out"
}
commit() { ( cd "$1" && echo "$RANDOM" > "f$2.txt" && git add -A && git commit -qm "$3" ) >/dev/null 2>&1; }
marker()  { cat "$SR_STATE_DIR/markers/$(printf '%s' "$1" | shasum | cut -c1-16)" 2>/dev/null; }
logf()    { cat "$SR_STATE_DIR/log.jsonl" 2>/dev/null; }

echo "status-reporter — test suite"

# ================= COLLECTION =================
echo "  -- collection --"
r=$(new_repo 1); write_config "$r"
out=$(run_end "$r" t1 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "first run in a repo sends nothing (no history dump)" || bad "first run sends nothing"
[ -n "$(marker "$r")" ] && ok "first run writes a marker" || bad "first run writes a marker"

commit "$r" b "fix(auth): only count failed login attempts"; commit "$r" c "feat(db): add missing indexes"
out=$(run_end "$r" t2 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "new commits are sent" || bad "new commits are sent" "nothing sent"

out=$(run_end "$r" t3 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "running again with no new commits sends nothing" || bad "no duplicate messages"

r9=$(new_repo 9); write_config "$r9"; run_end "$r9" t9a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
( cd "$r9" && git checkout -q -b other-branch ); commit "$r9" v "fix: work on another branch"
out=$(run_end "$r9" t9b SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "a branch switch still reports" || bad "a branch switch still reports"

# ================= THE report.json BOUNDARY =================
echo "  -- report.json boundary (what makes it extensible) --"
grep -qiE '(adaptive|contentType|attachments)' "$ROOT/hooks/session-end.sh" \
  && bad "the collector must NOT know a channel format" "session-end.sh mentions Adaptive Card" \
  || ok "the collector knows no channel format"
grep -qiE '(adaptive|contentType|attachments)' "$ROOT/hooks/lib/core.sh" \
  && bad "core.sh must NOT know a channel format" "core.sh mentions Adaptive Card" \
  || ok "core.sh knows no channel format"

# A fake adapter proves the claim: a new channel is one file, nothing else.
cat > "$ROOT/hooks/lib/adapters/faux.sh" <<'ADP'
#!/usr/bin/env bash
report="$(cat)"; [ -n "${SR_DRY_RUN_FILE:-}" ] || exit 2
printf 'FAUX:%s' "$(printf '%s' "$report" | /usr/bin/jq -r .repo)" > "$SR_DRY_RUN_FILE"
ADP
r10=$(new_repo 10); write_config "$r10" faux
run_end "$r10" t10a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r10" q "fix: x"
out=$(run_end "$r10" t10b SR_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ] && grep -q "^FAUX:repo-10" "$out"; then
  ok "a NEW channel works by adding one adapter file"
else
  bad "a new channel is one adapter file" "the fake adapter was never called"
fi
rm -f "$ROOT/hooks/lib/adapters/faux.sh"

# ================= TEAMS ADAPTER =================
echo "  -- teams adapter --"
out="$WORK/payload-t2.json"
if [ -f "$out" ]; then
  body=$(/usr/bin/jq -r '.attachments[0].content.body' "$out")
  /usr/bin/jq -e '.attachments[0].contentType=="application/vnd.microsoft.card.adaptive"' "$out" >/dev/null \
    && ok "correct Adaptive Card envelope" || bad "correct Adaptive Card envelope"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Commits" and .value=="2")' "$out" >/dev/null \
    && ok "counts 2 commits" || bad "counts 2 commits"
  echo "$body" | grep -q "login rate limit" && ok "carries the English summary" || bad "carries the English summary"
  echo "$body" | grep -q "only count failed login attempts" && ok "keeps the commit text" || bad "keeps the commit text"
  echo "$body" | grep -q "fix(auth)" && bad "the prefix should be stripped" || ok "strips the conventional-commit prefix"
  echo "$body" | grep -q "not yet deployed to production" && ok "carries the not-deployed warning" || bad "carries the not-deployed warning"
else
  bad "teams adapter" "no payload to inspect"
fi

# ================= SECRETS =================
echo "  -- secrets --"
r5=$(new_repo 5); write_config "$r5"; run_end "$r5" t5a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r5" k "fix: x"
out=$(run_end "$r5" t5b SR_CLAUDE_BIN="$WORK/bin/claude-ok" SR_WEBHOOK_FOR_TEST="")
[ -z "$out" ] && ok "an unreadable key sends nothing" || bad "an unreadable key sends nothing"
logf | grep -q "could not read the key" && ok "logs why the key was unreadable" || bad "logs why the key was unreadable"
if logf | grep -q "fake.invalid"; then bad "the log must NOT contain the URL" "the URL leaked into the log"; else ok "the URL never reaches the log"; fi
grep -q "fake.invalid" "$SR_CONFIG" && bad "the config must NOT contain the URL" || ok "the config holds a handle, not the URL"

# ================= SAFETY =================
echo "  -- safety --"
r6=$(new_repo 6); write_config "$r6"; run_end "$r6" t6a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r6" m "fix: x"
out=$(run_end "$r6" t6b STATUS_REPORTER_SKIP=1 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "STATUS_REPORTER_SKIP=1 sends nothing (recursion guard)" || bad "recursion guard" "still sent ⇒ INFINITE LOOP RISK"

r7=$(new_repo 7); write_config "$WORK/repo-OTHER"   # this repo has no rule
commit "$r7" n "fix: x"
out=$(run_end "$r7" t7 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "a repo with no rule sends nothing (default deny)" || bad "default deny"

r8=$(new_repo 8); write_config "$r8"; run_end "$r8" t8a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
before=$(marker "$r8"); commit "$r8" p "fix: something important"
run_end "$r8" t8b SR_DRY_RUN_FAIL=1 SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
[ "$before" = "$(marker "$r8")" ] && ok "a failed send does NOT move the marker" || bad "a failed send does not move the marker" "COMMITS LOST"
out=$(run_end "$r8" t8c SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "something important" \
  && ok "the next run re-reports the commits that slipped" || bad "re-reports the commits that slipped"

r11=$(new_repo 11); write_config "$r11"; run_end "$r11" t11a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r11" s "fix(auth): only count failed attempts"
out=$(run_end "$r11" t11b SR_CLAUDE_BIN="$WORK/bin/claude-fail")
[ -n "$out" ] && /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "only count failed attempts" \
  && ok "claude failing still sends, using raw commits" || bad "claude failing falls back to raw commits"

d="$WORK/not-a-repo"; mkdir -p "$d"; write_config "$d"
out=$(run_end "$d" t12 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "a non-git directory sends nothing" || bad "a non-git directory sends nothing"

# ================= CONTROL PANEL =================
echo "  -- control panel --"
write_config "$r"
bash "$SRBIN" status >"$WORK/st.txt" 2>&1
grep -q "DESTINATIONS" "$WORK/st.txt" && ok "sr status runs" || bad "sr status runs" "$(head -3 "$WORK/st.txt")"
grep -q "key found" "$WORK/st.txt" && ok "sr status reports key presence without printing it" || bad "sr status reports key presence"
grep -q "fake.invalid" "$WORK/st.txt" && bad "sr status must NOT print the URL" || ok "sr status never prints the URL"
bash "$SRBIN" history 5 >"$WORK/hi.txt" 2>&1
grep -qE "skipped|→|✗" "$WORK/hi.txt" && ok "sr history shows the log" || bad "sr history shows the log" "$(head -3 "$WORK/hi.txt")"
grep -q "fake.invalid" "$WORK/hi.txt" && bad "sr history must NOT print the URL" || ok "sr history never prints the URL"

# ================= SECRET VALIDATION + LOG DETAIL =================
echo "  -- secret validation --"
ADP="$ROOT/hooks/lib/adapters/teams.sh"
bash "$ADP" --validate "https://x.invalid/invoke" >/dev/null 2>&1 \
  && bad "a URL missing its query string must be rejected" "accepted anyway" \
  || ok "a URL missing ?api-version= is rejected before storing"
bash "$ADP" --validate "" >/dev/null 2>&1 && bad "an empty URL must be rejected" || ok "an empty URL is rejected"
FULL="https://a.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/18/workflows/abcdef0123456789abcdef0123456789/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=0123456789012345678901234567890123456789012"
bash "$ADP" --validate "$FULL" >/dev/null 2>&1 && ok "a complete URL is accepted" || bad "a complete URL is accepted"
if bash "$ADP" --validate "$FULL" 2>&1 | grep -q "$FULL"; then
  bad "--validate must NOT echo the URL" "the URL was printed"
else ok "--validate reports only a length, never the URL"; fi

echo "  -- log detail --"
logf | grep -q 'DRY 202' && ok "the log carries the adapter's detail (202 / run id)" \
                          || bad "the log carries the adapter's detail" "detail was empty"

# ================= DOCTOR + PORTABILITY =================
echo "  -- doctor --"
r_ok=$(new_repo 20); write_config "$r_ok"
bash "$SRBIN" doctor >/dev/null 2>&1 && ok "a valid config exits 0" || bad "a valid config exits 0"

# Regression: doctor USED TO print ✗ and still report a clean bill of health,
# because the loop ran after a pipe and the counter lived in a subshell.
/usr/bin/jq '.rules[0].repo = "/does/not/exist"' "$SR_CONFIG" > "$WORK/bad.json" && mv "$WORK/bad.json" "$SR_CONFIG"
out_doc="$(bash "$SRBIN" doctor 2>&1)"; rc_doc=$?
echo "$out_doc" | grep -q "does not exist" && ok "doctor spots a missing repo path" || bad "doctor spots a missing repo path"
[ "$rc_doc" -ne 0 ] && ok "doctor exits NON-ZERO when something is wrong" \
  || bad "doctor exits non-zero when something is wrong" "printed ✗ but reported healthy — subshell bug is back"
echo "$out_doc" | grep -q "problem(s) to fix" && ok "doctor counts the problems" || bad "doctor counts the problems"

/usr/bin/jq '.destinations.d1.secret = "keychain:does-not-exist"' "$SR_CONFIG" > "$WORK/b2.json" && mv "$WORK/b2.json" "$SR_CONFIG"
# Capture first, then match: `doctor | grep` under `set -o pipefail` returns
# doctor's (deliberately non-zero) status, so `&&` fails even when grep matched.
out_key="$(bash "$SRBIN" doctor 2>&1 || true)"
case "$out_key" in
  *"sr set-secret"*) ok "doctor names the fix for a missing key" ;;
  *) bad "doctor names the fix for a missing key" "no hint in the output" ;;
esac

echo "  -- portability --"
r_jq=$(new_repo 21); write_config "$r_jq"
run_end "$r_jq" t21a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r_jq" j "fix: x"
run_end "$r_jq" t21b SR_JQ="/no/such/jq" SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
logf | grep -q "jq not found" \
  && ok "a missing jq is LOGGED instead of failing silently" \
  || bad "a missing jq is logged" "silent ⇒ nobody learns why messages stopped"
grep -rq '"/usr/bin/jq"' "$ROOT/hooks" 2>/dev/null \
  && bad "jq's path must not be hardcoded" "a hardcoded path remains" \
  || ok "jq is resolved through PATH, not hardcoded"

# ================= ONBOARDING =================
echo "  -- onboarding --"
IW="$WORK/init"; mkdir -p "$IW/repo"; ( cd "$IW/repo" && git init -q . )
c1="$IW/c1.json"
SR_CONFIG="$c1" bash "$SRBIN" init --repo "$IW/repo" --dest demo >/dev/null 2>&1
[ -f "$c1" ] && ok "sr init writes a config" || bad "sr init writes a config"
/usr/bin/jq -e '.destinations.demo.secret == "keychain:demo"' "$c1" >/dev/null 2>&1 \
  && ok "the config points at a handle, never an inline value" || bad "the config uses a handle"
/usr/bin/jq -e '(.rules[0].repo | test("repo$"))' "$c1" >/dev/null 2>&1 \
  && ok "sr init records the right repo in the rule" || bad "sr init records the right repo"
[ "$(stat -f '%Lp' "$c1" 2>/dev/null || stat -c '%a' "$c1")" = "600" ] \
  && ok "the config is mode 600" || bad "the config is mode 600"

# A typo in the channel type is the hardest-to-trace cause of "silently sends
# nothing" — it has to be caught at init, not days later.
SR_CONFIG="$IW/c2.json" bash "$SRBIN" init --repo "$IW/repo" --dest x --type nope >/dev/null 2>&1 \
  && bad "an unknown channel type must be rejected" "config written anyway" \
  || ok "an unknown channel type is rejected at init"
[ -f "$IW/c2.json" ] && bad "a failed init must leave NO config" || ok "a failed init leaves no half-written config"

SR_CONFIG="$c1" bash "$SRBIN" init --repo "$IW/repo" --dest demo >/dev/null 2>&1 \
  && bad "a second init must refuse" "overwrote a live config" \
  || ok "init refuses to overwrite an existing config"

# The two most expensive misunderstandings must be stated on a successful test.
/usr/bin/jq '.destinations.demo.secret = "env:SR_WEBHOOK_FOR_TEST"' "$c1" > "$IW/c1b.json" && mv "$IW/c1b.json" "$c1"
out_t="$(SR_CONFIG="$c1" SR_DRY_RUN_FILE="$IW/p.json" bash "$SRBIN" test demo 2>&1 || true)"
case "$out_t" in
  *"NEXT Claude Code session"*) ok "sr test warns the hook loads next session" ;;
  *) bad "sr test warns the hook loads next session" "no warning found" ;;
esac
case "$out_t" in
  *"SETS A MARKER"*) ok "sr test warns the first session only sets a marker" ;;
  *) bad "sr test warns the first session only sets a marker" "no warning found" ;;
esac

# The slash command must forbid pasting the URL into chat — a mistake that has
# actually happened once.
CMD="$ROOT/commands/setup.md"
[ -f "$CMD" ] && ok "the /status-reporter:setup command exists" || bad "the setup command exists"
grep -q "DO NOT do this for them" "$CMD" 2>/dev/null && grep -q "paste the webhook URL into the chat" "$CMD" \
  && ok "the setup command forbids pasting the URL into chat" || bad "the setup command forbids pasting the URL into chat"

# Every command that handles the key must carry the same prohibition as setup.md.
for c in key add-project; do
  F="$ROOT/commands/$c.md"
  [ -f "$F" ] && ok "the /status-reporter:$c command exists" || bad "the /status-reporter:$c command exists"
  grep -q "paste the webhook URL into the chat" "$F" 2>/dev/null \
    && ok "$c forbids pasting the URL into chat" || bad "$c forbids pasting the URL into chat"
done

# why-quiet is only useful if it separates the logged skips from the silent ones.
Q="$ROOT/commands/why-quiet.md"
[ -f "$Q" ] && ok "the /status-reporter:why-quiet command exists" || bad "the /status-reporter:why-quiet command exists"
grep -q "NO log line at all" "$Q" 2>/dev/null \
  && ok "why-quiet distinguishes silent exits from logged skips" || bad "why-quiet distinguishes silent exits from logged skips"
grep -q "no commits yet" "$Q" 2>/dev/null \
  && ok "why-quiet covers the empty-repo exit" || bad "why-quiet covers the empty-repo exit"

# Both non-faults must appear, or the reader debugs a working install.
for f in commands/why-quiet.md commands/add-project.md; do
  grep -q "next Claude Code session" "$ROOT/$f" 2>/dev/null \
    && ok "$(basename $f) warns the hook loads next session" || bad "$(basename $f) warns the hook loads next session"
  grep -q "marker" "$ROOT/$f" 2>/dev/null \
    && ok "$(basename $f) warns about the first-session marker" || bad "$(basename $f) warns about the first-session marker"
done

echo
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
