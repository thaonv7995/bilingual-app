#!/bin/bash
set -e

ACTION=${1:-"install"}
TARGET_DIR=${2:-"/opt/bilingual-app"}
REPO_URL=${3:-""}

SERVICE_NAME="bilingual-reader"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Detect if we are inside the application source tree
if [ -f "$0" ] && [ "$(basename "$0")" = "deploy.sh" ] && [ -f "$(dirname "$0")/server.py" ] && [ -d "$(dirname "$0")/application" ]; then
    IS_SOURCE_TREE=true
    APP_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    IS_SOURCE_TREE=false
fi

# ==================== CROSS-OS HELPERS ====================
# Detect the system package manager (Debian/Ubuntu, Fedora/RHEL, openSUSE, Arch, macOS).
detect_pkg_mgr() {
    for m in apt-get dnf yum zypper pacman brew; do
        command -v "$m" &> /dev/null && { echo "$m"; return; }
    done
    echo none
}

# Ensure Python 3 (with venv + pip) is available, using whatever package manager exists.
ensure_python() {
    if command -v python3 &> /dev/null && python3 -c "import venv, ensurepip" &> /dev/null; then
        return 0
    fi
    echo "Installing Python 3 (+venv/pip)..."
    case "$(detect_pkg_mgr)" in
        apt-get) sudo apt-get update -y && sudo apt-get install -y python3 python3-venv python3-pip ;;
        dnf)     sudo dnf install -y python3 python3-pip ;;
        yum)     sudo yum install -y python3 python3-pip ;;
        zypper)  sudo zypper install -y python3 python3-pip python3-virtualenv ;;
        pacman)  sudo pacman -Sy --noconfirm python python-pip ;;
        brew)    brew install python ;;
        *) echo "!! No supported package manager. Please install Python 3 (with venv) manually, then re-run."; exit 1 ;;
    esac
    command -v python3 &> /dev/null || { echo "!! Python 3 still missing after install."; exit 1; }
}

# Ensure Node.js >=18 (only needed when building v2 from source).
ensure_node() {
    if command -v node &> /dev/null; then
        local maj; maj=$(node -v | sed 's/v\([0-9]*\).*/\1/')
        [ "${maj:-0}" -ge 18 ] && return 0
    fi
    echo "Installing Node.js 20..."
    case "$(detect_pkg_mgr)" in
        apt-get) curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs ;;
        dnf)     curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash - && sudo dnf install -y nodejs ;;
        yum)     curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash - && sudo yum install -y nodejs ;;
        zypper)  sudo zypper install -y nodejs20 || sudo zypper install -y nodejs ;;
        pacman)  sudo pacman -Sy --noconfirm nodejs npm ;;
        brew)    brew install node ;;
        *) echo "!! No supported package manager. Please install Node.js >=18 manually, then re-run."; exit 1 ;;
    esac
}

# This installer registers a systemd service (Linux). Bail out clearly elsewhere.
require_systemd() {
    if ! command -v systemctl &> /dev/null; then
        echo "============================================="
        echo "!! systemd (systemctl) not found."
        echo "   This installer registers a systemd service, which needs a systemd Linux"
        echo "   (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, ...)."
        echo "   On macOS / Windows, run the app directly instead:"
        echo "     cd \"$TARGET_DIR\" && application/.venv/bin/python3 server.py"
        echo "   (or use WSL / Docker). See the README 'Local Launch' section."
        echo "============================================="
        exit 1
    fi
}

# Print Help
show_help() {
    echo "Bilingual Book Reader Service Manager"
    echo "Usage:"
    echo "  Local Run:  ./deploy.sh [install|update|delete] [target_dir]"
    echo "  Curl Run:   curl -sSL <url> | bash -s -- install [target_dir] [repo_url]"
    echo "  From Release: curl -sSL <url> | bash -s -- install-release [target_dir] [owner/name]"
    echo ""
    echo "Actions:"
    echo "  install         Clone the repo, build v2, register the systemd service"
    echo "  install-release Download the latest GitHub Release tarball (prebuilt v2,"
    echo "                  no Node needed) and install the systemd service"
    echo "  update          Pull the latest code from GitHub and restart the process"
    echo "  delete          Stop, disable, and clean up the service and directories"
}

if [ "$ACTION" = "help" ] || [ "$ACTION" = "--help" ] || [ "$ACTION" = "-h" ]; then
    show_help
    exit 0
fi

# ==================== ACTION: DELETE ====================
if [ "$ACTION" = "delete" ] || [ "$ACTION" = "uninstall" ]; then
    echo "============================================="
    echo "Uninstalling Bilingual Book Reader Service..."
    echo "============================================="
    
    # 1. Stop and disable systemd service
    if [ -f "$SERVICE_FILE" ]; then
        echo "Stopping and disabling $SERVICE_NAME service..."
        sudo systemctl stop "$SERVICE_NAME" || true
        sudo systemctl disable "$SERVICE_NAME" || true
        echo "Removing systemd service file..."
        sudo rm -f "$SERVICE_FILE"
        sudo systemctl daemon-reload
    else
        echo "Service file $SERVICE_FILE not found, skipping..."
    fi
    
    # 2. Optionally delete files
    if [ "$IS_SOURCE_TREE" = "true" ]; then
        echo "Please delete the folder manually if needed: $APP_DIR"
    elif [ -d "$TARGET_DIR" ]; then
        read -p "Do you want to delete the installation directory at $TARGET_DIR? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Deleting $TARGET_DIR..."
            sudo rm -rf "$TARGET_DIR"
        fi
    fi
    echo "Uninstall completed successfully."
    exit 0
