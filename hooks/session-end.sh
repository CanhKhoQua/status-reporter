#!/usr/bin/env bash
# Cuối phiên: gửi một tin gồm những commit CHƯA từng được báo cho repo này.
#
# Không có SessionStart. Mốc được nhớ theo repo và chỉ dời khi gửi thành công,
# nên phiên bị kill, máy sập, hay cài plugin giữa chừng đều không làm mất commit.
#
# Im lặng thoát trong mọi trường hợp không chắc chắn: một tin sai gửi vào kênh
# chung tệ hơn nhiều so với không có tin.
set -uo pipefail

# Chống đệ quy: `claude -p` bên dưới cũng là một phiên Claude Code, kết thúc nó
# lại kích hoạt chính hook này. Xem tp_summarize trong lib.sh.
[ "${TEAMS_PROGRESS_SKIP:-}" = "1" ] && exit 0

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

MAX_LINES=15

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | "$TP_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Không có webhook trong .env.local = project này không bật plugin. Đây là toàn
# bộ cơ chế giới hạn phạm vi, không phải lỗi.
webhook="$(tp_read_webhook "$cwd")"
[ -n "$webhook" ] || exit 0

head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0
marker="$(tp_marker_file "$cwd")"
mkdir -p "$(dirname "$marker")" 2>/dev/null || exit 0

# Lần đầu ở repo này: đặt mốc rồi thôi. Không báo, vì "chưa từng báo" lúc này
# nghĩa là toàn bộ lịch sử repo — không ai muốn đọc cái đó.
if [ ! -f "$marker" ]; then
  printf '%s\n' "$head_sha" > "$marker"
  exit 0
fi

read -r last_sha < "$marker"
[ "$last_sha" = "$head_sha" ] && exit 0

commits="$(tp_unreported_commits "$last_sha")"
if [ -z "$commits" ]; then
  # HEAD đổi nhưng không có commit mới nào (đổi nhánh, reset...). Dời mốc theo
  # để lần sau không phải rà lại.
  printf '%s\n' "$head_sha" > "$marker"
  exit 0
fi

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

# Mốc CHỈ dời khi gửi thành công. Dời trước là mất trắng những commit này nếu
# Teams từ chối payload.
if tp_post "$webhook" "$payload"; then
  printf '%s\n' "$head_sha" > "$marker"
fi
exit 0
