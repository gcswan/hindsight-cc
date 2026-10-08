#!/bin/sh
#
# Tests for scripts/ensure-hindsight.sh
#
# No docker/curl required: config-parser tests source the script's functions
# (guarded by ENSURE_HINDSIGHT_LIB=1), and flow tests use fake docker/curl/sleep
# shims on PATH whose behavior is driven by FAKE_* env vars.
#
# Run: sh scripts/test/test_ensure_hindsight.sh

# Resolve the script under test relative to this test file.
TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SCRIPT="$TEST_DIR/../ensure-hindsight.sh"

# Never let a test touch a real data directory: point the script at a throwaway
# one for the whole run (the script reads HINDSIGHT_DATA_DIR).
TEST_DATA_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/eh_data.XXXXXX")
HINDSIGHT_DATA_DIR="$TEST_DATA_ROOT/hindsight-data"
export HINDSIGHT_DATA_DIR
trap 'rm -rf "$TEST_DATA_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "PASS: $1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "FAIL: $1"
}

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1 (expected [$2], got [$3])"
	fi
}

# ---------------------------------------------------------------------------
# Config parser tests
# ---------------------------------------------------------------------------

config_parser_tests() {
	# Source functions only (no main flow).
	# shellcheck disable=SC1090
	ENSURE_HINDSIGHT_LIB=1 . "$SCRIPT"

	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_cfg.XXXXXX")
	CONFIG_FILE="$tmp/config.env"

	# A value containing `=` (base64-ish key), surrounding double quotes,
	# surrounding single quotes, a comment, a blank line, leading/trailing
	# whitespace around a key, and an unknown key that must be ignored.
	{
		echo '# this is a comment'
		echo ''
		echo 'HINDSIGHT_API_LLM_API_KEY=sk-abc=def==ghi'
		echo 'HINDSIGHT_API_LLM_MODEL="gpt-5-nano"'
		echo "HINDSIGHT_API_LLM_PROVIDER='openai'"
		echo '   HINDSIGHT_API_LLM_BASE_URL   =http://localhost:1234'
		echo 'UNKNOWN_KEY=should-be-ignored'
		echo '#HINDSIGHT_API_LLM_MODEL=commented-out'
	} >"$CONFIG_FILE"

	assert_eq "config: value containing = is preserved" \
		"sk-abc=def==ghi" "$(config_get HINDSIGHT_API_LLM_API_KEY)"
	assert_eq "config: surrounding double quotes stripped" \
		"gpt-5-nano" "$(config_get HINDSIGHT_API_LLM_MODEL)"
	assert_eq "config: surrounding single quotes stripped" \
		"openai" "$(config_get HINDSIGHT_API_LLM_PROVIDER)"
	# Key is trimmed; value is kept literal (spec trims the key, not the value).
	assert_eq "config: key whitespace trimmed (value literal)" \
		"http://localhost:1234" "$(config_get HINDSIGHT_API_LLM_BASE_URL)"
	assert_eq "config: unknown key not retrievable as a known key" \
		"" "$(config_get UNKNOWN_KEY)"

	# Leading/trailing whitespace in VALUE is preserved (not trimmed per spec).
	printf 'HINDSIGHT_API_LLM_MODEL= spaced \n' >"$CONFIG_FILE"
	assert_eq "config: value whitespace preserved" \
		" spaced " "$(config_get HINDSIGHT_API_LLM_MODEL)"

	# Missing file yields empty.
	CONFIG_FILE="$tmp/does-not-exist.env"
	assert_eq "config: missing file yields empty" \
		"" "$(config_get HINDSIGHT_API_LLM_MODEL)"

	# resolve_config precedence: env beats config beats default.
	CONFIG_FILE="$tmp/config.env"
	printf 'HINDSIGHT_API_LLM_PROVIDER=cfg-provider\nHINDSIGHT_API_LLM_MODEL=cfg-model\nHINDSIGHT_API_LLM_API_KEY=cfg-key\n' >"$CONFIG_FILE"

	(
		unset HINDSIGHT_API_LLM_PROVIDER HINDSIGHT_API_LLM_MODEL HINDSIGHT_API_LLM_API_KEY HINDSIGHT_API_LLM_BASE_URL
		HINDSIGHT_API_LLM_PROVIDER="env-provider"
		export HINDSIGHT_API_LLM_PROVIDER
		resolve_config
		[ "$EFF_PROVIDER" = "env-provider" ] || { echo "BAD_PROVIDER:$EFF_PROVIDER"; exit 1; }
		[ "$EFF_MODEL" = "cfg-model" ] || { echo "BAD_MODEL:$EFF_MODEL"; exit 1; }
		[ "$EFF_API_KEY" = "cfg-key" ] || { echo "BAD_KEY:$EFF_API_KEY"; exit 1; }
		echo OK
	) >"$tmp/resolve.out" 2>&1
	assert_eq "resolve_config: env>config>default precedence" \
		"OK" "$(cat "$tmp/resolve.out")"

	# Default kicks in when neither env nor config provides the value.
	printf 'HINDSIGHT_API_LLM_API_KEY=cfg-key\n' >"$CONFIG_FILE"
	(
		unset HINDSIGHT_API_LLM_PROVIDER HINDSIGHT_API_LLM_MODEL HINDSIGHT_API_LLM_API_KEY HINDSIGHT_API_LLM_BASE_URL
		resolve_config
		[ "$EFF_PROVIDER" = "openai" ] || { echo "BAD_PROVIDER:$EFF_PROVIDER"; exit 1; }
		[ "$EFF_MODEL" = "gpt-5-nano" ] || { echo "BAD_MODEL:$EFF_MODEL"; exit 1; }
		[ -z "$EFF_BASE_URL" ] || { echo "BAD_BASE:$EFF_BASE_URL"; exit 1; }
		echo OK
	) >"$tmp/resolve2.out" 2>&1
	assert_eq "resolve_config: built-in defaults apply" \
		"OK" "$(cat "$tmp/resolve2.out")"

	rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Flow tests with fake binaries
# ---------------------------------------------------------------------------

# build_shims DIR  — writes fake docker/curl/sleep into DIR.
# Shim behavior driven by env the test exports:
#   FAKE_HEALTH_OK            curl returns 0 when "1"
#   FAKE_HINDSIGHT_CC_EXISTS  docker ps reports legacy container when "1"
#   FAKE_HINDSIGHT_EXISTS     docker ps reports new container when "1"
#   FAKE_LOG                  file to which docker logs its argv
#   FAKE_MARKER               file created by `docker run` (started marker)
#   FAKE_DAEMON_ARCH          what `docker info` reports as the architecture
#   FAKE_IMAGE_ARCH           what `docker image inspect` reports (default arm64)
#   FAKE_STATE                `State.Status ExitCode Restarting` (default "exited 0 false")
#   FAKE_PREV_EXISTS          docker ps reports the rollback container when "1"
#   FAKE_RUN_KEY_FILE         file that receives the API key docker run inherited
#   FAKE_STOP_FAIL            `docker stop` fails when "1"
#   FAKE_RENAME_FAIL          `docker rename` fails when "1"
build_shims() {
	dir="$1"

	cat >"$dir/docker" <<'EOF'
#!/bin/sh
echo "$@" >>"$FAKE_LOG"
cmd="$1"
case "$cmd" in
info)
	# `docker info --format '{{.Architecture}}'`: FAKE_DAEMON_ARCH, else silent.
	[ -n "${FAKE_DAEMON_ARCH:-}" ] && echo "$FAKE_DAEMON_ARCH"
	exit 0
	;;
ps)
	# Determine which name filter was requested and echo a fake id if "exists".
	for a in "$@"; do
		case "$a" in
		name=^hindsight-cc$)
			[ "${FAKE_HINDSIGHT_CC_EXISTS:-0}" = "1" ] && echo "ccid123"
			;;
		name=^hindsight$)
			[ "${FAKE_HINDSIGHT_EXISTS:-0}" = "1" ] && echo "hsid456"
			;;
		name=^hindsight-prev$)
			[ "${FAKE_PREV_EXISTS:-0}" = "1" ] && echo "previd789"
			;;
		esac
	done
	exit 0
	;;
