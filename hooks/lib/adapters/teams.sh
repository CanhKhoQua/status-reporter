#!/usr/bin/env bash
# Adapter Microsoft Teams.
#
# Hợp đồng chung cho MỌI adapter:
#   stdin  : report.json (xem tp_build_report trong core.sh)
#   $1     : bí mật của đích (ở đây là URL webhook)
#   thoát 0: đã gửi thành công
#
# Thêm kênh mới = thêm một file cạnh file này theo đúng hợp đồng trên. Không
# đụng vào core.sh, không đụng vào session-end.sh, không đụng adapter khác.
set -uo pipefail

JQ="${TP_JQ:-/usr/bin/jq}"
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
if [ -n "${TP_DRY_RUN_FILE:-}" ]; then
  printf '%s' "$payload" > "$TP_DRY_RUN_FILE"
  [ "${TP_DRY_RUN_FAIL:-}" = "1" ] && exit 1
  exit 0
fi

# curl KHÔNG coi 4xx/5xx là lỗi — phải tự kiểm mã trả về, nếu không thì thất bại
# hoàn toàn vô hình. Thông báo lỗi chỉ nói mã HTTP, không bao giờ nói URL.
code=$(printf '%s' "$payload" | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary @- \
  --max-time 20 "$webhook" 2>/dev/null) || code="000"
case "$code" in
  2*) exit 0 ;;
  *)  echo "[teams-progress] Teams từ chối: HTTP $code" >&2; exit 1 ;;
esac
