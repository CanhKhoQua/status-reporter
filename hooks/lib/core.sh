#!/usr/bin/env bash
# Tầng lõi: cấu hình, bí mật, định tuyến, nhật ký.
#
# KHÔNG có gì ở đây biết Teams là gì. Việc dựng payload nằm trong
# lib/adapters/<type>.sh — thêm một kênh mới là thêm một file ở đó, không sửa
# file này.
#
# LUẬT BẤT BIẾN: giá trị bí mật không bao giờ được in ra stdout/stderr, không
# bao giờ vào nhật ký, không bao giờ nằm trong thông báo lỗi. Lỗi chỉ nói mã HTTP
# và tên đích. Đây là thuộc tính của code, không phải lời hứa của người viết.

TP_JQ="${TP_JQ:-/usr/bin/jq}"

tp_config_file() { printf '%s' "${TP_CONFIG:-$HOME/.config/teams-progress/config.json}"; }
tp_state_dir()   { printf '%s' "${TP_STATE_DIR:-$HOME/.local/state/teams-progress}"; }
tp_log_file()    { printf '%s' "$(tp_state_dir)/log.jsonl"; }

tp_config() {
  local f; f="$(tp_config_file)"
  [ -f "$f" ] || return 1
  "$TP_JQ" -e . "$f" 2>/dev/null
}

# Bí mật được tham chiếu bằng HANDLE, không bao giờ nằm trong config. Nhờ vậy
# config là file thường: commit được, gửi cho đồng nghiệp được, dán vào chat
# được, mà không lộ gì.
#
#   keychain:tên   → Keychain macOS, service=teams-progress, account=tên
#   env:TÊN_BIẾN   → biến môi trường (dùng cho CI hoặc test)
tp_resolve_secret() {
  local handle="$1"
  case "$handle" in
    keychain:*)
      security find-generic-password -s teams-progress -a "${handle#keychain:}" -w 2>/dev/null
      ;;
    env:*)
      eval "printf '%s' \"\${${handle#env:}:-}\""
      ;;
    *) return 1 ;;
  esac
}

# Có khoá hay không — trả lời được mà KHÔNG in giá trị ra. `tp status` cần biết
# điều này, và đây là cách duy nhất hỏi mà không làm lộ.
tp_secret_present() {
  local v; v="$(tp_resolve_secret "$1")" || return 1
  [ -n "$v" ]
}

tp_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null; }

