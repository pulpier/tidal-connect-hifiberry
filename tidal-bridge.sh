#!/bin/bash

# Tidal Connect Bridge for HiFiBerry OS NG
# Monitors speaker_controller_application via tmux, syncs volume,
# exports metadata to /tmp/tidal-status.json and POSTs events to ACR

ACR_URL="http://localhost:1080/api/player/tidal/update"
CONFIGURATOR_URL="http://localhost:1081/api/v1/soundcard/detect"
STATUS_FILE="/tmp/tidal-status.json"
PREV_VOLUME=-1
PREV_STATE=""
PREV_TITLE=""
PREV_ARTIST=""
PREV_POSITION=-1

echo "Starting Tidal Connect bridge..."

# Query configurator for ALSA card index and volume control name
detect_soundcard() {
    local response
    response=$(curl -s "$CONFIGURATOR_URL" 2>/dev/null)
    if [ -z "$response" ]; then
        echo "WARNING: configurator not reachable, using defaults (card 0, Digital)"
        ALSA_CARD=0
        VOLUME_CONTROL="Digital"
        return
    fi
    ALSA_CARD=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('hardware_index',0))" 2>/dev/null)
    VOLUME_CONTROL=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('volume_control','Digital'))" 2>/dev/null)
    [ -z "$ALSA_CARD" ] && ALSA_CARD=0
    [ -z "$VOLUME_CONTROL" ] && VOLUME_CONTROL="Digital"
}

detect_soundcard
echo "ALSA card index: $ALSA_CARD"
echo "Volume control: $VOLUME_CONTROL"

# Get mixer range from ALSA
ALSA_MAX=$(docker exec tidal_connect amixer -c "$ALSA_CARD" get "$VOLUME_CONTROL" 2>/dev/null \
    | grep -o 'Limits:.*Playback [0-9]* - [0-9]*' | grep -o '[0-9]*$')
[ -z "$ALSA_MAX" ] && ALSA_MAX=207
echo "ALSA max value: $ALSA_MAX"
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

while true; do
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

    # Parse volume from volume bar (count # symbols)
    VOLUME=$(echo "$TMUX_OUTPUT" | grep 'l.*#.*k$' | tr -cd '#' | wc -c)

    # Duration: ms -> seconds
    if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
        DURATION_SEC=$((DURATION / 1000))
    else
        DURATION_SEC=0
    fi

    # Notify ACR of state changes
    if [ "$STATE" != "$PREV_STATE" ]; then
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
    if [ "$TITLE" != "$PREV_TITLE" ] || [ "$ARTIST" != "$PREV_ARTIST" ]; then
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

    # Update hardware volume if changed
    if [ "$VOLUME" != "$PREV_VOLUME" ] && [ -n "$VOLUME" ] && [ "$VOLUME" -ge 0 ] 2>/dev/null; then
        ALSA_VALUE=$((VOLUME * ALSA_MAX / 38))
        [ "$ALSA_VALUE" -gt "$ALSA_MAX" ] && ALSA_VALUE=$ALSA_MAX
        PCT=$((VOLUME * 100 / 38))
        echo "[$(date '+%H:%M:%S')] Volume: $VOLUME/38 (${PCT}%) -> ALSA ${VOLUME_CONTROL} $ALSA_VALUE/$ALSA_MAX (card $ALSA_CARD)"
        docker exec tidal_connect amixer -c "$ALSA_CARD" set "$VOLUME_CONTROL" "$ALSA_VALUE" > /dev/null 2>&1
        PREV_VOLUME=$VOLUME
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
  "volume": $VOLUME,
  "timestamp": $TIMESTAMP
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    sleep 0.5
done
