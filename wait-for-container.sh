#!/bin/bash
# Robust container readiness check with retry logic

CONTAINER_NAME="${1:-tidal_connect}"
MAX_WAIT="${2:-30}"
CHECK_INTERVAL="${3:-1}"

wait_for_container_stopped() {
    local elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        # Check if container exists and is stopped
        if ! docker ps | grep -q "$CONTAINER_NAME"; then
            # Container not in running list
            local state=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)
            if [ "$state" != "true" ]; then
                echo "Container $CONTAINER_NAME is stopped (waited ${elapsed}s)"
                return 0
            fi
        fi
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    echo "ERROR: Container $CONTAINER_NAME did not stop within ${MAX_WAIT}s" >&2
    return 1
}

wait_for_container_running() {
    local elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        local state=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)
        if [ "$state" = "true" ]; then
            echo "Container $CONTAINER_NAME is running (waited ${elapsed}s)"
            return 0
        fi
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    echo "ERROR: Container $CONTAINER_NAME did not start within ${MAX_WAIT}s" >&2
    return 1
}

wait_for_container_healthy() {
    local elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        if docker ps | grep -q "$CONTAINER_NAME"; then
            # Container is running, check if tidal_connect_application is actually running
            local tidal_running=$(docker exec "$CONTAINER_NAME" pgrep -f "tidal_connect_application" 2>/dev/null)
            if [ -n "$tidal_running" ]; then
                # Give it a moment to initialize
                sleep 2
                # Check for immediate crashes
                if docker exec "$CONTAINER_NAME" pgrep -f "tidal_connect_application" >/dev/null 2>&1; then
                    echo "Container $CONTAINER_NAME is healthy (waited ${elapsed}s)"
                    return 0
                fi
            fi
        fi
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    echo "ERROR: Container $CONTAINER_NAME did not become healthy within ${MAX_WAIT}s" >&2
    return 1
}

case "${4:-running}" in
    stopped)
        wait_for_container_stopped
        ;;
    running)
        wait_for_container_running
        ;;
    healthy)
        wait_for_container_healthy
        ;;
    *)
        echo "Usage: $0 [container_name] [max_wait_seconds] [check_interval] [stopped|running|healthy]"
        exit 1
        ;;
esac