run)
	# Record the API key docker would inherit from the caller's environment,
	# then simulate a started server.
	[ -n "${FAKE_RUN_KEY_FILE:-}" ] && printf '%s' "${HINDSIGHT_API_LLM_API_KEY:-}" >"$FAKE_RUN_KEY_FILE"
	[ -n "${FAKE_MARKER:-}" ] && : >"$FAKE_MARKER"
	exit 0
	;;
start)
	# Starting an existing container also brings the server up.
	[ -n "${FAKE_MARKER:-}" ] && : >"$FAKE_MARKER"
	exit 0
	;;
image)
	# `docker image inspect -f '{{.Architecture}}' <id>`
	echo "${FAKE_IMAGE_ARCH:-arm64}"
	exit 0
	;;
inspect)
	case "$*" in
	*"{{.Image}}"*)
		echo "sha256:fakeimage"
		;;
	*"{{.State.Status}}"*)
		echo "${FAKE_STATE:-exited 0 false}"
		;;
	*)
		# Emit an EMPTY API key (the recreate path) when FAKE_MISSING_KEY=1,
		# otherwise a present key (the docker-start path).
		if [ "${FAKE_MISSING_KEY:-0}" = "1" ]; then
			echo "HINDSIGHT_API_LLM_API_KEY="
		else
			echo "HINDSIGHT_API_LLM_API_KEY=present"
		fi
		;;
	esac
	exit 0
	;;
