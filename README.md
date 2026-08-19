# status-reporter

Cuối mỗi phiên làm việc với Claude Code, công cụ gom các commit chưa báo, tóm
tắt thành vài câu tiếng Anh, rồi đăng **một** tin lên kênh chat.

Mục đích: quản lý biết đang có việc gì được làm, mà không phải đọc git log và
không bị 30 tin nhắn một ngày.

## Nó KHÔNG phải cái gì

Đây không phải thông báo deploy. Tin nhắn nói về code trên máy lập trình viên —
có thể chưa push, chưa merge, chắc chắn chưa lên production. Mỗi card đều mang
dòng `⚠️ Work in progress — not yet deployed to production.` Đừng bỏ dòng đó.

## Kiến trúc

```
  Thu thập                 Định tuyến            Bộ chuyển
  session-end.sh           core.sh               lib/adapters/
┌──────────────────┐    ┌──────────────┐    ┌──────────────┐
│ git log từ mốc   │    │ repo nào →   │    │ teams.sh     │
│ → tóm tắt        │───▶│ đích nào     │───▶│ (slack.sh)   │
│ → report.json    │    │ + nhật ký    │    │ (discord.sh) │
└──────────────────┘    └──────────────┘    └──────────────┘
```

Ranh giới nằm ở **`report.json`** — một tài liệu trung lập với kênh:

```json
{ "event": "session_end", "repo": "tnm-dms", "branch": "main",
  "commits": ["sửa hạn mức đăng nhập", "bù index"], "count": 2,
  "summary": "Worked on the login rate limit…",
  "state": "work_in_progress", "at": "2026-08-19T21:14:00+07:00" }
```

Tầng thu thập dừng ở đó; nó không biết Adaptive Card là gì. **Thêm một kênh mới
= thêm một file trong `lib/adapters/`**, không sửa gì khác. Có một ca kiểm thử
dựng adapter giả để chứng minh đúng điều này.

Hợp đồng của adapter:

| | |
|---|---|
| stdin | `report.json` |
| `$1` | bí mật của đích |
| thoát 0 | đã gửi |
| stdout | *(tuỳ chọn)* một dòng chi tiết → vào nhật ký |
| `--validate <bí mật>` | *(tuỳ chọn)* kiểm bí mật có đúng dạng của kênh này không |

`--validate` là thứ khiến `sr set-secret` bắt được URL cắt cụt **trước** khi nạp,
thay vì để người dùng phát hiện qua một cú HTTP 400 khó hiểu vài phút sau.

## Cấu hình

`~/.config/status-reporter/config.json`:

```json
{
  "destinations": {
    "tnm-team": { "type": "teams", "secret": "keychain:tnm-team" }
  },
  "rules": [
    { "repo": "~/duong/dan/repo", "on": "session_end", "to": ["tnm-team"] }
  ]
}
```

Repo **không có luật** thì không gửi đi đâu. Mặc định là KHÔNG gửi — thà im lặng
còn hơn đăng nhầm việc của project khác vào kênh công ty.

## Bí mật

`secret` là **handle, không phải giá trị**:

| Handle | Nguồn |
|---|---|
| `keychain:tên` | Keychain macOS, service `status-reporter`, account `tên` |
| `env:TÊN_BIẾN` | biến môi trường (dùng cho CI và kiểm thử) |

Nạp khoá — copy URL vào clipboard rồi:

```bash
sr set-secret tnm-team
```

Lệnh này kiểm clipboard **trước khi nạp** (đủ `?api-version=`, đủ `&sig=`, đủ
dài), rồi ghi thẳng vào Keychain. Nó tồn tại vì nếu không có nó thì cách nhanh
nhất để đưa URL vào là dán vào một khung chat hoặc gõ ra dòng lệnh — cái đầu làm
lộ credential cho mô hình, cái sau ghi nó vào `~/.zsh_history` vĩnh viễn.

Cách thủ công vẫn dùng được:

```bash
security add-generic-password -s status-reporter -a tnm-team -w
```

Nhờ vậy `config.json` là file thường: commit được, gửi cho đồng nghiệp được,
dán vào chat được, mà không lộ gì.

**Ba luật bất biến** — là thuộc tính của code, không phải lời hứa của người viết:

1. giá trị bí mật không bao giờ vào stdout/stderr
2. không bao giờ vào nhật ký
3. thông báo lỗi chỉ nói mã HTTP và tên đích, không nói URL

Có bốn ca kiểm thử canh đúng ba luật này.

### Nên dùng webhook RIÊNG cho công cụ

Đừng xài chung credential mà app production đang dùng. Tạo một flow Power
Automate thứ hai vào cùng kênh: thu hồi độc lập, truy vết được nguồn, và bán
kính thiệt hại khi lộ chỉ còn "ai đó đăng được bài vào một kênh".

URL đó là một **Power Automate Workflow** có trigger *"When a Teams webhook
request is received"*. Định dạng Office 365 Connector / MessageCard cũ đã bị
khai tử — gửi theo nó nhận 202 rồi rơi vào hư vô.

## Bảng điều khiển

```bash
sr doctor          # kiểm điều kiện chạy — chạy cái này ĐẦU TIÊN khi thấy im lặng
sr status          # đích đến, repo được bật, thống kê 7 ngày
sr history [n]     # n dòng nhật ký gần nhất
sr test <đích>     # gửi tin kiểm tra, có ghi rõ là tin thử
sr init            # tạo file cấu hình mẫu
```

