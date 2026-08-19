---
description: Cài đặt status-reporter từ đầu — dựng cấu hình, nạp khoá kênh, kiểm và bắn thử
---

Dắt người dùng cài `status-reporter` cho tới khi nó thật sự chạy. Làm tuần tự,
đừng nhảy cóc, và **dừng lại chờ** ở mỗi bước cần họ thao tác.

Đường dẫn `sr`: thử `command -v sr`, không có thì dùng `${CLAUDE_PLUGIN_ROOT}/bin/sr`.

## 1. Kiểm máy trước

Chạy `sr doctor`. Nếu thiếu `jq`/`git`/`curl` thì dừng lại, bảo họ cài, đừng làm tiếp.

## 2. Cấu hình

Nếu `sr doctor` báo chưa có config: chạy `sr init --repo <repo> --dest <tên>`.

- `<repo>`: thư mục git họ muốn báo cáo. Đoán từ thư mục làm việc hiện tại, rồi
  **hỏi lại cho chắc**.
- `<tên>`: tên kênh nhận báo cáo, ví dụ `tnm-team`.

## 3. Khoá của kênh — KHÔNG được tự làm hộ

**Tuyệt đối không** bảo họ dán webhook URL vào khung chat, và không tự chạy lệnh
nào có chứa URL đó. URL là credential: vào khung chat là lộ cho mô hình và nằm
lại trong transcript.

Bảo họ tự làm trong terminal:

1. Power Automate → mở flow nhận webhook của kênh
2. Trigger *"When a Teams webhook request is received"* → ô **HTTP URL**
3. Bấm **nút copy** cạnh ô đó — bôi đen bằng chuột sẽ thiếu đoạn
   `?api-version=…&sig=…`, và kênh sẽ trả HTTP 400
4. `sr set-secret <tên>`

Rồi chạy `sr doctor` để xác nhận `khoá tìm thấy`.

## 4. Bắn thử

`sr test <tên>`. Card mang nhãn *"🧪 Tin kiểm tra"*. Hỏi họ **có thấy trong kênh
không** — đừng suy ra từ mã thoát.

Nếu `sr test` thành công mà kênh trống: đó là do flow, không phải do công cụ.
`HTTP 202` chỉ nghĩa là Power Automate đã **nhận**, không phải đã **đăng**. Lấy
`run=…` trong `sr history` rồi bảo họ mở Run history của flow tra mã đó.

## 5. Nói trước hai điều này — bắt buộc

Đây là hai hiểu nhầm chắc chắn xảy ra nếu không nói:

- Hook nạp từ **phiên Claude Code kế tiếp**, không phải phiên đang mở.
- Phiên đầu tiên ở mỗi repo **chỉ đặt mốc, không gửi gì**. Tin thật đầu tiên đến
  từ phiên thứ hai trở đi.

Kết lại bằng: kênh im thì chạy `sr history` — mỗi lần bỏ qua đều ghi rõ lý do.
