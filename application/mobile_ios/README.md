# Bilingual Reader iOS App (Native SwiftUI)

Khung ứng dụng di động đọc sách song ngữ viết bằng ngôn ngữ **Swift & SwiftUI thuần** dành riêng cho các thiết bị iPhone và iPad để đạt hiệu năng mượt mà nhất có thể.

## Cấu trúc thư mục mã nguồn
```text
application/mobile_ios/
├── BilingualReaderApp.swift        # App Entry Point
├── Models/
│   └── Book.swift                  # Các struct dữ liệu (Book, Highlight, User)
├── Services/
│   ├── APIService.swift            # Lớp mạng kết nối API (async/await URLSession)
│   └── VocaService.swift           # Voca qua proxy backend (tra từ, tạo thẻ, audio, practice)
└── Views/
    ├── LoginView.swift             # Màn hình đăng nhập gradient cao cấp
    ├── BookshelfView.swift         # Lưới hiển thị danh sách sách được phân quyền
    ├── ReaderView.swift            # Trình đọc phân trang chia đôi màn hình song ngữ
    └── BilingualWebView.swift      # UIViewRepresentable bao WKWebView đồng bộ cuộn
```

## Hướng dẫn thiết lập dự án trên Xcode

Để biên dịch và chạy dự án này trên iOS Simulator hoặc thiết bị thật (iPhone/iPad):

### Bước 1: Khởi tạo dự án Xcode
1. Mở **Xcode** trên máy Mac của bạn.
2. Chọn **File -> New -> Project...**
3. Chọn **iOS -> App** và nhấn **Next**.
4. Thiết lập thông tin dự án:
   - **Product Name**: `BilingualReader`
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
5. Nhấn **Next** và lưu dự án vào máy.

### Bước 2: Import mã nguồn
1. Xóa file `ContentView.swift` mặc định mà Xcode tự sinh ra.
2. Kéo thả toàn bộ các file trong thư mục `application/mobile_ios/` vào cây thư mục dự án của bạn trên Xcode.
3. Khi Xcode hiện hộp thoại import, tích chọn **"Copy items if needed"** và **"Create groups"**.

### Bước 3: Cấu hình Quyền bảo mật kết nối mạng (ATS)
Vì máy chủ của bạn mặc định chạy trên giao thức `http` (HTTP thô) thay vì `https`, bạn cần cho phép ứng dụng iOS kết nối HTTP không bảo mật cục bộ:
1. Mở tệp `Info.plist` trong Xcode (hoặc nhấn vào tab **Info** ở mục cấu hình Target dự án).
2. Thêm một thuộc tính mới: **App Transport Security Settings**.
3. Bên dưới nó, thêm thuộc tính con: **Allow Arbitrary Loads** và đặt giá trị là **YES**.

### Bước 4: Chạy ứng dụng
1. Chọn máy ảo kiểm thử (ví dụ: **iPhone 15 Pro** hoặc **iPad Pro**).
2. Nhấn nút **Run** (phím tắt `Cmd + R`) để biên dịch và chạy ứng dụng.
3. Nhập địa chỉ IP máy chủ của bạn (ví dụ: `http://192.168.1.5:27099`) và đăng nhập để bắt đầu trải nghiệm!

## Cấu hình Voca API

Giống web-v2, iOS đi qua proxy `/api/voca/*` của backend — **không gọi thẳng Voca**. Khóa nằm trên server (bảng `user_settings`), không bao giờ lưu trên máy và không bao giờ được trả về cho app.

Người dùng nhập ở màn hình **Settings** của app (hoặc ở bản web — dùng chung):

- **Base URL**: `https://voca.thaonv.online` — bắt buộc `https`. Host cũng trả lời `http` mà **không** redirect, nên một URL `http://` sẽ gửi API key ở dạng thô. Host cũ `voca-bridge.thaonv.online` đã **chết** (Cloudflare 502).
- **API Key**: chuỗi dạng `voca_...` (phải giữ tiền tố `voca_`). Chỉ backend gắn header `X-API-Key`; app không giữ khóa.

Hệ quả cần biết:

- **Cấu hình một lần dùng cả hai nơi** — nhập ở web thì iPad khỏi nhập, và ngược lại.
- **Ô API key luôn trống** kể cả khi đã cấu hình (server không trả khóa về). Để trống = giữ khóa cũ; gõ giá trị mới = thay.
- **Tính năng Voca cần đăng nhập server sách.** Từ đã đồng bộ sẵn vẫn tra được từ bộ nhớ máy.
- Lần đầu chạy bản này, bản sao khóa cũ trên máy (Keychain `vocaApiKey`, UserDefaults `vocaBridgeToken`/`vocaBridgeOrigin`) sẽ bị xóa.

Envelope trả về được bóc ngay trong app. Chi tiết endpoint, mã lỗi và giới hạn 120 request/phút: [voca-integration.md](../docs/voca-integration.md).

### ⚠️ Thu hồi khóa đã lộ

Khóa Voca API từng bị hardcode trong `VocaService.swift` đã được commit vào repo. Xóa khỏi HEAD **không** xóa khỏi lịch sử git. Vào **Voca → Settings → API Keys**, thu hồi khóa cũ, tạo khóa mới rồi nhập lại trong Settings của app.

## Cơ chế đồng bộ cuộn (Scroll Synchronization) bằng Swift
- **BilingualWebView**: Bọc thành phần `WKWebView` của Apple và nhúng mã Javascript lắng nghe cuộn. Khi người dùng kéo trang sách, tọa độ cuộn được đẩy ngược lại luồng Swift qua `WKScriptMessageHandler` cục bộ của iOS với độ trễ gần như bằng 0.
- **NotificationCenter**: Khi nhận được tọa độ cuộn từ WebView A, Swift sẽ kích hoạt một thông báo `ScrollTo_` để WebView B nhận và tự động thực thi lệnh `window.scrollTo` tương thích tức thời, đảm bảo hai bên luôn hiển thị khớp đoạn dịch song ngữ.
