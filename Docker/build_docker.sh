#!/bin/bash

DOCKER_IMAGE=${DOCKER_IMAGE:-edgecrush3r/tidal-connect}

echo "Building Docker image: ${DOCKER_IMAGE}"
cd .. &&  docker build -f Docker/Dockerfile -t ${DOCKER_IMAGE} .
echo "Done..."
