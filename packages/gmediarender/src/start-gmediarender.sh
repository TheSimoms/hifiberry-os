#!/bin/bash
#
# start-gmediarender.sh - GMediaRender (UPnP/DLNA renderer) startup script
# Handles startup with system hostname, sound card detection, and ACR bridge.
#

# User validation check
# Allow running as root, or as the user specified in /etc/hifiberry.user
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "root" ]; then
    if [ -f "/etc/hifiberry.user" ]; then
        AUTHORIZED_USER=$(cat /etc/hifiberry.user 2>/dev/null | tr -d '\n\r ')
        if [ "$CURRENT_USER" != "$AUTHORIZED_USER" ]; then
            echo "Error: not starting gmediarender, this should run as user $AUTHORIZED_USER"
            exit 0
        fi
    else
        echo "Error: not starting gmediarender, /etc/hifiberry.user not found and not running as root"
        exit 0
    fi
fi

# Sound card detection check
echo "Checking for sound card..."
if ! /usr/bin/config-soundcard --detect >/dev/null 2>&1; then
    echo "No sound card detected, not starting gmediarender"
    exit 0
fi
echo "Sound card detected successfully."

# Wait for Avahi (needed for UPnP multicast discovery)
echo "Checking if Avahi daemon is running..."
ATTEMPTS=0
MAX_ATTEMPTS=6  # 6 attempts x 5 seconds = 30 seconds max wait time

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if pgrep avahi-daemon >/dev/null && avahi-browse -a -t >/dev/null 2>&1; then
        echo "Avahi daemon is running and responding."
        break
    else
        ATTEMPTS=$((ATTEMPTS + 1))
        if [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; then
            echo "Avahi daemon is not ready. Waiting 5 seconds... (Attempt $ATTEMPTS/$MAX_ATTEMPTS)"
            sleep 5
        else
            echo "Warning: Avahi daemon is not running or not responding after 30 seconds."
            echo "UPnP discovery may not work correctly."
        fi
    fi
done

# Get the pretty hostname first, then try normal hostname, and finally use HiFiBerry as fallback
PRETTY_HOSTNAME=$(hostnamectl hostname --pretty 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$PRETTY_HOSTNAME" ]; then
    PRETTY_HOSTNAME=$(hostname 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$PRETTY_HOSTNAME" ]; then
        PRETTY_HOSTNAME="HiFiBerry"
    fi
fi

# Stable UUID for UPnP device identity across restarts
if [ -n "${XDG_RUNTIME_DIR:-}" ] || [ -n "${XDG_SESSION_ID:-}" ]; then
    UUID_DIR="${HOME}/.gmediarender"
else
    UUID_DIR="/var/lib/gmediarender"
fi
mkdir -p "$UUID_DIR" 2>/dev/null || true
UUID_FILE="$UUID_DIR/uuid"

# Generate a UUID on first run, reuse it on subsequent starts
if [ ! -f "$UUID_FILE" ]; then
    uuidgen > "$UUID_FILE"
fi
UUID=$(cat "$UUID_FILE")

# Build gmediarender command
GMEDIARENDER_CMD="/usr/bin/gmediarender"
GMEDIARENDER_OPTS=("--friendly-name" "${PRETTY_HOSTNAME} (DLNA)")

# Pass the UUID string for persistent device identity
GMEDIARENDER_OPTS+=("-u" "$UUID")

# Configure GStreamer audio sink
# Use alsasink which will route through PipeWire's ALSA compatibility layer
GMEDIARENDER_OPTS+=("--gstout-audiosink" "alsasink")

# Get hardware device from config-soundcard
if command -v config-soundcard >/dev/null 2>&1; then
    HW_INDEX=$(config-soundcard --no-eeprom --hw 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$HW_INDEX" ]; then
        echo "Using hardware device: hw:$HW_INDEX"
        GMEDIARENDER_OPTS+=("--gstout-audiodevice" "hw:$HW_INDEX")
    fi
fi

echo "Starting gmediarender with device name: ${PRETTY_HOSTNAME} (DLNA)"
echo "Command: $GMEDIARENDER_CMD ${GMEDIARENDER_OPTS[@]}"

# Launch gmediarender and pipe output through the metadata bridge
# The bridge script reads gmrender's log output and posts state/metadata
# updates to ACR's generic player API
exec $GMEDIARENDER_CMD "${GMEDIARENDER_OPTS[@]}" 2>&1 | /usr/bin/gmediarender-bridge
