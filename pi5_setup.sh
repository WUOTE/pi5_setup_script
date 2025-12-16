#!/bin/bash

set -e  # Exit on error
trap 'echo "Error occurred at line $LINENO. Exiting."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_FILE="$HOME/.pi5_setup_stage"
LOG_FILE="$HOME/pi5_setup.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Get current stage
get_stage() {
    if [ -f "$STAGE_FILE" ]; then
        cat "$STAGE_FILE"
    else
        echo "0"
    fi
}

# Set stage
set_stage() {
    echo "$1" > "$STAGE_FILE"
}

# --- Stage Definitions ---
declare -a STAGE_NAMES
STAGE_NAMES[0]="System Update & Reboot"
STAGE_NAMES[1]="Argon EEPROM Install & Reboot"
STAGE_NAMES[2]="Argon One Script Install & Reboot"
STAGE_NAMES[3]="Force SD Card Boot & Reboot"
STAGE_NAMES[4]="Tailscale Installation"
STAGE_NAMES[5]="AdGuard Home Installation"
STAGE_NAMES[6]="Docker Install & Logout"
STAGE_NAMES[7]="Portainer Installation"
STAGE_NAMES[8]="N8N Installation"
STAGE_NAMES[9]="N8N Workflow Import"
STAGE_NAMES[10]="Git Repo Clone (Host)"
STAGE_NAMES[11]="RPI-Clone Setup & Final Summary"

# Configuration variables
# Current timezone (surely)
TIMEZONE="${TIMEZONE:-Asia/Bangladesh}"

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    error "Please do not run this script as root. Run as regular user with sudo privileges."
    exit 1
fi

CURRENT_STAGE=$(get_stage)
log "Script started. Current stage file indicates next stage is: $CURRENT_STAGE"

# --- Display Interactive Menu ---
echo -e "\n--- Raspberry Pi Setup Stages ---"
for i in "${!STAGE_NAMES[@]}"; do
    # Format stage number for alignment
    printf -v STAGE_NUM "%-2s" "$i"
    
    if [ "$i" -lt "$CURRENT_STAGE" ]; then
        echo -e "  ${GREEN}[DONE]${NC}     Stage $STAGE_NUM: ${STAGE_NAMES[$i]}"
    elif [ "$i" -eq "$CURRENT_STAGE" ]; then
        echo -e "  ${YELLOW}[NEXT]${NC}     Stage $STAGE_NUM: ${STAGE_NAMES[$i]}"
    else
        echo -e "  [PENDING]  Stage $STAGE_NUM: ${STAGE_NAMES[$i]}"
    fi
done
echo -e "-----------------------------------\n"
# --- End Menu ---


# --- Interactive Stage Selection ---
read -p "Enter stage to run (0-11) [Default: $CURRENT_STAGE]: " CHOSEN_STAGE
TARGET_STAGE="${CHOSEN_STAGE:-$CURRENT_STAGE}"
# -----------------------------------

# Validate input
if ! [[ "$TARGET_STAGE" =~ ^[0-9]+$ ]] || [ "$TARGET_STAGE" -lt 0 ] || [ "$TARGET_STAGE" -gt 11 ]; then
    error "Invalid selection. Please enter a number between 0 and 11."
    exit 1
fi

log "--- User selected Stage $TARGET_STAGE: ${STAGE_NAMES[$TARGET_STAGE]} ---"

