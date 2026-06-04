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
build_shims() {
	dir="$1"

	cat >"$dir/docker" <<'EOF'
#!/bin/sh
echo "$@" >>"$FAKE_LOG"
cmd="$1"
case "$cmd" in
info)
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
		esac
	done
	exit 0
	;;
run)
	# Simulate a started server.
	[ -n "${FAKE_MARKER:-}" ] && : >"$FAKE_MARKER"
	exit 0
	;;
start)
	# Starting an existing container also brings the server up.
	[ -n "${FAKE_MARKER:-}" ] && : >"$FAKE_MARKER"
	exit 0
	;;
inspect)
	# Emit an EMPTY API key (the recreate path) when FAKE_MISSING_KEY=1,
	# otherwise a present key (the docker-start path).
	if [ "${FAKE_MISSING_KEY:-0}" = "1" ]; then
		echo "HINDSIGHT_API_LLM_API_KEY="
	else
		echo "HINDSIGHT_API_LLM_API_KEY=present"
	fi
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

echo "=== config parser tests ==="
config_parser_tests

echo "=== flow tests ==="
flow_test_healthy_no_mutation
flow_test_migration_then_create
flow_test_recreate_on_missing_key
flow_test_migration_noop_when_both_exist
flow_test_local_provider_no_key
flow_test_no_docker

echo ""
echo "=== summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
