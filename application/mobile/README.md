# Bilingual Reader Mobile (iOS / Android)

Khung ứng dụng di động đọc sách song ngữ song song cho iPhone và iPad được xây dựng bằng **React Native** và **Expo**.

Ứng dụng kết nối trực tiếp với API backend của bạn, đồng bộ hóa tủ sách cá nhân và thực hiện cơ chế đồng bộ cuộn (scroll-sync) mượt mà giữa hai WebViews.

## Cấu trúc thư mục ứng dụng
```text
application/mobile/
├── App.js                     # Quản lý Đăng nhập, Thư viện và Màn hình chính
├── components/
│   └── BilingualReader.js    # WebView kép song ngữ tích hợp script đồng bộ cuộn
└── package.json               # Định nghĩa các dependencies của Expo
```

## Hướng dẫn cài đặt và chạy thử

### Bước 1: Cài đặt Node.js
Đảm bảo máy tính của bạn đã cài đặt Node.js (bản 18 trở lên).

### Bước 2: Cài đặt Expo CLI và các dependencies
Mở Terminal, di chuyển vào thư mục `application/mobile` và cài đặt:

```bash
cd application/mobile
npm install
```

### Bước 3: Khởi chạy dự án Expo
Chạy lệnh sau để bật Expo Developer Tools:

```bash
npm run ios
```
*Hoặc chỉ chạy `npm start` để mở menu lựa chọn.*

### Bước 4: Kiểm thử trên thiết bị
- **iOS Simulator**: Nếu dùng macOS và có cài Xcode, nhấn nút `i` trên màn hình terminal để mở trực tiếp simulator.
- **Thiết bị thật (iPhone/iPad)**:
  1. Tải ứng dụng **Expo Go** từ App Store về điện thoại.
  2. Đảm bảo điện thoại và máy tính chạy server kết nối chung một mạng Wi-Fi.
  3. Quét mã QR hiển thị ở màn hình terminal để tải ứng dụng trực tiếp lên điện thoại.

## Cơ chế hoạt động của ứng dụng
1. **Đăng nhập và Bảo mật**: Người dùng nhập IP máy chủ backend (mặc định chạy ở port `27099`). Ứng dụng thực hiện POST request để lấy JWT token. Token này được truyền vào các query parameters hoặc cookie của WebView để xác thực quyền đọc sách.
2. **Double WebView**: Render hai WKWebViews hiển thị bản dịch tiếng Anh và tiếng Việt cạnh nhau.
3. **Đồng bộ cuộn (Scroll Sync)**: Đoạn mã JavaScript (`injectScrollListener`) được nhúng trực tiếp vào hai WebView để bắt sự kiện cuộn. Tọa độ cuộn được gửi về luồng xử lý của React Native thông qua `postMessage` và đồng bộ ngược lại WebView đối diện ngay lập tức.
