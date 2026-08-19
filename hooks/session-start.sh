#!/usr/bin/env bash
# Ghi mốc đầu phiên: HEAD hiện tại + thời điểm. Cuối phiên lấy hai giá trị này
# để biết những commit nào là của phiên vừa rồi.
#
# Hook này không bao giờ được làm hỏng việc mở phiên — mọi đường đều exit 0.
set -uo pipefail

[ "${TEAMS_PROGRESS_SKIP:-}" = "1" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

input=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$input" | "$TP_JQ" -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | "$TP_JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$session_id" ] && [ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

state_dir="$(tp_state_dir)"
mkdir -p "$state_dir" 2>/dev/null || exit 0
printf '%s %s\n' "$sha" "$(date +%s)" > "$state_dir/$session_id" 2>/dev/null || true

# Dọn mốc cũ hơn 7 ngày: phiên bị kill không chạy SessionEnd nên file ở lại mãi.
find "$state_dir" -type f -mtime +7 -delete 2>/dev/null || true
exit 0
