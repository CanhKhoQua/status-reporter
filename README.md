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

Thư mục này là symlink tại `~/.claude/skills/teams-progress`, nên Claude Code
**tự nạp mỗi phiên** dưới tên `teams-progress@skills-dir`. Sửa file xong là có
hiệu lực ngay phiên sau — không cài, không `plugin update`, không cần commit.

```bash
ln -s ~/Developer/teams-progress ~/.claude/skills/teams-progress
```

Đừng đồng thời cài qua marketplace (`claude plugin install`): bản đó là một bản
sao riêng, chạy song song với bản này thì hook kích hoạt hai lần và kênh Teams
nhận hai tin giống hệt nhau cho cùng một phiên.

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

Chỉ một hook: `SessionEnd`.

Mốc "đã báo tới đâu" được nhớ **theo repo**, không theo phiên, tại
`~/.cache/teams-progress/repos/<hash đường dẫn>`. Cuối phiên, plugin lấy mọi
commit `HEAD` với tới mà mốc cũ không với tới, tóm tắt bằng
`claude -p --model haiku`, rồi POST Adaptive Card.

Vì mốc theo repo chứ không theo phiên, phiên bị kill, máy sập, hay cài plugin
giữa chừng đều không làm mất commit — lần chạy sau vẫn thấy chúng chưa được báo.

Lần chạy đầu ở một repo chỉ đặt mốc rồi thôi: "chưa từng báo" lúc đó nghĩa là
toàn bộ lịch sử repo, không ai muốn đọc cái đó.

Im lặng thoát khi: không có commit mới, không có webhook, không phải repo git,
hoặc cờ chống đệ quy đang bật.

Nếu `claude -p` lỗi hoặc quá giờ, plugin gửi danh sách commit thô thay vì bỏ tin.

### Hai chỗ dễ sai

**Đệ quy.** `claude -p` cũng là một phiên Claude Code, kết thúc nó lại kích hoạt
`SessionEnd` của chính plugin này. Chặn bằng `TEAMS_PROGRESS_SKIP=1` đặt lúc gọi;
dòng đầu của cả hai script thoát ngay nếu thấy cờ. Bỏ nó ra là script tự nhân
bản đến khi phải giết tiến trình bằng tay.

**Mốc chỉ dời khi gửi thành công.** Dời trước rồi mới gửi là mất trắng những
commit đó nếu Teams từ chối payload. Có một ca kiểm thử riêng cho đúng việc này.

**Đổi nhánh.** Dùng `git log HEAD --not <mốc>` chứ không dùng khoảng `a..b`:
cách đầu vẫn đúng khi mốc không còn là tổ tiên của HEAD (checkout, rebase), cách
sau thì vô nghĩa. Kèm `--since=7 days` để lỡ checkout sang nhánh cũ cũng không
đổ cả lịch sử tháng trước vào kênh.

## Kiểm thử

```bash
bash tests/run-tests.sh
```

20 ca, không chạm mạng và không chạm Teams: `curl` được thay bằng ghi ra file,
`claude` được thay bằng script giả.

## Giấy phép

MIT
