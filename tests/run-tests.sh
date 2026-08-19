#!/usr/bin/env bash
# Chạy: bash tests/run-tests.sh
#
# Không chạm mạng, không chạm Teams: tp_post ghi payload ra TP_DRY_RUN_FILE và
# `claude` được thay bằng script giả. "Không gửi" được kiểm bằng sự VẮNG MẶT
# của file payload.
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; }

mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho "Worked on the login rate limit and added database indexes."\n' > "$WORK/bin/claude-ok"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/claude-fail"
chmod +x "$WORK/bin/"*

STATE="$WORK/state"

new_repo() {
  local d="$WORK/repo-$1"; mkdir -p "$d"; cd "$d"
  git init -q .; git config user.email t@t.t; git config user.name T
  echo a > a.txt; git add -A; git commit -qm "chore: khởi tạo"
  echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > .env.local
  printf '%s' "$d"
}

# Chạy session-end một lần. In đường dẫn payload nếu có gửi.
run_end() {
  local repo="$1" tag="$2"; shift 2
  local out="$WORK/payload-$tag.json"
  ( cd "$repo" && printf '{"session_id":"s","cwd":"%s"}' "$repo" | \
      env TP_STATE_DIR="$STATE" TP_DRY_RUN_FILE="$out" "$@" \
      bash "$HOOKS/session-end.sh" ) >/dev/null 2>&1
  [ -f "$out" ] && printf '%s' "$out"
}

commit() { ( cd "$1" && echo "$RANDOM" > "f$2.txt" && git add -A && git commit -qm "$3" ) >/dev/null 2>&1; }
marker_of() { ( cd "$1" && cat "$STATE/repos/$(printf '%s' "$1" | shasum | cut -c1-16)" 2>/dev/null ); }

echo "teams-progress — kiểm thử"