case $TARGET_STAGE in
    0)
        log "=== STAGE 0: ${STAGE_NAMES[0]} ==="
        
        log "Updating system packages..."
        sudo apt update
        # full-upgrade replaces the need for upgrade + dist-upgrade
        sudo apt full-upgrade -y
        sudo apt autoremove -y
        sudo apt clean
        
        set_stage 1
        log "Stage 0 complete. Rebooting..."
        sleep 2
        sudo reboot
        ;;
        
    1)
        log "=== STAGE 1: ${STAGE_NAMES[1]} ==="
        
        log "Installing Argon EEPROM..."
        log "This may update bootloader settings."
        curl -fsSL https://download.argon40.com/argon-eeprom.sh | bash
        
        set_stage 2
        log "Stage 1 complete. Rebooting..."
        sleep 2
        sudo reboot
        ;;
        
    2)
        log "=== STAGE 2: ${STAGE_NAMES[2]} ==="
        
        log "Installing Argon One script..."
        curl -fsSL https://download.argon40.com/argon1.sh | bash
        
        set_stage 3
        log "Stage 2 complete. Rebooting..."
        sleep 2
        sudo reboot
        ;;

    3)
        log "=== STAGE 3: ${STAGE_NAMES[3]} ==="
        
        log "Setting bootloader to prioritize SD Card (B1)..."
        log "This prevents a failed boot from a blank NVMe after Argon EEPROM update."
        
        # B1 = Boot from SD Card
        # We are forcing B1 to ensure setup continues from SD Card
        sudo raspi-config nonint do_boot_order B1
        
        log "Boot order set."
        set_stage 4
        log "Stage 3 complete. Rebooting to apply boot order..."
        sleep 2
        sudo reboot
        ;;
        
    4)
        log "=== STAGE 4: ${STAGE_NAMES[4]} ==="
        
        log ""
        echo -e "${YELLOW}Please enter your Tailscale auth key:${NC}"
        read -r TAILSCALE_AUTH_KEY
        
        if [ -z "$TAILSCALE_AUTH_KEY" ]; then
            error "No auth key provided. Exiting."
            warning "Please run the script again and provide a valid Tailscale auth key."
            exit 1
        fi
        
        log "Installing Tailscale and connecting with exit node advertisement..."
        curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --advertise-exit-node --accept-dns=false
        
        log "Enabling IP forwarding for exit node functionality..."
        echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
        echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
        sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
        
        set_stage 5
        log "Stage 4 complete. Run this script again to continue."
        sleep 2
        ;;
        
    5)
        log "=== STAGE 5: ${STAGE_NAMES[5]} ==="
        
        cd "$HOME"
        
        log "Installing jq to parse GitHub API..."
        sudo apt-get update && sudo apt-get install -y jq
        
        log "Finding latest AdGuard Home release for arm64..."
        LATEST_URL=$(curl -s "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.assets[] | select(.name | test("linux_arm64.tar.gz")) | .browser_download_url')

        if [ -z "$LATEST_URL" ] || [ "$LATEST_URL" == "null" ]; then
            error "Could not find latest AdGuard Home URL. Exiting."
            exit 1
        fi
        
        log "Downloading AdGuard Home: $LATEST_URL"
        wget -q --show-progress -O AdGuardHome_linux_arm64.tar.gz "$LATEST_URL"
        
        log "Extracting AdGuard Home..."
        # --- THIS IS THE CORRECTED LINE ---
        tar -xzf AdGuardHome_linux_arm64.tar.gz
        
        # Handle case where directory name might change slightly
        rm -f AdGuardHome_linux_arm64.tar.gz
        if [ ! -d "AdGuardHome" ]; then
            error "Extracted directory 'AdGuardHome' not found. Please check extraction."
            exit 1
        fi
        
        cd AdGuardHome
        
        log "Installing AdGuard Home as service..."
        sudo ./AdGuardHome -s install
        
        log "AdGuard Home installed. Access it at http://$(hostname -I | awk '{print $1}'):3000"
        warning "Manual steps required:"
        warning "1. Complete AdGuard Home setup in web interface"
        warning "2. Set to listen on all interfaces (0.0.0.0)"
        warning "3. Configure Cloudflare TLS: tls://one.one.one.one"
        warning "4. Set rate limit to 0"
        warning "5. Add filters as needed"
        warning "6. Add AdGuard's Tailscale IP to Tailscale admin DNS settings"
        
        set_stage 6
        log "Stage 5 complete. Run this script again to continue."
        sleep 2
        ;;
        
    6)
        log "=== STAGE 6: ${STAGE_NAMES[6]} ==="
        
        log "Removing old Docker packages..."
        for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do 
            sudo apt-get remove -y $pkg 2>/dev/null || true
        done
        
        log "Installing prerequisites..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        
        log "Adding Docker GPG key..."
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        
        log "Adding Docker repository..."
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update
        
        log "Installing Docker..."
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        log "Configuring Docker permissions..."
        sudo groupadd docker 2>/dev/null || true
        sudo usermod -aG docker $USER
        
        log "Testing Docker..."
        # Use sudo for this first test since we haven't logged out/in
        sudo docker run --rm hello-world
        
        warning "Docker installed but you need to log out and back in for group permissions to take effect."
        warning "After logging back in, run this script again to continue."
        
        set_stage 7
        log "Stage 6 complete. Please log out and log back in, then run this script again."
        exit 0
        ;;
        
    7)
        log "=== STAGE 7: ${STAGE_NAMES[7]} ==="
        
        # Test if docker works without sudo
        if ! docker ps >/dev/null 2>&1; then
            error "Docker group permissions not active. Please log out and back in."
            warning "Run this script again and re-select stage 7 after logging in."
            exit 1
        fi
        
        log "Creating Portainer volume..."
        docker volume create portainer_data
        
        log "Starting Portainer..."
        docker run -d \
            -p 8000:8000 \
            -p 9443:9443 \
            --name portainer \
            --restart=always \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            portainer/portainer-ee:sts
        
        log "Portainer installed. Access it at https://$(hostname -I | awk '{print $1}'):9443"
        
        set_stage 8
        log "Stage 7 complete. Run this script again to continue."
        sleep 2
        ;;
        
    8)
        log "=== STAGE 8: ${STAGE_NAMES[8]} ==="
        
        log "Creating N8N volume..."
        docker volume create n8n_data
        
        log "Starting N8N..."
        docker run -d \
            --name n8n \
            --restart unless-stopped \
            -p 5678:5678 \
            -e GENERIC_TIMEZONE="$TIMEZONE" \
            -e TZ="$TIMEZONE" \
            -e N8N_HIDE_USAGE_PAGE="false" \
            -e N8N_ONBOARDING_FLOW_DISABLED="true" \
            -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
            -e N8N_DIAGNOSTICS_ENABLED="false" \
            -e N8N_DEFAULT_LOCALE="en" \
            -e N8N_SECURE_COOKIE="false" \
            -e N8N_RUNNERS_ENABLED=true \
            -e NODES_EXCLUDE="[]" \
            -e N8N_GIT_NODE_DISABLE_BARE_REPOS="false" \
            -e N8N_RESTRICT_FILE_ACCESS_TO="/home/node/git/dunkbin-stats-images/" \
            -v n8n_data:/home/node/.n8n \
            docker.n8n.io/n8nio/n8n
            
        log "Waiting for N8N to start..."
        # Robust wait loop instead of 'sleep 10'
        for _ in {1..30}; do # Wait up to 30 seconds
            if curl -fs "http://127.0.0.1:5678/healthz" > /dev/null; then
                log "N8N is up and running!"
                break
            fi
            sleep 1
        done
        
        if ! curl -fs "http://127.0.0.1:5678/healthz" > /dev/null; then
            error "N8N failed to start. Check docker logs for 'n8n' container."
            exit 1
        fi
        
        set_stage 9
        log "Stage 8 complete. Run this script again to continue."
        sleep 2
        ;;
        
    9)
        log "=== STAGE 9: ${STAGE_NAMES[9]} ==="
        
        # Check if N8N container is running
        if ! docker ps | grep -q n8n; then
            error "N8N container is not running. Please check Docker logs."
            exit 1
        fi
        
        log "Cloning dunkbin-stats-images repository into N8N container..."
        docker exec -u node n8n /bin/sh -c "cd /home/node && git clone https://github.com/WUOTE/dunkbin-stats-images.git" || {
            warning "Repository might already exist or git not available in container. Attempting pull..."
            docker exec -u node n8n /bin/sh -c "cd /home/node/dunkbin-stats-images && git pull" || true
        }
        
        log "Importing N8N workflows..."
        docker exec -u node n8n /bin/sh -c "n8n import:workflow --separate --input=/home/node/dunkbin-stats-images/n8n_workflows" || {
            error "Failed to import workflows. You may need to do this manually."
            warning "To import manually, run:"
            warning "docker exec -u node n8n /bin/sh -c 'n8n import:workflow --separate --input=/home/node/dunkbin-stats-images/n8n_workflows'"
        }
        
        log "N8N workflows imported successfully."
        log "Access N8N at http://$(hostname -I | awk '{print $1}'):5678"
        
        set_stage 10
        log "Stage 9 complete. Run this script again to continue."
        sleep 2
        ;;
        
    10)
        log "=== STAGE 10: ${STAGE_NAMES[10]} ==="
        
        log "Cloning repository to host machine..."
        mkdir -p "$HOME/git"
        cd "$HOME/git"
        
        if [ -d "dunkbin-stats-images" ]; then
            log "Repository already exists, pulling latest changes..."
            cd dunkbin-stats-images
            git pull
        else
            log "Cloning repository..."
            git clone https://github.com/WUOTE/dunkbin-stats-images.git
            cd dunkbin-stats-images
        fi
        
        set_stage 11
        log "Stage 10 complete. Run this script again for final stage."
        sleep 2
        ;;
        
    11)
        log "=== STAGE 11: ${STAGE_NAMES[11]} ==="
        
        log "Installing rpi-clone..."
        cd "$HOME/git"
        
        if [ -d "rpi-clone" ]; then
            log "rpi-clone already exists, pulling latest changes..."
            cd rpi-clone
            git pull
        else
            log "Cloning rpi-clone repository..."
            git clone https://github.com/geerlingguy/rpi-clone.git
            cd rpi-clone
        fi
        
        log "Installing rpi-clone scripts..."
        sudo cp rpi-clone rpi-clone-setup /usr/local/sbin
        
        log "Checking for NVMe drive..."
        if lsblk | grep -q "nvme0n1"; then
            warning "NVMe drive detected (nvme0gpn1)"
            warning "Ready to clone SD card to NVMe drive"
            warning ""
            warning "To clone your SD card to NVMe, run:"
            warning "  sudo rpi-clone nvme0n1"
            warning ""
            warning "This will:"
            warning "1. Create a bootable backup of your SD card on the NVMe"
            warning "2. Allow you to boot from NVMe for better performance"
            warning "3. Keep SD card as backup"
            warning ""
            warning "CAUTION: This will ERASE all data on nvme0n1!"
        else
            warning "No NVMe drive detected at nvme0n1"
            warning "rpi-clone installed. When you connect an NVMe drive, run:"
            warning "  lsblk  (to identify the drive)"
            warning "  sudo rpi-clone nvme0n1  (or appropriate device name)"
        fi
        
        log ""
        log "=========================================="
        log "=== SETUP COMPLETE ==="
        log "=========================================="
        log ""
        log "Services installed:"
        log "- Tailscale: $(tailscale ip 2>/dev/null || echo 'Run: sudo tailscale up')"
        log "- AdGuard Home: http://$(hostname -I | awk '{print $1}'):3000"
        log "- Portainer: https://$(hostname -I | awk '{print $1}'):9443"
        log "- N8N: http://$(hostname -I | awk '{print $1}'):5678"
        log "- rpi-clone: Installed at /usr/local/sbin/rpi-clone"
        log ""
        log "Manual steps remaining:"
        log "1. Configure AdGuard Home filters and upstream DNS"
        log "2. Add AdGuard's Tailscale IP to Tailscale DNS settings"
        log "3. Access Portainer to manage containers"
        log "4. Configure N8N workflows as needed"
        log "5. (Optional) Clone to NVMe: sudo rpi-clone nvme0n1"
        log ""
        log "To reset and start over: rm $STAGE_FILE"
        log "Setup log saved to: $LOG_FILE"
        
        # Clean up stage file
        rm -f "$STAGE_FILE"
        
        log "All done! 🎉"
        ;;
        
    *)
        # This case is now technically unreachable due to the validation
        error "Unknown stage: $TARGET_STAGE"
        error "Valid stages are 0-11."
        error "To reset, run: rm $STAGE_FILE"
        exit 1
        ;;
esac
