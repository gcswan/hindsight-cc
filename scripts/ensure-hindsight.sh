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
HINDSIGHT_IMAGE_DEFAULT="ghcr.io/vectorize-io/hindsight:0.8.6"
CONFIG_FILE="${HINDSIGHT_CONFIG_FILE:-$HOME/.config/hindsight-cc/config.env}"
# Host directory bind-mounted as the embedded Postgres (pg0) data directory.
DATA_DIR="${HINDSIGHT_DATA_DIR:-$HOME/hindsight-data}"

# Built-in defaults for LLM settings.
DEFAULT_PROVIDER="openai"
DEFAULT_MODEL="gpt-5-nano"

# Container resource defaults. 4g is double the 2 GB the Hindsight docs
# recommend for the full image and well under a typical Docker Desktop VM.
DEFAULT_MEMORY_LIMIT="4g"
# Stable worker identity so tasks claimed by a previous container can be
# recovered after a recreate (the container ID changes every time).
WORKER_ID="hindsight-local"

# Effective (resolved) config values, populated by resolve_*().
EFF_PROVIDER=""
EFF_MODEL=""
EFF_API_KEY=""
EFF_BASE_URL=""
EFF_PLATFORM=""
EFF_MEMORY_LIMIT=""

# Recorded by guard_installation so a failed recreate can undo the swap.
GUARD_SWAPPED=0
GUARD_HAVE=""
GUARD_WANT=""

# debug_enabled
# Returns 0 when HINDSIGHT_DEBUG asks for verbose output.
debug_enabled() {
	case "${HINDSIGHT_DEBUG:-}" in
	1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) return 0 ;;
	esac
	return 1
}

# Debug function - only outputs if HINDSIGHT_DEBUG is set
debug() {
	if debug_enabled; then
		echo "[hindsight-cc:ensure-hindsight] $1" >&2
	fi
	return 0
}

# config_get KEY
# Reads CONFIG_FILE line-by-line and echoes the value for KEY, or nothing.
# Careful parser (NOT `source`): splits on the FIRST `=` only (values may
# contain `=`), skips blank lines and `#` comments, trims whitespace around
# the key, and strips ONE pair of matching surrounding single/double quotes
# from the value. The value is otherwise kept literal (no escape handling, no
# execution). Only the keys listed below are meaningful to callers.
config_get() {
	cg_want="$1"

	# Only these keys are recognized; ignore anything else.
	case "$cg_want" in
	HINDSIGHT_API_LLM_PROVIDER | HINDSIGHT_API_LLM_MODEL | HINDSIGHT_API_LLM_API_KEY | HINDSIGHT_API_LLM_BASE_URL | HINDSIGHT_PLATFORM | HINDSIGHT_MEMORY_LIMIT) ;;
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

# valid_memory_limit VALUE
# Accepts `none` or a Docker memory size: digits with an optional b/k/m/g suffix.
valid_memory_limit() {
	case "$1" in
	none) return 0 ;;
	'' | *[!0-9bBkKmMgG]* | [!0-9]*) return 1 ;;
	esac
	return 0
}

# resolve_memory_limit
# EFF_MEMORY_LIMIT: env HINDSIGHT_MEMORY_LIMIT > config.env > default. `none`
# disables the limit. An invalid value is ignored (debug log) in favor of the
# default, so a typo can never stop the container from being created.
resolve_memory_limit() {
	EFF_MEMORY_LIMIT="${HINDSIGHT_MEMORY_LIMIT:-}"
	[ -n "$EFF_MEMORY_LIMIT" ] || EFF_MEMORY_LIMIT=$(config_get HINDSIGHT_MEMORY_LIMIT)
	[ -n "$EFF_MEMORY_LIMIT" ] || EFF_MEMORY_LIMIT="$DEFAULT_MEMORY_LIMIT"
	if ! valid_memory_limit "$EFF_MEMORY_LIMIT"; then
		debug "Ignoring invalid HINDSIGHT_MEMORY_LIMIT '$EFF_MEMORY_LIMIT'; using $DEFAULT_MEMORY_LIMIT"
		EFF_MEMORY_LIMIT="$DEFAULT_MEMORY_LIMIT"
	fi
}

# platform_arch PLATFORM
# Echoes the image architecture name (arm64|amd64) for a Docker platform string,
# or nothing for anything else.
platform_arch() {
	case "$1" in
	linux/arm64) echo arm64 ;;
	linux/amd64) echo amd64 ;;
	esac
}

