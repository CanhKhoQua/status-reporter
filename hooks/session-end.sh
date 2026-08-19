#!/usr/bin/env bash
# Cuối phiên: gom commit chưa báo → dựng report.json → giao cho các đích đã
# cấu hình cho repo này.
#
# File này KHÔNG biết Teams là gì. Nó dừng ở report.json; việc dựng payload và
# gửi thuộc về lib/adapters/<type>.sh.
#
# Im lặng thoát trong mọi trường hợp không chắc chắn — nhưng luôn GHI NHẬT KÝ
# lý do, để "sao hôm nay không có tin?" luôn có câu trả lời.
set -uo pipefail

# Chống đệ quy: `claude -p` trong tp_summarize cũng là một phiên Claude Code,
# kết thúc nó lại kích hoạt chính hook này.
[ "${TEAMS_PROGRESS_SKIP:-}" = "1" ] && exit 0

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

TP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
export TP_LIB_DIR
# shellcheck source=lib/core.sh
. "$TP_LIB_DIR/core.sh"

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | "$TP_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

repo_path="$(tp_realpath "$cwd")"
repo_name="$(basename "$repo_path")"

# Repo không có luật trong config = không gửi đi đâu. Mặc định KHÔNG gửi: thà
# im lặng còn hơn đăng nhầm công việc của một project khác vào kênh công ty.
dests="$(tp_dests_for_repo "$repo_path" session_end)"
[ -n "$dests" ] || exit 0

head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0
marker="$(tp_marker_file "$repo_path")"
mkdir -p "$(dirname "$marker")" 2>/dev/null || exit 0

# Lần đầu ở repo này: đặt mốc rồi thôi. "Chưa từng báo" lúc này nghĩa là toàn bộ
# lịch sử repo — không ai muốn đọc cái đó.
if [ ! -f "$marker" ]; then
  printf '%s\n' "$head_sha" > "$marker"
  tp_log_event "$repo_name" "-" "skipped" "lần đầu ở repo, chỉ đặt mốc"
  exit 0
fi

read -r last_sha < "$marker"
if [ "$last_sha" = "$head_sha" ]; then
  tp_log_event "$repo_name" "-" "skipped" "không có commit mới"
  exit 0
fi

commits="$(tp_unreported_commits "$last_sha")"
if [ -z "$commits" ]; then
  # HEAD đổi nhưng không có commit mới (checkout, reset). Dời mốc theo để lần
  # sau khỏi rà lại.
  printf '%s\n' "$head_sha" > "$marker"
  tp_log_event "$repo_name" "-" "skipped" "HEAD đổi nhưng không có commit mới"
  exit 0
fi

clean="$(printf '%s\n' "$commits" | tp_clean_subject)"
summary="$(tp_summarize "$clean")"
# claude lỗi hoặc quá giờ → dùng danh sách commit thô. Thà thô còn hơn mất tin.
[ -n "$summary" ] || summary="$clean"

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
report="$(tp_build_report session_end "$repo_name" "$repo_path" "$branch" "$summary" "$clean")"
[ -n "$report" ] || exit 0

# Mốc CHỈ dời khi có ít nhất một đích nhận được. Dời trước là mất trắng những
# commit này nếu mọi đích đều từ chối.
any_ok=0
while IFS= read -r dest; do
  [ -n "$dest" ] || continue
  tp_deliver "$dest" "$report" && any_ok=1
done <<< "$dests"

[ "$any_ok" = "1" ] && printf '%s\n' "$head_sha" > "$marker"
exit 0
