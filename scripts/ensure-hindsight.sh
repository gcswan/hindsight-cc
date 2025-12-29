#!/bin/bash

# Ensure Hindsight server is running
# Called by SessionStart hook to auto-start the server

CONTAINER_NAME="hindsight-2020"
HEALTH_URL="http://localhost:8888/health"

# Check if Hindsight server is already responding
if curl -s --connect-timeout 2 "$HEALTH_URL" > /dev/null 2>&1; then
    exit 0
fi

# Check if container exists but is stopped
CONTAINER_ID=$(docker ps -aq -f "name=$CONTAINER_NAME" 2>/dev/null)

if [ -n "$CONTAINER_ID" ]; then
    # Container exists, try to start it
    docker start "$CONTAINER_ID" > /dev/null 2>&1
else
    # No container, create and start new one
    mkdir -p ~/hindsight-data

    # Get API key from environment
    API_KEY="$HINDSIGHT_API_LLM_API_KEY"

    if [ -z "$API_KEY" ]; then
        echo "Warning: HINDSIGHT_API_LLM_API_KEY not set" >&2
        echo "Hindsight LLM features may not work" >&2
    fi

    # Start Hindsight container in detached mode
    docker run -d --name "$CONTAINER_NAME" \
        -p 8888:8888 -p 9999:9999 \
        -e HINDSIGHT_API_LLM_API_KEY="$API_KEY" \
        -e HINDSIGHT_API_LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-gpt-4o-mini}" \
        -v "$HOME/hindsight-data:/home/hindsight/.pg0" \
        ghcr.io/vectorize-io/hindsight:latest > /dev/null 2>&1
fi

# Wait for server to be ready (up to 30 seconds)
for i in {1..30}; do
    if curl -s --connect-timeout 1 "$HEALTH_URL" > /dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

echo "Warning: Hindsight server did not start within 30 seconds" >&2
exit 1
