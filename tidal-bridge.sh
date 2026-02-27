#!/bin/bash

# Tidal Connect Bridge for HiFiBerry OS NG
# Monitors speaker_controller_application via tmux,
# exports metadata to /tmp/tidal-status.json and POSTs events to ACR
#
# Volume is NOT managed here — it is controlled by ACR/configurator.

ACR_URL="http://localhost:1080/api/player/tidal/update"
STATUS_FILE="/tmp/tidal-status.json"
PREV_STATE=""
PREV_TITLE=""
PREV_ARTIST=""
PREV_POSITION=-1

echo "Starting Tidal Connect bridge..."
echo "ACR endpoint: $ACR_URL"
echo "Status file: $STATUS_FILE"

is_container_ready() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tidal_connect$' && \
    docker exec tidal_connect pgrep -f "speaker_controller_application" >/dev/null 2>&1
}

wait_for_container() {
    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if is_container_ready; then
            echo "Container ready (attempt $((attempt + 1)))"
            return 0
        fi
        [ $((attempt % 10)) -eq 0 ] && [ $attempt -gt 0 ] && echo "Waiting for container... ($attempt attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    echo "ERROR: Container not ready after $max_attempts attempts"
    return 1
}

post_to_acr() {
    local json="$1"
    curl -s -o /dev/null -X POST "$ACR_URL" \
        -H "Content-Type: application/json" \
        -d "$json" 2>/dev/null
}

# Wait for initial container startup
if ! wait_for_container; then
    echo "Exiting: Container not available"
    exit 1
fi

CONSECUTIVE_ERRORS=0
LOOP_COUNT=0
RESYNC_INTERVAL=60  # Re-send full state every 60 iterations (~30s) to survive ACR restarts

while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))
    if ! is_container_ready; then
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        if [ $CONSECUTIVE_ERRORS -ge 5 ]; then
            # Notify ACR that tidal is stopped
            if [ "$PREV_STATE" != "IDLE" ]; then
                post_to_acr '{"type":"state_changed","state":"stopped"}'
                PREV_STATE="IDLE"
            fi
            echo "Waiting for container to recover..."
            if wait_for_container; then
                echo "Container recovered"
                CONSECUTIVE_ERRORS=0
            else
                sleep 10
            fi
        else
            sleep 2
        fi
        continue
    fi
    CONSECUTIVE_ERRORS=0

    # Capture tmux output from speaker_controller_application
    TMUX_OUTPUT=$(docker exec -t tidal_connect /usr/bin/tmux capture-pane -pS -50 2>/dev/null | tr -d '\r')

    if [ -z "$TMUX_OUTPUT" ]; then
        sleep 0.5
        continue
    fi

    # Parse playback state
    STATE=$(echo "$TMUX_OUTPUT" | grep -o 'PlaybackState::[A-Z]*' | tail -1 | cut -d: -f3)
    [ -z "$STATE" ] && STATE="IDLE"

    # Parse metadata
    ARTIST=$(echo "$TMUX_OUTPUT" | grep '^xartists:' | tail -1 | sed 's/^xartists: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    ALBUM=$(echo "$TMUX_OUTPUT" | grep '^xalbum name:' | tail -1 | sed 's/^xalbum name: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    TITLE=$(echo "$TMUX_OUTPUT" | grep '^xtitle:' | tail -1 | sed 's/^xtitle: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//')
    DURATION=$(echo "$TMUX_OUTPUT" | grep '^xduration:' | tail -1 | sed 's/^xduration: //' | sed 's/xx.*$//' | sed 's/[[:space:]]*$//')

    # Parse position (e.g., "38 / 227")
    POSITION_LINE=$(echo "$TMUX_OUTPUT" | grep -E '^ *[0-9]+ */ *[0-9]+$' | tail -1 | tr -d ' ')
    POSITION=$(echo "$POSITION_LINE" | cut -d'/' -f1)
    [ -z "$POSITION" ] && POSITION=0

    # Duration: ms -> seconds
    if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
        DURATION_SEC=$((DURATION / 1000))
    else
        DURATION_SEC=0
    fi

    # Periodic full re-sync (handles ACR restarts)
    FORCE_RESYNC=false
    if [ $((LOOP_COUNT % RESYNC_INTERVAL)) -eq 0 ]; then
        FORCE_RESYNC=true
    fi

    # Notify ACR of state changes
    if [ "$STATE" != "$PREV_STATE" ] || [ "$FORCE_RESYNC" = true ]; then
        case "$STATE" in
            PLAYING) ACR_STATE="playing" ;;
            PAUSED)  ACR_STATE="paused" ;;
            *)       ACR_STATE="stopped" ;;
        esac
        post_to_acr "{\"type\":\"state_changed\",\"state\":\"$ACR_STATE\"}"
        echo "[$(date '+%H:%M:%S')] State: $STATE"
        PREV_STATE="$STATE"
    fi

    # Notify ACR of track changes
    if [ "$TITLE" != "$PREV_TITLE" ] || [ "$ARTIST" != "$PREV_ARTIST" ] || [ "$FORCE_RESYNC" = true ]; then
        if [ -n "$TITLE" ]; then
            # Escape for JSON
            TITLE_J=$(echo "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ARTIST_J=$(echo "$ARTIST" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ALBUM_J=$(echo "$ALBUM" | sed 's/\\/\\\\/g; s/"/\\"/g')
            post_to_acr "{\"type\":\"song_changed\",\"song\":{\"title\":\"$TITLE_J\",\"artist\":\"$ARTIST_J\",\"album\":\"$ALBUM_J\",\"duration\":$DURATION_SEC}}"
            echo "[$(date '+%H:%M:%S')] Track: $ARTIST - $TITLE"
        fi
        PREV_TITLE="$TITLE"
        PREV_ARTIST="$ARTIST"
    fi

    # Notify ACR of position changes (every 5 seconds to avoid spam)
    if [ "$STATE" = "PLAYING" ] && [ -n "$POSITION" ] && [ "$POSITION" != "$PREV_POSITION" ]; then
        DIFF=$((POSITION - PREV_POSITION))
        if [ "$DIFF" -lt 0 ] || [ "$DIFF" -ge 5 ]; then
            post_to_acr "{\"type\":\"position_changed\",\"position\":$POSITION}"
            PREV_POSITION="$POSITION"
        fi
    fi

    # Write status JSON (atomic)
    TIMESTAMP=$(date +%s)
    ARTIST_JSON=$(echo "$ARTIST" | sed 's/"/\\"/g')
    TITLE_JSON=$(echo "$TITLE" | sed 's/"/\\"/g')
    ALBUM_JSON=$(echo "$ALBUM" | sed 's/"/\\"/g')
    cat > "${STATUS_FILE}.tmp" <<EOF
{
  "state": "$STATE",
  "artist": "$ARTIST_JSON",
  "title": "$TITLE_JSON",
  "album": "$ALBUM_JSON",
  "duration": $DURATION_SEC,
  "position": $POSITION,
  "timestamp": $TIMESTAMP
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    sleep 0.5
done
