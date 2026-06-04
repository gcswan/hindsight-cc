#!/bin/sh

# Ensure Hindsight server is running
# Called by SessionStart hook to auto-start the server.
#
# v2: the plugin uses a single SHARED Docker container named "hindsight" so
# sibling projects (e.g. pi-ndsight) can share one server + one data volume.
# A one-time migration retires the old "hindsight-cc" container name.

CONTAINER_NAME="hindsight"
LEGACY_CONTAINER_NAME="hindsight-cc"
# Keep the health URL consistent with the Python client, which reads
# HINDSIGHT_BASE_URL (defaulting to http://localhost:8888).
HEALTH_URL="${HINDSIGHT_BASE_URL:-http://localhost:8888}/health"
HINDSIGHT_IMAGE_DEFAULT="ghcr.io/vectorize-io/hindsight:0.7.2"
CONFIG_FILE="${HINDSIGHT_CONFIG_FILE:-$HOME/.config/hindsight-cc/config.env}"

# Built-in defaults for LLM settings.
DEFAULT_PROVIDER="openai"
DEFAULT_MODEL="gpt-5-nano"

# Effective (resolved) config values, populated by resolve_config().
EFF_PROVIDER=""
EFF_MODEL=""
EFF_API_KEY=""
EFF_BASE_URL=""

# Debug function - only outputs if HINDSIGHT_DEBUG is set
debug() {
	case "${HINDSIGHT_DEBUG:-}" in
	1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
		echo "[hindsight-cc:ensure-hindsight] $1" >&2
		;;
	esac
}

