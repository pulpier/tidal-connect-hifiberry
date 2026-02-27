#!/bin/bash

# Tidal Connect Bridge: Syncs volume and exports metadata for AudioControl2
# This enables phone volume control and HifiBerry UI metadata display

ALSA_MIXER="Digital"  # HifiBerry DAC+ uses the Digital mixer
STATUS_FILE="/tmp/tidal-status.json"
PREV_VOLUME=-1
PREV_HASH=""

echo "Starting Tidal Connect bridge..."
echo "Monitoring speaker controller and syncing to ALSA mixer: $ALSA_MIXER"
echo "Exporting metadata to: $STATUS_FILE"

# Function to check if container is ready
is_container_ready() {
    docker ps | grep -q tidal_connect && \
    docker exec tidal_connect pgrep -f "speaker_controller_application" >/dev/null 2>&1
}

# Function to wait for container with retry logic
wait_for_container() {
    local max_attempts=60  # 60 * 2s = 2 minutes
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if is_container_ready; then
            echo "Container is ready (attempt $((attempt + 1)))"
            return 0
        fi
        
        if [ $((attempt % 10)) -eq 0 ] && [ $attempt -gt 0 ]; then
            echo "Waiting for container... ($attempt attempts)"
        fi
        
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "ERROR: Container did not become ready after $max_attempts attempts"
    return 1
}

# Wait for initial container startup
if ! wait_for_container; then
    echo "Exiting: Container not available"
    exit 1
fi

CONSECUTIVE_ERRORS=0
MAX_CONSECUTIVE_ERRORS=5

while true; do
    # Check if container is still available
    if ! is_container_ready; then
        echo "[$(date '+%H:%M:%S')] Container not available, waiting for restart..."
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        
        if [ $CONSECUTIVE_ERRORS -ge $MAX_CONSECUTIVE_ERRORS ]; then
            echo "Waiting for container to become available..."
            if wait_for_container; then
                echo "Container recovered, resuming monitoring"
                CONSECUTIVE_ERRORS=0
            else
                echo "Container did not recover, retrying..."
                sleep 10
            fi
        else
            sleep 2
        fi
        continue
    fi
    
    # Reset error counter on successful connection
    if [ $CONSECUTIVE_ERRORS -gt 0 ]; then
        echo "[$(date '+%H:%M:%S')] Container connection restored"
        CONSECUTIVE_ERRORS=0
    fi
    
    # Capture tmux output from speaker_controller_application
    TMUX_OUTPUT=$(docker exec -t tidal_connect /usr/bin/tmux capture-pane -pS -50 2>/dev/null | tr -d '\r')
    
    if [ -z "$TMUX_OUTPUT" ]; then
        sleep 0.5
        continue
    fi
    
    # Parse playback state (PLAYING, PAUSED, IDLE, BUFFERING)
    STATE=$(echo "$TMUX_OUTPUT" | grep -o 'PlaybackState::[A-Z]*' | cut -d: -f3)
    [ -z "$STATE" ] && STATE="IDLE"
    
    # Parse metadata fields
    # Extract value up to first "xx" separator or end of line, then trim trailing spaces and 'x' characters
    ARTIST=$(echo "$TMUX_OUTPUT" | grep '^xartists:' | sed 's/^xartists: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    ALBUM=$(echo "$TMUX_OUTPUT" | grep '^xalbum name:' | sed 's/^xalbum name: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    TITLE=$(echo "$TMUX_OUTPUT" | grep '^xtitle:' | sed 's/^xtitle: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    DURATION=$(echo "$TMUX_OUTPUT" | grep '^xduration:' | sed 's/^xduration: //' | sed 's/xx.*$//' | sed 's/[[:space:]]*$//')
    SHUFFLE=$(echo "$TMUX_OUTPUT" | grep '^xshuffle:' | sed 's/^xshuffle: //' | sed 's/xx.*$//' | sed 's/[[:space:]]*$//')
    
    # Parse position (e.g., "38 / 227")
    POSITION_LINE=$(echo "$TMUX_OUTPUT" | grep -E '^ *[0-9]+ */ *[0-9]+$' | tr -d ' ')
    POSITION=$(echo "$POSITION_LINE" | cut -d'/' -f1)
    [ -z "$POSITION" ] && POSITION=0
    
    # Parse volume from volume bar (count # symbols)
    VOLUME=$(echo "$TMUX_OUTPUT" | grep 'l.*#.*k$' | tr -cd '#' | wc -c)
    
    # Convert duration from milliseconds to seconds if present
    if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ]; then
        DURATION_SEC=$((DURATION / 1000))
    else
        DURATION_SEC=0
    fi
    
    # Create status hash to detect changes
    STATUS_HASH="${STATE}|${ARTIST}|${TITLE}|${ALBUM}|${POSITION}|${VOLUME}"
    
    # Update ALSA volume if changed
    if [ "$VOLUME" != "$PREV_VOLUME" ] && [ -n "$VOLUME" ] && [ "$VOLUME" -ge 0 ]; then
        # Map volume: speaker controller shows 0-38 # symbols
        # Map to ALSA Digital mixer range 0-207
        ALSA_VALUE=$((VOLUME * 207 / 38))
        
        # Clamp to valid range
        if [ "$ALSA_VALUE" -gt 207 ]; then
            ALSA_VALUE=207
        fi
        
        echo "[$(date '+%H:%M:%S')] Volume changed: $VOLUME/38 -> Setting ALSA $ALSA_MIXER to $ALSA_VALUE/207"
        docker exec tidal_connect amixer set "$ALSA_MIXER" "$ALSA_VALUE" > /dev/null 2>&1
        
        PREV_VOLUME=$VOLUME
    fi
    
    # Export metadata to JSON file if anything changed
    if [ "$STATUS_HASH" != "$PREV_HASH" ]; then
        # Get current timestamp
        TIMESTAMP=$(date +%s)
        
        # Escape quotes in strings for JSON
        ARTIST_JSON=$(echo "$ARTIST" | sed 's/"/\\"/g')
        TITLE_JSON=$(echo "$TITLE" | sed 's/"/\\"/g')
        ALBUM_JSON=$(echo "$ALBUM" | sed 's/"/\\"/g')
        
        # Write JSON status file (atomic write via temp file)
        cat > "${STATUS_FILE}.tmp" <<EOF
{
  "state": "$STATE",
  "artist": "$ARTIST_JSON",
  "title": "$TITLE_JSON",
  "album": "$ALBUM_JSON",
  "duration": $DURATION_SEC,
  "position": $POSITION,
  "volume": $VOLUME,
  "shuffle": "$SHUFFLE",
  "timestamp": $TIMESTAMP
}
EOF
        mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        
        echo "[$(date '+%H:%M:%S')] Updated metadata: $STATE - $ARTIST - $TITLE"
        PREV_HASH=$STATUS_HASH
    fi
    
    sleep 0.5  # Check twice per second
done

