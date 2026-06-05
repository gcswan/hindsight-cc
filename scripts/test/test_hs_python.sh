#!/bin/sh
#
# Tests for scripts/hs-python.sh
#
# hs-python.sh picks a WORKING python3 interpreter and execs a hindsight hook
# script with it, so a transiently-broken ambient `python3` (e.g. a relocated
# uv/pyenv interpreter that passes a trivial probe but fails importing a
# C-extension) can never turn a silent hook into a noisy "hook error".
#
# No real interpreters are mutated: tests drive the candidate list with the
# HS_PYTHON_CANDIDATES override and put fake `goodpy`/`brokenpy` shims on PATH.
#
# Run: sh scripts/test/test_hs_python.sh

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SCRIPT="$TEST_DIR/../hs-python.sh"
# Resolve to the real interpreter BINARY, not a pyenv/asdf shim: a shim can add
# ~3.3s of startup that would trip the probe's timeout backstop and make goodpy
# (our stand-in for "a working interpreter") flaky. sys.executable is the direct
# underlying binary.
_PY=$(command -v python3 || command -v python)
REAL_PY=$("$_PY" -c 'import sys; print(sys.executable)' 2>/dev/null || printf '%s' "$_PY")

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

# assert_not_contains DESC HAYSTACK NEEDLE
assert_not_contains() {
	case "$2" in
	*"$3"*) fail "$1 (found unwanted [$3] in [$2])" ;;
	*) pass "$1" ;;
	esac
}

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
	case "$2" in
	*"$3"*) pass "$1" ;;
	*) fail "$1 (expected [$3] in [$2])" ;;
	esac
}

# ---------------------------------------------------------------------------
# Test fixture: a sandbox dir with fake interpreter shims and a target script.
# ---------------------------------------------------------------------------
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hs_py.XXXXXX")
BIN="$SANDBOX/bin"
mkdir -p "$BIN"

# goodpy: a working interpreter -> just the real python3.
cat >"$BIN/goodpy" <<EOF
#!/bin/sh
exec "$REAL_PY" "\$@"
EOF
chmod +x "$BIN/goodpy"

# brokenpy: fails the probe AND, if ever exec'd, prints a scary line to stderr.
cat >"$BIN/brokenpy" <<'EOF'
#!/bin/sh
echo "Could not find platform dependent libraries <exec_prefix>" >&2
exit 1
EOF
chmod +x "$BIN/brokenpy"

# hangpy: simulates a wedged interpreter whose probe never returns. The shim's
# timeout backstop must skip it rather than stall the user's prompt forever.
cat >"$BIN/hangpy" <<'EOF'
#!/bin/sh
sleep 30
EOF
chmod +x "$BIN/hangpy"

# target script: proves it was exec'd, that stdin reached it intact, and that
# the probe did not pollute stdout. Echoes "RAN:<stdin>".
cat >"$SANDBOX/target.py" <<'EOF'
import sys
sys.stdout.write("RAN:" + sys.stdin.read())
EOF

# run_shim CANDIDATES STDIN  -> populates OUT / ERR / RC
run_shim() {
	_cands="$1"
	_stdin="$2"
	ERRFILE="$SANDBOX/err"
	OUT=$(printf '%s' "$_stdin" | PATH="$BIN:$PATH" HS_PYTHON_CANDIDATES="$_cands" \
		sh "$SCRIPT" "$SANDBOX/target.py" 2>"$ERRFILE")
	RC=$?
	ERR=$(cat "$ERRFILE")
}

# run_shim_debug CANDIDATES STDIN  -> like run_shim but with HINDSIGHT_DEBUG=1,
# so the shim's diagnostic stderr is exercised. stdout must stay clean.
run_shim_debug() {
	_cands="$1"
	_stdin="$2"
	ERRFILE="$SANDBOX/err"
	OUT=$(printf '%s' "$_stdin" | PATH="$BIN:$PATH" HS_PYTHON_CANDIDATES="$_cands" \
		HINDSIGHT_DEBUG=1 sh "$SCRIPT" "$SANDBOX/target.py" 2>"$ERRFILE")
	RC=$?
	ERR=$(cat "$ERRFILE")
}

# ---------------------------------------------------------------------------
# 1. Happy path: first working candidate is exec'd; stdin passes through;
#    only the target's stdout is emitted (no probe pollution).
# ---------------------------------------------------------------------------
run_shim "goodpy" "PAYLOAD"
assert_eq "happy: target exec'd with stdin intact" "RAN:PAYLOAD" "$OUT"
assert_eq "happy: exit code forwarded (0)" "0" "$RC"