# config_get KEY
# Reads CONFIG_FILE line-by-line and echoes the value for KEY, or nothing.
# Careful parser (NOT `source`): splits on the FIRST `=` only (values may
# contain `=`), skips blank lines and `#` comments, trims whitespace around
# the key, and strips ONE pair of matching surrounding single/double quotes
# from the value. The value is otherwise kept literal (no escape handling, no
# execution). Only the four HINDSIGHT_API_LLM_* keys are meaningful to callers.
config_get() {
	cg_want="$1"

	# Only the four HINDSIGHT_API_LLM_* keys are recognized; ignore anything else.
	case "$cg_want" in
	HINDSIGHT_API_LLM_PROVIDER | HINDSIGHT_API_LLM_MODEL | HINDSIGHT_API_LLM_API_KEY | HINDSIGHT_API_LLM_BASE_URL) ;;
	*) return 0 ;;
	esac

	[ -f "$CONFIG_FILE" ] || return 0

	# `|| [ -n "$cg_line" ]` so a final line without a trailing newline is read.
	while IFS= read -r cg_line || [ -n "$cg_line" ]; do
		# Skip leading whitespace to detect blank lines and comments.
		cg_trimmed=$(printf '%s' "$cg_line" | sed 's/^[[:space:]]*//')
		case "$cg_trimmed" in
		'' | '#'*)
			continue
			;;
		esac

		# Require a `=` to be a KEY=value line.
		case "$cg_line" in
		*=*) ;;
		*) continue ;;
		esac

		# Split on the FIRST `=` only.
		cg_key=${cg_line%%=*}
		cg_val=${cg_line#*=}

		# Trim surrounding whitespace from the key (only).
		cg_key=$(printf '%s' "$cg_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

		[ "$cg_key" = "$cg_want" ] || continue

		# Strip ONE pair of matching surrounding quotes from the value.
		case "$cg_val" in
		'"'*'"')
			cg_val=${cg_val#\"}
			cg_val=${cg_val%\"}
			;;
		"'"*"'")
			cg_val=${cg_val#\'}
			cg_val=${cg_val%\'}
			;;
		esac

		printf '%s' "$cg_val"
		return 0
	done <"$CONFIG_FILE"

	return 0
}

# resolve_config
# Computes the effective value of each setting with precedence:
#   explicit env var (set + non-empty) > config.env value > built-in default.
# The config file is consulted ONLY here, i.e. only when (re)creating.
resolve_config() {
	EFF_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-}"
	[ -n "$EFF_PROVIDER" ] || EFF_PROVIDER=$(config_get HINDSIGHT_API_LLM_PROVIDER)
	[ -n "$EFF_PROVIDER" ] || EFF_PROVIDER="$DEFAULT_PROVIDER"

	EFF_MODEL="${HINDSIGHT_API_LLM_MODEL:-}"
	[ -n "$EFF_MODEL" ] || EFF_MODEL=$(config_get HINDSIGHT_API_LLM_MODEL)
	[ -n "$EFF_MODEL" ] || EFF_MODEL="$DEFAULT_MODEL"

	EFF_API_KEY="${HINDSIGHT_API_LLM_API_KEY:-}"
	[ -n "$EFF_API_KEY" ] || EFF_API_KEY=$(config_get HINDSIGHT_API_LLM_API_KEY)

	# Optional; no default. Only passed through to the container when set.
	EFF_BASE_URL="${HINDSIGHT_API_LLM_BASE_URL:-}"
	[ -n "$EFF_BASE_URL" ] || EFF_BASE_URL=$(config_get HINDSIGHT_API_LLM_BASE_URL)
}

# require_api_key
# Validates the EFFECTIVE key (env or config), not just the env var. Callers
# must run resolve_config() first.
require_api_key() {
	if [ -n "$EFF_API_KEY" ]; then
		return 0
	fi

	echo "Error: HINDSIGHT_API_LLM_API_KEY is required before starting Hindsight" >&2
	return 1
}

container_missing_api_key() {
	cmk_id="$1"
	cmk_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cmk_id" 2>/dev/null)

	if [ -z "$cmk_env" ]; then
		return 1
	fi

	echo "$cmk_env" | grep -q '^HINDSIGHT_API_LLM_API_KEY=$'
}

create_container() {
	debug "Creating Hindsight container"
	mkdir -p ~/hindsight-data

	HINDSIGHT_IMAGE="${HINDSIGHT_IMAGE:-$HINDSIGHT_IMAGE_DEFAULT}"
	debug "Starting new container with image ${HINDSIGHT_IMAGE}"
	debug "Starting Hindsight with model: ${EFF_MODEL}"

	# Pass an optional LLM base URL (for local providers) only when resolved;
	# never pass an empty one. Accumulate via positional params to stay DRY.
	set --
	if [ -n "$EFF_BASE_URL" ]; then
		set -- "$@" -e HINDSIGHT_API_LLM_BASE_URL="$EFF_BASE_URL"
	fi

	# Embedded Postgres builds a to_tsvector GENERATED column during migrations,
	# needing >500MB shared memory; Docker's default 64MB /dev/shm causes DiskFull
	# crashes on first start/upgrade.
	docker run -d --name "$CONTAINER_NAME" \
		--shm-size=2g \
		-p 8888:8888 -p 9999:9999 \
		-e HINDSIGHT_API_LLM_API_KEY="$EFF_API_KEY" \
		-e HINDSIGHT_API_LLM_MODEL="$EFF_MODEL" \
		-e HINDSIGHT_API_LLM_PROVIDER="$EFF_PROVIDER" \
		"$@" \
		-v "$HOME/hindsight-data:/home/hindsight/.pg0" \
		"$HINDSIGHT_IMAGE" >/dev/null 2>&1
}

# migrate_legacy_container
# One-time retirement of the old "hindsight-cc" container name. This runs
# BEFORE the health probe on purpose: the legacy container may be the very
# thing answering on :8888, and the whole point is to retire that name. After
# `docker rm -f`, the health probe fails and we recreate under the new name.
# Data lives in the shared ~/hindsight-data volume, so nothing is lost — just a
# brief one-time restart. Exact-name matching (^name$) so "hindsight-cc" does
# not match "hindsight". Self-limiting: once "hindsight" exists, this no-ops.
migrate_legacy_container() {
	legacy_id=$(docker ps -aq -f "name=^${LEGACY_CONTAINER_NAME}$" 2>/dev/null)
	new_id=$(docker ps -aq -f "name=^${CONTAINER_NAME}$" 2>/dev/null)

	if [ -n "$legacy_id" ] && [ -z "$new_id" ]; then
		debug "Migrating: removing legacy '${LEGACY_CONTAINER_NAME}' container"
		docker rm -f "$LEGACY_CONTAINER_NAME" >/dev/null 2>&1
	fi
}

# server_healthy
# Returns 0 if the health endpoint answers.
server_healthy() {
	curl -s --connect-timeout 2 "$HEALTH_URL" >/dev/null 2>&1
}

# wait_for_ready
# Polls health up to 25s after a (re)create; warns and returns 1 if it never
# comes up. Capped below the 30s SessionStart hook timeout so the hook returns
# its own warning rather than being killed at the boundary.
wait_for_ready() {
	debug "Waiting for server to be ready (up to 25 seconds)"
	i=1
	while [ "$i" -le 25 ]; do
		if curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1; then
			debug "Server ready after $i seconds"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done

	debug "Server did not start within 25 seconds"
	echo "Warning: Hindsight server did not start within 25 seconds" >&2
	return 1
}

# create_or_recreate
# Create/recreate the container only when not healthy. Because the health probe
# in main() already exited on a healthy server, this can never clobber a healthy
# shared container.
create_or_recreate() {
	container_id=$(docker ps -aq -f "name=^${CONTAINER_NAME}$" 2>/dev/null)

	if [ -n "$container_id" ]; then
		debug "Found existing container $container_id"

		if container_missing_api_key "$container_id"; then
			resolve_config
			if ! require_api_key; then
				return 1
			fi
			debug "Existing container is missing HINDSIGHT_API_LLM_API_KEY, recreating it"
			docker rm -f "$container_id" >/dev/null 2>&1
			create_container
		else
			debug "Starting existing container"
			docker start "$container_id" >/dev/null 2>&1
		fi
	else
		debug "No existing container, creating new one"
		resolve_config
		if ! require_api_key; then
			return 1
		fi
		create_container
	fi
}

main() {
	debug "Starting"

	# Check Docker is available; soft-exit so SessionStart is never blocked.
	if ! command -v docker >/dev/null 2>&1; then
		debug "Docker not found in PATH"
		exit 0
	fi

	if ! docker info >/dev/null 2>&1; then
		debug "Docker daemon not running or not accessible"
		exit 0
	fi

	# One-time legacy migration, BEFORE the health probe (see function comment).
	migrate_legacy_container

	# Health-probe-first reuse: if the server answers, do NOT touch any
	# container — this makes sharing safe regardless of which project started it.
	if server_healthy; then
		debug "Server already running"
		exit 0
	fi

	debug "Server not responding, checking container status"

	if ! create_or_recreate; then
		exit 1
	fi

	if wait_for_ready; then
		exit 0
	fi
	exit 1
}

# When sourced (e.g. by tests) only the functions are wanted; skip the main
# flow. The `&&` short-circuits when run directly so the bare `return` is never
# reached outside a sourced context.
[ "${ENSURE_HINDSIGHT_LIB:-}" = 1 ] && return 0

main "$@"
