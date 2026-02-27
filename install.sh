#!/bin/bash
set -e

# Tidal Connect installer for HiFiBerry OS NG
# Run as root: sudo ./install.sh

INSTALL_DIR="/opt/tidal-connect"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Preflight checks ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (sudo ./install.sh)"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/Docker/src/bin/tidal_connect_application.gz" ]; then
    echo "Error: run this script from the tidal-connect repository directory"
    exit 1
fi

# Detect the HiFiBerry audio user (runs PipeWire)
if [ -f /etc/hifiberry.user ]; then
    AUDIO_USER=$(cat /etc/hifiberry.user)
else
    AUDIO_USER=$(logname 2>/dev/null || echo "")
fi

if [ -z "$AUDIO_USER" ]; then
    echo "Error: cannot determine audio user. Set it in /etc/hifiberry.user"
    exit 1
fi

AUDIO_UID=$(id -u "$AUDIO_USER")
AUDIO_HOME=$(eval echo "~$AUDIO_USER")

echo "Tidal Connect Installer"
echo "======================="
echo "Audio user:  $AUDIO_USER (uid $AUDIO_UID)"
echo "Install dir: $INSTALL_DIR"
echo ""

# --- Step 1: Install Docker if missing ---

if ! command -v docker &>/dev/null; then
    echo "[1/6] Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-v2
    systemctl enable docker
    systemctl start docker
    usermod -aG docker "$AUDIO_USER"
else
    echo "[1/6] Docker already installed"
fi

# --- Step 2: Check kernel page size (Pi 5/CM5 needs 4K pages) ---

PAGE_SIZE=$(getconf PAGESIZE)
if [ "$PAGE_SIZE" -gt 4096 ]; then
    echo "[2/6] Fixing kernel page size (currently ${PAGE_SIZE}, need 4096)..."
    if ! grep -q '^kernel=kernel8.img' /boot/firmware/config.txt 2>/dev/null; then
        echo "" >> /boot/firmware/config.txt
        echo "# 4K page kernel for ARM32 Docker compatibility (tidal-connect)" >> /boot/firmware/config.txt
        echo "kernel=kernel8.img" >> /boot/firmware/config.txt
        NEEDS_REBOOT=1
    fi
else
    echo "[2/6] Kernel page size OK (${PAGE_SIZE})"
fi

# --- Step 3: Ensure PipeWire PulseAudio socket is available ---

PULSE_SOCKET="/run/user/${AUDIO_UID}/pulse/native"
PULSE_COOKIE="${AUDIO_HOME}/.config/pulse/cookie"

echo "[3/6] Checking PipeWire PulseAudio..."
if [ -S "$PULSE_SOCKET" ]; then
    echo "  PulseAudio socket: $PULSE_SOCKET (OK)"
else
    echo "  PulseAudio socket not found, starting pipewire-pulse..."
    sudo -u "$AUDIO_USER" XDG_RUNTIME_DIR="/run/user/${AUDIO_UID}" \
        systemctl --user start pipewire-pulse.socket pipewire-pulse.service 2>/dev/null || true
    sleep 1
    if [ ! -S "$PULSE_SOCKET" ]; then
        echo "  WARNING: PulseAudio socket still not available at $PULSE_SOCKET"
        echo "  Tidal Connect will not have audio until pipewire-pulse is running."
    fi
fi

# --- Step 4: Install files ---

echo "[4/6] Installing files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Copy everything
cp -r "$SCRIPT_DIR/Docker" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/entrypoint.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/tidal-bridge.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/tidal-watchdog.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/volume-bridge.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/wait-for-avahi.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/wait-for-container.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/wait-for-mdns-clear.sh" "$INSTALL_DIR/"

# Generate .env with hostname as friendly name
DEVICE_NAME=$(hostname -s | sed 's/[^a-zA-Z0-9 _-]//g')
[ -z "$DEVICE_NAME" ] && DEVICE_NAME="HiFiBerry"
cat > "$INSTALL_DIR/.env" <<EOF
FRIENDLY_NAME=${DEVICE_NAME}
MODEL_NAME=HiFiBerry
MQA_PASSTHROUGH=false
MQA_CODEC=false
PLAYBACK_DEVICE=default
EOF

