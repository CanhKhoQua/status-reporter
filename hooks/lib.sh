#!/usr/bin/env bash
# Hàm dùng chung cho session-start.sh và session-end.sh.
#
# Mọi hàm ở đây đều phải chạy được ngoài Claude Code — tests/run-tests.sh nạp
# đúng file này. Đó là lý do không hàm nào đọc stdin hay gọi `exit`.

TP_JQ="${TP_JQ:-/usr/bin/jq}"

tp_state_dir() {
  printf '%s' "${TP_STATE_DIR:-$HOME/.cache/teams-progress}"
}

# URL webhook lấy từ .env.local của CHÍNH project đang mở. Đây cũng là cơ chế
# giới hạn phạm vi: project nào không có biến này thì hook im lặng thoát, nên
# không cần whitelist đường dẫn.
#
# Không bao giờ in giá trị ra log — nó là thông tin xác thực, ai có URL là đăng
# được vào kênh.
tp_read_webhook() {
  local dir="$1" f line val
  for f in "$dir/.env.local" "$dir/.env"; do
    [ -f "$f" ] || continue
    line=$(grep -m1 '^TEAMS_WEBHOOK_URL=' "$f" 2>/dev/null) || true
    [ -n "$line" ] || continue
    val="${line#TEAMS_WEBHOOK_URL=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "$val"
    return 0
  done
  printf '%s' "${TEAMS_PROGRESS_WEBHOOK_URL:-}"
}

# Danh sách commit của phiên.
#
# Đường chính là khoảng base..HEAD. Nhưng nếu trong phiên có đổi nhánh hoặc
# rebase thì base không còn là tổ tiên của HEAD, lúc đó khoảng đó vô nghĩa —
# rơi về lọc theo thời điểm mở phiên. Không có nhánh thứ hai này thì mọi phiên
# có checkout đều mất báo cáo, mà đổi nhánh là chuyện hằng ngày.
tp_commits_since() {
  local base_sha="$1" base_epoch="$2"
  if [ -n "$base_sha" ] && git cat-file -e "${base_sha}^{commit}" 2>/dev/null &&
     git merge-base --is-ancestor "$base_sha" HEAD 2>/dev/null; then
    git log --no-merges --format='%s' "${base_sha}..HEAD" 2>/dev/null
  else
    git log --no-merges --format='%s' --since="@${base_epoch}" 2>/dev/null
  fi
}

# Bỏ tiền tố conventional-commit. Manager đọc "fix(auth):" không ra nghĩa gì,
# phần sau dấu hai chấm mới là câu tiếng Việt anh viết cho người đọc.
tp_clean_subject() {
  sed -E 's/^[a-z]+(\([^)]*\))?!?: *//'
}

# Tóm tắt bằng tiếng Anh. Nếu claude lỗi/quá giờ thì trả chuỗi rỗng — bên gọi
# tự rơi về danh sách commit thô, thà thô còn hơn mất tin.
#
# TEAMS_PROGRESS_SKIP=1 là chốt chống đệ quy: `claude -p` cũng là một phiên
# Claude Code, kết thúc nó lại kích hoạt SessionEnd của chính plugin này. Thiếu
# dòng đó là script tự nhân bản đến khi phải giết tiến trình bằng tay.
tp_summarize() {
  local commits="$1" bin out
  bin="${TP_CLAUDE_BIN:-claude}"
  command -v "$bin" >/dev/null 2>&1 || return 0
  out=$(TEAMS_PROGRESS_SKIP=1 "$bin" -p --model haiku "$(cat <<PROMPT
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

# Adaptive Card 1.5 trong envelope của Power Automate Workflows. Định dạng
# MessageCard / O365 connector cũ đã bị khai tử, gửi theo nó là 202 rồi rơi vào
# hư vô.
tp_build_payload() {
  local repo="$1" branch="$2" count="$3" when="$4" summary="$5" details="$6"
  "$TP_JQ" -n \
    --arg repo "$repo" --arg branch "$branch" --arg count "$count" \
    --arg when "$when" --arg summary "$summary" --arg details "$details" '
    {
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.5",
          body: [
            { type: "TextBlock", text: ("🔧 Development update — " + $when),
              weight: "Bolder", size: "Medium", wrap: true },
            { type: "FactSet", facts: [
                { title: "Repo",    value: $repo },
                { title: "Branch",  value: $branch },
                { title: "Commits", value: $count }
            ]},
            { type: "TextBlock", text: $summary, wrap: true, spacing: "Medium" },
            { type: "TextBlock", text: $details, wrap: true, isSubtle: true,
              size: "Small", spacing: "Small" },
            { type: "TextBlock",
              text: "⚠️ Work in progress — not yet deployed to production.",
              wrap: true, size: "Small", color: "Warning", spacing: "Medium" }
          ]
        }
      }]
    }'
}

# TP_DRY_RUN_FILE cho phép test chạy trọn đường đi mà không chạm mạng.
tp_post() {
  local webhook="$1" payload="$2" code
  if [ -n "${TP_DRY_RUN_FILE:-}" ]; then
    printf '%s' "$payload" > "$TP_DRY_RUN_FILE"
    return 0
  fi
  code=$(printf '%s' "$payload" | curl -sS -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' --data-binary @- \
    --max-time 20 "$webhook" 2>/dev/null) || code="000"
  # curl không coi 4xx/5xx là lỗi, phải tự kiểm mã trả về — nếu không thì thất
  # bại hoàn toàn vô hình.
  case "$code" in
    2*) return 0 ;;
    *)  echo "[teams-progress] gửi thất bại: HTTP $code" >&2; return 1 ;;
  esac
}

# Giờ VN, cố định UTC+7. Máy dev ở Mỹ nên tuyệt đối không dùng giờ local.
tp_vn_time() {
  TZ=Asia/Ho_Chi_Minh date '+%d %b %Y, %H:%M'
}
