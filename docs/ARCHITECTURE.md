# Kiến trúc Kỹ thuật Chi tiết (ARCHITECTURE.md)

Tài liệu này đi sâu vào các quyết định thiết kế kỹ thuật, cơ chế bảo mật và giao thức đồng bộ hóa dữ liệu của hệ thống **Bilingual Digital Library**.

---

## 📦 Định dạng Gói Sách (BKB Package Format)

Sách song ngữ được biên dịch từ file gốc PDF sang các trang HTML tĩnh riêng lẻ. Khi hoàn tất, sách được đóng gói thành một file nén dạng `.bkb` (ZIP nén).

### Cấu trúc bên trong một file `.bkb`:
```text
my-book.bkb (ZIP)
  ├── book.json             # Metadata của sách (title, author, cover, v.v.)
  └── output/               # Các file HTML và asset đã dựng
        ├── assets/         # Tài nguyên CSS, ảnh, fonts của sách
        ├── en/             # Bản gốc Tiếng Anh
        │     ├── page_0001.html
        │     └── ...
        └── vi/             # Bản dịch Tiếng Việt
              ├── page_0001.html
              └── ...
```

Khi tệp này được tải lên Admin Portal, endpoint `/api/books/upload` sẽ giải nén nó trực tiếp vào thư mục `books/my-book/` của máy chủ.

---

## 🔒 Mô hình Bảo mật & Phân quyền (Security & Access Control)

Các tài liệu sách tĩnh thường chứa bản quyền và thông tin nhạy cảm. Để ngăn chặn việc tải lậu, toàn bộ nội dung sách tĩnh đều được bảo vệ.

### 1. Cơ chế Intercept File tĩnh
Hệ thống không chia sẻ trực tiếp thư mục `books/` thông qua `StaticFiles` thông thường. Thay vào đó:
- Mọi tài nguyên trong `/books/{slug}/output/{path}` đều được phục vụ thông qua một endpoint an toàn của FastAPI: `@app.get("/books/{slug}/output/{path:path}")`.
- Hàm handler `serve_secure_book_static` sẽ chặn yêu cầu và kiểm tra:
  1. Yêu cầu có đi kèm JWT token hợp lệ hay không (lấy từ Header `Authorization`, Cookie `jwt_token`, hoặc Query Parameter `token`).
  2. Người dùng có vai trò Admin hay không (`is_admin == True`).
  3. Nếu không phải Admin, kiểm tra bảng `user_permissions` xem người dùng này đã được cấp quyền đọc `book_slug` tương ứng chưa.
- Chỉ khi thỏa mãn các điều kiện trên, file tĩnh mới được trả về qua `FileResponse`.

---

## 🖍️ Cơ chế Đồng bộ Highlight & Note (Highlight Syncing)

Highlight hoạt động dựa trên các bộ định vị phần tử DOM (DOM selectors).

### 1. Phía Web App
- Khi người dùng bôi đen đoạn văn và chọn màu highlight, một hàm JS sẽ tìm phần tử bao bọc gần nhất có ID (hoặc thẻ `<p>` có index tương ứng) và lưu thông tin về máy chủ qua API:
  `POST /api/books/{slug}/highlights`
- JSON payload lưu trữ:
  ```json
  {
    "page_number": 1,
    "element_id": "p_12",
    "color": "#ffeb3b",
    "selected_text": "Bilingual books are awesome.",
    "note": "Ghi chú mẫu của người dùng"
  }
  ```
- Khi mở trang sách, một đoạn code JS trong `app.js` sẽ tự động tải danh sách highlights tương ứng với trang đó từ API `GET /api/books/{slug}/highlights?page=N`. Sau đó, nó duyệt DOM và bọc văn bản bằng thẻ `<mark style="background-color: ...">` để hiển thị.

### 2. Phía iOS SwiftUI Bridge
Do ứng dụng iOS tải các file HTML tĩnh trực tiếp vào `WKWebView`, nó không dùng trực tiếp code trong `app.js`. Vì vậy, một cầu nối đặc biệt đã được thiết lập:
- **`BilingualWebView.swift`** thực hiện inject một file script `WKUserScript` chứa trình lắng nghe sự kiện bôi đen văn bản (`selectionchange` và các cử chỉ chạm `mouseup` / `touchend`).
- Khi người dùng chọn text, script sẽ tính toán tọa độ và gọi hàm callback:
  ```javascript
  window.webkit.messageHandlers.iosListener.postMessage({
      type: "textSelected",
      text: selectedText,
      rect: {x: ..., y: ..., width: ..., height: ...}
  });
  ```
- Phía Swift bắt được message, hiển thị bảng chọn màu và ô nhập Note gốc. Khi người dùng nhấn lưu, ứng dụng Swift gửi API trực tiếp lên backend để cập nhật DB, đồng thời gọi thực thi JS trên WebView để thay đổi màu nền DOM ngay lập tức.

---

## 🤖 Trợ lý Học tập AI (Ollama Proxy Chat)

- Để loại bỏ rào cản chính sách CORS của trình duyệt đối với các máy chủ AI cục bộ (như Ollama chạy ở cổng `11434`), backend FastAPI cung cấp một endpoint proxy bảo mật `/api/chat`.
- Client (Web và iOS) chỉ cần gửi yêu cầu chat đến `/api/chat`. Máy chủ backend sẽ đọc cấu hình AI (địa chỉ máy chủ Ollama/OpenAI API và API Key được lưu bảo mật ở Client-side và truyền qua header) để làm trung gian chuyển tiếp yêu cầu, hỗ trợ cả phản hồi stream thời gian thực.