stop)
	[ "${FAKE_STOP_FAIL:-0}" = "1" ] && exit 1
	exit 0
	;;
rename)
	[ "${FAKE_RENAME_FAIL:-0}" = "1" ] && exit 1
	exit 0
	;;
*)
	exit 0
	;;
esac
EOF
	chmod +x "$dir/docker"

	cat >"$dir/curl" <<'EOF'
#!/bin/sh
# Health passes once the server has been "started" (marker exists), else honor
# FAKE_HEALTH_OK.
if [ -n "${FAKE_MARKER:-}" ] && [ -f "$FAKE_MARKER" ]; then
	exit 0
fi
[ "${FAKE_HEALTH_OK:-0}" = "1" ] && exit 0
exit 1
EOF
	chmod +x "$dir/curl"

	# No-op sleep so the wait loop never costs real time.
	cat >"$dir/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$dir/sleep"
}

# log_has SUBSTR LOGFILE
log_has() {
	grep -q -- "$1" "$2" 2>/dev/null
}

flow_test_healthy_no_mutation() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_a.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"

	# Health OK; migration cannot fire (no legacy container) so no rm/run.
	out=$(
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_HEALTH_OK=1 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(a): healthy server exits 0" "0" "$rc"
	if log_has " run " "$log" || log_has "^run " "$log"; then
		fail "flow(a): healthy server must NOT call docker run"
	else
		pass "flow(a): no docker run on healthy server"
	fi
	if log_has "rm -f" "$log"; then
		fail "flow(a): healthy server must NOT call docker rm"
	else
		pass "flow(a): no docker rm on healthy server"
	fi

	rm -rf "$tmp"
}

