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

SR_JQ="${SR_JQ:-/usr/bin/jq}"

sr_config_file() { printf '%s' "${SR_CONFIG:-$HOME/.config/status-reporter/config.json}"; }
sr_state_dir()   { printf '%s' "${SR_STATE_DIR:-$HOME/.local/state/status-reporter}"; }
sr_log_file()    { printf '%s' "$(sr_state_dir)/log.jsonl"; }

sr_config() {
  local f; f="$(sr_config_file)"
  [ -f "$f" ] || return 1
  "$SR_JQ" -e . "$f" 2>/dev/null
}

# Bí mật được tham chiếu bằng HANDLE, không bao giờ nằm trong config. Nhờ vậy
# config là file thường: commit được, gửi cho đồng nghiệp được, dán vào chat
# được, mà không lộ gì.
#
#   keychain:tên   → Keychain macOS, service=status-reporter, account=tên
#   env:TÊN_BIẾN   → biến môi trường (dùng cho CI hoặc test)
sr_resolve_secret() {
  local handle="$1"
  case "$handle" in
    keychain:*)
      security find-generic-password -s status-reporter -a "${handle#keychain:}" -w 2>/dev/null
      ;;
    env:*)
      eval "printf '%s' \"\${${handle#env:}:-}\""
      ;;
    *) return 1 ;;
  esac
}

# Có khoá hay không — trả lời được mà KHÔNG in giá trị ra. `sr status` cần biết
# điều này, và đây là cách duy nhất hỏi mà không làm lộ.
sr_secret_present() {
  local v; v="$(sr_resolve_secret "$1")" || return 1
  [ -n "$v" ]
}

sr_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null; }

