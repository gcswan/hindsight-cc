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
# the first that works. The candidate list ends with absolute system paths, so a
# poisoned PATH or an activated-but-broken venv cannot shadow every option. If
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

# Debug -> stderr, only when HINDSIGHT_DEBUG is truthy (matches ensure-hindsight).
hs_debug() {
	case "${HINDSIGHT_DEBUG:-}" in
	1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
		echo "[hindsight-cc:hs-python] $1" >&2
		;;
	esac
}

# Probe mirrors what the hook scripts import at runtime: json (pulls the _json
# C-extension), urllib.request (the REST client), plus os/socket. A
# partially-relocated interpreter passes `import sys` but fails THIS, which is
# exactly the failure we must detect and skip. Require Python >= 3.6 (f-strings).
HS_PROBE='import sys; assert sys.version_info[:2] >= (3, 6); import json, os, socket, urllib.request'

# hs_works CMD -> 0 if CMD is a usable interpreter, quietly.
hs_works() {
	# stdin from /dev/null so the hook payload on our stdin is untouched;
	# stdout+stderr discarded so a probe never pollutes the prompt channel.
	"$1" -c "$HS_PROBE" </dev/null >/dev/null 2>&1
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
	if hs_works "$cand"; then
		hs_debug "using interpreter: $cand"
		exec "$cand" "$SCRIPT" "$@"
	fi
done

hs_debug "no working python3 interpreter found; soft-failing (no-op)"
exit 0
