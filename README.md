# Bilingual Reader

Ứng dụng đọc sách song ngữ Anh – Việt đa nền tảng (Web, iOS, iPadOS) tích hợp từ điển Voca và trợ lý AI.

[![Release](https://img.shields.io/github/v/release/thaonv7995/bilingual-app?style=flat-square)](https://github.com/thaonv7995/bilingual-app/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/thaonv7995/bilingual-app/deploy.yml?branch=main&style=flat-square&label=CI)](https://github.com/thaonv7995/bilingual-app/actions)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue?style=flat-square)](application/backend)

## Tính năng chính

- **Đọc song ngữ chuẩn A4**: Chế độ xem song song (`Split`) hoặc đơn ngữ (`EN` / `VI`), tự động đồng bộ vị trí đọc giữa các thiết bị.
- **Tùy chỉnh giao diện theo sách (`Aa`)**: Phông chữ (Serif, Sans, Viết tay, Mono), màu giấy, màu mực, vân giấy và cỡ chữ với cơ chế chống tràn khung A4.
- **Học tập tích hợp**: Tô sáng (Highlight), tra từ & tạo flashcard qua Voca 2.0, hỏi đáp ngữ cảnh với AI và nghe Audiobook.
- **Đa nền tảng**: Giao diện Web PWA (`React 19` + `TypeScript`) và ứng dụng gốc `SwiftUI` cho iPhone & iPad hỗ trợ đọc ngoại tuyến.

## Cài đặt nhanh (Linux Server)

Cài đặt hoặc cập nhật bản Release mới nhất (chạy nền qua `systemd` tại cổng `27099`, không cần cài Node.js):

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- install-release /opt/bilingual-app
```

Gỡ cài đặt:

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- delete /opt/bilingual-app
```

## Phát triển cục bộ (Local Development)

**1. Backend (FastAPI — Python 3.10+)**

```bash
cd application
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements-api.txt -e backend
cd ..
python3 server.py   # http://localhost:27099
```

**2. Web App (Node.js 22+)**

```bash
cd application/web-app-v2
npm install
npm run dev         # Vite HMR (hoặc `npm run build` để đóng gói)
```

**3. iOS & iPadOS (XcodeGen)**

```bash
cd application/mobile_ios
xcodegen generate
open BilingualReader.xcodeproj
```

## Cấu trúc thư mục

```text
bilingual-app/
├── server.py                  # Khởi chạy FastAPI server (:27099)
├── deploy.sh                  # Script triển khai tự động trên Linux (systemd)
├── books/                     # Thư mục lưu sách (.bkb) đã giải nén
└── application/
    ├── backend/               # FastAPI, SQLite, Auth, AI & Voca Proxy
    ├── web-app-v2/            # Ứng dụng Web (React 19, TypeScript, Vite)
    ├── mobile_ios/            # Ứng dụng iOS & iPadOS (SwiftUI)
    └── docs/                  # Tài liệu kỹ thuật
```

## Kiểm thử & Tài liệu

```bash
# Backend tests
cd application/backend && ../.venv/bin/pytest -q

# Frontend tests
cd application/web-app-v2 && npm test
```

- Triển khai & CI/CD: [application/backend/docs/DEPLOYMENT.md](application/backend/docs/DEPLOYMENT.md)
- Tích hợp Voca 2.0: [application/docs/voca-integration.md](application/docs/voca-integration.md)
- Biến môi trường mẫu: [application/.env.example](application/.env.example)
