# Bilingual Reader iOS App (Native SwiftUI)

Khung ứng dụng di động đọc sách song ngữ viết bằng ngôn ngữ **Swift & SwiftUI thuần** dành riêng cho các thiết bị iPhone và iPad để đạt hiệu năng mượt mà nhất có thể.

## Cấu trúc thư mục mã nguồn
```text
application/mobile_ios/
├── BilingualReaderApp.swift        # App Entry Point
├── Models/
│   └── Book.swift                  # Các struct dữ liệu (Book, Highlight, User)
├── Services/
│   └── APIService.swift            # Lớp mạng kết nối API (async/await URLSession)
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

## Cơ chế đồng bộ cuộn (Scroll Synchronization) bằng Swift
- **BilingualWebView**: Bọc thành phần `WKWebView` của Apple và nhúng mã Javascript lắng nghe cuộn. Khi người dùng kéo trang sách, tọa độ cuộn được đẩy ngược lại luồng Swift qua `WKScriptMessageHandler` cục bộ của iOS với độ trễ gần như bằng 0.
- **NotificationCenter**: Khi nhận được tọa độ cuộn từ WebView A, Swift sẽ kích hoạt một thông báo `ScrollTo_` để WebView B nhận và tự động thực thi lệnh `window.scrollTo` tương thích tức thời, đảm bảo hai bên luôn hiển thị khớp đoạn dịch song ngữ.
