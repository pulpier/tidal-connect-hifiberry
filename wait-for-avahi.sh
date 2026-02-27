#!/bin/bash
# Wait for Avahi to become ready before starting Tidal Connect

TIMEOUT=30
ELAPSED=0

until systemctl is-active --quiet avahi-daemon; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Avahi did not become ready within ${TIMEOUT}s"
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED+1))
done

echo "Avahi is ready after ${ELAPSED} seconds"

