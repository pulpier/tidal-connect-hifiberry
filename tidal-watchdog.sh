#!/bin/bash

# Tidal Connect Watchdog: Monitors for connection issues and auto-recovers
# This script detects token expiration and connection errors, then restarts the service

LOG_FILE="/var/log/tidal-watchdog.log"
CHECK_INTERVAL=30  # Check every 30 seconds
RESTART_COOLDOWN=60  # Don't restart more than once per minute
LAST_RESTART=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

get_container_status() {
    docker inspect -f '{{.State.Running}}' tidal_connect 2>/dev/null
}

check_for_errors() {
    # Get logs from the last CHECK_INTERVAL seconds
    RECENT_LOGS=$(docker logs --since ${CHECK_INTERVAL}s tidal_connect 2>&1)
    
    # Check for critical errors
    # Token expiration - these are clear errors that require restart
    if echo "$RECENT_LOGS" | grep -qiE "(invalid_grant|token has expired|authentication.*failed)"; then
        echo "token_expired"
        return
    fi
    
    # Connection loss - only trigger on actual errors, not normal EOF
    # "End of file" (EOF) is normal during connection teardown, so we ignore those
    if echo "$RECENT_LOGS" | grep -qiE "handle_read_frame error|connection.*refused|connection.*reset|socket.*disconnected" && \
       ! echo "$RECENT_LOGS" | grep -qiE "asio\.misc:2.*End of file|normal.*shutdown"; then
        echo "connection_lost"
        return
    fi
    
    # Check if container is running but not responsive
    if [ "$(get_container_status)" != "true" ]; then
        echo "container_down"
        return
    fi
    
    echo "ok"
}

wait_for_service_stopped() {
    local max_wait=20
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if ! systemctl is-active --quiet tidal.service && \
           [ "$(get_container_status)" != "true" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

wait_for_service_started() {
    local max_wait=45
    local waited=0
    local check_interval=2
    
    while [ $waited -lt $max_wait ]; do
        # Check if service is active AND container is running AND tidal app is running
        if systemctl is-active --quiet tidal.service && \
           [ "$(get_container_status)" = "true" ]; then
            # Double-check tidal_connect_application is actually running
            if docker exec tidal_connect pgrep -f "tidal_connect_application" >/dev/null 2>&1; then
                # Give it a moment to stabilize
                sleep 2
                # Verify it didn't crash immediately
                if docker exec tidal_connect pgrep -f "tidal_connect_application" >/dev/null 2>&1; then
                    return 0
                fi
            fi
        fi
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    return 1
}

restart_service() {
    local reason="$1"
    local current_time=$(date +%s)
    
    # Enforce cooldown to prevent restart loops
    if [ $((current_time - LAST_RESTART)) -lt $RESTART_COOLDOWN ]; then
        log "⏳ Restart requested but cooldown active (${RESTART_COOLDOWN}s)"
        return 1
    fi
    
    log "🔄 Restarting Tidal Connect service (Reason: $reason)"
    
    # Stop service if it's running
    if systemctl is-active --quiet tidal.service || systemctl is-failed tidal.service; then
        if systemctl is-failed tidal.service; then
            log "   Service is in failed state, resetting..."
            systemctl reset-failed tidal.service 2>/dev/null || true
        fi
        
        log "   Stopping service..."
        systemctl stop tidal.service
        
        if ! wait_for_service_stopped; then
            log "⚠ Service did not stop cleanly, forcing..."
            # Kill any stuck processes
            pkill -f "docker-compose.*tidal" 2>/dev/null || true
            docker stop tidal_connect 2>/dev/null || true
            sleep 2
        else
            log "   Service stopped cleanly"
        fi
    fi
    
    # Ensure clean state before starting
    if docker ps -a | grep -q tidal_connect; then
        docker rm -f tidal_connect 2>/dev/null || true
    fi
    
    # Start service
    log "   Starting service..."
    systemctl start tidal.service
    
    # Wait for healthy state with proper verification
    log "   Waiting for service to become healthy..."
    if wait_for_service_started; then
        log "✓ Service restarted successfully"
        LAST_RESTART=$current_time
        
        # Restart volume bridge to ensure it reconnects
        systemctl restart tidal-volume-bridge.service 2>/dev/null || true
        
        # Check for immediate collision errors
        sleep 3
        if docker logs --since 3s tidal_connect 2>&1 | grep -q "AVAHI_CLIENT_S_COLLISION"; then
            log "⚠ WARNING: mDNS collision detected after restart"
            return 1
        fi
        
        return 0
    else
        log "✗ Service restart failed - container not healthy"
        # Log diagnostics
        systemctl status tidal.service --no-pager -l | head -15 | while read line; do
            log "   $line"
        done
        return 1
    fi
}

# Main monitoring loop
log "=========================================="
log "Tidal Connect Watchdog started"
log "Check interval: ${CHECK_INTERVAL}s"
log "Restart cooldown: ${RESTART_COOLDOWN}s"
log "=========================================="

while true; do
    # Check if container exists
    if ! docker ps -a | grep -q tidal_connect; then
        log "⚠ Tidal Connect container not found, waiting..."
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # Check for errors
    STATUS=$(check_for_errors)
    
    case "$STATUS" in
        token_expired)
            log "⚠ Detected: Token expired"
            restart_service "token_expired"
            ;;
        connection_lost)
            log "⚠ Detected: Connection lost"
            restart_service "connection_lost"
            ;;
        container_down)
            log "⚠ Detected: Container down"
            restart_service "container_down"
            ;;
        ok)
            # Silently continue
            ;;
    esac
    
    sleep $CHECK_INTERVAL
done

