#!/bin/bash
set -e

ACTION=${1:-"install"}
TARGET_DIR=${2:-"/opt/bilingual-app"}
REPO_URL=${3:-""}

SERVICE_NAME="bilingual-reader"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Detect if we are inside the application source tree
if [ -f "$(dirname "$0")/server.py" ] && [ -d "$(dirname "$0")/application" ]; then
    IS_SOURCE_TREE=true
    APP_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    IS_SOURCE_TREE=false
fi

# Print Help
show_help() {
    echo "Bilingual Book Reader Service Manager"
    echo "Usage:"
    echo "  Local Run:  ./deploy.sh [install|update|delete] [target_dir]"
    echo "  Curl Run:   curl -sSL <url> | bash -s -- install [target_dir] [repo_url]"
    echo ""
    echo "Actions:"
    echo "  install   Install and register the systemd service (default)"
    echo "  update    Pull the latest code from GitHub and restart the process"
    echo "  delete    Stop, disable, and clean up the service and directories"
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

# 1. Check/Install Python 3 & venv
echo "Checking Python 3 installation..."
if ! command -v python3 &> /dev/null; then
    echo "Python 3 not found. Installing..."
    sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip
elif ! python3 -c "import venv" &> /dev/null; then
    echo "Python 3 venv module not found. Installing..."
    sudo apt-get update && sudo apt-get install -y python3-venv
fi

# 2. Bootstrap Virtual Environment if missing
if [ ! -d "$TARGET_DIR/application/.venv" ]; then
    echo "Creating virtual environment..."
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
echo "Service is now running on port 27099."
echo "You can check status using: sudo systemctl status $SERVICE_NAME"
echo "============================================="