# Đích nào nhận báo cáo của repo này. Luật khớp theo đường dẫn tuyệt đối, nên
# repo không có luật = không gửi đi đâu. Mặc định là KHÔNG gửi.
tp_dests_for_repo() {
  local repo="$1" event="$2" cfg
  cfg="$(tp_config)" || return 0
  printf '%s' "$cfg" | "$TP_JQ" -r --arg repo "$repo" --arg ev "$event" '
    (.rules // [])
    | map(select((.repo | sub("^~"; env.HOME)) == $repo and ((.on // "session_end") == $ev)))
    | map(.to // []) | flatten | unique | .[]'
}

tp_dest_field() {
  local name="$1" field="$2" cfg
  cfg="$(tp_config)" || return 1
  printf '%s' "$cfg" | "$TP_JQ" -r --arg n "$name" --arg f "$field" \
    '.destinations[$n][$f] // empty'
}

# Mốc "đã báo tới đâu", nhớ THEO REPO chứ không theo phiên: phiên bị kill, máy
# sập, hay cài plugin giữa chừng đều không làm mất commit.
tp_marker_file() {
  local key; key=$(printf '%s' "$1" | shasum | cut -c1-16)
  printf '%s/markers/%s' "$(tp_state_dir)" "$key"
}

# Nhật ký để trả lời câu hỏi sẽ được hỏi nhiều nhất: "sao hôm nay không thấy
# tin nào?". Không có nó thì mọi nhánh thoát im lặng đều không để lại dấu vết.
tp_log() {
  local f; f="$(tp_log_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$f" 2>/dev/null || true
}

tp_log_event() {
  local repo="$1" dest="$2" status="$3" detail="$4" count="${5:-0}"
  tp_log "$("$TP_JQ" -nc --arg at "$(tp_iso_now)" --arg repo "$repo" --arg dest "$dest" \
    --arg status "$status" --arg detail "$detail" --argjson count "$count" \
    '{at:$at, repo:$repo, dest:$dest, status:$status, detail:$detail, count:$count}')"
}

tp_iso_now() { TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%dT%H:%M:%S+07:00'; }
tp_vn_time() { TZ=Asia/Ho_Chi_Minh date '+%d %b %Y, %H:%M'; }

# Bỏ tiền tố conventional-commit. Manager đọc "fix(auth):" không ra nghĩa gì;
# phần sau dấu hai chấm mới là câu viết cho người đọc.
tp_clean_subject() { sed -E 's/^[a-z]+(\([^)]*\))?!?: *//'; }

# Commit chưa báo: mọi thứ HEAD với tới mà mốc cũ không với tới.
#
# `--not <sha>` đúng cả khi đổi nhánh hay rebase — khác với khoảng `a..b`, nó
# không đòi mốc phải là tổ tiên của HEAD. Chặn thêm --since để lỡ checkout sang
# nhánh cũ thì cũng không đổ cả lịch sử tháng trước vào kênh.
tp_unreported_commits() {
  local last="$1"
  [ -n "$last" ] && git cat-file -e "${last}^{commit}" 2>/dev/null || return 0
  git log --no-merges --format='%s' --since="7 days ago" HEAD --not "$last" 2>/dev/null
}

# TEAMS_PROGRESS_SKIP=1 là chốt chống đệ quy: `claude -p` cũng là một phiên
# Claude Code, kết thúc nó lại kích hoạt chính hook này. Thiếu dòng đó là script
# tự nhân bản đến khi phải giết tiến trình bằng tay.
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

# Tài liệu trung lập với kênh. ĐÂY là ranh giới khiến hệ thống mở rộng được:
# adapter nhận JSON này, không nhận biến rời rạc. Thêm Slack = thêm một file
# đọc đúng JSON này.
tp_build_report() {
  local event="$1" repo_name="$2" repo_path="$3" branch="$4" summary="$5" commits="$6"
  "$TP_JQ" -n \
    --arg event "$event" --arg repo "$repo_name" --arg path "$repo_path" \
    --arg branch "$branch" --arg summary "$summary" --arg at "$(tp_iso_now)" \
    --arg when "$(tp_vn_time)" --arg commits "$commits" '
    {
      event: $event, repo: $repo, repo_path: $path, branch: $branch,
      commits: ($commits | split("\n") | map(select(length > 0))),
      summary: $summary, at: $at, when: $when,
      state: "work_in_progress"
    } | .count = (.commits | length)'
}

# Giao một báo cáo tới một đích. Tra kiểu → gọi adapter tương ứng → ghi nhật ký.
# Hàm này không biết gì về Teams, Slack hay bất kỳ kênh nào.
tp_deliver() {
  local dest="$1" report="$2" type secret_handle secret adapter rc repo count
  repo="$(printf '%s' "$report" | "$TP_JQ" -r .repo)"
  count="$(printf '%s' "$report" | "$TP_JQ" -r .count)"
  type="$(tp_dest_field "$dest" type)"
  secret_handle="$(tp_dest_field "$dest" secret)"
  if [ -z "$type" ] || [ -z "$secret_handle" ]; then
    tp_log_event "$repo" "$dest" "error" "đích chưa cấu hình đủ"; return 1
  fi
  adapter="${TP_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/adapters/${type}.sh"
  if [ ! -f "$adapter" ]; then
    tp_log_event "$repo" "$dest" "error" "không có adapter cho kiểu '$type'"; return 1
  fi
  secret="$(tp_resolve_secret "$secret_handle")"
  if [ -z "$secret" ]; then
    tp_log_event "$repo" "$dest" "error" "không lấy được khoá từ $secret_handle"; return 1
  fi
  # URL đi thẳng vào adapter qua tham số, không qua biến nào bị in ra.
  printf '%s' "$report" | bash "$adapter" "$secret"
  rc=$?
  if [ $rc -eq 0 ]; then tp_log_event "$repo" "$dest" "sent" "" "$count"
  else tp_log_event "$repo" "$dest" "failed" "adapter trả mã $rc" "$count"; fi
  return $rc
}