fi

# ==================== ACTION: REMOTE BOOTSTRAP (RUN VIA CURL) ====================
if [ "$IS_SOURCE_TREE" = "false" ]; then
    if [ "$ACTION" = "install" ]; then
        echo "============================================="
        echo "Bootstrapping Bilingual Book Reader Installation..."
        echo "============================================="
        
        if [ -z "$REPO_URL" ]; then
            echo "Error: Git repository URL is required for bootstrap installation."
            echo "Usage: curl -sSL <script_url> | bash -s -- install [target_dir] [repo_url]"
            exit 1
        fi
        
        echo "Target directory: $TARGET_DIR"
        echo "Git repository: $REPO_URL"
        
        # Clone or update repository
        if [ -d "$TARGET_DIR/.git" ]; then
            echo "Target directory already exists and is a git repository. Pulling latest updates..."
            cd "$TARGET_DIR"
            sudo git reset --hard HEAD
            sudo git fetch --all
            CURRENT_BRANCH=$(sudo git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
            sudo git pull origin "$CURRENT_BRANCH"
        else
            echo "Cloning repository..."
            if [ -d "$TARGET_DIR" ]; then
                echo "Warning: Target directory exists but is not a git repository. Clearing it for a clean clone..."
                sudo rm -rf "$TARGET_DIR"
            fi
            sudo git clone "$REPO_URL" "$TARGET_DIR"
        fi
        
        # Run local installer
        echo "Triggering local installation..."
        cd "$TARGET_DIR"
        sudo chmod +x deploy.sh
        sudo ./deploy.sh install "$TARGET_DIR"
        exit 0

    elif [ "$ACTION" = "install-release" ]; then
        echo "============================================="
        echo "Installing Bilingual Book Reader from a GitHub Release..."
        echo "============================================="
        # $3 (optional) overrides the owner/name slug; defaults to this repo.
        RELEASE_REPO=${REPO_URL:-"thaonv7995/bilingual-app"}
        TARBALL_URL="https://github.com/$RELEASE_REPO/releases/latest/download/release.tar.gz"
        echo "Target directory: $TARGET_DIR"
        echo "Release tarball:  $TARBALL_URL"

        sudo mkdir -p "$TARGET_DIR"
        echo "Downloading + extracting the latest release (ships a prebuilt v2 dist)..."
        if ! curl -fsSL "$TARBALL_URL" | sudo tar -xz -C "$TARGET_DIR"; then
            echo "Error: failed to download/extract the release tarball from $TARBALL_URL"
            exit 1
        fi

        # Local install: no Node needed since dist/ is bundled (see build step).
        echo "Triggering local installation..."
        cd "$TARGET_DIR"
        sudo chmod +x deploy.sh
        sudo ./deploy.sh install "$TARGET_DIR"
        exit 0

    elif [ "$ACTION" = "update" ]; then
        echo "============================================="
        echo "Bootstrapping Bilingual Book Reader Update..."
        echo "============================================="
        
        if [ ! -d "$TARGET_DIR" ]; then
            echo "Error: Target directory $TARGET_DIR does not exist. Please run install first."
            exit 1
        fi
        
        echo "Target directory: $TARGET_DIR"
        
        # Update repository
        echo "Pulling latest changes from Git..."
        cd "$TARGET_DIR"
        sudo git reset --hard HEAD
        sudo git fetch --all
        CURRENT_BRANCH=$(sudo git rev-parse --abbrev-ref HEAD)
        sudo git pull origin "$CURRENT_BRANCH"
        
        # Run local update installer
        echo "Triggering local update..."
        sudo chmod +x deploy.sh
        sudo ./deploy.sh update "$TARGET_DIR"
        exit 0
        
    elif [ "$ACTION" = "delete" ] || [ "$ACTION" = "uninstall" ]; then
        echo "============================================="
        echo "Bootstrapping Bilingual Book Reader Uninstall..."
        echo "============================================="
        
        if [ ! -d "$TARGET_DIR" ]; then
            echo "Error: Target directory $TARGET_DIR does not exist, nothing to uninstall."
            exit 0
        fi
        
        echo "Target directory: $TARGET_DIR"
        
        # Run local uninstaller
        echo "Triggering local uninstall..."
        cd "$TARGET_DIR"
        sudo chmod +x deploy.sh
        sudo ./deploy.sh delete "$TARGET_DIR"
        exit 0
    else
        echo "Error: Unknown action '$ACTION' for remote bootstrap execution."
        show_help
        exit 1
    fi
fi

# ==================== LOCAL OPERATIONS (SOURCE TREE REQUIRED) ====================
if [ "$IS_SOURCE_TREE" = "false" ]; then
    echo "Error: This action must be executed inside the application source tree."
    show_help
    exit 1
fi

# Set the target dir to the current source directory since we are in-tree
TARGET_DIR="$APP_DIR"

# ==================== ACTION: UPDATE ====================
if [ "$ACTION" = "update" ]; then
    echo "============================================="
    echo "Updating Bilingual Book Reader..."
    echo "============================================="
    
    if [ -d "$TARGET_DIR/.git" ]; then
        echo "Pulling latest changes from Git..."
        cd "$TARGET_DIR"
        git reset --hard HEAD
        git fetch --all
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git pull origin "$CURRENT_BRANCH"
    else
        echo "Not a Git repository, skipping source code pull..."
    fi
fi

# ==================== ACTION: INSTALL / UPDATE (BUILD & RUN WORK) ====================
echo "============================================="
echo "Building and Configuring Process..."
echo "============================================="

# 0. This installer needs systemd (Linux). Fail fast with guidance otherwise.
require_systemd

# 1. Check/Install Python 3 & venv (cross-OS)
echo "Checking Python 3 installation..."
ensure_python

# 2. Bootstrap Virtual Environment if missing or broken
if [ ! -f "$TARGET_DIR/application/.venv/bin/activate" ]; then
    echo "Creating virtual environment..."
    rm -rf "$TARGET_DIR/application/.venv"
    python3 -m venv "$TARGET_DIR/application/.venv"
fi

# 3. Align shebangs and paths
echo "Aligning virtual environment paths..."
cd "$TARGET_DIR/application"
bash scripts/fix-venv.sh

# 4. Update dependencies
echo "Updating Python API dependencies..."
.venv/bin/python3 -m pip install -r backend/requirements-api.txt
cd "$TARGET_DIR"

# 4.5. Build the v2 frontend (React + Vite) so the backend serves v2, not the
# legacy v1 files. main.py only serves v2 when FRONTEND_V2_DIST points at a
# built dist (set in the systemd unit below); dist is gitignored so we build it
# here on every install/update.
V2_DIST_DIR="$TARGET_DIR/application/web-app-v2/dist"

# Skip the frontend build when a prebuilt dist is already present AND Node is not
# installed — the "install from GitHub Release" case: the release tarball ships
# the built dist/, so no Node/npm is needed on the server. Otherwise (git clone,
# or an update on a box that has Node) build fresh so v2 never goes stale.
if [ -f "$V2_DIST_DIR/index.html" ] && ! command -v node &> /dev/null; then
    echo "Using the prebuilt v2 dist from the release tarball (Node not required)."
else
    echo "Checking Node.js (required to build web-app-v2)..."
    ensure_node

    echo "Building v2 frontend (npm ci && npm run build)..."
    cd "$TARGET_DIR/application/web-app-v2"
    npm ci
    npm run build
    cd "$TARGET_DIR"
fi

if [ ! -f "$V2_DIST_DIR/index.html" ]; then
    echo "Error: no v2 dist at $V2_DIST_DIR/index.html (build failed or missing). Aborting."
    exit 1
fi

# 5. Make launcher executable
chmod +x "$TARGET_DIR/server.py"

# 6. Setup systemd service
echo "Configuring systemd service..."
RUN_USER=${SUDO_USER:-$USER}
if [ "$RUN_USER" = "root" ]; then
    # If run via sudo, use the original user to run the server
    RUN_USER=${SUDO_USER:-root}
fi
echo "Running service as user: $RUN_USER"

echo "Ensuring file ownership for $RUN_USER..."
sudo chown -R "$RUN_USER":"$RUN_USER" "$TARGET_DIR"

sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Bilingual Book Reader & AI Proxy Service
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$TARGET_DIR
ExecStart=$TARGET_DIR/application/.venv/bin/python3 server.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=FRONTEND_V2_DIST=$TARGET_DIR/application/web-app-v2/dist
# Optional secrets / overrides (VOCA_API_ORIGIN — legacy VOCA_BRIDGE_ORIGIN is
# still read —, VOCA_BRIDGE_TOKEN, DATABASE_URL, JWT secret, …). Create
# $TARGET_DIR/.env as KEY=VALUE lines; the leading '-' makes the file optional.
EnvironmentFile=-$TARGET_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

# 7. Start / Restart service
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling $SERVICE_NAME service..."
sudo systemctl enable "$SERVICE_NAME"

echo "Restarting $SERVICE_NAME service..."
sudo systemctl restart "$SERVICE_NAME"

echo "============================================="
echo "Service is now running on port 27099 (serving v2 from $V2_DIST_DIR)."
echo "You can check status using: sudo systemctl status $SERVICE_NAME"
echo "Optional: add secrets to $TARGET_DIR/.env then 'sudo systemctl restart $SERVICE_NAME'."
echo "============================================="
