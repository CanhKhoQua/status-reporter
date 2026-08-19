#!/usr/bin/env bash
# Adapter Microsoft Teams.
#
# Hợp đồng chung cho MỌI adapter:
#   stdin  : report.json (xem sr_build_report trong core.sh)
#   $1     : bí mật của đích (ở đây là URL webhook)
#   thoát 0: đã gửi thành công
#
# Thêm kênh mới = thêm một file cạnh file này theo đúng hợp đồng trên. Không
# đụng vào core.sh, không đụng vào session-end.sh, không đụng adapter khác.
set -uo pipefail

# Bình thường core.sh xuất sẵn SR_JQ; dòng dự phòng dành cho lúc adapter được
# gọi trực tiếp (chế độ --validate, hoặc kiểm thử).
JQ="${SR_JQ:-$(command -v jq 2>/dev/null || printf '/usr/bin/jq')}"
# Chế độ kiểm bí mật: `teams.sh --validate <url>`. Nhờ nó mà `sr set-secret`
# bắt được URL thiếu query string TRƯỚC khi nạp, thay vì để người dùng phát hiện
# qua một cú HTTP 400 khó hiểu vài phút sau.
if [ "${1:-}" = "--validate" ]; then
  u="${2:-}"
  [ -n "$u" ] || { echo "rỗng"; exit 1; }
  case "$u" in https://*) ;; *) echo "không bắt đầu bằng https://"; exit 1 ;; esac
  printf '%s' "$u" | grep -q 'api-version=' || { echo "thiếu ?api-version= — URL bị cắt mất query string"; exit 1; }
  printf '%s' "$u" | grep -q 'sig='         || { echo "thiếu &sig= — URL bị cắt mất chữ ký"; exit 1; }
  [ "${#u}" -ge 200 ] || { echo "chỉ ${#u} ký tự, quá ngắn (URL đủ thường 250-700)"; exit 1; }
  echo "hợp lệ (${#u} ký tự)"; exit 0
fi

webhook="${1:-}"
[ -n "$webhook" ] || exit 2
report="$(cat)"
[ -n "$report" ] || exit 2

# Adaptive Card 1.5 trong envelope của Power Automate Workflows. Định dạng
# MessageCard / O365 connector cũ đã bị khai tử: gửi theo nó nhận 202 rồi rơi
# vào hư vô — thành công giả, không ai thấy tin.
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
                   + (if .count > 15 then "\n• … và " + ((.count - 15)|tostring) + " commit nữa" else "" end)),
            wrap: true, isSubtle: true, size: "Small", spacing: "Small" },
          { type: "TextBlock",
            text: (if .state == "test" then "🧪 Tin kiểm tra — vui lòng bỏ qua."
                   else "⚠️ Work in progress — not yet deployed to production." end),
            wrap: true, size: "Small", color: "Warning", spacing: "Medium" }
        ]
      }
    }]
  }')"
[ -n "$payload" ] || exit 3

# Chế độ chạy khô cho kiểm thử: đi trọn đường dựng payload mà không chạm mạng.
if [ -n "${SR_DRY_RUN_FILE:-}" ]; then
  printf '%s' "$payload" > "$SR_DRY_RUN_FILE"
  [ "${SR_DRY_RUN_FAIL:-}" = "1" ] && exit 1
  printf "DRY 202 · run=fake"
  exit 0
fi

# curl KHÔNG coi 4xx/5xx là lỗi — phải tự kiểm mã trả về, nếu không thì thất bại
# hoàn toàn vô hình. Thông báo lỗi chỉ nói mã HTTP, không bao giờ nói URL.
#
# 202 KHÁC 200. Power Automate trả 202 ngay khi NHẬN yêu cầu rồi mới chạy flow
# bất đồng bộ — action "Post card" có thể hỏng sau đó mà webhook không hề biết.
# Ghi rõ sự khác biệt này vào nhật ký, kèm run-id để tra cứu, thay vì báo "đã
# gửi" cho một thứ mình chỉ biết là "đã nhận".
hdr="$(mktemp)"
trap 'rm -f "$hdr"' EXIT
code=$(printf '%s' "$payload" | curl -sS -D "$hdr" -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary @- \
  --max-time 20 "$webhook" 2>/dev/null) || code="000"
run_id=$(grep -i '^x-ms-workflow-run-id:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}')
case "$code" in
  202) printf 'HTTP 202 đã nhận (chưa xác nhận đăng)%s' "${run_id:+ · run=$run_id}"; exit 0 ;;
  2*)  printf 'HTTP %s%s' "$code" "${run_id:+ · run=$run_id}"; exit 0 ;;
  *)   echo "[status-reporter] kênh từ chối: HTTP $code" >&2; exit 1 ;;
esac
