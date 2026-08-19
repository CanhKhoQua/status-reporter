# teams-progress

Cuối mỗi phiên làm việc với Claude Code, plugin gom các commit của phiên đó,
tóm tắt thành 2–3 câu tiếng Anh, rồi đăng **một** tin lên kênh Microsoft Teams.

Mục đích: quản lý biết đang có việc gì được làm, mà không phải đọc git log và
không bị 30 tin nhắn một ngày.

## Nó KHÔNG phải cái gì

Đây không phải thông báo deploy. Tin nhắn nói về code trên máy lập trình viên —
có thể chưa commit lên remote, chưa merge, chắc chắn chưa lên production. Mỗi
card đều mang dòng `⚠️ Work in progress — not yet deployed to production.`
Đừng bỏ dòng đó.

## Cài

```bash
# trong Claude Code
/plugin marketplace add /đường/dẫn/tới/teams-progress
/plugin install teams-progress@teams-progress
```

## Bật cho một project

Plugin **chỉ chạy khi project có `TEAMS_WEBHOOK_URL`** trong `.env.local` hoặc
`.env`. Không có biến đó thì hook thoát im lặng. Đó là toàn bộ cơ chế giới hạn
phạm vi — không cần whitelist đường dẫn.

Nếu project không dùng `.env.local`, đặt biến môi trường
`TEAMS_PROGRESS_WEBHOOK_URL`.

URL đó là một **Power Automate Workflow** có trigger *"When a Teams webhook
request is received"*. Định dạng Office 365 Connector / MessageCard cũ đã bị
khai tử — gửi theo nó sẽ nhận 202 rồi rơi vào hư vô.

## Cách hoạt động

| Mốc | Việc |
|---|---|
| `SessionStart` | ghi HEAD hiện tại + thời điểm vào `~/.cache/teams-progress/<session_id>` |
| `SessionEnd` | lấy commit trong khoảng đó → `claude -p --model haiku` tóm tắt → POST Adaptive Card |

Im lặng thoát khi: không commit nào trong phiên, không có webhook, không phải
repo git, hoặc cờ chống đệ quy đang bật.

Nếu `claude -p` lỗi hoặc quá giờ, plugin gửi danh sách commit thô thay vì bỏ tin.

### Hai chỗ dễ sai

**Đệ quy.** `claude -p` cũng là một phiên Claude Code, kết thúc nó lại kích hoạt
`SessionEnd` của chính plugin này. Chặn bằng `TEAMS_PROGRESS_SKIP=1` đặt lúc gọi;
dòng đầu của cả hai script thoát ngay nếu thấy cờ. Bỏ nó ra là script tự nhân
bản đến khi phải giết tiến trình bằng tay.

**Đổi nhánh giữa phiên.** Sau `git checkout`, SHA đầu phiên không còn là tổ tiên
của HEAD nên khoảng `base..HEAD` vô nghĩa. Plugin phát hiện và rơi về lọc theo
thời điểm mở phiên. Thiếu nhánh này thì mọi phiên có checkout đều mất báo cáo.

## Kiểm thử

```bash
bash tests/run-tests.sh
```

16 ca, không chạm mạng và không chạm Teams: `curl` được thay bằng ghi ra file,
`claude` được thay bằng script giả.

## Giấy phép

MIT
