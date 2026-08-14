# Debian Server Deployment Guide

Guide to setting up automated deployment via GitHub Actions (CI/CD) and managing the application lifecycle (`install`, `update`, `delete`) on a Debian/Ubuntu server.

## 1. Prerequisites on Debian Server

Ensure the host server has standard git and python capabilities. The deployment script `deploy.sh` auto-installs missing packages on Debian/Ubuntu systems, including **Node.js 20** (via NodeSource) which is needed to build the v2 frontend:

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip git curl
```

---

## 2. Deployment model (pull-based)

Deployment is **pull-based**: the server itself pulls the code and builds. There is no CI push to the server, so **no SSH secrets are required**.

- **CI (`.github/workflows/deploy.yml`)** runs on push to `main` and on tags. It runs the backend tests, builds the v2 frontend (`npm ci && npm run build`), packages a release tarball, uploads it as a build artifact, and — on tags — publishes a GitHub Release. It does **not** deploy to any server.
- **Server deploy** happens via the `curl … | bash -s -- install|update` commands below. On install/update the script clones/pulls the repo, builds the v2 frontend, and (re)starts the systemd service with `FRONTEND_V2_DIST` set so the backend serves v2.

> Want push-based CD instead? Add an SSH/rsync job to the workflow that ships the release tarball (it already contains the built `dist`) and restarts systemd. Not configured today.

### Secrets / runtime config on the server

Backend secrets are read from an **optional** `.env` file at the install root (e.g. `/opt/bilingual-app/.env`), wired into the service via `EnvironmentFile=-`. Create it as `KEY=VALUE` lines and restart the service:

```bash
sudo tee /opt/bilingual-app/.env >/dev/null <<'ENV'
VOCA_BRIDGE_ORIGIN=https://voca-bridge.thaonv.online
VOCA_BRIDGE_TOKEN=<server-default token, optional — users can also set their own>
# DATABASE_URL=sqlite:////opt/bilingual-app/bilingual_reader.db
ENV
sudo systemctl restart bilingual-reader
```

---

## 3. Deployment & Lifecycle Commands

### 🚀 Cài đặt (Installation via single command)
You can install and bootstrap the application on a fresh Debian server using a single `curl` command (this clones the repository into the specified directory, sets up python virtualenv, installs dependencies, and runs it as a systemd process):

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- install /opt/bilingual-app https://github.com/thaonv7995/bilingual-app.git
```
*Hãy chắc chắn máy chủ Debian đã cấu hình SSH key để truy cập hoặc sử dụng Personal Access Token trong HTTPS URL nếu repository là private.*

### 🔄 Cập nhật (Update to latest version)
To update the source code to the latest commit on GitHub, update python virtualenv dependencies, and restart the background systemd service using a single command:

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- update /opt/bilingual-app
```

### 🗑️ Gỡ cài đặt (Delete / Uninstall)
To stop and disable the background service, clean up systemd files, and delete the target directory:

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- delete /opt/bilingual-app
```
*Lưu ý: Lệnh delete sẽ hiển thị dấu nhắc hỏi bạn xác nhận trước khi xóa thư mục mã nguồn tại `/opt/bilingual-app`.*

---

## 4. Managing the Server Process (systemd)

The application runs as a background systemd service called `bilingual-reader`.

```bash
# Check service status
sudo systemctl status bilingual-reader

# View application execution logs
sudo journalctl -u bilingual-reader -f -n 100

# Manually start the service
sudo systemctl start bilingual-reader

# Manually stop the service
sudo systemctl stop bilingual-reader

# Manually restart the service
sudo systemctl restart bilingual-reader
```
The application binds to port `27099` on the host machine. You can map a reverse proxy (e.g. Nginx or Caddy) to route external domain traffic to `http://localhost:27099/`.