# resolve_platform
# EFF_PLATFORM is the Docker platform the container must run as:
#   1. HINDSIGHT_PLATFORM (env, then config.env): the first value that is
#      exactly linux/arm64 or linux/amd64. Any other value is ignored (debug log).
#   2. Otherwise the Docker DAEMON's architecture (not `uname -m`, so a remote
#      daemon or an Intel host is handled correctly).
#   3. Otherwise empty: no --platform flag is passed (Docker's own default).
# Passing --platform explicitly matters: without it Docker silently reuses
# whichever architecture a local tag happens to point at, so a stale amd64 tag
# on an arm64 host runs under emulation with only a discarded stderr warning.
resolve_platform() {
	for rp_candidate in "${HINDSIGHT_PLATFORM:-}" "$(config_get HINDSIGHT_PLATFORM)"; do
		case "$rp_candidate" in
		linux/arm64 | linux/amd64)
			EFF_PLATFORM="$rp_candidate"
			return 0
			;;
		'') ;;
		*) debug "Ignoring invalid HINDSIGHT_PLATFORM '$rp_candidate'" ;;
		esac
	done

	rp_arch=$(docker info --format '{{.Architecture}}' 2>/dev/null)
	case "$rp_arch" in
	aarch64 | arm64) EFF_PLATFORM="linux/arm64" ;;
	x86_64 | amd64) EFF_PLATFORM="linux/amd64" ;;
	*) EFF_PLATFORM="" ;;
	esac
}

# require_api_key
# Validates the EFFECTIVE key (env or config), not just the env var. Callers
# must run resolve_config() first. Local providers (Ollama, LM Studio) talk to a
# custom endpoint set via HINDSIGHT_API_LLM_BASE_URL and need no key, so a
# resolved base URL also satisfies this check.
require_api_key() {
	if [ -n "$EFF_API_KEY" ] || [ -n "$EFF_BASE_URL" ]; then
		return 0
	fi

	echo "Error: HINDSIGHT_API_LLM_API_KEY is required before starting Hindsight (or set HINDSIGHT_API_LLM_BASE_URL for a local provider)" >&2
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

# elf_arch FILE
# Echoes arm64, amd64, or unknown from the ELF e_machine field (2 bytes at
# offset 18, little-endian: 0x3e 0x00 = x86-64, 0xb7 0x00 = aarch64).
elf_arch() {
	ea_bytes=$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')
	case "$ea_bytes" in
	b700) echo arm64 ;;
	3e00) echo amd64 ;;
	*) echo unknown ;;
	esac
}

