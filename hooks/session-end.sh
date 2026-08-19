#!/usr/bin/env bash
# Cuối phiên: gom commit của phiên, tóm tắt, gửi một tin lên Teams.
#
# Im lặng thoát trong mọi trường hợp không chắc chắn. Một tin sai gửi vào kênh
# chung tệ hơn nhiều so với việc không có tin.
set -uo pipefail

# Chống đệ quy — xem tp_summarize trong lib.sh.
[ "${TEAMS_PROGRESS_SKIP:-}" = "1" ] && exit 0

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

MAX_LINES=15

input=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$input" | "$TP_JQ" -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | "$TP_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$session_id" ] && [ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Không có webhook trong .env.local = project này không bật plugin. Đây là cơ
# chế giới hạn phạm vi, không phải lỗi.
webhook="$(tp_read_webhook "$cwd")"
[ -n "$webhook" ] || exit 0

state_file="$(tp_state_dir)/$session_id"
[ -f "$state_file" ] || exit 0
read -r base_sha base_epoch < "$state_file"
rm -f "$state_file"
[ -n "${base_epoch:-}" ] || exit 0

commits="$(tp_commits_since "$base_sha" "$base_epoch")"
[ -n "$commits" ] || exit 0   # phiên không commit gì → không có gì để báo

total=$(printf '%s\n' "$commits" | grep -c . || true)
clean=$(printf '%s\n' "$commits" | tp_clean_subject)
details=$(printf '%s\n' "$clean" | head -n "$MAX_LINES" | sed 's/^/• /')
if [ "$total" -gt "$MAX_LINES" ]; then
  details="$details
• … và $((total - MAX_LINES)) commit nữa"
fi

summary="$(tp_summarize "$clean")"
# claude lỗi hoặc quá giờ → gửi danh sách thô. Thà thô còn hơn im.
[ -n "$summary" ] || summary="$clean"

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
repo=$(basename "$cwd")

payload="$(tp_build_payload "$repo" "$branch" "$total" "$(tp_vn_time)" "$summary" "$details")"
[ -n "$payload" ] || exit 0

tp_post "$webhook" "$payload" || true
exit 0