# Generate docker-compose.yml with correct paths for this system
cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  tidal-connect:
    container_name: tidal_connect
    build:
      context: .
      dockerfile: Docker/Dockerfile
    image: hifiberry-tidal-connect:latest
    tty: true
    network_mode: host
    devices:
      - /dev/snd
    volumes:
      - ./entrypoint.sh:/entrypoint.sh:ro
      - /var/run/dbus:/var/run/dbus
      - ${PULSE_SOCKET}:${PULSE_SOCKET}
      - ${PULSE_COOKIE}:/root/.config/pulse/cookie:ro
    environment:
      - PULSE_SERVER=unix:${PULSE_SOCKET}
      - PULSE_COOKIE=/root/.config/pulse/cookie
    env_file: .env
    restart: "no"
EOF

chmod +x "$INSTALL_DIR/entrypoint.sh"
chmod +x "$INSTALL_DIR/tidal-bridge.sh"
chmod +x "$INSTALL_DIR/tidal-watchdog.sh"

# Register tidal as a player in AudioControl (ACR) via players.d/
ACR_PLAYERS_D="/etc/audiocontrol/players.d"
if [ -d "/etc/audiocontrol" ]; then
    mkdir -p "$ACR_PLAYERS_D"
    cat > "$ACR_PLAYERS_D/tidal.json" <<'PLAYEREOF'
{
    "generic": {
        "name": "tidal",
        "enable": true,
        "supports_api_events": true,
        "capabilities": ["killable"]
    }
}
PLAYEREOF
    echo "  Registered tidal player in $ACR_PLAYERS_D/tidal.json"
else
    echo "  WARNING: /etc/audiocontrol not found, skipping ACR player registration"
    echo "  Metadata bridge requires hifiberry-audiocontrol >= 0.6.17"
fi

# Register in Web UI player registry
HBOS_PLAYERS_D="/etc/hifiberry/players.d"
mkdir -p "$HBOS_PLAYERS_D/icons"

cat > "$HBOS_PLAYERS_D/tidal.json" <<'PLAYERUIEOF'
{
    "name": "Tidal",
    "provided_by": "tidal-connect",
    "systemd_service": "tidal-connect",
    "icon": "tidal",
    "allow_change": true
}
PLAYERUIEOF

if [ -f "$SCRIPT_DIR/icons/tidal.svg" ]; then
    cp "$SCRIPT_DIR/icons/tidal.svg" "$HBOS_PLAYERS_D/icons/tidal.svg"
    echo "  Installed tidal icon"
fi

echo "  Registered tidal in Web UI player registry"

# Register systemd permissions via configserver drop-in
mkdir -p /etc/configserver/conf.d
cat > /etc/configserver/conf.d/tidal-connect.json <<'CONFEOF'
{
    "systemd": {
        "tidal-connect": "all"
    }
}
CONFEOF
echo "  Registered tidal-connect systemd permissions"

# --- Step 5: Build Docker image ---

echo "[5/6] Building Docker image (this may take a few minutes)..."
cd "$INSTALL_DIR"
docker compose build --no-cache

# --- Step 6: Install systemd services ---

echo "[6/6] Installing systemd services..."
cp "$SCRIPT_DIR/tidal-connect.service" /etc/systemd/system/
cp "$SCRIPT_DIR/tidal-bridge.service" /etc/systemd/system/
cp "$SCRIPT_DIR/tidal-watchdog.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable tidal-connect.service
systemctl enable tidal-bridge.service

# --- Done ---

echo ""
echo "Installation complete!"
echo ""

if [ "${NEEDS_REBOOT:-0}" = "1" ]; then
    echo "*** REBOOT REQUIRED ***"
    echo "The kernel was changed to 4K page size (needed for ARM32 Docker containers"
    echo "on Pi 5/CM5). Run: sudo reboot"
    echo ""
    echo "After reboot, Tidal Connect will start automatically."
else
    echo "Starting Tidal Connect..."
    systemctl start tidal-connect.service
    systemctl start tidal-bridge.service
    sleep 3

    if systemctl is-active --quiet tidal-connect.service; then
        echo "Tidal Connect is running!"
        echo "Look for '${DEVICE_NAME}' in your Tidal app's device list."
    else
        echo "WARNING: Service failed to start. Check: journalctl -u tidal-connect"
    fi
fi
