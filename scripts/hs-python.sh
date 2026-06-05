#!/bin/sh
#
# Pick a WORKING Python 3 interpreter and exec a hindsight hook script with it.
#
# Why this exists (v2): the plugin's hooks run under the *ambient* `python3`
# (v1 used the plugin's own scripts/.venv/bin/python3, which v2 deliberately
# dropped for a stdlib-only/no-venv design). In a project that activates a
# uv/venv/pyenv interpreter, that ambient `python3` can be transiently broken --
# e.g. a relocated/relinked uv standalone whose platform libraries aren't where
# the binary expects. Such an interpreter boots far enough to satisfy a trivial
# `import sys` probe but dies importing a C-extension, so a bare
# `python3 hook.py` prints a scary CPython startup error ("Could not find
# platform dependent libraries <exec_prefix>") as a "hook error" -- even though
# hindsight is designed to fail silently when memory is unavailable.
#
# This shim probes candidate interpreters with the SAME imports the hooks
# actually need (json + urllib + a C-extension), skips any that fail, and execs
# the first that works. The candidate list begins with absolute system paths, so
# a poisoned PATH or an activated-but-broken venv cannot shadow every option. If
# none work it exits 0 silently -- hindsight just does nothing this turn,
# matching its soft-fail contract, instead of emitting a noisy error.
#
# Usage (from hooks.json):
#   sh "${CLAUDE_PLUGIN_ROOT}/scripts/hs-python.sh" \
#      "${CLAUDE_PLUGIN_ROOT}/scripts/retain-prompt.py" [args...]
#
# The hook payload arrives on stdin. The probe reads from /dev/null so it never
# consumes that stdin, and discards stdout/stderr so it never pollutes the
# prompt-injection channel; only the final exec inherits the real stdin/stdout.

# Debug gate -> truthy HINDSIGHT_DEBUG (matches ensure-hindsight). Factored out
# of hs_debug so hs_works can decide whether to surface a probe's rejection
# reason without re-parsing the env var.
hs_debug_on() {
	case "${HINDSIGHT_DEBUG:-}" in
	1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) return 0 ;;
	*) return 1 ;;
	esac
}

# Debug line -> stderr, only when HINDSIGHT_DEBUG is truthy.
hs_debug() {
	hs_debug_on && echo "[hindsight-cc:hs-python] $1" >&2
}

# Probe mirrors what the hook scripts import at runtime: json (pulls the _json
# C-extension), urllib.request (the REST client), plus os/socket. A
# partially-relocated interpreter passes `import sys` but fails THIS, which is
# exactly the failure we must detect and skip. Require Python >= 3.6 (f-strings).
HS_PROBE='import sys; assert sys.version_info[:2] >= (3, 6); import json, os, socket, urllib.request'

# Bound each probe so a genuinely HUNG interpreter (e.g. a wedged pyenv/asdf
# resolver on a slow/networked FS) can't stall the hook on the user's prompt
# path forever -- the rest of the plugin bounds recall/retain the same way.
#
# The bound must clear the slowest interpreter we'd legitimately ACCEPT: a
# pyenv/asdf `python3` shim measured ~3.3s of resolution overhead (see the
# candidate-ordering note below). A tight bound would KILL that healthy-but-slow
# interpreter and, on a shim-only host, make hindsight soft-fail forever -- worse
# than the noisy error this shim exists to prevent. 10s is a generous backstop
# that trips only on a true hang, never a merely-slow interpreter. Overridable
# via HS_PROBE_TIMEOUT (seconds). `timeout` is GNU coreutils (Linux; macOS
# exposes it as `gtimeout`); when neither exists the probe is unbounded.
HS_PROBE_TIMEOUT="${HS_PROBE_TIMEOUT:-10}"
HS_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
	HS_TIMEOUT="timeout $HS_PROBE_TIMEOUT"
elif command -v gtimeout >/dev/null 2>&1; then
	HS_TIMEOUT="gtimeout $HS_PROBE_TIMEOUT"
fi

# hs_works CMD -> 0 if CMD is a usable interpreter. Quiet by default; under
# HINDSIGHT_DEBUG it surfaces WHY a candidate was rejected (e.g. the "Could not
# find platform dependent libraries" message that motivates this shim) so a
# silent no-op is diagnosable instead of opaque.
hs_works() {
	# stdin from /dev/null so the hook payload on our stdin is untouched.
	# Word-splitting HS_TIMEOUT (empty, or e.g. "timeout 10") is intentional.
	# shellcheck disable=SC2086
	if hs_debug_on; then
		# Capture stderr (dup'd into the substitution) while discarding stdout,
		# so a rejected candidate's reason can be logged. stdout never leaks.
		_err=$($HS_TIMEOUT "$1" -c "$HS_PROBE" </dev/null 2>&1 >/dev/null)
		_rc=$?
		if [ "$_rc" -ne 0 ] && [ -n "$_err" ]; then
			hs_debug "rejected $1: $_err"
		fi
		return "$_rc"
	fi
	# Quiet path: stdout+stderr discarded so a probe never pollutes the channel.
	$HS_TIMEOUT "$1" -c "$HS_PROBE" </dev/null >/dev/null 2>&1
}

SCRIPT="${1:-}"
if [ -z "$SCRIPT" ]; then
	hs_debug "no hook script argument; nothing to run"
	exit 0
fi
shift

# Candidate interpreters, in order of preference. We deliberately lead with
# ABSOLUTE, DIRECT system interpreters rather than the ambient `python3`:
#
#   * Robustness: absolute paths bypass PATH entirely, so a poisoned PATH or an
#     activated-but-broken venv cannot shadow them.
#   * Speed: the hooks are stdlib-only, so ANY working python3 >= 3.6 is equally
#     correct -- and a bare `python3` routed through a pyenv/asdf shim measured
#     ~3.3s of pure resolution overhead per launch on the author's machine, vs
#     ~0.02s for a direct interpreter. Probing the shim and then exec'ing it
#     would pay that cost twice. Leading with direct interpreters makes the
#     shim FASTER than v2's bare `python3`, not slower.
#
# Order: macOS homebrew (arm64, then x86_64/manual), then /usr/bin/python3
# (system on macOS-with-CLT and the distro python on Linux), then the ambient
# `python3`/versioned/`python` names as universal fallbacks. Absent absolute
# paths fail the probe instantly (command-not-found), so listing them is free.
# Overridable via HS_PYTHON_CANDIDATES (space-separated) to pin an interpreter.
HS_CANDIDATES="${HS_PYTHON_CANDIDATES:-/opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python}"

# Word-splitting of the space-separated candidate list is intentional.
# shellcheck disable=SC2086
for cand in $HS_CANDIDATES; do
	hs_debug "probing: $cand"
	if hs_works "$cand"; then
		hs_debug "using interpreter: $cand"
		exec "$cand" "$SCRIPT" "$@"
	fi
done

hs_debug "no working python3 interpreter found; soft-failing (no-op)"
exit 0
