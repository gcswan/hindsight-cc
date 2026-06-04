#!/bin/sh

# Ensure Hindsight server is running
# Called by SessionStart hook to auto-start the server

CONTAINER_NAME="hindsight-cc"
HEALTH_URL="http://localhost:8888/health"
HINDSIGHT_IMAGE_DEFAULT="ghcr.io/vectorize-io/hindsight:0.7.2"
API_KEY="${HINDSIGHT_API_LLM_API_KEY:-}"

# Debug function - only outputs if HINDSIGHT_DEBUG is set
debug() {
	case "${HINDSIGHT_DEBUG:-}" in
	1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
		echo "[hindsight-cc:ensure-hindsight] $1" >&2
		;;
	esac
}

require_api_key() {
	if [ -n "$API_KEY" ]; then
		return 0
	fi

	echo "Error: HINDSIGHT_API_LLM_API_KEY is required before starting Hindsight" >&2
	return 1
}

container_missing_api_key() {
	container_id="$1"
	container_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" 2>/dev/null)

	if [ -z "$container_env" ]; then
		return 1
	fi

	echo "$container_env" | grep -q '^HINDSIGHT_API_LLM_API_KEY=$'
}

create_container() {
	debug "Creating Hindsight container"
	mkdir -p ~/hindsight-data

	HINDSIGHT_IMAGE="${HINDSIGHT_IMAGE:-$HINDSIGHT_IMAGE_DEFAULT}"
	debug "Starting new container with image ${HINDSIGHT_IMAGE}"
	debug "Starting Hindsight with model: ${HINDSIGHT_API_LLM_MODEL:-gpt-5-nano}"

	# Embedded Postgres builds a to_tsvector GENERATED column during migrations,
	# needing >500MB shared memory; Docker's default 64MB /dev/shm causes DiskFull
	# crashes on first start/upgrade.
	docker run -d --name "$CONTAINER_NAME" \
		--shm-size=2g \
		-p 8888:8888 -p 9999:9999 \
		-e HINDSIGHT_API_LLM_API_KEY="$API_KEY" \
		-e HINDSIGHT_API_LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-gpt-5-nano}" \
		-e HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-openai}" \
		-v "$HOME/hindsight-data:/home/hindsight/.pg0" \
		"$HINDSIGHT_IMAGE" >/dev/null 2>&1
}

debug "Starting"

# Check Docker is available
if ! command -v docker >/dev/null 2>&1; then
	debug "Docker not found in PATH"
	exit 0
fi

if ! docker info >/dev/null 2>&1; then
	debug "Docker daemon not running or not accessible"
	exit 0
fi

# Check if Hindsight server is already responding
if curl -s --connect-timeout 2 "$HEALTH_URL" >/dev/null 2>&1; then
	debug "Server already running"
	exit 0
fi

debug "Server not responding, checking container status"

# Check if container exists but is stopped
CONTAINER_ID=$(docker ps -aq -f "name=$CONTAINER_NAME" 2>/dev/null)

if [ -n "$CONTAINER_ID" ]; then
	debug "Found existing container $CONTAINER_ID"

	if container_missing_api_key "$CONTAINER_ID"; then
		if ! require_api_key; then
			exit 1
		fi

		debug "Existing container is missing HINDSIGHT_API_LLM_API_KEY, recreating it"
		docker rm -f "$CONTAINER_ID" >/dev/null 2>&1
		create_container
	else
		debug "Starting existing container"
		docker start "$CONTAINER_ID" >/dev/null 2>&1
	fi
else
	debug "No existing container, creating new one"
	if ! require_api_key; then
		exit 1
	fi
	create_container
fi

# Wait for server to be ready (up to 30 seconds)
debug "Waiting for server to be ready (up to 30 seconds)"
i=1
while [ "$i" -le 30 ]; do
	if curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1; then
		debug "Server ready after $i seconds"
		exit 0
	fi
	sleep 1
	i=$((i + 1))
done

debug "Server did not start within 30 seconds"
echo "Warning: Hindsight server did not start within 30 seconds" >&2
exit 1
