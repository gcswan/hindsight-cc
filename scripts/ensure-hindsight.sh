#!/bin/bash

# Ensure Hindsight server is running
# Called by SessionStart hook to auto-start the server

CONTAINER_NAME="hindsight-cc"
HEALTH_URL="http://localhost:8888/health"
HINDSIGHT_IMAGE_DEFAULT="ghcr.io/vectorize-io/hindsight:0.1.16"

# Debug function - only outputs if HINDSIGHT_DEBUG is set
debug() {
    if [[ "${HINDSIGHT_DEBUG,,}" =~ ^(1|true|yes)$ ]]; then
    echo "[hindsight-cc:ensure-hindsight] $1" >&2
    fi
}

debug "Starting"

# Check Docker is available
if ! command -v docker &> /dev/null; then
    debug "Docker not found in PATH"
    exit 0
fi

if ! docker info &> /dev/null 2>&1; then
    debug "Docker daemon not running or not accessible"
    exit 0
fi

# Check if Hindsight server is already responding
if curl -s --connect-timeout 2 "$HEALTH_URL" > /dev/null 2>&1; then
    debug "Server already running"
    exit 0
fi

debug "Server not responding, checking container status"

# Check if container exists but is stopped
CONTAINER_ID=$(docker ps -aq -f "name=$CONTAINER_NAME" 2>/dev/null)

if [ -n "$CONTAINER_ID" ]; then
    # Container exists, try to start it
    debug "Found existing container $CONTAINER_ID, starting it"
    docker start "$CONTAINER_ID" > /dev/null 2>&1
else
    # No container, create and start new one
    debug "No existing container, creating new one"
    mkdir -p ~/hindsight-data

    # Get API key from environment
    API_KEY="$HINDSIGHT_API_LLM_API_KEY"

    if [ -z "$API_KEY" ]; then
        echo "Warning: HINDSIGHT_API_LLM_API_KEY not set" >&2
        echo "Hindsight LLM features may not work" >&2
    fi

    HINDSIGHT_IMAGE="${HINDSIGHT_IMAGE:-$HINDSIGHT_IMAGE_DEFAULT}"
    debug "Starting new container with image ${HINDSIGHT_IMAGE}"
    debug "Starting Hindsight with model: ${HINDSIGHT_API_LLM_MODEL:-gpt-4o-mini}"

    # Start Hindsight container in detached mode
    docker run -d --name "$CONTAINER_NAME" \
        -p 8888:8888 -p 9999:9999 \
        -e HINDSIGHT_API_LLM_API_KEY="$API_KEY" \
        -e HINDSIGHT_API_LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-gpt-4o-mini}" \
        -v "$HOME/hindsight-data:/home/hindsight/.pg0" \
        "$HINDSIGHT_IMAGE" > /dev/null 2>&1
fi

# Wait for server to be ready (up to 30 seconds)
debug "Waiting for server to be ready (up to 30 seconds)"
for i in {1..30}; do
    if curl -s --connect-timeout 1 "$HEALTH_URL" > /dev/null 2>&1; then
        debug "Server ready after $i seconds"
        exit 0
    fi
    sleep 1
done

debug "Server did not start within 30 seconds"
echo "Warning: Hindsight server did not start within 30 seconds" >&2
exit 1
