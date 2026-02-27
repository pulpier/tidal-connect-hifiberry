#!/bin/bash
# Wait for mDNS registration to clear before restarting
# Handles both normal restarts and cold boot scenarios

FRIENDLY_NAME="${1}"
MAX_WAIT="${2:-15}"
CHECK_INTERVAL="${3:-2}"

# If we can't get the friendly name, fall back to minimum safe delay
if [ -z "$FRIENDLY_NAME" ]; then
    if [ -f "Docker/.env" ]; then
        FRIENDLY_NAME=$(grep "^FRIENDLY_NAME=" Docker/.env | cut -d= -f2)
    fi
fi

if [ -z "$FRIENDLY_NAME" ]; then
    echo "WARNING: Cannot determine FRIENDLY_NAME, using minimum 5s delay"
    sleep 5
    exit 0
fi

# Check if Avahi is in collision state (e.g., from cold boot with stale cache)
check_avahi_collision() {
    # Look for recent collision errors in journal
    if journalctl -u avahi-daemon --since "30 seconds ago" 2>/dev/null | grep -qi "collision\|conflict"; then
        return 0  # Collision detected
    fi
    return 1  # No collision
}

# If Avahi is in collision state, we need to clear it
if check_avahi_collision; then
    echo "⚠️  Avahi collision state detected (likely from cold boot)"
    echo "   Restarting Avahi to clear collision state..."
    systemctl restart avahi-daemon
    
    # Wait for Avahi to fully restart
    sleep 3
    
    # Wait for it to become active
    local waited=0
    while [ $waited -lt 10 ]; do
        if systemctl is-active --quiet avahi-daemon; then
            echo "   Avahi restarted successfully"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    # Give mDNS cache time to clear after Avahi restart
    echo "   Waiting for mDNS cache to clear..."
    sleep 5
fi

# Check if avahi-browse is available for active checking
if ! command -v avahi-browse &> /dev/null; then
    echo "avahi-browse not available, using safe 5s delay"
    sleep 5
    exit 0
fi

echo "Waiting for mDNS name '$FRIENDLY_NAME' to clear..."

elapsed=0
consecutive_clears=0

while [ $elapsed -lt $MAX_WAIT ]; do
    # Check if the name is still registered
    # We want to see it disappear, then stay gone for at least 2 checks
    if timeout 2 avahi-browse -t -p -r _tidalconnect._tcp 2>/dev/null | grep -q "$FRIENDLY_NAME"; then
        echo "  mDNS name still registered (${elapsed}s)"
        consecutive_clears=0
    else
        consecutive_clears=$((consecutive_clears + 1))
        if [ $consecutive_clears -ge 2 ]; then
            echo "mDNS name cleared (waited ${elapsed}s)"
            exit 0
        fi
    fi
    
    sleep $CHECK_INTERVAL
    elapsed=$((elapsed + CHECK_INTERVAL))
done

# Even if we couldn't verify clearance, we've waited a reasonable time
echo "mDNS check timeout after ${elapsed}s - proceeding anyway"
exit 0

