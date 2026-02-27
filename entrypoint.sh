#!/bin/bash

echo "Starting Speaker Application in Background (TMUX)"
/usr/bin/tmux new-session -d -s speaker_controller_application '/app/tidal-connect/bin/speaker_controller_application'

echo "Starting TIDAL Connect.."
echo "Configuration:"
echo "  FRIENDLY_NAME: ${FRIENDLY_NAME}"
echo "  MODEL_NAME: ${MODEL_NAME}"
echo "  PLAYBACK_DEVICE: ${PLAYBACK_DEVICE}"
echo "  MQA_PASSTHROUGH: ${MQA_PASSTHROUGH}"
echo "  MQA_CODEC: ${MQA_CODEC}"
echo ""

/app/tidal-connect/bin/tidal_connect_application \
   --tc-certificate-path "/app/tidal-connect/id_certificate/certificate.dat" \
   -f "${FRIENDLY_NAME:-HiFiBerry}" \
   --codec-mpegh true \
   --codec-mqa ${MQA_CODEC:-false} \
   --model-name "${MODEL_NAME:-HiFiBerry}" \
   --disable-app-security false \
   --disable-web-security false \
   --enable-mqa-passthrough ${MQA_PASSTHROUGH:-false} \
   --playback-device "${PLAYBACK_DEVICE:-default}" \
   --log-level 3 \
   --enable-websocket-log "0"

echo "TIDAL Connect Container Stopped.."