# Đích nào nhận báo cáo của repo này. Luật khớp theo đường dẫn tuyệt đối, nên
# repo không có luật = không gửi đi đâu. Mặc định là KHÔNG gửi.
sr_dests_for_repo() {
  local repo="$1" event="$2" cfg
  cfg="$(sr_config)" || return 0
  printf '%s' "$cfg" | "$SR_JQ" -r --arg repo "$repo" --arg ev "$event" '
    (.rules // [])
    | map(select((.repo | sub("^~"; env.HOME)) == $repo and ((.on // "session_end") == $ev)))
    | map(.to // []) | flatten | unique | .[]'
}

sr_dest_field() {
  local name="$1" field="$2" cfg
  cfg="$(sr_config)" || return 1
  printf '%s' "$cfg" | "$SR_JQ" -r --arg n "$name" --arg f "$field" \
    '.destinations[$n][$f] // empty'
}

# Mốc "đã báo tới đâu", nhớ THEO REPO chứ không theo phiên: phiên bị kill, máy
# sập, hay cài plugin giữa chừng đều không làm mất commit.
sr_marker_file() {
  local key; key=$(printf '%s' "$1" | shasum | cut -c1-16)
  printf '%s/markers/%s' "$(sr_state_dir)" "$key"
}

# Nhật ký để trả lời câu hỏi sẽ được hỏi nhiều nhất: "sao hôm nay không thấy
# tin nào?". Không có nó thì mọi nhánh thoát im lặng đều không để lại dấu vết.
sr_log() {
  local f; f="$(sr_log_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$f" 2>/dev/null || true
}

sr_log_event() {
  local repo="$1" dest="$2" status="$3" detail="$4" count="${5:-0}"
  sr_log "$("$SR_JQ" -nc --arg at "$(sr_iso_now)" --arg repo "$repo" --arg dest "$dest" \
    --arg status "$status" --arg detail "$detail" --argjson count "$count" \
    '{at:$at, repo:$repo, dest:$dest, status:$status, detail:$detail, count:$count}')"
}

sr_iso_now() { TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%dT%H:%M:%S+07:00'; }
sr_vn_time() { TZ=Asia/Ho_Chi_Minh date '+%d %b %Y, %H:%M'; }

# Bỏ tiền tố conventional-commit. Manager đọc "fix(auth):" không ra nghĩa gì;
# phần sau dấu hai chấm mới là câu viết cho người đọc.
sr_clean_subject() { sed -E 's/^[a-z]+(\([^)]*\))?!?: *//'; }

# Commit chưa báo: mọi thứ HEAD với tới mà mốc cũ không với tới.
#
# `--not <sha>` đúng cả khi đổi nhánh hay rebase — khác với khoảng `a..b`, nó
# không đòi mốc phải là tổ tiên của HEAD. Chặn thêm --since để lỡ checkout sang
# nhánh cũ thì cũng không đổ cả lịch sử tháng trước vào kênh.
sr_unreported_commits() {
  local last="$1"
  [ -n "$last" ] && git cat-file -e "${last}^{commit}" 2>/dev/null || return 0
  git log --no-merges --format='%s' --since="7 days ago" HEAD --not "$last" 2>/dev/null
}

# STATUS_REPORTER_SKIP=1 là chốt chống đệ quy: `claude -p` cũng là một phiên
# Claude Code, kết thúc nó lại kích hoạt chính hook này. Thiếu dòng đó là script
# tự nhân bản đến khi phải giết tiến trình bằng tay.
sr_summarize() {
  local commits="$1" bin out
  bin="${SR_CLAUDE_BIN:-claude}"
  command -v "$bin" >/dev/null 2>&1 || return 0
  out=$(STATUS_REPORTER_SKIP=1 "$bin" -p --model haiku "$(cat <<PROMPT
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
sr_build_report() {
  local event="$1" repo_name="$2" repo_path="$3" branch="$4" summary="$5" commits="$6"
  "$SR_JQ" -n \
    --arg event "$event" --arg repo "$repo_name" --arg path "$repo_path" \
    --arg branch "$branch" --arg summary "$summary" --arg at "$(sr_iso_now)" \
    --arg when "$(sr_vn_time)" --arg commits "$commits" '
    {
      event: $event, repo: $repo, repo_path: $path, branch: $branch,
      commits: ($commits | split("\n") | map(select(length > 0))),
      summary: $summary, at: $at, when: $when,
      state: "work_in_progress"
    } | .count = (.commits | length)'
}

# Giao một báo cáo tới một đích. Tra kiểu → gọi adapter tương ứng → ghi nhật ký.
# Hàm này không biết gì về Teams, Slack hay bất kỳ kênh nào.
sr_deliver() {
  local dest="$1" report="$2" type secret_handle secret adapter rc repo count
  repo="$(printf '%s' "$report" | "$SR_JQ" -r .repo)"
  count="$(printf '%s' "$report" | "$SR_JQ" -r .count)"
  type="$(sr_dest_field "$dest" type)"
  secret_handle="$(sr_dest_field "$dest" secret)"
  if [ -z "$type" ] || [ -z "$secret_handle" ]; then
    sr_log_event "$repo" "$dest" "error" "đích chưa cấu hình đủ"; return 1
  fi
  adapter="${SR_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/adapters/${type}.sh"
  if [ ! -f "$adapter" ]; then
    sr_log_event "$repo" "$dest" "error" "không có adapter cho kiểu '$type'"; return 1
  fi
  secret="$(sr_resolve_secret "$secret_handle")"
  if [ -z "$secret" ]; then
    sr_log_event "$repo" "$dest" "error" "không lấy được khoá từ $secret_handle"; return 1
  fi
  # URL đi thẳng vào adapter qua tham số, không qua biến nào bị in ra.
  #
  # Adapter được phép in MỘT dòng chi tiết ra stdout (mã HTTP, run-id...) — nó
  # vào thẳng nhật ký. Đây là phần mở rộng của hợp đồng adapter, và là cách
  # `sr history` biết được nhiều hơn "thành công/thất bại".
  local detail
  detail="$(printf '%s' "$report" | bash "$adapter" "$secret")"
  rc=$?
  if [ $rc -eq 0 ]; then sr_log_event "$repo" "$dest" "sent" "$detail" "$count"
  else sr_log_event "$repo" "$dest" "failed" "${detail:-adapter trả mã $rc}" "$count"; fi
  return $rc
}