flow_test_migration_then_create() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_b.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	marker="$tmp/started.marker"

	# Legacy "hindsight-cc" exists, "hindsight" does not, health initially fails.
	# Provide an effective API key so create path is reached.
	out=$(
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=1 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_API_LLM_API_KEY="test-key" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(b): exits 0 after create+ready" "0" "$rc"
	if log_has "rm -f hindsight-cc" "$log"; then
		pass "flow(b): docker rm -f on legacy container"
	else
		fail "flow(b): expected 'docker rm -f hindsight-cc'"
	fi
	if log_has "run -d --name hindsight " "$log"; then
		pass "flow(b): docker run creates 'hindsight'"
	else
		fail "flow(b): expected 'docker run -d --name hindsight'"
	fi
	# rm must come before run.
	rm_line=$(grep -n "rm -f hindsight-cc" "$log" | head -1 | cut -d: -f1)
	run_line=$(grep -n "run -d --name hindsight " "$log" | head -1 | cut -d: -f1)
	if [ -n "$rm_line" ] && [ -n "$run_line" ] && [ "$rm_line" -lt "$run_line" ]; then
		pass "flow(b): migration rm precedes create run"
	else
		fail "flow(b): rm($rm_line) should precede run($run_line)"
	fi

	rm -rf "$tmp"
}

flow_test_recreate_on_missing_key() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_d.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	marker="$tmp/started.marker"

	# "hindsight" exists but its inspected env has an EMPTY API key, so the
	# script must rm -f that container and recreate it. An effective key is
	# supplied via env. This is the only path that fires the destructive
	# recreate gated on container_missing_api_key + require_api_key.
	out=$(
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=1 \
			FAKE_MISSING_KEY=1 \
			HINDSIGHT_API_LLM_API_KEY="test-key" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(d): exits 0 after recreate+ready" "0" "$rc"
	if log_has "rm -f hsid456" "$log"; then
		pass "flow(d): missing-key container is removed"
	else
		fail "flow(d): expected 'docker rm -f hsid456'"
	fi
	if log_has "run -d --name hindsight " "$log"; then
		pass "flow(d): missing-key container is recreated"
	else
		fail "flow(d): expected 'docker run -d --name hindsight'"
	fi

	rm -rf "$tmp"
}

flow_test_migration_noop_when_both_exist() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_e.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	marker="$tmp/started.marker"

	# Both legacy and new containers exist: migration must NOT remove the legacy
	# one (the self-limiting invariant). Health fails initially; the existing
	# "hindsight" has a key, so it is simply started.
	out=$(
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=1 \
			FAKE_HINDSIGHT_EXISTS=1 \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(e): exits 0 after start" "0" "$rc"
	if log_has "rm -f hindsight-cc" "$log"; then
		fail "flow(e): legacy container must NOT be removed when 'hindsight' exists"
	else
		pass "flow(e): migration no-ops when both containers exist"
	fi
	if log_has "start hsid456" "$log"; then
		pass "flow(e): existing 'hindsight' container is started"
	else
		fail "flow(e): expected 'docker start hsid456'"
	fi

	rm -rf "$tmp"
}

flow_test_local_provider_no_key() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_f.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	marker="$tmp/started.marker"

	# A local provider (Ollama) sets a base URL and NO API key. The container
	# must still be created: require_api_key is satisfied by the base URL, and
	# create_container must NOT pass an (empty) HINDSIGHT_API_LLM_API_KEY env
	# (which would otherwise trigger a recreate loop next session).
	out=$(
		unset HINDSIGHT_API_LLM_API_KEY
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_API_LLM_PROVIDER="ollama" \
			HINDSIGHT_API_LLM_BASE_URL="http://localhost:11434/v1" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(f): local provider (no key) creates container" "0" "$rc"
	if log_has "run -d --name hindsight " "$log"; then
		pass "flow(f): container created for local provider without a key"
	else
		fail "flow(f): expected 'docker run -d --name hindsight'"
	fi
	if log_has "HINDSIGHT_API_LLM_BASE_URL=http://localhost:11434/v1" "$log"; then
		pass "flow(f): base URL passed through to container"
	else
		fail "flow(f): expected base URL env on docker run"
	fi
	if log_has "HINDSIGHT_API_LLM_API_KEY" "$log"; then
		fail "flow(f): must NOT pass an API key env for a keyless local provider"
	else
		pass "flow(f): no API key env on docker run for local provider"
	fi

	rm -rf "$tmp"
}