Nhật ký tồn tại để trả lời câu hỏi sẽ được hỏi nhiều nhất: *"sao hôm nay không
thấy tin nào?"*. Công cụ im lặng thoát ở nhiều nhánh, và mỗi nhánh đều ghi lý do.

Cố tình **không** làm web dashboard: với công cụ chạy trên laptop một người dùng,
nó đòi server, đòi auth, đòi giữ sống — đổi lại thứ mà một lệnh là xong. Web chỉ
đáng khi nhiều người cần xem và tự cấu hình.

## Cài

Thư mục này là symlink tại `~/.claude/skills/status-reporter`, nên Claude Code tự
nạp mỗi phiên dưới tên `status-reporter@skills-dir`. Sửa file là có hiệu lực ngay
phiên sau — không cài, không `plugin update`, không cần commit.

```bash
ln -s ~/Developer/status-reporter ~/.claude/skills/status-reporter
ln -s ~/Developer/status-reporter/bin/sr ~/.local/bin/sr     # cho tiện gõ
```

Đừng đồng thời cài qua marketplace (`claude plugin install`): bản đó là một bản
sao riêng, chạy song song thì hook kích hoạt hai lần và kênh nhận hai tin giống
hệt nhau cho cùng một phiên.

Muốn phát hành cho người khác thì `marketplace.json` đã sẵn sàng:

```bash
gh repo create <owner>/status-reporter --public --source=. --push
claude plugin tag --push
```

## Cách hoạt động

Một hook duy nhất: `SessionEnd`.

Mốc "đã báo tới đâu" nhớ **theo repo**, không theo phiên, tại
`~/.local/state/status-reporter/markers/<hash>`. Nhờ vậy phiên bị kill, máy sập,
hay cài công cụ giữa chừng đều không làm mất commit.

Lần chạy đầu ở một repo chỉ đặt mốc rồi thôi: "chưa từng báo" lúc đó nghĩa là
toàn bộ lịch sử repo.

### Bốn chỗ dễ sai

**Đệ quy.** `claude -p` cũng là một phiên Claude Code, kết thúc nó lại kích hoạt
`SessionEnd` của chính công cụ này. Chặn bằng `STATUS_REPORTER_SKIP=1` đặt lúc
gọi; dòng đầu của hook thoát ngay nếu thấy cờ. Bỏ nó ra là script tự nhân bản
đến khi phải giết tiến trình bằng tay.

**Mốc chỉ dời khi gửi thành công.** Dời trước rồi mới gửi là mất trắng những
commit đó nếu kênh từ chối payload.

**Đổi nhánh.** Dùng `git log HEAD --not <mốc>` chứ không dùng khoảng `a..b`:
cách đầu vẫn đúng khi mốc không còn là tổ tiên của HEAD (checkout, rebase). Kèm
`--since=7 days` để lỡ checkout sang nhánh cũ cũng không đổ cả lịch sử tháng
trước vào kênh.

**curl không coi 4xx/5xx là lỗi.** Phải tự kiểm mã trả về, nếu không thì thất
bại hoàn toàn vô hình.

**202 không phải 200.** Power Automate trả 202 ngay khi *nhận* yêu cầu rồi mới
chạy flow bất đồng bộ — action "Post card" có thể hỏng sau đó mà webhook không
hề biết. Nhật ký ghi rõ `HTTP 202 đã nhận (chưa xác nhận đăng)` kèm
`x-ms-workflow-run-id` để tra trong Run history, thay vì báo "đã gửi" cho một
thứ chỉ mới "đã nhận".

## Yêu cầu

`jq`, `git`, `curl`. `claude` là tuỳ chọn — thiếu nó thì tin nhắn là danh sách
commit thô thay vì tóm tắt.

Đường dẫn `jq` **không** được đóng cứng: công cụ tự tìm qua `PATH`. macOS 15 mới
có sẵn `/usr/bin/jq`; máy cũ hơn và Linux thì nó nằm chỗ khác, và đóng cứng
đường dẫn nghĩa là công cụ hỏng câm — không gửi gì, không báo gì. Nếu vẫn thiếu
`jq`, hook **ghi vào nhật ký** thay vì im lặng.

Chạy `sr doctor` để biết máy thiếu gì.

### Chỉ chạy trên macOS

`keychain:` cần `security`, và `sr set-secret` cần `pbpaste` — cả hai là của
macOS. Trên Linux/WSL hiện chỉ dùng được handle `env:`. `sr doctor` báo rõ điều
này thay vì để hỏng giữa chừng.

Muốn hỗ trợ đầy đủ thì cần một tầng backend bí mật cắm được (`pass:`, `file:`),
theo đúng khuôn adapter kênh đang dùng — chưa làm vì chưa có người dùng thật nào
cần.

## Giới hạn đã biết

Công cụ chạy trên laptop thì mức đảm bảo có trần của nó — bất kỳ tiến trình nào
chạy dưới cùng tài khoản cũng đọc được Keychain đó. Nếu việc báo cáo này thành
hạ tầng của cả đội, câu trả lời đúng là chuyển sang **server**: CI/CD đăng bài,
secret nằm trong GitHub Actions secrets hoặc vault, không có bản sao nào trên
máy cá nhân.

## Kiểm thử

```bash
bash tests/run-tests.sh
```

41 ca. Không chạm mạng, không chạm kênh chat, không chạm Keychain thật: adapter
ghi payload ra file thay vì `curl`, `claude` là script giả, bí mật lấy qua
handle `env:`.

## Giấy phép

MIT
