#!/usr/bin/env bash
# Chạy: bash tests/run-tests.sh
#
# Không chạm mạng, không chạm Teams: tp_post ghi payload ra TP_DRY_RUN_FILE và
# `claude` được thay bằng script giả. "Không gửi" được kiểm bằng sự VẮNG MẶT
# của file đó.
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; }

# --- công cụ giả ---------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude-ok" <<'EOF'
#!/usr/bin/env bash
echo "Worked on the login rate limit and added database indexes."
EOF
cat > "$WORK/bin/claude-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/bin/"*

# Dựng một repo git sạch, trả về đường dẫn.
new_repo() {
  local d="$WORK/repo-$1"; mkdir -p "$d"; cd "$d"
  git init -q .; git config user.email t@t.t; git config user.name T
  echo a > a.txt; git add -A; git commit -qm "chore: khởi tạo"
  printf '%s' "$d"
}

# Chạy trọn start → (commit) → end. In ra đường dẫn payload nếu có gửi.
run_session() {
  local repo="$1" sid="$2"; shift 2
  local state="$WORK/state-$sid" out="$WORK/payload-$sid.json"
  local json="{\"session_id\":\"$sid\",\"cwd\":\"$repo\"}"
  ( cd "$repo" && printf '%s' "$json" | \
      env TP_STATE_DIR="$state" "$@" bash "$HOOKS/session-start.sh" ) >/dev/null 2>&1
  [ -n "${MAKE_COMMITS:-}" ] && ( cd "$repo" && eval "$MAKE_COMMITS" ) >/dev/null 2>&1
  ( cd "$repo" && printf '%s' "$json" | \
      env TP_STATE_DIR="$state" TP_DRY_RUN_FILE="$out" "$@" \
      bash "$HOOKS/session-end.sh" ) >/dev/null 2>&1
  [ -f "$out" ] && printf '%s' "$out"
}

echo "teams-progress — kiểm thử"

# --- 1. phiên không commit gì → không gửi -------------------------------
r=$(new_repo 1); echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$r/.env.local"
MAKE_COMMITS="" out=$(run_session "$r" s1 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "phiên không commit → không gửi" \
             || bad "phiên không commit → không gửi" "đã gửi, lẽ ra phải im"

# --- 2. có commit → gửi, payload đúng -----------------------------------
r=$(new_repo 2); echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$r/.env.local"
MAKE_COMMITS='echo b>b.txt; git add -A; git commit -qm "fix(auth): sửa hạn mức đăng nhập"; echo c>c.txt; git add -A; git commit -qm "feat(db): bù index"'
out=$(run_session "$r" s2 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ]; then
  ok "có commit → có gửi"
  body=$(/usr/bin/jq -r '.attachments[0].content.body' "$out")
  echo "$body" | grep -q "login rate limit" \
    && ok "payload mang tóm tắt tiếng Anh" || bad "payload mang tóm tắt tiếng Anh"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Commits" and .value=="2")' "$out" >/dev/null \
    && ok "đếm đúng 2 commit" || bad "đếm đúng 2 commit" "$(/usr/bin/jq -c '.attachments[0].content.body[1]' "$out")"
  echo "$body" | grep -q "sửa hạn mức đăng nhập" \
    && ok "bỏ tiền tố fix(auth):, giữ câu tiếng Việt" || bad "bỏ tiền tố fix(auth):"
  echo "$body" | grep -q "fix(auth)" \
    && bad "tiền tố lẽ ra phải bị cắt" || ok "tiền tố conventional-commit đã bị cắt"
  echo "$body" | grep -q "not yet deployed to production" \
    && ok "có cảnh báo chưa lên production" || bad "có cảnh báo chưa lên production"
  /usr/bin/jq -e '.attachments[0].contentType=="application/vnd.microsoft.card.adaptive"' "$out" >/dev/null \
    && ok "đúng envelope Adaptive Card" || bad "đúng envelope Adaptive Card"
else
  bad "có commit → có gửi" "không gửi gì"
fi

# --- 3. cờ chống đệ quy --------------------------------------------------
r=$(new_repo 3); echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$r/.env.local"
MAKE_COMMITS='echo b>b.txt; git add -A; git commit -qm "fix: x"'
out=$(run_session "$r" s3 TEAMS_PROGRESS_SKIP=1 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "TEAMS_PROGRESS_SKIP=1 → không gửi (chống đệ quy)" \
             || bad "TEAMS_PROGRESS_SKIP=1 → không gửi" "vẫn gửi ⇒ NGUY CƠ LẶP VÔ HẠN"

# --- 4. project không có webhook → im ------------------------------------
r=$(new_repo 4)   # cố ý không tạo .env.local
MAKE_COMMITS='echo b>b.txt; git add -A; git commit -qm "fix: x"'
out=$(run_session "$r" s4 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không có TEAMS_WEBHOOK_URL → không gửi (giới hạn phạm vi)" \
             || bad "không có TEAMS_WEBHOOK_URL → không gửi"

# --- 5. claude lỗi → vẫn gửi, dùng commit thô ----------------------------
r=$(new_repo 5); echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$r/.env.local"
MAKE_COMMITS='echo b>b.txt; git add -A; git commit -qm "fix(auth): sửa hạn mức"'
out=$(run_session "$r" s5 TP_CLAUDE_BIN="$WORK/bin/claude-fail")
if [ -n "$out" ]; then
  ok "claude lỗi → vẫn gửi (không mất tin)"
  /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "sửa hạn mức" \
    && ok "fallback dùng commit thô" || bad "fallback dùng commit thô"
else
  bad "claude lỗi → vẫn gửi" "im lặng ⇒ mất tin"
fi

# --- 6. không phải repo git → im ----------------------------------------
d="$WORK/khong-phai-repo"; mkdir -p "$d"; echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$d/.env.local"
MAKE_COMMITS="" out=$(run_session "$d" s6 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không phải repo git → không gửi" || bad "không phải repo git → không gửi"

# --- 7. đổi nhánh giữa phiên → vẫn báo được ------------------------------
r=$(new_repo 7); echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$r/.env.local"
MAKE_COMMITS='git checkout -q -b nhanh-khac; echo b>b.txt; git add -A; git commit -qm "fix: trên nhánh khác"'
out=$(run_session "$r" s7 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ]; then
  ok "đổi nhánh giữa phiên → vẫn gửi"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Branch" and .value=="nhanh-khac")' "$out" >/dev/null \
    && ok "card ghi đúng tên nhánh" || bad "card ghi đúng tên nhánh"
else
  bad "đổi nhánh giữa phiên → vẫn gửi" "mất báo cáo khi checkout"
fi

# --- 8. webhook có dấu nháy trong .env.local -----------------------------
r=$(new_repo 8); echo 'TEAMS_WEBHOOK_URL="https://fake.invalid/x"' > "$r/.env.local"
MAKE_COMMITS='echo b>b.txt; git add -A; git commit -qm "fix: x"'
out=$(run_session "$r" s8 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "đọc được URL có dấu nháy kép" || bad "đọc được URL có dấu nháy kép"

echo
printf 'Kết quả: %d đạt, %d hỏng\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