flow_test_no_key_aborts_without_create() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_g.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"

	# No API key, no base URL, health fails, and no existing container of either
	# name. require_api_key must abort: the script exits 1 and creates NOTHING
	# (it must refuse to spin up a keyless cloud container). The real environment
	# has a key set, so we unset it (and provider/base URL) in this subshell.
	out=$(
		unset HINDSIGHT_API_LLM_API_KEY HINDSIGHT_API_LLM_BASE_URL HINDSIGHT_API_LLM_PROVIDER
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(g): keyless run aborts with exit 1" "1" "$rc"
	if log_has "run -d" "$log"; then
		fail "flow(g): keyless run must NOT create a container (docker run -d found)"
	else
		pass "flow(g): no docker run on keyless abort"
	fi

	rm -rf "$tmp"
}

flow_test_no_docker() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_c.XXXXXX")
	# Empty shim dir as the ONLY PATH so `command -v docker` fails. The script
	# is executed via its shebang (#!/bin/sh) so it needs nothing on PATH.
	chmod +x "$SCRIPT" 2>/dev/null
	out=$(
		PATH="$tmp" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			"$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')
	assert_eq "flow(c): docker not found exits 0" "0" "$rc"
	rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Container platform, resources, and recreate (see
# docs/superpowers/specs/2026-10-08-hindsight-container-platform-design.md)
# ---------------------------------------------------------------------------

# platform_for DAEMON_ARCH [OVERRIDE]
# Prints what resolve_platform picks for a fake Docker daemon architecture and an
# optional HINDSIGHT_PLATFORM. Uses the global $tmp as the shim directory.
platform_for() {
	pf_arch="$1"
	pf_override="${2:-}"
	(
		unset HINDSIGHT_PLATFORM
		if [ -n "$pf_override" ]; then
			HINDSIGHT_PLATFORM="$pf_override"
			export HINDSIGHT_PLATFORM
		fi
		PATH="$tmp:$PATH"
		FAKE_LOG="$tmp/docker.log"
		FAKE_DAEMON_ARCH="$pf_arch"
		export PATH FAKE_LOG FAKE_DAEMON_ARCH
		resolve_platform
		printf '%s' "$EFF_PLATFORM"
	)
}

# limit_for [ENV_VALUE]
# Prints what resolve_memory_limit picks for an optional HINDSIGHT_MEMORY_LIMIT.
limit_for() {
	lf_env="${1:-}"
	(
		unset HINDSIGHT_MEMORY_LIMIT
		if [ -n "$lf_env" ]; then
			HINDSIGHT_MEMORY_LIMIT="$lf_env"
			export HINDSIGHT_MEMORY_LIMIT
		fi
		resolve_memory_limit
		printf '%s' "$EFF_MEMORY_LIMIT"
	)
}

resolution_tests() {
	# shellcheck disable=SC1090
	ENSURE_HINDSIGHT_LIB=1 . "$SCRIPT"

	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_res.XXXXXX")
	build_shims "$tmp"
	: >"$tmp/docker.log"
	CONFIG_FILE="$tmp/none.env"

	assert_eq "platform: aarch64 daemon -> linux/arm64" "linux/arm64" "$(platform_for aarch64)"
	assert_eq "platform: arm64 daemon -> linux/arm64" "linux/arm64" "$(platform_for arm64)"
	assert_eq "platform: x86_64 daemon -> linux/amd64" "linux/amd64" "$(platform_for x86_64)"
	assert_eq "platform: amd64 daemon -> linux/amd64" "linux/amd64" "$(platform_for amd64)"
	assert_eq "platform: unknown daemon arch -> empty (no --platform)" "" "$(platform_for s390x)"
	assert_eq "platform: env override beats daemon arch" "linux/amd64" "$(platform_for aarch64 linux/amd64)"
	assert_eq "platform: invalid override is ignored" "linux/arm64" "$(platform_for aarch64 linux/s390x)"

	printf 'HINDSIGHT_PLATFORM=linux/amd64\nHINDSIGHT_MEMORY_LIMIT=3g\n' >"$tmp/cfg.env"
	CONFIG_FILE="$tmp/cfg.env"
	assert_eq "config: HINDSIGHT_PLATFORM is a recognized key" "linux/amd64" "$(config_get HINDSIGHT_PLATFORM)"
	assert_eq "platform: config.env override beats daemon arch" "linux/amd64" "$(platform_for aarch64)"
	assert_eq "platform: env override beats config.env" "linux/arm64" "$(platform_for aarch64 linux/arm64)"
	assert_eq "platform: an invalid env value does not hide a valid config.env value" "linux/amd64" "$(platform_for aarch64 linux/s390x)"
	assert_eq "memory: config.env value used when env is unset" "3g" "$(limit_for)"
	assert_eq "memory: env beats config.env" "6g" "$(limit_for 6g)"

	printf 'HINDSIGHT_PLATFORM="linux/arm64"\nHINDSIGHT_MEMORY_LIMIT='"'"'2G'"'"'\n' >"$tmp/quoted.env"
	CONFIG_FILE="$tmp/quoted.env"
	assert_eq "platform: a quoted config.env value is accepted" "linux/arm64" "$(platform_for x86_64)"
	assert_eq "memory: a quoted, uppercase-unit config.env value is accepted" "2G" "$(limit_for)"

	CONFIG_FILE="$tmp/none.env"
	assert_eq "memory: default is 4g" "4g" "$(limit_for)"
	assert_eq "memory: 'none' disables the limit" "none" "$(limit_for none)"
	assert_eq "memory: megabytes accepted" "4096m" "$(limit_for 4096m)"
	assert_eq "memory: garbage falls back to the default" "4g" "$(limit_for garbage)"
	assert_eq "memory: bad suffix falls back to the default" "4g" "$(limit_for 4x)"
	assert_eq "memory: leading letter falls back to the default" "4g" "$(limit_for g4)"

	rm -rf "$tmp"
}

flow_test_create_flags() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_h.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	keyfile="$tmp/run-key"
	printf 'HINDSIGHT_API_LLM_API_KEY=s3cret-from-config\n' >"$tmp/config.env"

	# No container exists and the server is down, so the create path runs. The
	# API key comes ONLY from config.env, never from the caller's environment.
	out=$(
		unset HINDSIGHT_API_LLM_API_KEY HINDSIGHT_MEMORY_LIMIT HINDSIGHT_PLATFORM
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$tmp/started.marker" \
			FAKE_RUN_KEY_FILE="$keyfile" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			FAKE_DAEMON_ARCH=aarch64 \
			HINDSIGHT_CONFIG_FILE="$tmp/config.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(h): create exits 0" "0" "$rc"
	for flag in \
		"--platform linux/arm64" \
		"--restart unless-stopped" \
		"--stop-timeout 40" \
		"--shm-size=2g" \
		"--memory 4g" \
		"--memory-swap 4g" \
		"--health-cmd curl -sf http://localhost:8888/health" \
		"--health-interval 30s" \
		"--health-start-period 120s" \
		"--log-opt max-size=10m" \
		"--log-opt max-file=3" \
		"-e HINDSIGHT_API_WORKER_ID=hindsight-local"; do
		if log_has "$flag" "$log"; then
			pass "flow(h): docker run has '$flag'"
		else
			fail "flow(h): docker run is missing '$flag'"
		fi
	done
	if log_has "s3cret-from-config" "$log"; then
		fail "flow(h): the API key value must NOT appear in docker's argv"
	else
		pass "flow(h): the API key value is absent from docker's argv"
	fi
	if log_has "HINDSIGHT_API_LLM_API_KEY=" "$log"; then
		fail "flow(h): the API key must be passed by name, not NAME=value"
	else
		pass "flow(h): the API key is passed by name only"
	fi
	if log_has "-e HINDSIGHT_API_LLM_API_KEY " "$log"; then
		pass "flow(h): bare -e HINDSIGHT_API_LLM_API_KEY is present"
	else
		fail "flow(h): expected a bare '-e HINDSIGHT_API_LLM_API_KEY'"
	fi
	assert_eq "flow(h): docker inherits the key from the environment" \
		"s3cret-from-config" "$(cat "$keyfile" 2>/dev/null)"

	rm -rf "$tmp"
}

flow_test_memory_limit_override() {
	for lim in 6g none; do
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_i.XXXXXX")
		build_shims "$tmp"
		log="$tmp/docker.log"
		: >"$log"

		out=$(
			unset HINDSIGHT_PLATFORM
			PATH="$tmp:$PATH" \
				FAKE_LOG="$log" \
				FAKE_MARKER="$tmp/started.marker" \
				FAKE_HEALTH_OK=0 \
				FAKE_HINDSIGHT_CC_EXISTS=0 \
				FAKE_HINDSIGHT_EXISTS=0 \
				HINDSIGHT_API_LLM_API_KEY="test-key" \
				HINDSIGHT_MEMORY_LIMIT="$lim" \
				HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
				sh "$SCRIPT"
			echo "exit=$?"
		)
		rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

		assert_eq "flow(i): HINDSIGHT_MEMORY_LIMIT=$lim creates the container" "0" "$rc"
		if [ "$lim" = "none" ]; then
			if log_has "--memory " "$log" || log_has "--memory-swap" "$log"; then
				fail "flow(i): 'none' must pass no memory flags"
			else
				pass "flow(i): 'none' passes no memory flags"
			fi
		elif log_has "--memory $lim" "$log" && log_has "--memory-swap $lim" "$log"; then
			pass "flow(i): $lim is passed as --memory and --memory-swap"
		else
			fail "flow(i): expected --memory $lim and --memory-swap $lim"
		fi

		rm -rf "$tmp"
	done
}

flow_test_unknown_arch_omits_platform() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_j.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"

	# `docker info` reports no architecture: keep today's behavior (no flag).
	out=$(
		unset HINDSIGHT_PLATFORM
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$tmp/started.marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_API_LLM_API_KEY="test-key" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(j): unknown architecture still creates the container" "0" "$rc"
	if log_has "--platform" "$log"; then
		fail "flow(j): no --platform when the architecture is unknown"
	else
		pass "flow(j): no --platform when the architecture is unknown"
	fi

	rm -rf "$tmp"
}

flow_test_key_with_shell_metacharacters() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_n.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	keyfile="$tmp/run-key"

	# Real keys can contain characters the shell treats specially. The value must
	# reach docker intact (through the environment) and must never be in argv.
	key='ab c"d$HOME;e&f|g`h'
	out=$(
		unset HINDSIGHT_PLATFORM
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$tmp/started.marker" \
			FAKE_RUN_KEY_FILE="$keyfile" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			HINDSIGHT_API_LLM_API_KEY="$key" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(n): a key with shell metacharacters creates the container" "0" "$rc"
	assert_eq "flow(n): the key arrives intact through the environment" "$key" "$(cat "$keyfile" 2>/dev/null)"
	if log_has 'ab c' "$log"; then
		fail "flow(n): the key must not appear in docker's argv"
	else
		pass "flow(n): the key is absent from docker's argv"
	fi

	rm -rf "$tmp"
}

# ---------------------------------------------------------------------------

echo "=== config parser tests ==="
config_parser_tests

echo "=== platform and memory-limit resolution ==="
resolution_tests

echo "=== flow tests ==="
flow_test_healthy_no_mutation
flow_test_migration_then_create
flow_test_recreate_on_missing_key
flow_test_migration_noop_when_both_exist
flow_test_local_provider_no_key
flow_test_no_key_aborts_without_create
flow_test_no_docker
flow_test_create_flags
flow_test_memory_limit_override
flow_test_unknown_arch_omits_platform
flow_test_key_with_shell_metacharacters

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