# --- 1. lần đầu ở repo → chỉ đặt mốc, không gửi -------------------------
r=$(new_repo 1)
out=$(run_end "$r" t1 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "lần đầu ở repo → không gửi (không đổ cả lịch sử)" \
             || bad "lần đầu ở repo → không gửi" "đã gửi"
[ -n "$(marker_of "$r")" ] && ok "lần đầu có ghi mốc" || bad "lần đầu có ghi mốc"

# --- 2. có commit mới → gửi, nội dung đúng ------------------------------
commit "$r" b "fix(auth): sửa hạn mức đăng nhập"
commit "$r" c "feat(db): bù index"
out=$(run_end "$r" t2 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ]; then
  ok "có commit mới → gửi"
  body=$(/usr/bin/jq -r '.attachments[0].content.body' "$out")
  echo "$body" | grep -q "login rate limit" && ok "mang tóm tắt tiếng Anh" || bad "mang tóm tắt tiếng Anh"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Commits" and .value=="2")' "$out" >/dev/null \
    && ok "đếm đúng 2 commit" || bad "đếm đúng 2 commit"
  echo "$body" | grep -q "sửa hạn mức đăng nhập" && ok "giữ câu tiếng Việt" || bad "giữ câu tiếng Việt"
  echo "$body" | grep -q "fix(auth)" && bad "tiền tố lẽ ra bị cắt" || ok "cắt tiền tố conventional-commit"
  echo "$body" | grep -q "not yet deployed to production" && ok "có cảnh báo chưa lên production" || bad "có cảnh báo chưa lên production"
  /usr/bin/jq -e '.attachments[0].contentType=="application/vnd.microsoft.card.adaptive"' "$out" >/dev/null \
    && ok "đúng envelope Adaptive Card" || bad "đúng envelope Adaptive Card"
else
  bad "có commit mới → gửi" "không gửi gì"
fi

# --- 3. chạy lại ngay, không commit gì thêm → không gửi -----------------
out=$(run_end "$r" t3 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không commit mới → không gửi (không lặp tin)" \
             || bad "không commit mới → không gửi" "gửi lại tin cũ"

# --- 4. gửi thất bại → mốc KHÔNG dời, lần sau báo lại -------------------
r4=$(new_repo 4); run_end "$r4" t4a TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
before=$(marker_of "$r4")
commit "$r4" x "fix: việc quan trọng"
run_end "$r4" t4b TP_DRY_RUN_FAIL=1 TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
after=$(marker_of "$r4")
[ "$before" = "$after" ] && ok "gửi thất bại → mốc KHÔNG dời" \
                        || bad "gửi thất bại → mốc KHÔNG dời" "mốc đã dời ⇒ MẤT COMMIT"
out=$(run_end "$r4" t4c TP_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ]; then
  /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "việc quan trọng" \
    && ok "lần sau báo lại đúng commit đã trượt" || bad "lần sau báo lại commit đã trượt"
else
  bad "lần sau báo lại commit đã trượt" "im lặng ⇒ mất trắng"
fi

# --- 5. cờ chống đệ quy --------------------------------------------------
r5=$(new_repo 5); run_end "$r5" t5a TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r5" y "fix: x"
out=$(run_end "$r5" t5b TEAMS_PROGRESS_SKIP=1 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "TEAMS_PROGRESS_SKIP=1 → không gửi (chống đệ quy)" \
             || bad "TEAMS_PROGRESS_SKIP=1 → không gửi" "vẫn gửi ⇒ NGUY CƠ LẶP VÔ HẠN"

# --- 6. không có webhook → im -------------------------------------------
r6=$(new_repo 6); rm -f "$r6/.env.local"
commit "$r6" z "fix: x"
out=$(run_end "$r6" t6 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không có TEAMS_WEBHOOK_URL → không gửi (giới hạn phạm vi)" \
             || bad "không có TEAMS_WEBHOOK_URL → không gửi"

# --- 7. không phải repo git → im ----------------------------------------
d="$WORK/khong-phai-repo"; mkdir -p "$d"; echo 'TEAMS_WEBHOOK_URL=https://fake.invalid/x' > "$d/.env.local"
out=$(run_end "$d" t7 TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không phải repo git → không gửi" || bad "không phải repo git → không gửi"

# --- 8. claude lỗi → vẫn gửi bằng commit thô ----------------------------
r8=$(new_repo 8); run_end "$r8" t8a TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r8" w "fix(auth): sửa hạn mức"
out=$(run_end "$r8" t8b TP_CLAUDE_BIN="$WORK/bin/claude-fail")
if [ -n "$out" ]; then
  ok "claude lỗi → vẫn gửi (không mất tin)"
  /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "sửa hạn mức" \
    && ok "fallback dùng commit thô" || bad "fallback dùng commit thô"
else
  bad "claude lỗi → vẫn gửi" "im lặng ⇒ mất tin"
fi

# --- 9. đổi nhánh giữa chừng → vẫn báo commit mới -----------------------
r9=$(new_repo 9); run_end "$r9" t9a TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
( cd "$r9" && git checkout -q -b nhanh-khac ) 2>/dev/null
commit "$r9" v "fix: trên nhánh khác"
out=$(run_end "$r9" t9b TP_CLAUDE_BIN="$WORK/bin/claude-ok")
if [ -n "$out" ]; then
  ok "đổi nhánh → vẫn gửi"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Branch" and .value=="nhanh-khac")' "$out" >/dev/null \
    && ok "card ghi đúng tên nhánh" || bad "card ghi đúng tên nhánh"
else
  bad "đổi nhánh → vẫn gửi" "mất báo cáo khi checkout"
fi

# --- 10. URL có dấu nháy kép --------------------------------------------
r10=$(new_repo 10); echo 'TEAMS_WEBHOOK_URL="https://fake.invalid/x"' > "$r10/.env.local"
run_end "$r10" t10a TP_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r10" u "fix: x"
out=$(run_end "$r10" t10b TP_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "đọc được URL có dấu nháy kép" || bad "đọc được URL có dấu nháy kép"

echo
printf 'Kết quả: %d đạt, %d hỏng\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
