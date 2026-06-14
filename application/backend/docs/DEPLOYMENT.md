# Debian Server Deployment Guide

Guide to setting up automated deployment via GitHub Actions (CI/CD) and managing the application lifecycle (`install`, `update`, `delete`) on a Debian/Ubuntu server.

## 1. Prerequisites on Debian Server

Ensure the host server has standard git and python capabilities. The deployment script `deploy.sh` will auto-install missing packages on Debian/Ubuntu systems:

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip git curl
```

---

## 2. GitHub CI/CD Action Secrets Setup

The automated workflow relies on SSH/SCP to push clean packages to the target server. Go to your repository settings on GitHub (**Settings > Secrets and variables > Actions**) and add the following repository secrets:

| Secret Name | Description | Example Value |
| :--- | :--- | :--- |
| `SSH_HOST` | Server public IP address or domain | `192.168.1.50` or `my.server.com` |
| `SSH_USERNAME` | SSH user authorized to deploy | `root` or `deploy-user` |
| `SSH_KEY` | Plaintext SSH private key | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `SSH_PORT` | SSH port (Optional, defaults to 22) | `22` or `2222` |
| `DEPLOY_PATH` | Server path where the app should live | `/opt/bilingual-app` or `/home/ubuntu/bilingual-app` |

---

## 3. Deployment & Lifecycle Commands

### 🚀 Cài đặt (Installation via single command)
You can install and bootstrap the application on a fresh Debian server using a single `curl` command (this clones the repository into the specified directory, sets up python virtualenv, installs dependencies, and runs it as a systemd process):

```bash
curl -sSL https://raw.githubusercontent.com/thaonv7995/bilingual-app/main/deploy.sh | bash -s -- install /opt/bilingual-app https://github.com/thaonv7995/bilingual-app.git
```
*Hãy chắc chắn máy chủ Debian đã cấu hình SSH key để truy cập hoặc sử dụng Personal Access Token trong HTTPS URL nếu repository là private.*

### 🔄 Cập nhật (Update to latest version)
To update the source code to the latest commit on GitHub, re-install any new dependencies, and restart the backend service:

```bash
cd /opt/bilingual-app
sudo ./deploy.sh update
```

### 🗑️ Gỡ cài đặt (Delete / Uninstall)
To stop and disable the background service, remove systemd configurations, and clean up the installation directory:

```bash
cd /opt/bilingual-app
sudo ./deploy.sh delete
```
*Lưu ý: Lệnh delete sẽ hiển thị dấu nhắc hỏi bạn có muốn xóa thư mục mã nguồn tại `/opt/bilingual-app` hay không.*

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