# ---------------------------------------------------------------------------
# 2. A broken first candidate is SKIPPED (probe fails) and the shim falls
#    through to the next working one. The broken interpreter's stderr never
#    surfaces (it was only probed, never exec'd, and the probe is silenced).
# ---------------------------------------------------------------------------
run_shim "brokenpy goodpy" "XYZ"
assert_eq "fallback: skipped broken, ran via good interpreter" "RAN:XYZ" "$OUT"
assert_eq "fallback: exit 0" "0" "$RC"
assert_not_contains "fallback: broken interpreter's error is not surfaced" "$ERR" "exec_prefix"

# ---------------------------------------------------------------------------
# 3. The probe must NOT consume the hook payload on stdin (it reads /dev/null).
#    A broken first candidate forces a probe to run before the good one.
# ---------------------------------------------------------------------------
run_shim "brokenpy goodpy" "the-whole-payload-must-survive"
assert_eq "stdin: probe does not nibble stdin" "RAN:the-whole-payload-must-survive" "$OUT"

# ---------------------------------------------------------------------------
# 4. No working interpreter -> soft-fail SILENTLY: exit 0, no stdout, no stderr.
#    This is the whole point: never emit a noisy hook error.
# ---------------------------------------------------------------------------
run_shim "brokenpy" "q"
assert_eq "no-python: exits 0 (soft-fail)" "0" "$RC"
assert_eq "no-python: no stdout (no prompt pollution)" "" "$OUT"
assert_eq "no-python: no stderr noise" "" "$ERR"

# ---------------------------------------------------------------------------
# 5. No script argument -> exit 0, no output (defensive; never error).
# ---------------------------------------------------------------------------
NOARG_OUT=$(PATH="$BIN:$PATH" sh "$SCRIPT" 2>"$SANDBOX/err2")
NOARG_RC=$?
assert_eq "no-arg: exits 0" "0" "$NOARG_RC"
assert_eq "no-arg: no stdout" "" "$NOARG_OUT"

# ---------------------------------------------------------------------------
# 6. Under HINDSIGHT_DEBUG, a rejected candidate's REASON is surfaced to stderr
#    (so a silent no-op is diagnosable) -- while stdout stays clean. This is the
#    debug-mode complement of test 2's non-debug "error is not surfaced".
# ---------------------------------------------------------------------------
run_shim_debug "brokenpy goodpy" "DBG"
assert_eq "debug: stdout still clean (debug goes to stderr)" "RAN:DBG" "$OUT"
assert_eq "debug: exit 0" "0" "$RC"
assert_contains "debug: logs the candidate it probed" "$ERR" "probing: brokenpy"
assert_contains "debug: surfaces the rejection reason" "$ERR" "rejected brokenpy"
assert_contains "debug: surfaces the underlying error text" "$ERR" "exec_prefix"
assert_contains "debug: logs the interpreter it chose" "$ERR" "using interpreter: goodpy"

# ---------------------------------------------------------------------------
# 7. Under HINDSIGHT_DEBUG with no working interpreter -> still a silent-stdout
#    soft-fail (exit 0, no stdout), but the all-fail reason IS logged to stderr.
# ---------------------------------------------------------------------------
run_shim_debug "brokenpy" "q"
assert_eq "debug-no-python: exits 0" "0" "$RC"
assert_eq "debug-no-python: no stdout" "" "$OUT"
assert_contains "debug-no-python: logs the soft-fail" "$ERR" "no working python3 interpreter found"

# ---------------------------------------------------------------------------
# 8. A HANGING candidate is bounded by the probe timeout and skipped, so the
#    shim falls through to a working interpreter instead of stalling the user's
#    prompt forever. Only meaningful where `timeout`/`gtimeout` exists; without
#    it the probe is unbounded by design, so skip rather than hang the suite.
# ---------------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
	HANG_START=$(date +%s)
	HANG_OUT=$(printf '%s' "BOUNDED" | PATH="$BIN:$PATH" \
		HS_PYTHON_CANDIDATES="hangpy goodpy" HS_PROBE_TIMEOUT=1 \
		sh "$SCRIPT" "$SANDBOX/target.py" 2>/dev/null)
	HANG_RC=$?
	HANG_ELAPSED=$(($(date +%s) - HANG_START))
	assert_eq "hang: bounded probe skips hung candidate, runs good one" "RAN:BOUNDED" "$HANG_OUT"
	assert_eq "hang: exit 0" "0" "$HANG_RC"
	if [ "$HANG_ELAPSED" -lt 10 ]; then
		pass "hang: completed well under the 30s hang (took ${HANG_ELAPSED}s)"
	else
		fail "hang: took ${HANG_ELAPSED}s -- probe was not bounded"
	fi
else
	pass "hang: skipped (no timeout/gtimeout; probe is unbounded by design)"
fi

# ---------------------------------------------------------------------------
rm -rf "$SANDBOX"
echo ""
echo "hs-python: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