# find_pg_binary DIR
# Echoes the first DIR/<version>/bin/postgres that exists, or nothing.
find_pg_binary() {
	for fpb_file in "$1"/*/bin/postgres; do
		if [ -f "$fpb_file" ]; then
			echo "$fpb_file"
			return 0
		fi
	done
	return 0
}

# guard_installation ARCH
# The embedded Postgres binaries that pg0 downloads into DATA_DIR/installation
# are architecture-specific. When they do not match ARCH (arm64|amd64), park
# them as installation.<their-arch> (never deleting anything) and, if a copy
# for ARCH was parked earlier, move that into place; otherwise leave
# installation absent so pg0 downloads the right ones. Only call this when no
# container is using DATA_DIR. Records the swap in GUARD_* for undo_guard.
guard_installation() {
	gi_want="$1"
	[ -n "$gi_want" ] || return 0

	gi_dir="$DATA_DIR/installation"
	gi_bin=$(find_pg_binary "$gi_dir")
	[ -n "$gi_bin" ] || return 0

	gi_have=$(elf_arch "$gi_bin")
	# Do not touch what cannot be identified, or what already matches.
	[ "$gi_have" != "unknown" ] || return 0
	[ "$gi_have" != "$gi_want" ] || return 0

	gi_park="$DATA_DIR/installation.$gi_have"
	if [ -e "$gi_park" ]; then
		echo "Error: embedded Postgres binaries are $gi_have but $gi_want is needed, and $gi_park already exists; move one aside and retry" >&2
		return 1
	fi

	debug "Parking $gi_have Postgres binaries as $gi_park (need $gi_want)"
	mv "$gi_dir" "$gi_park" || return 1
	if [ -d "$DATA_DIR/installation.$gi_want" ]; then
		if ! mv "$DATA_DIR/installation.$gi_want" "$gi_dir"; then
			mv "$gi_park" "$gi_dir"
			return 1
		fi
	fi

	GUARD_SWAPPED=1
	GUARD_HAVE="$gi_have"
	GUARD_WANT="$gi_want"
	return 0
}

# undo_guard
# Reverses the swap recorded by guard_installation. A no-op when none happened.
undo_guard() {
	[ "$GUARD_SWAPPED" = "1" ] || return 0

	ug_dir="$DATA_DIR/installation"
	if [ -e "$ug_dir" ]; then
		if [ -e "$DATA_DIR/installation.$GUARD_WANT" ]; then
			echo "Error: cannot undo the installation swap: $DATA_DIR/installation.$GUARD_WANT already exists" >&2
			return 1
		fi
		mv "$ug_dir" "$DATA_DIR/installation.$GUARD_WANT" || return 1
	fi
	mv "$DATA_DIR/installation.$GUARD_HAVE" "$ug_dir" || return 1
	GUARD_SWAPPED=0
	return 0
}

create_container() {
	debug "Creating Hindsight container"
	mkdir -p "$DATA_DIR"

	resolve_platform
	resolve_memory_limit
	if ! guard_installation "$(platform_arch "$EFF_PLATFORM")"; then
		return 1
	fi

	HINDSIGHT_IMAGE="${HINDSIGHT_IMAGE:-$HINDSIGHT_IMAGE_DEFAULT}"
	debug "Starting new container with image ${HINDSIGHT_IMAGE} (platform: ${EFF_PLATFORM:-docker default})"
	debug "Starting Hindsight with model: ${EFF_MODEL}"

	# Optional pieces accumulate in the positional params so the docker run
	# below stays one readable command.
	set --
	if [ -n "$EFF_PLATFORM" ]; then
		set -- "$@" --platform "$EFF_PLATFORM"
	fi
	if [ "$EFF_MEMORY_LIMIT" != "none" ]; then
		set -- "$@" --memory "$EFF_MEMORY_LIMIT" --memory-swap "$EFF_MEMORY_LIMIT"
	fi
	# Pass the optional API key and base URL only when resolved; never pass an
	# empty one. Omitting an empty key matters: a container created with an empty
	# HINDSIGHT_API_LLM_API_KEY= env would be flagged as "missing key" on the next
	# run and recreated every session (an infinite loop for local providers, which
	# legitimately have no key).
	if [ -n "$EFF_API_KEY" ]; then
		# Bare name: docker forwards the value from OUR environment (set on the
		# docker command below), so the secret never appears in argv or `ps`.
		set -- "$@" -e HINDSIGHT_API_LLM_API_KEY
	fi
	if [ -n "$EFF_BASE_URL" ]; then
		set -- "$@" -e HINDSIGHT_API_LLM_BASE_URL="$EFF_BASE_URL"
	fi

	# Why each flag:
	#   --restart unless-stopped   comes back after a Docker/host restart (docs).
	#   --stop-timeout 40          the image's shutdown trap waits up to 30s for
	#                              Postgres to flush WAL; Docker's default is 10s.
	#   --shm-size=2g              embedded Postgres builds a to_tsvector GENERATED
	#                              column during migrations, needing >500MB shared
	#                              memory; the 64MB default causes DiskFull crashes.
	#   --health-*                 the image has no HEALTHCHECK; it ships curl.
	#   --log-opt                  bound the json-file log (a crash loop is noisy).
	#   HINDSIGHT_API_WORKER_ID    stable across recreates (docs recommend it).
	# Capture combined output (instead of discarding it) so that, on failure,
	# the cause (port already bound, image pull error, OOM, bad flag) is
	# recoverable via HINDSIGHT_DEBUG rather than silently lost. The success
	# stdout (the container id) is unused, so capturing it is harmless.
	run_out=$(HINDSIGHT_API_LLM_API_KEY="$EFF_API_KEY" docker run -d --name "$CONTAINER_NAME" \
		--restart unless-stopped \
		--stop-timeout 40 \
		--shm-size=2g \
		--health-cmd "curl -sf http://localhost:8888/health" \
		--health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 120s \
		--log-opt max-size=10m --log-opt max-file=3 \
		-p 8888:8888 -p 9999:9999 \
		-e HINDSIGHT_API_LLM_MODEL="$EFF_MODEL" \
		-e HINDSIGHT_API_LLM_PROVIDER="$EFF_PROVIDER" \
		-e HINDSIGHT_API_WORKER_ID="$WORKER_ID" \
		"$@" \
		-v "$DATA_DIR:/home/hindsight/.pg0" \
		"$HINDSIGHT_IMAGE" 2>&1)
	run_rc=$?
	[ "$run_rc" -ne 0 ] && debug "docker run failed (rc=$run_rc): $run_out"
	return "$run_rc"
}

# container_image_arch NAME
# Echoes the architecture (arm64|amd64) of the image NAME was created from, or
# nothing if it cannot be determined.
container_image_arch() {
	cia_img=$(docker inspect -f '{{.Image}}' "$1" 2>/dev/null)
	[ -n "$cia_img" ] || return 0
	docker image inspect -f '{{.Architecture}}' "$cia_img" 2>/dev/null
	return 0
}

# container_exec_failure ID
# Echoes a short description when the container stopped in a way that means its
# binary cannot run here (132 = illegal instruction, 126 = not executable,
# 127 = not found) or Docker is crash-looping it. Echoes nothing otherwise.
container_exec_failure() {
	cef_state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.State.Restarting}}' "$1" 2>/dev/null)
	case "$cef_state" in
	"exited 132 "*) echo "exit code 132" ;;
	"exited 126 "*) echo "exit code 126" ;;
	"exited 127 "*) echo "exit code 127" ;;
	"restarting "*) echo "restarting" ;;
	esac
	return 0
}

# report_platform_drift
# Debug-only: say so when the existing container's image architecture differs
# from what this host should run. Read-only, and skipped entirely unless
# HINDSIGHT_DEBUG is on so the healthy SessionStart path stays one curl.
report_platform_drift() {
	debug_enabled || return 0
	rpd_id=$(docker ps -aq -f "name=^${CONTAINER_NAME}$" 2>/dev/null)
	[ -n "$rpd_id" ] || return 0

	resolve_platform
	rpd_want=$(platform_arch "$EFF_PLATFORM")
	rpd_have=$(container_image_arch "$rpd_id")
	if [ -n "$rpd_want" ] && [ -n "$rpd_have" ] && [ "$rpd_want" != "$rpd_have" ]; then
		debug "Platform drift: container image is $rpd_have but this host should run $rpd_want (run 'ensure-hindsight.sh recreate')"
	fi
	return 0
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
	# --max-time bounds the whole request (connect + read), not just the TCP
	# connect, so a server that accepts the connection but stalls on /health
	# can't hang the probe.
	curl -s --connect-timeout 2 --max-time 3 "$HEALTH_URL" >/dev/null 2>&1
}

# wait_for_ready
# Polls health until the server answers or a ~24s wall-clock deadline passes;
# warns and returns 1 if it never comes up. The deadline (not an attempt count)
# is what caps the wait below the 30s SessionStart hook timeout, so the hook
# returns its own warning rather than being killed at the boundary. --max-time
# bounds each probe's connect+read, so a server that binds the port but stalls
# on /health (the slow embedded-Postgres migration case) can't drag a single
# attempt past the budget.
wait_for_ready() {
	debug "Waiting for server to be ready (up to ~24 seconds)"
	wfr_deadline=$(($(date +%s) + 24))
	while [ "$(date +%s)" -lt "$wfr_deadline" ]; do
		if curl -s --connect-timeout 1 --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
			debug "Server ready"
			return 0
		fi
		sleep 1
	done

	debug "Server did not become ready within the ~24s deadline"
	echo "Warning: Hindsight server did not start within ~24 seconds" >&2
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
			# A container that cannot execute its binary will just crash again;
			# starting it in a loop every session hides that. Say what it means.
			cef=$(container_exec_failure "$container_id")
			if [ -n "$cef" ]; then
				echo "Error: container '$CONTAINER_NAME' is not runnable (state: $cef). Exit codes 132/126/127 mean the binary could not execute and 'restarting' means a crash loop; all point at an image/architecture mismatch. Check 'docker logs $CONTAINER_NAME', then try: HINDSIGHT_PLATFORM=linux/amd64 ensure-hindsight.sh recreate" >&2
				return 1
			fi

			debug "Starting existing container"
			start_out=$(docker start "$container_id" 2>&1)
			start_rc=$?
			# Use if/fi (not `&& debug`): as the function's last command, a
			# `[ rc -ne 0 ] && ...` would itself return 1 on a SUCCESSFUL start
			# (the test is false), making create_or_recreate report failure.
			if [ "$start_rc" -ne 0 ]; then
				debug "docker start failed (rc=$start_rc): $start_out"
			fi
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
		report_platform_drift
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
