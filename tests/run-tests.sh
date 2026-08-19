#!/usr/bin/env bash
# Chạy: bash tests/run-tests.sh
#
# Không chạm mạng, không chạm Teams, không chạm Keychain thật:
#   - adapter ghi payload ra SR_DRY_RUN_FILE thay vì curl
#   - `claude` là script giả
#   - bí mật lấy qua handle env: thay vì keychain:
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/session-end.sh"
TP="$ROOT/bin/sr"
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
  echo a > a.txt; git add -A; git commit -qm "chore: khởi tạo"
  printf '%s' "$(pwd -P)"
}

write_config() {  # $1=repo path, $2=type (mặc định teams)
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

echo "status-reporter — kiểm thử"

# ================= TẦNG THU THẬP =================
echo "  ── thu thập ──"
r=$(new_repo 1); write_config "$r"
out=$(run_end "$r" t1 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "lần đầu ở repo → không gửi (không đổ cả lịch sử)" || bad "lần đầu → không gửi"
[ -n "$(marker "$r")" ] && ok "lần đầu có đặt mốc" || bad "lần đầu có đặt mốc"

commit "$r" b "fix(auth): sửa hạn mức đăng nhập"; commit "$r" c "feat(db): bù index"
out=$(run_end "$r" t2 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "có commit mới → gửi" || bad "có commit mới → gửi" "không gửi"

out=$(run_end "$r" t3 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "chạy lại, không commit mới → không gửi" || bad "không lặp tin"

r9=$(new_repo 9); write_config "$r9"; run_end "$r9" t9a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
( cd "$r9" && git checkout -q -b nhanh-khac ); commit "$r9" v "fix: trên nhánh khác"
out=$(run_end "$r9" t9b SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && ok "đổi nhánh → vẫn gửi" || bad "đổi nhánh → vẫn gửi"

# ================= RANH GIỚI REPORT =================
echo "  ── ranh giới report.json (chỗ khiến hệ thống mở rộng được) ──"
grep -qiE '(adaptive|contentType|attachments)' "$ROOT/hooks/session-end.sh" \
  && bad "tầng thu thập KHÔNG được biết định dạng kênh" "session-end.sh có nhắc Adaptive Card" \
  || ok "tầng thu thập không biết định dạng kênh nào"
grep -qiE '(adaptive|contentType|attachments)' "$ROOT/hooks/lib/core.sh" \
  && bad "core.sh KHÔNG được biết định dạng kênh" "core.sh có nhắc Adaptive Card" \
  || ok "core.sh không biết định dạng kênh nào"

# adapter giả: chứng minh thêm kênh mới = thêm 1 file, không sửa gì khác
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
  ok "kênh MỚI chạy được chỉ bằng cách thêm 1 file adapter"
else
  bad "kênh mới chỉ cần thêm 1 file adapter" "adapter giả không được gọi"
fi
rm -f "$ROOT/hooks/lib/adapters/faux.sh"

# ================= ADAPTER TEAMS =================
echo "  ── adapter Teams ──"
out="$WORK/payload-t2.json"
if [ -f "$out" ]; then
  body=$(/usr/bin/jq -r '.attachments[0].content.body' "$out")
  /usr/bin/jq -e '.attachments[0].contentType=="application/vnd.microsoft.card.adaptive"' "$out" >/dev/null \
    && ok "đúng envelope Adaptive Card" || bad "đúng envelope Adaptive Card"
  /usr/bin/jq -e '.attachments[0].content.body[1].facts[]|select(.title=="Commits" and .value=="2")' "$out" >/dev/null \
    && ok "đếm đúng 2 commit" || bad "đếm đúng 2 commit"
  echo "$body" | grep -q "login rate limit" && ok "mang tóm tắt tiếng Anh" || bad "mang tóm tắt tiếng Anh"
  echo "$body" | grep -q "sửa hạn mức đăng nhập" && ok "giữ câu tiếng Việt" || bad "giữ câu tiếng Việt"
  echo "$body" | grep -q "fix(auth)" && bad "tiền tố lẽ ra bị cắt" || ok "cắt tiền tố conventional-commit"
  echo "$body" | grep -q "not yet deployed to production" && ok "có cảnh báo chưa lên production" || bad "có cảnh báo chưa lên production"
else
  bad "adapter Teams" "không có payload để kiểm"
fi

# ================= BÍ MẬT =================
echo "  ── bí mật ──"
r5=$(new_repo 5); write_config "$r5"; run_end "$r5" t5a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r5" k "fix: x"
out=$(run_end "$r5" t5b SR_CLAUDE_BIN="$WORK/bin/claude-ok" SR_WEBHOOK_FOR_TEST="")
[ -z "$out" ] && ok "không lấy được khoá → không gửi" || bad "không lấy được khoá → không gửi"
logf | grep -q "không lấy được khoá" && ok "ghi nhật ký lý do thiếu khoá" || bad "ghi nhật ký lý do thiếu khoá"
if logf | grep -q "fake.invalid"; then bad "nhật ký KHÔNG được chứa URL" "URL đã lọt vào log"; else ok "URL không bao giờ lọt vào nhật ký"; fi
grep -q "fake.invalid" "$SR_CONFIG" && bad "config KHÔNG được chứa URL" || ok "config chỉ chứa handle, không chứa URL"

# ================= AN TOÀN =================
echo "  ── an toàn ──"
r6=$(new_repo 6); write_config "$r6"; run_end "$r6" t6a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r6" m "fix: x"
out=$(run_end "$r6" t6b STATUS_REPORTER_SKIP=1 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "STATUS_REPORTER_SKIP=1 → không gửi (chống đệ quy)" || bad "chống đệ quy" "vẫn gửi ⇒ NGUY CƠ LẶP VÔ HẠN"

r7=$(new_repo 7); write_config "$WORK/repo-KHAC"   # repo hiện tại không có luật
commit "$r7" n "fix: x"
out=$(run_end "$r7" t7 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "repo không có luật → không gửi (mặc định deny)" || bad "mặc định deny"

r8=$(new_repo 8); write_config "$r8"; run_end "$r8" t8a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
before=$(marker "$r8"); commit "$r8" p "fix: việc quan trọng"
run_end "$r8" t8b SR_DRY_RUN_FAIL=1 SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
[ "$before" = "$(marker "$r8")" ] && ok "gửi thất bại → mốc KHÔNG dời" || bad "gửi thất bại → mốc KHÔNG dời" "MẤT COMMIT"
out=$(run_end "$r8" t8c SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -n "$out" ] && /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "việc quan trọng" \
  && ok "lần sau báo lại đúng commit đã trượt" || bad "báo lại commit đã trượt"

r11=$(new_repo 11); write_config "$r11"; run_end "$r11" t11a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r11" s "fix(auth): sửa hạn mức"
out=$(run_end "$r11" t11b SR_CLAUDE_BIN="$WORK/bin/claude-fail")
[ -n "$out" ] && /usr/bin/jq -r '.attachments[0].content.body' "$out" | grep -q "sửa hạn mức" \
  && ok "claude lỗi → vẫn gửi bằng commit thô" || bad "claude lỗi → fallback commit thô"

d="$WORK/khong-phai-repo"; mkdir -p "$d"; write_config "$d"
out=$(run_end "$d" t12 SR_CLAUDE_BIN="$WORK/bin/claude-ok")
[ -z "$out" ] && ok "không phải repo git → không gửi" || bad "không phải repo git → không gửi"

# ================= BẢNG ĐIỀU KHIỂN =================
echo "  ── bảng điều khiển ──"
write_config "$r"
bash "$TP" status >"$WORK/st.txt" 2>&1
grep -q "ĐÍCH ĐẾN" "$WORK/st.txt" && ok "sr status chạy được" || bad "sr status chạy được" "$(head -3 "$WORK/st.txt")"
grep -q "khoá tìm thấy" "$WORK/st.txt" && ok "sr status báo có khoá mà không in giá trị" || bad "sr status báo trạng thái khoá"
grep -q "fake.invalid" "$WORK/st.txt" && bad "sr status KHÔNG được in URL" "URL hiện trên màn hình" || ok "sr status không in URL"
bash "$TP" history 5 >"$WORK/hi.txt" 2>&1
grep -qE "bỏ qua|→|✗" "$WORK/hi.txt" && ok "sr history hiện được nhật ký" || bad "sr history hiện nhật ký" "$(head -3 "$WORK/hi.txt")"
grep -q "fake.invalid" "$WORK/hi.txt" && bad "sr history KHÔNG được in URL" || ok "sr history không in URL"

# ================= KIỂM BÍ MẬT + NHẬT KÝ CHI TIẾT =================
echo "  ── kiểm bí mật trước khi nạp ──"
ADP="$ROOT/hooks/lib/adapters/teams.sh"
bash "$ADP" --validate "https://x.invalid/invoke" >/dev/null 2>&1 \
  && bad "URL thiếu query string phải bị từ chối" "lại chấp nhận" \
  || ok "URL thiếu ?api-version= bị từ chối trước khi nạp"
bash "$ADP" --validate "" >/dev/null 2>&1 && bad "URL rỗng phải bị từ chối" || ok "URL rỗng bị từ chối"
FULL="https://a.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/18/workflows/abcdef0123456789abcdef0123456789/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=0123456789012345678901234567890123456789012"
bash "$ADP" --validate "$FULL" >/dev/null 2>&1 && ok "URL đầy đủ được chấp nhận" || bad "URL đầy đủ được chấp nhận"
if bash "$ADP" --validate "$FULL" 2>&1 | grep -q "$FULL"; then
  bad "--validate KHÔNG được in lại URL" "URL bị in ra"
else ok "--validate không in lại URL, chỉ báo độ dài"; fi

echo "  ── nhật ký mang chi tiết từ adapter ──"
logf | grep -q 'DRY 202' && ok "nhật ký ghi chi tiết adapter trả về (202/run-id)" \
                          || bad "nhật ký ghi chi tiết adapter trả về" "detail rỗng"

# ================= DOCTOR + TÍNH DI ĐỘNG =================
echo "  ── doctor ──"
SRBIN="$ROOT/bin/sr"
r_ok=$(new_repo 20); write_config "$r_ok"
bash "$SRBIN" doctor >/dev/null 2>&1 && ok "config hợp lệ → doctor thoát 0" || bad "config hợp lệ → doctor thoát 0"

# Hồi quy: doctor TỪNG in ✗ rồi vẫn kết luận "không có vấn đề", vì vòng lặp chạy
# sau ống dẫn nên biến đếm nằm trong subshell và mất khi subshell kết thúc.
/usr/bin/jq '.rules[0].repo = "/khong/ton/tai"' "$SR_CONFIG" > "$WORK/bad.json" && mv "$WORK/bad.json" "$SR_CONFIG"
out_doc="$(bash "$SRBIN" doctor 2>&1)"; rc_doc=$?
echo "$out_doc" | grep -q "không tồn tại" && ok "doctor phát hiện repo không tồn tại" || bad "doctor phát hiện repo không tồn tại"
[ "$rc_doc" -ne 0 ] && ok "doctor thoát KHÁC 0 khi có vấn đề" \
  || bad "doctor thoát khác 0 khi có vấn đề" "in ✗ mà vẫn báo khoẻ — lỗi subshell tái phát"
echo "$out_doc" | grep -q "vấn đề cần sửa" && ok "doctor đếm đúng số vấn đề" || bad "doctor đếm số vấn đề"

/usr/bin/jq '.destinations.d1.secret = "keychain:khong-ton-tai-dau"' "$SR_CONFIG" > "$WORK/b2.json" && mv "$WORK/b2.json" "$SR_CONFIG"
# Hứng ra biến TRƯỚC rồi mới grep: `doctor | grep` dưới `set -o pipefail` trả mã
# của doctor (cố tình khác 0), nên `&&` hỏng dù grep có khớp.
out_key="$(bash "$SRBIN" doctor 2>&1 || true)"
case "$out_key" in
  *"sr set-secret"*) ok "doctor chỉ đúng cách sửa khi thiếu khoá" ;;
  *) bad "doctor chỉ cách sửa khi thiếu khoá" "không thấy gợi ý trong output" ;;
esac

echo "  ── tính di động ──"
r_jq=$(new_repo 21); write_config "$r_jq"
run_end "$r_jq" t21a SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
commit "$r_jq" j "fix: x"
run_end "$r_jq" t21b SR_JQ="/khong/co/jq" SR_CLAUDE_BIN="$WORK/bin/claude-ok" >/dev/null
logf | grep -q "không tìm thấy jq" \
  && ok "thiếu jq → GHI NHẬT KÝ thay vì hỏng câm" \
  || bad "thiếu jq → ghi nhật ký" "im lặng ⇒ không ai biết vì sao mất tin"
grep -rq '"/usr/bin/jq"' "$ROOT/hooks" 2>/dev/null \
  && bad "không được đóng cứng /usr/bin/jq" "còn đường dẫn cứng" \
  || ok "jq tìm động, không đóng cứng đường dẫn"

# ================= ONBOARDING =================
echo "  ── onboarding ──"
IW="$WORK/init"; mkdir -p "$IW/repo"; ( cd "$IW/repo" && git init -q . )
c1="$IW/c1.json"
SR_CONFIG="$c1" bash "$SRBIN" init --repo "$IW/repo" --dest demo >/dev/null 2>&1
[ -f "$c1" ] && ok "sr init sinh được config" || bad "sr init sinh được config"
/usr/bin/jq -e '.destinations.demo.secret == "keychain:demo"' "$c1" >/dev/null 2>&1 \
  && ok "config trỏ secret bằng handle, không nhúng giá trị" || bad "config dùng handle"
/usr/bin/jq -e --arg r "$IW/repo" '(.rules[0].repo | test("repo$"))' "$c1" >/dev/null 2>&1 \
  && ok "sr init ghi đúng repo vào luật" || bad "sr init ghi đúng repo"
[ "$(stat -f '%Lp' "$c1" 2>/dev/null || stat -c '%a' "$c1")" = "600" ] \
  && ok "config đặt quyền 600" || bad "config đặt quyền 600"

# Gõ sai kiểu kênh là nguyên nhân "im lặng không gửi" khó lần nhất — phải chặn
# ngay lúc init chứ không để phát hiện sau vài ngày không thấy tin.
SR_CONFIG="$IW/c2.json" bash "$SRBIN" init --repo "$IW/repo" --dest x --type khong-co >/dev/null 2>&1 \
  && bad "kiểu kênh không tồn tại phải bị từ chối" "vẫn ghi config" \
  || ok "kiểu kênh không tồn tại bị từ chối ngay lúc init"
[ -f "$IW/c2.json" ] && bad "init hỏng thì KHÔNG được để lại config" || ok "init hỏng không để lại config nửa vời"

SR_CONFIG="$c1" bash "$SRBIN" init --repo "$IW/repo" --dest demo >/dev/null 2>&1 \
  && bad "init lần hai phải từ chối" "ghi đè config đang dùng" \
  || ok "init không ghi đè config đã có"

# Hai hiểu nhầm tốn thời gian nhất phải được nói ngay lúc test thành công.
# Cần khoá CÓ THẬT thì `sr test` mới vào được nhánh thành công — đổi handle sang
# env: để không phải đụng Keychain thật.
/usr/bin/jq '.destinations.demo.secret = "env:SR_WEBHOOK_FOR_TEST"' "$c1" > "$IW/c1b.json" && mv "$IW/c1b.json" "$c1"
out_t="$(SR_CONFIG="$c1" SR_DRY_RUN_FILE="$IW/p.json" bash "$SRBIN" test demo 2>&1 || true)"
case "$out_t" in
  *"KẾ TIẾP"*) ok "sr test cảnh báo hook nạp từ phiên sau" ;;
  *) bad "sr test cảnh báo hook nạp từ phiên sau" "không thấy cảnh báo" ;;
esac
case "$out_t" in
  *"ĐẶT MỐC"*) ok "sr test cảnh báo phiên đầu chỉ đặt mốc" ;;
  *) bad "sr test cảnh báo phiên đầu chỉ đặt mốc" "không thấy cảnh báo" ;;
esac

# Slash command phải cấm dán URL vào chat — đó là lỗi đã thật sự xảy ra một lần.
CMD="$ROOT/commands/setup.md"
[ -f "$CMD" ] && ok "có slash command /status-reporter:setup" || bad "có slash command setup"
grep -q "KHÔNG được tự làm hộ" "$CMD" 2>/dev/null && grep -q "dán webhook URL vào khung chat" "$CMD" \
  && ok "slash command cấm dán URL vào chat" || bad "slash command cấm dán URL vào chat"

echo
printf 'Kết quả: %d đạt, %d hỏng\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
