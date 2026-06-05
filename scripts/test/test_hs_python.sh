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
REAL_PY=$(command -v python3 || command -v python)

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

# assert_contains DESC HAYSTACK NEEDLE
assert_not_contains() {
	case "$2" in
	*"$3"*) fail "$1 (found unwanted [$3] in [$2])" ;;
	*) pass "$1" ;;
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
rm -rf "$SANDBOX"
echo ""
echo "hs-python: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
