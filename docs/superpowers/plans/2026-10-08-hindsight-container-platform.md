# Container Platform Pinning, Resources, and Recreate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/ensure-hindsight.sh` run the Hindsight container on the host's native architecture by default (never silently emulated), apply the documented run flags, detect and report drift, and add an operator-run `recreate` command with rollback; then migrate the live container back to native arm64.

**Architecture:** One POSIX-sh script (`ensure-hindsight.sh`) gains small single-purpose functions (platform and memory resolution, ELF architecture detection and a Postgres-binary guard, drift and crash diagnosis, `recreate`), each unit-tested with the existing fake-`docker` harness. A new stdlib-only Python helper (`container_info.py`) feeds the existing status command. The live migration is a separate, supervised runbook (Task 9) that uses the finished `recreate` command.

**Tech Stack:** POSIX `sh` (macOS `/bin/sh` is bash 3.2), Python 3 stdlib (must import on the macOS system Python 3.9), pytest/ruff/pyright (dev-only venv), Docker CLI.

**Spec:** `docs/superpowers/specs/2026-10-08-hindsight-container-platform-design.md` (approved; read it first, especially the Findings table).

## Global Constraints

Every task's requirements implicitly include this section.

- **Public repository.** Nothing sensitive may be committed or pushed (see "Public Repo Safety" below). **Do not run `git push` or open a PR unless the maintainer's instructions for this run explicitly ask for it.** When they do: push only the feature branch (never force, never any other branch, never to `main`), and only after Task 8's scan and suites are clean. Otherwise commits stay local.
- Image pin stays `ghcr.io/vectorize-io/hindsight:0.8.6`, overridable with `HINDSIGHT_IMAGE`. Container name `hindsight`; rollback container `hindsight-prev`.
- `ensure-hindsight.sh` stays POSIX `sh`: no `local`, no arrays, no `[[ ]]`; function-scoped variables use a short prefix (`gi_`, `rp_`, `cef_`, ...) as the file already does. **Do not put a `case` statement inside `$( ... )` in test files**: macOS `/bin/sh` (bash 3.2) mis-parses a case pattern's `)` there; use `if`.
- Existing invariants are preserved: health-probe-first reuse; a healthy container is never touched; Docker missing or the daemon down soft-exits 0 for hooks; config precedence `env var > ~/.config/hindsight-cc/config.env > built-in default`.
- `docker run` values, exactly: `--restart unless-stopped`, `--stop-timeout 40`, `--shm-size=2g` (unchanged), `--memory` and `--memory-swap` both `4g` by default (`HINDSIGHT_MEMORY_LIMIT=none` passes neither), `--health-cmd "curl -sf http://localhost:8888/health"` with `--health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 120s`, `--log-opt max-size=10m --log-opt max-file=3`, `-e HINDSIGHT_API_WORKER_ID=hindsight-local`, ports `8888:8888` and `9999:9999`, data mount `"$DATA_DIR:/home/hindsight/.pg0"`.
- `HINDSIGHT_PLATFORM` accepts exactly `linux/arm64` or `linux/amd64`; the first valid value wins (env, then `config.env`), else the Docker **daemon's** architecture (`docker info --format '{{.Architecture}}'`), else no `--platform` flag.
- The LLM API key is passed to Docker **by name from the environment** (`-e HINDSIGHT_API_LLM_API_KEY`), never as `NAME=value` in argv.
- Embedded Postgres binaries are moved aside as `installation.<arch>`, **never deleted**, and only when no container is using the data directory.
- Python is stdlib-only, imports on Python 3.9, and soft-fails (never raises out of the status command).
- Existing suites stay green at every step: `sh scripts/test/test_ensure_hindsight.sh` (29 assertions before this plan), `sh scripts/test/test_hs_python.sh` (23), `./scripts/.venv/bin/pytest scripts/test` (record the baseline you see in Task 0).

### Public Repo Safety

This repository is public. In every file you write (code, tests, docs, comments, commit messages) and in every command you run:

- No secrets or credentials of any kind: API keys, tokens, passwords, password-manager item IDs or secret-reference URIs, private keys. Test fixtures use obviously fake values (`test-key`, `s3cret-from-config`).
- No personal or machine-identifying details: home-directory paths or usernames, hostnames, hardware serials, local session or transcript IDs.
- No employer, client, or internal project names, and no bank IDs derived from private repositories.
- No real data from anyone's memory store (memories, prompts, transcripts, logs).
- Write incident details generically ("an unrelated project", "the operator's secret manager"). Use `~/`, `<repo>`, and placeholders such as `$OP_ITEM` in docs and runbooks.
- Keep any list of names to avoid in an **untracked** local file (see Task 8), never in the repo.

## Review Focus

Input classes and failure modes the spec implies that are most likely to bite a person using this. Each has a test in the task named in brackets.

1. **A data directory path containing a space** must not break bind mounts or the Postgres-binary moves. [Task 3: `guard_tests` and `flow_test_create_parks_wrong_arch_installation` use `"$tmp/data dir"`; Task 5 `flow_test_recreate_success` too]
2. **`docker stop` failing during `recreate`** must abort before anything is renamed or created. [Task 5: `flow_test_recreate_command_failures`]
3. **`docker rename` failing during `recreate`** must restart the original container and create nothing. [Task 5: `flow_test_recreate_command_failures`]
4. **An invalid env override next to a valid `config.env` value**, and **quoted / uppercase-unit config values**, must resolve sensibly (first valid value wins; `"linux/arm64"` and `2G` accepted). [Task 1: `resolution_tests`]
5. **An API key full of shell metacharacters** (spaces, quotes, `$`, `;`, `&`, `|`, a backtick) must reach Docker intact through the environment and never appear in argv. [Task 2: `flow_test_key_with_shell_metacharacters`]

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `scripts/ensure-hindsight.sh` | modify | Platform/memory resolution, run flags, Postgres-binary guard, drift and crash diagnosis, `recreate`. Stays one POSIX script; new logic is small functions |
| `scripts/test/test_ensure_hindsight.sh` | modify | Data-dir safety net, richer fake `docker`, tests for every new behavior |
| `scripts/container_info.py` | create | Stdlib-only, read-only Docker facts for status output |
| `scripts/test/test_container_info.py` | create | Unit tests for `container_info` with Docker stubbed |
| `scripts/get-status.py` | modify | Print the container lines after the server line |
| `scripts/test/test_get_status.py` | modify | One output test, plus a `sys.path` line so sibling imports are not test-order dependent |
| `commands/memory-status.md` | modify | Tell Claude how to present the new lines |
| `commands/setup.md` | modify | Point at `recreate` instead of `docker rm -f` |
| `README.md`, `CLAUDE.md`, `CHANGELOG.md` | modify | Document the new settings and commands |
| `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | modify | Version `2.1.0` |

New tests are added to `test_ensure_hindsight.sh` as functions, in the "Container platform, resources, and recreate" section that Task 1 creates directly above the file's final run section (the `# ----` line followed by `echo "=== config parser tests ==="`). Keep each new function in that section and add its call in the run section as the task says.

---

### Task 0: Branch, baselines, and docs commit

**Files:**
- Commit: `docs/superpowers/specs/2026-10-08-hindsight-container-platform-design.md`, `docs/superpowers/plans/2026-10-08-hindsight-container-platform.md` (this file)

**Interfaces:**
- Produces: branch `feat/container-platform-pinning` based on `main`, with the baseline numbers recorded for later comparison.

- [ ] **Step 1: Branch from `main`**

Run from the repo root (`<repo>`):

```bash
git status --short
git switch -c feat/container-platform-pinning main
```

Expected: `git status --short` shows only the two untracked docs (the spec and this plan); the switch succeeds. If you were handed this plan inside a dedicated worktree that is already on a `feat/container-platform-pinning` branch based on `main` (the usual handoff), skip the `git switch` and just confirm `git branch --show-current` and that `git merge-base HEAD main` equals `git rev-parse main`. If `main` and the branch you started on diverge in `CHANGELOG.md` or `.claude-plugin/plugin.json` (an unmerged patch release), note it: Task 7 inserts `## [2.1.0]` above the newest changelog heading and sets the version to `2.1.0`, so a later rebase may need a trivial conflict resolution there.

- [ ] **Step 2: Record baselines**

```bash
sh scripts/test/test_ensure_hindsight.sh 2>&1 | tail -1
sh scripts/test/test_hs_python.sh 2>&1 | tail -1
./scripts/.venv/bin/pytest scripts/test -q -p no:cacheprovider 2>&1 | tail -1
```

Expected: `=== summary: 29 passed, 0 failed ===`; `hs-python: 23 passed, 0 failed`; pytest all green with some skips. **Write down the pytest numbers** (the plan was written on a branch that reported `97 passed, 20 skipped`; `main` may report fewer). If `scripts/.venv` is missing, run `./scripts/install-dependencies.sh` first.

- [ ] **Step 3: Public-repo scan of the two docs, then commit them**

Run the scan from Task 8, Step 1 against the two files (`git diff --no-index /dev/null <file>` works for untracked files; or just `grep` them with the same patterns). Expected: no hits. Then:

```bash
git add docs/superpowers/specs/2026-10-08-hindsight-container-platform-design.md docs/superpowers/plans/2026-10-08-hindsight-container-platform.md
git commit -m "docs: add container platform design spec and implementation plan"
```

Append the repo's usual trailer lines to commit messages (see `git log -3 --format=%B`); add nothing else identifying.

---

### Task 1: Test harness upgrade, config keys, and platform/memory resolution

**Files:**
- Modify: `scripts/test/test_ensure_hindsight.sh` (safety net, shim, new section, call)
- Modify: `scripts/ensure-hindsight.sh` (constants, `debug_enabled`/`debug`, `config_get` allowlist, three new functions)

**Interfaces:**
- Produces (script): `DATA_DIR`, `DEFAULT_MEMORY_LIMIT`, `WORKER_ID`, `EFF_PLATFORM`, `EFF_MEMORY_LIMIT`; `debug_enabled`; `valid_memory_limit VALUE`; `resolve_memory_limit` (sets `EFF_MEMORY_LIMIT`); `resolve_platform` (sets `EFF_PLATFORM`).
- Produces (tests): fake `docker` honoring `FAKE_DAEMON_ARCH`, `FAKE_IMAGE_ARCH`, `FAKE_STATE`, `FAKE_PREV_EXISTS`, `FAKE_RUN_KEY_FILE`, `FAKE_STOP_FAIL`, `FAKE_RENAME_FAIL`; `HINDSIGHT_DATA_DIR` pointed at a throwaway directory for the whole run; `platform_for`, `limit_for`, `resolution_tests`.

- [ ] **Step 1: Add the data-directory safety net to the test file**

Insert directly after the line `SCRIPT="$TEST_DIR/../ensure-hindsight.sh"`:

```sh
# Never let a test touch a real data directory: point the script at a throwaway
# one for the whole run (the script reads HINDSIGHT_DATA_DIR).
TEST_DATA_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/eh_data.XXXXXX")
HINDSIGHT_DATA_DIR="$TEST_DATA_ROOT/hindsight-data"
export HINDSIGHT_DATA_DIR
trap 'rm -rf "$TEST_DATA_ROOT"' EXIT
```

This makes sure no test can ever touch a real data directory once the script learns to move files in it.

- [ ] **Step 2: Replace the fake `docker` in `build_shims`**

In `test_ensure_hindsight.sh`, replace the block from `cat >"$dir/docker" <<'EOF'` through its closing `EOF` line with:

```sh
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
```

Also replace the comment block above `build_shims()` (the lines that list the `FAKE_*` variables) with:

```sh
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
```

- [ ] **Step 3: Confirm nothing regressed**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | tail -1`
Expected: `=== summary: 29 passed, 0 failed ===`

- [ ] **Step 4: Write the failing resolution tests**

Directly above the file's final run section (the `# ----` line followed by `echo "=== config parser tests ==="`), add this section header and the three functions:

```sh
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
```

In the run section, add these lines immediately before `echo "=== flow tests ==="`:

```sh
echo "=== platform and memory-limit resolution ==="
resolution_tests

```

- [ ] **Step 5: Run to verify the new tests fail**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E 'command not found|^FAIL|summary' | tail -8`

Expected: lines like `resolve_platform: command not found` and `FAIL: platform: aarch64 daemon -> linux/arm64 (expected [linux/arm64], got [])`, ending in `=== summary: 30 passed, 20 failed ===` (29 existing, plus `platform: unknown daemon arch -> empty`, which holds trivially). The 20 failures are 10 `platform`, 9 `memory`, 1 `config`.

- [ ] **Step 6: Implement: constants and the `debug` refactor**

In `scripts/ensure-hindsight.sh`:

(a) After the `CONFIG_FILE="${HINDSIGHT_CONFIG_FILE:-...}"` line add:

```sh
# Host directory bind-mounted as the embedded Postgres (pg0) data directory.
DATA_DIR="${HINDSIGHT_DATA_DIR:-$HOME/hindsight-data}"
```

(b) Replace the block from `# Built-in defaults for LLM settings.` through the end of the `debug()` function (its closing `}`) with:

```sh
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
```

(c) In `config_get`, change the comment line `# execution). Only the four HINDSIGHT_API_LLM_* keys are meaningful to callers.` to `# execution). Only the keys listed below are meaningful to callers.`, and replace

```sh
	# Only the four HINDSIGHT_API_LLM_* keys are recognized; ignore anything else.
	case "$cg_want" in
	HINDSIGHT_API_LLM_PROVIDER | HINDSIGHT_API_LLM_MODEL | HINDSIGHT_API_LLM_API_KEY | HINDSIGHT_API_LLM_BASE_URL) ;;
```

with

```sh
	# Only these keys are recognized; ignore anything else.
	case "$cg_want" in
	HINDSIGHT_API_LLM_PROVIDER | HINDSIGHT_API_LLM_MODEL | HINDSIGHT_API_LLM_API_KEY | HINDSIGHT_API_LLM_BASE_URL | HINDSIGHT_PLATFORM | HINDSIGHT_MEMORY_LIMIT) ;;
```

- [ ] **Step 7: Implement: the resolution functions**

Directly after the `resolve_config()` function add:

```sh
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
```

and, after those two, add:

```sh
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
```

(`platform_arch` arrives in Task 3, where its tests live.)

- [ ] **Step 8: Run to verify everything passes**

Run: `sh -n scripts/ensure-hindsight.sh && sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|summary'`
Expected: only `=== summary: 50 passed, 0 failed ===` (29 existing + 21 new).

- [ ] **Step 9: Commit**

```bash
git add scripts/ensure-hindsight.sh scripts/test/test_ensure_hindsight.sh
git commit -m "feat(ensure-hindsight): resolve platform and memory limit; harden the test harness"
```

---

### Task 2: Run flags, platform pinning, and the API key by name

**Files:**
- Modify: `scripts/ensure-hindsight.sh` (`create_container`)
- Modify: `scripts/test/test_ensure_hindsight.sh` (four flow tests and their calls)

**Interfaces:**
- Consumes: `resolve_platform`, `resolve_memory_limit`, `DATA_DIR`, `WORKER_ID` (Task 1).
- Produces: `create_container` that passes every flag in Global Constraints and forwards the key through the environment.

- [ ] **Step 1: Write the failing flow tests**

Add these functions to the "Container platform, resources, and recreate" section:

```sh
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
```

In the run section, after `flow_test_no_docker`, add:

```sh
flow_test_create_flags
flow_test_memory_limit_override
flow_test_unknown_arch_omits_platform
flow_test_key_with_shell_metacharacters
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL' | head -20`
Expected: failures for the missing flags (`--platform linux/arm64`, `--restart unless-stopped`, `--stop-timeout 40`, `--memory 4g`, health and log options, the worker ID), `the API key value must NOT appear in docker's argv`, `the API key must be passed by name`, and the two `flow(i)` memory assertions. All earlier assertions still pass.

- [ ] **Step 3: Implement `create_container`**

Replace the whole `create_container()` function with:

```sh
create_container() {
	debug "Creating Hindsight container"
	mkdir -p "$DATA_DIR"

	resolve_platform
	resolve_memory_limit

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
```

- [ ] **Step 4: Run to verify they pass**

Run: `sh -n scripts/ensure-hindsight.sh && sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|summary'`
Expected: only `=== summary: ... 0 failed ===`.

- [ ] **Step 5: Check the real flag set against real Docker (read-only, throwaway)**

Unit tests use a fake `docker`, so confirm real Docker accepts the flags. This starts a throwaway container on alternate ports with a scratch data directory and the LLM disabled; it never touches the live `hindsight` container or `~/hindsight-data`. Because `create_container` now passes `--platform`, Docker may fetch the arm64 variant and retag the local `...:0.8.6` to it (a harmless, intended change: the live container keeps running its own image ID):

```bash
SCRATCH=$(mktemp -d)
HINDSIGHT_CONFIG_FILE=/dev/null sh -c '
ENSURE_HINDSIGHT_LIB=1 . ./scripts/ensure-hindsight.sh
CONTAINER_NAME=hs-flagcheck; DATA_DIR='"$SCRATCH"'
HINDSIGHT_MEMORY_LIMIT=1400m HINDSIGHT_API_LLM_PROVIDER=none
export HINDSIGHT_MEMORY_LIMIT HINDSIGHT_API_LLM_PROVIDER
docker() { for x in "$@"; do case "$x" in 8888:8888) x=18888:8888;; 9999:9999) x=19999:9999;; esac; set -- "$@" "$x"; shift; done; command docker "$@"; }
resolve_config; create_container; echo "rc=$?"
for i in $(seq 1 30); do sleep 4; curl -sf -m 3 http://localhost:18888/health >/dev/null && break; done
command docker inspect hs-flagcheck --format "health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} stoptimeout={{.Config.StopTimeout}} shm={{.HostConfig.ShmSize}} mem={{.HostConfig.Memory}}"
command docker stop hs-flagcheck >/dev/null; command docker inspect -f "exit={{.State.ExitCode}}" hs-flagcheck'
docker rm -f hs-flagcheck >/dev/null 2>&1; rm -rf "$SCRATCH"
```

Expected: `rc=0`, then `health=healthy restart=unless-stopped stoptimeout=40 shm=2147483648 mem=1468006400`, then `exit=0`. (Skip this step if Docker is unavailable; it is a confidence check, not part of the suite. This host's default log driver is `local`; `--log-opt max-size`/`max-file` are valid for it and for `json-file`.)

- [ ] **Step 6: Commit**

```bash
git add scripts/ensure-hindsight.sh scripts/test/test_ensure_hindsight.sh
git commit -m "feat(ensure-hindsight): pin --platform, add documented run flags, pass the key by name"
```

---

### Task 3: Embedded Postgres binary guard

**Files:**
- Modify: `scripts/ensure-hindsight.sh` (`GUARD_*` variables, `platform_arch`, `elf_arch`, `find_pg_binary`, `guard_installation`, `undo_guard`, and a guard call in `create_container`)
- Modify: `scripts/test/test_ensure_hindsight.sh` (helpers, `guard_tests`, one flow test)

**Interfaces:**
- Consumes: `create_container`, `DATA_DIR`, `debug` (Tasks 1-2).
- Produces: `platform_arch PLATFORM` (echoes `arm64`/`amd64`/nothing); `elf_arch FILE` (echoes `arm64`/`amd64`/`unknown`); `find_pg_binary DIR`; `guard_installation ARCH` (returns 0/1, records the swap in `GUARD_SWAPPED`/`GUARD_HAVE`/`GUARD_WANT`); `undo_guard`. Tasks 4 and 5 use `platform_arch`, and Task 5 uses `undo_guard`.

- [ ] **Step 1: Write the failing tests**

Add to the test section:

```sh
# mkelf FILE ARCH
# Writes a 20-byte ELF header whose e_machine says ARCH (amd64|arm64); any other
# ARCH writes a non-ELF file. Enough for elf_arch to classify.
mkelf() {
	mkdir -p "$(dirname "$1")"
	case "$2" in
	amd64) printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000\076\000' >"$1" ;;
	arm64) printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000\267\000' >"$1" ;;
	*) printf 'not an elf file' >"$1" ;;
	esac
}

# guard_fresh: reset DATA_DIR and the recorded swap between guard scenarios.
guard_fresh() {
	rm -rf "$DATA_DIR"
	mkdir -p "$DATA_DIR"
	GUARD_SWAPPED=0
	GUARD_HAVE=""
	GUARD_WANT=""
}

# present PATH -> "present" or "absent"
present() {
	if [ -e "$1" ]; then echo present; else echo absent; fi
}

guard_tests() {
	# shellcheck disable=SC1090
	ENSURE_HINDSIGHT_LIB=1 . "$SCRIPT"

	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_guard.XXXXXX")
	# A space in the path must not break any of the moves.
	DATA_DIR="$tmp/data dir"
	pg="18.1.0/bin/postgres"

	mkelf "$tmp/x86" amd64
	mkelf "$tmp/arm" arm64
	mkelf "$tmp/junk" other
	assert_eq "elf_arch: x86-64 header" "amd64" "$(elf_arch "$tmp/x86")"
	assert_eq "elf_arch: aarch64 header" "arm64" "$(elf_arch "$tmp/arm")"
	assert_eq "elf_arch: non-ELF file" "unknown" "$(elf_arch "$tmp/junk")"
	assert_eq "elf_arch: missing file" "unknown" "$(elf_arch "$tmp/nope")"
	assert_eq "platform_arch: linux/arm64" "arm64" "$(platform_arch linux/arm64)"
	assert_eq "platform_arch: linux/amd64" "amd64" "$(platform_arch linux/amd64)"
	assert_eq "platform_arch: empty" "" "$(platform_arch "")"

	# 1. Mismatch with no saved copy: park it, leave installation for pg0 to refill.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" amd64
	guard_installation arm64
	rc=$?
	assert_eq "guard(1): mismatch returns 0" "0" "$rc"
	assert_eq "guard(1): installation is moved aside" "absent" "$(present "$DATA_DIR/installation")"
	assert_eq "guard(1): the parked copy is the amd64 one" "amd64" "$(elf_arch "$DATA_DIR/installation.amd64/$pg")"
	assert_eq "guard(1): the swap is recorded" "1" "$GUARD_SWAPPED"
	# pg0 downloads fresh binaries into installation; undo must keep them.
	mkelf "$DATA_DIR/installation/$pg" arm64
	undo_guard
	rc=$?
	assert_eq "guard(1): undo returns 0" "0" "$rc"
	assert_eq "guard(1): undo restores the original amd64 installation" "amd64" "$(elf_arch "$DATA_DIR/installation/$pg")"
	assert_eq "guard(1): undo saves the downloaded arm64 copy" "arm64" "$(elf_arch "$DATA_DIR/installation.arm64/$pg")"
	assert_eq "guard(1): undo clears the recorded swap" "0" "$GUARD_SWAPPED"

	# 2. Mismatch with a saved matching copy: swap it in; undo swaps it back.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" amd64
	mkelf "$DATA_DIR/installation.arm64/$pg" arm64
	guard_installation arm64
	rc=$?
	assert_eq "guard(2): returns 0" "0" "$rc"
	assert_eq "guard(2): the saved arm64 copy is now installation" "arm64" "$(elf_arch "$DATA_DIR/installation/$pg")"
	assert_eq "guard(2): the amd64 copy is parked" "amd64" "$(elf_arch "$DATA_DIR/installation.amd64/$pg")"
	assert_eq "guard(2): the saved copy slot is consumed" "absent" "$(present "$DATA_DIR/installation.arm64")"
	undo_guard
	assert_eq "guard(2): undo puts amd64 back" "amd64" "$(elf_arch "$DATA_DIR/installation/$pg")"
	assert_eq "guard(2): undo puts arm64 back in its slot" "arm64" "$(elf_arch "$DATA_DIR/installation.arm64/$pg")"
	assert_eq "guard(2): undo leaves no amd64 slot" "absent" "$(present "$DATA_DIR/installation.amd64")"

	# 3. Already the right architecture: nothing moves.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" arm64
	guard_installation arm64
	assert_eq "guard(3): matching installation is untouched" "installation" "$(ls "$DATA_DIR")"
	assert_eq "guard(3): no swap recorded" "0" "$GUARD_SWAPPED"

	# 4. Unidentifiable binary: never touched.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" other
	guard_installation arm64
	assert_eq "guard(4): an unidentifiable binary is untouched" "installation" "$(ls "$DATA_DIR")"

	# 5. Nothing installed yet: nothing to do.
	guard_fresh
	guard_installation arm64
	rc=$?
	assert_eq "guard(5): empty data dir returns 0" "0" "$rc"
	assert_eq "guard(5): empty data dir stays empty" "" "$(ls "$DATA_DIR")"

	# 6. The parking slot is taken: refuse, change nothing.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" amd64
	mkelf "$DATA_DIR/installation.amd64/$pg" amd64
	guard_installation arm64 2>/dev/null
	rc=$?
	assert_eq "guard(6): a taken parking slot returns 1" "1" "$rc"
	assert_eq "guard(6): installation is left in place" "amd64" "$(elf_arch "$DATA_DIR/installation/$pg")"
	assert_eq "guard(6): no swap recorded" "0" "$GUARD_SWAPPED"

	# 7. No architecture to compare against: nothing to do.
	guard_fresh
	mkelf "$DATA_DIR/installation/$pg" amd64
	guard_installation ""
	assert_eq "guard(7): an empty target architecture is a no-op" "amd64" "$(elf_arch "$DATA_DIR/installation/$pg")"

	rm -rf "$tmp"
}

flow_test_create_parks_wrong_arch_installation() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_k.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	data="$tmp/data dir"
	mkelf "$data/installation/18.1.0/bin/postgres" amd64

	# A new container on an arm64 daemon must not inherit amd64 Postgres binaries.
	out=$(
		unset HINDSIGHT_PLATFORM
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$tmp/started.marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=0 \
			FAKE_DAEMON_ARCH=aarch64 \
			HINDSIGHT_DATA_DIR="$data" \
			HINDSIGHT_API_LLM_API_KEY="test-key" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "flow(k): create exits 0" "0" "$rc"
	assert_eq "flow(k): the amd64 Postgres binaries were parked" "amd64" \
		"$(elf_arch "$data/installation.amd64/18.1.0/bin/postgres")"
	if log_has "-v $data:/home/hindsight/.pg0" "$log"; then
		pass "flow(k): the data dir is the one bind-mounted"
	else
		fail "flow(k): expected the data dir bind mount on docker run"
	fi

	rm -rf "$tmp"
}
```

In the run section, add before `echo "=== flow tests ==="`:

```sh
echo "=== installation guard ==="
guard_tests

```

and after `flow_test_unknown_arch_omits_platform` add:

```sh
flow_test_create_parks_wrong_arch_installation
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E 'not found|^FAIL' | head`
Expected: `elf_arch: command not found`, `guard_installation: command not found`, and `FAIL` lines for every `elf_arch`, `platform_arch`, `guard(N)` and `flow(k)` assertion.

- [ ] **Step 3: Implement**

(a) After the `EFF_MEMORY_LIMIT=""` line in the header add a blank line and then:

```sh
# Recorded by guard_installation so a failed recreate can undo the swap.
GUARD_SWAPPED=0
GUARD_HAVE=""
GUARD_WANT=""
```

(b) Directly above the comment block of `resolve_platform` add:

```sh
# platform_arch PLATFORM
# Echoes the image architecture name (arm64|amd64) for a Docker platform string,
# or nothing for anything else.
platform_arch() {
	case "$1" in
	linux/arm64) echo arm64 ;;
	linux/amd64) echo amd64 ;;
	esac
}
```

(c) Directly above `create_container()` add:

```sh
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
```

(d) In `create_container`, replace

```sh
	resolve_platform
	resolve_memory_limit

```

with

```sh
	resolve_platform
	resolve_memory_limit
	if ! guard_installation "$(platform_arch "$EFF_PLATFORM")"; then
		return 1
	fi

```

- [ ] **Step 4: Run to verify they pass**

Run: `sh -n scripts/ensure-hindsight.sh && sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|summary'`
Expected: only `=== summary: ... 0 failed ===`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ensure-hindsight.sh scripts/test/test_ensure_hindsight.sh
git commit -m "feat(ensure-hindsight): park wrong-architecture embedded Postgres binaries"
```

---

### Task 4: Exec-failure diagnosis and drift reporting

**Files:**
- Modify: `scripts/ensure-hindsight.sh` (`container_image_arch`, `container_exec_failure`, `report_platform_drift`, `create_or_recreate`, `main`)
- Modify: `scripts/test/test_ensure_hindsight.sh` (helper, two flow tests)

**Interfaces:**
- Consumes: `platform_arch`, `resolve_platform` (Tasks 1, 3), `debug_enabled` (Task 1).
- Produces: `container_image_arch NAME` (echoes `arm64`/`amd64`/nothing); `container_exec_failure ID` (echoes `exit code 132|126|127` or `restarting` or nothing); `report_platform_drift` (debug-only, read-only). Task 5 uses `container_image_arch`.

- [ ] **Step 1: Write the failing tests**

Add to the test section:

```sh
# log_has_mutation LOGFILE
# True when docker was asked to change anything (as opposed to inspect/list).
log_has_mutation() {
	grep -q -E '^(run|rm|start|stop|rename|update) ' "$1" 2>/dev/null
}

flow_test_exec_failure_is_diagnosed_not_restarted() {
	for state in "exited 132 false" "exited 126 false" "exited 127 false" "restarting 1 true"; do
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_l.XXXXXX")
		build_shims "$tmp"
		log="$tmp/docker.log"
		: >"$log"

		out=$(
			PATH="$tmp:$PATH" \
				FAKE_LOG="$log" \
				FAKE_HEALTH_OK=0 \
				FAKE_HINDSIGHT_CC_EXISTS=0 \
				FAKE_HINDSIGHT_EXISTS=1 \
				FAKE_STATE="$state" \
				HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
				sh "$SCRIPT" 2>&1
			echo "exit=$?"
		)
		rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

		assert_eq "flow(l): '$state' exits 1" "1" "$rc"
		if log_has "start hsid456" "$log"; then
			fail "flow(l): '$state' must NOT be started again"
		else
			pass "flow(l): '$state' is not started again"
		fi
		case "$out" in
		*"not runnable"*"recreate"*) pass "flow(l): '$state' prints a diagnosis naming recreate" ;;
		*) fail "flow(l): '$state' expected a 'not runnable ... recreate' diagnosis, got: $out" ;;
		esac

		rm -rf "$tmp"
	done

	# Any other exit code (a normal stop, a kill) is still just started.
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_l2.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	out=$(
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_MARKER="$tmp/started.marker" \
			FAKE_HEALTH_OK=0 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=1 \
			FAKE_STATE="exited 137 false" \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT"
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')
	assert_eq "flow(l): exit code 137 still starts the container" "0" "$rc"
	if log_has "start hsid456" "$log"; then
		pass "flow(l): exit code 137 is started"
	else
		fail "flow(l): expected 'docker start hsid456' for exit code 137"
	fi
	rm -rf "$tmp"
}

flow_test_drift_is_reported_only_in_debug() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_flow_m.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"

	# Server healthy, container image is amd64 on an arm64 daemon.
	: >"$log"
	out=$(
		unset HINDSIGHT_PLATFORM
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_HEALTH_OK=1 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=1 \
			FAKE_DAEMON_ARCH=aarch64 \
			FAKE_IMAGE_ARCH=amd64 \
			HINDSIGHT_DEBUG=1 \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT" 2>&1
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')
	assert_eq "flow(m): healthy server with drift exits 0" "0" "$rc"
	case "$out" in
	*"Platform drift"*"amd64"*"arm64"*) pass "flow(m): debug output reports the drift" ;;
	*) fail "flow(m): expected a 'Platform drift' debug line, got: $out" ;;
	esac
	if log_has_mutation "$log"; then
		fail "flow(m): reporting drift must not change any container"
	else
		pass "flow(m): reporting drift changes nothing"
	fi

	# Without debug the healthy path must not even inspect the container.
	: >"$log"
	out=$(
		unset HINDSIGHT_PLATFORM HINDSIGHT_DEBUG
		PATH="$tmp:$PATH" \
			FAKE_LOG="$log" \
			FAKE_HEALTH_OK=1 \
			FAKE_HINDSIGHT_CC_EXISTS=0 \
			FAKE_HINDSIGHT_EXISTS=1 \
			FAKE_DAEMON_ARCH=aarch64 \
			FAKE_IMAGE_ARCH=amd64 \
			HINDSIGHT_CONFIG_FILE="$tmp/none.env" \
			sh "$SCRIPT" 2>&1
		echo "exit=$?"
	)
	case "$out" in
	*"Platform drift"*) fail "flow(m): drift must not be reported without HINDSIGHT_DEBUG" ;;
	*) pass "flow(m): no drift output without HINDSIGHT_DEBUG" ;;
	esac
	if log_has "image inspect" "$log"; then
		fail "flow(m): the healthy path must not inspect images without HINDSIGHT_DEBUG"
	else
		pass "flow(m): the healthy path stays inspection-free without HINDSIGHT_DEBUG"
	fi

	rm -rf "$tmp"
}
```

In the run section, after `flow_test_create_parks_wrong_arch_installation`, add:

```sh
flow_test_exec_failure_is_diagnosed_not_restarted
flow_test_drift_is_reported_only_in_debug
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL' | head`
Expected: `flow(l)` failures (the container is started instead of diagnosed; no `not runnable ... recreate` message) and `flow(m)` failures (no `Platform drift` debug line).

- [ ] **Step 3: Implement**

(a) Directly after the `create_container()` function add:

```sh
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
```

(b) Replace the whole `create_or_recreate` function (including its comment block) with:

```sh
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
```

(c) In `main`, replace

```sh
	if server_healthy; then
		debug "Server already running"
		exit 0
	fi
```

with

```sh
	if server_healthy; then
		debug "Server already running"
		report_platform_drift
		exit 0
	fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `sh -n scripts/ensure-hindsight.sh && sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|summary'`
Expected: only `=== summary: ... 0 failed ===`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ensure-hindsight.sh scripts/test/test_ensure_hindsight.sh
git commit -m "feat(ensure-hindsight): diagnose exec failures and report platform drift"
```

---

### Task 5: The `recreate` subcommand

**Files:**
- Modify: `scripts/ensure-hindsight.sh` (header usage comment, `verify_container_arch`, `wait_for_ready`, `recreate_container`, `docker_ready`, `main`)
- Modify: `scripts/test/test_ensure_hindsight.sh` (helpers, five test functions)

**Interfaces:**
- Consumes: `create_container`, `guard`/`undo_guard` (Task 3), `container_image_arch` (Task 4), `resolve_config`, `require_api_key`, `resolve_platform`.
- Produces: `wait_for_ready [SECONDS]` (default 24, so the hook is unchanged); `verify_container_arch`; `recreate_container` (returns 0/1); `docker_ready`; `main` dispatching `recreate` and rejecting other arguments with exit 2. `HINDSIGHT_RECREATE_WAIT_SECONDS` (default 180) bounds the post-create wait.

- [ ] **Step 1: Write the failing tests**

Add to the test section:

```sh
# log_before FIRST SECOND LOGFILE
# True when FIRST's first match in LOGFILE comes before SECOND's first match.
log_before() {
	lb_a=$(grep -n -- "$1" "$3" | head -1 | cut -d: -f1)
	lb_b=$(grep -n -- "$2" "$3" | head -1 | cut -d: -f1)
	[ -n "$lb_a" ] && [ -n "$lb_b" ] && [ "$lb_a" -lt "$lb_b" ]
}

# recreate_run TMP
# Runs `ensure-hindsight.sh recreate` against the fake shims in TMP, printing the
# combined output and then an `exit=N` line. Callers export FAKE_* / HINDSIGHT_*
# in a surrounding subshell.
recreate_run() {
	PATH="$1:$PATH" \
		FAKE_LOG="$1/docker.log" \
		HINDSIGHT_CONFIG_FILE="$1/none.env" \
		HINDSIGHT_RECREATE_WAIT_SECONDS=1 \
		sh "$SCRIPT" recreate 2>&1
	echo "exit=$?"
}

flow_test_recreate_success() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_rec_a.XXXXXX")
	build_shims "$tmp"
	log="$tmp/docker.log"
	: >"$log"
	data="$tmp/data dir"
	mkelf "$data/installation/18.1.0/bin/postgres" amd64
	mkelf "$data/installation.arm64/18.1.0/bin/postgres" arm64

	out=$(
		unset HINDSIGHT_PLATFORM HINDSIGHT_MEMORY_LIMIT
		FAKE_HINDSIGHT_EXISTS=1
		FAKE_DAEMON_ARCH=aarch64
		FAKE_IMAGE_ARCH=arm64
		FAKE_MARKER="$tmp/started.marker"
		HINDSIGHT_DATA_DIR="$data"
		HINDSIGHT_API_LLM_API_KEY="test-key"
		export FAKE_HINDSIGHT_EXISTS FAKE_DAEMON_ARCH FAKE_IMAGE_ARCH FAKE_MARKER HINDSIGHT_DATA_DIR HINDSIGHT_API_LLM_API_KEY
		recreate_run "$tmp"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

	assert_eq "recreate(a): exits 0" "0" "$rc"
	if log_before "stop -t 60 hindsight" "rename hindsight hindsight-prev" "$log" &&
		log_before "rename hindsight hindsight-prev" "update --restart=no hindsight-prev" "$log" &&
		log_before "update --restart=no hindsight-prev" "run -d --name hindsight " "$log"; then
		pass "recreate(a): stop, rename, disable restart on the old one, then create"
	else
		fail "recreate(a): wrong docker call order: $(tr '\n' '|' <"$log")"
	fi
	if grep -q -E '^rm ' "$log"; then
		fail "recreate(a): the previous container must be kept, not removed"
	else
		pass "recreate(a): the previous container is kept for rollback"
	fi
	assert_eq "recreate(a): the saved arm64 binaries were swapped in" "arm64" \
		"$(elf_arch "$data/installation/18.1.0/bin/postgres")"
	assert_eq "recreate(a): the amd64 binaries were parked" "amd64" \
		"$(elf_arch "$data/installation.amd64/18.1.0/bin/postgres")"
	case "$out" in
	*"kept, stopped, as 'hindsight-prev'"*) pass "recreate(a): tells the operator where the rollback copy is" ;;
	*) fail "recreate(a): expected the rollback copy to be named, got: $out" ;;
	esac

	rm -rf "$tmp"
}

flow_test_recreate_refusals() {
	# (b) a rollback copy already exists, (c) there is nothing to recreate,
	# (d) there is no API key: each must refuse BEFORE changing anything.
	for scenario in prev-exists no-container no-key; do
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_rec_b.XXXXXX")
		build_shims "$tmp"
		log="$tmp/docker.log"
		: >"$log"

		out=$(
			unset HINDSIGHT_PLATFORM HINDSIGHT_API_LLM_API_KEY HINDSIGHT_API_LLM_BASE_URL
			FAKE_DAEMON_ARCH=aarch64
			FAKE_HINDSIGHT_EXISTS=1
			HINDSIGHT_API_LLM_API_KEY="test-key"
			# (if, not case: a case pattern's `)` inside $( ) breaks bash 3.2 as /bin/sh)
			if [ "$scenario" = prev-exists ]; then FAKE_PREV_EXISTS=1; fi
			if [ "$scenario" = no-container ]; then FAKE_HINDSIGHT_EXISTS=0; fi
			if [ "$scenario" = no-key ]; then unset HINDSIGHT_API_LLM_API_KEY; fi
			export FAKE_DAEMON_ARCH FAKE_HINDSIGHT_EXISTS FAKE_PREV_EXISTS
			[ -n "${HINDSIGHT_API_LLM_API_KEY:-}" ] && export HINDSIGHT_API_LLM_API_KEY
			recreate_run "$tmp"
		)
		rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

		assert_eq "recreate(b): $scenario exits 1" "1" "$rc"
		if log_has_mutation "$log"; then
			fail "recreate(b): $scenario must not change any container: $(tr '\n' '|' <"$log")"
		else
			pass "recreate(b): $scenario changes nothing"
		fi

		rm -rf "$tmp"
	done
}

flow_test_recreate_rolls_back() {
	# (e) the new container never becomes healthy, (f) it comes up as the wrong
	# architecture. Both must restore the original container and Postgres binaries.
	for scenario in unhealthy wrong-arch; do
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_rec_c.XXXXXX")
		build_shims "$tmp"
		log="$tmp/docker.log"
		: >"$log"
		data="$tmp/data"
		mkelf "$data/installation/18.1.0/bin/postgres" amd64
		mkelf "$data/installation.arm64/18.1.0/bin/postgres" arm64

		out=$(
			unset HINDSIGHT_PLATFORM
			FAKE_HINDSIGHT_EXISTS=1
			FAKE_DAEMON_ARCH=aarch64
			FAKE_IMAGE_ARCH=arm64
			HINDSIGHT_DATA_DIR="$data"
			HINDSIGHT_API_LLM_API_KEY="test-key"
			# "unhealthy" sets no FAKE_MARKER, so the new server never answers.
			if [ "$scenario" = wrong-arch ]; then
				FAKE_MARKER="$tmp/started.marker"
				FAKE_IMAGE_ARCH=amd64
				export FAKE_MARKER
			fi
			export FAKE_HINDSIGHT_EXISTS FAKE_DAEMON_ARCH FAKE_IMAGE_ARCH HINDSIGHT_DATA_DIR HINDSIGHT_API_LLM_API_KEY
			recreate_run "$tmp"
		)
		rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

		assert_eq "recreate(c): $scenario exits 1" "1" "$rc"
		if log_before "run -d --name hindsight " "rename hindsight-prev hindsight" "$log" &&
			log_before "rename hindsight-prev hindsight" "start hindsight" "$log"; then
			pass "recreate(c): $scenario renames the old container back and starts it"
		else
			fail "recreate(c): $scenario did not roll back: $(tr '\n' '|' <"$log")"
		fi
		if grep -q -E '^rm hindsight$' "$log"; then
			pass "recreate(c): $scenario removes the failed new container"
		else
			fail "recreate(c): $scenario expected 'docker rm hindsight'"
		fi
		if log_has "update --restart=unless-stopped hindsight" "$log"; then
			pass "recreate(c): $scenario restores the restart policy"
		else
			fail "recreate(c): $scenario expected the restart policy to be restored"
		fi
		assert_eq "recreate(c): $scenario restores the amd64 binaries" "amd64" \
			"$(elf_arch "$data/installation/18.1.0/bin/postgres")"
		assert_eq "recreate(c): $scenario restores the saved arm64 slot" "arm64" \
			"$(elf_arch "$data/installation.arm64/18.1.0/bin/postgres")"
		case "$out" in
		*"rolling back"*) pass "recreate(c): $scenario says it is rolling back" ;;
		*) fail "recreate(c): $scenario expected a 'rolling back' message, got: $out" ;;
		esac

		rm -rf "$tmp"
	done
}

flow_test_recreate_command_failures() {
	# `docker stop` failing must abort before anything is renamed or created;
	# `docker rename` failing must put the original container back to work.
	for scenario in stop-fails rename-fails; do
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_rec_e.XXXXXX")
		build_shims "$tmp"
		log="$tmp/docker.log"
		: >"$log"

		out=$(
			unset HINDSIGHT_PLATFORM
			FAKE_HINDSIGHT_EXISTS=1
			FAKE_DAEMON_ARCH=aarch64
			HINDSIGHT_API_LLM_API_KEY="test-key"
			if [ "$scenario" = stop-fails ]; then FAKE_STOP_FAIL=1; fi
			if [ "$scenario" = rename-fails ]; then FAKE_RENAME_FAIL=1; fi
			export FAKE_HINDSIGHT_EXISTS FAKE_DAEMON_ARCH HINDSIGHT_API_LLM_API_KEY FAKE_STOP_FAIL FAKE_RENAME_FAIL
			recreate_run "$tmp"
		)
		rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')

		assert_eq "recreate(e): $scenario exits 1" "1" "$rc"
		if grep -q -E '^run ' "$log"; then
			fail "recreate(e): $scenario must not create a container"
		else
			pass "recreate(e): $scenario creates no container"
		fi
		if [ "$scenario" = stop-fails ]; then
			if grep -q -E '^rename ' "$log"; then
				fail "recreate(e): a failed stop must not be followed by a rename"
			else
				pass "recreate(e): a failed stop stops the whole recreate"
			fi
		elif log_has "start hindsight" "$log"; then
			pass "recreate(e): a failed rename restarts the original container"
		else
			fail "recreate(e): a failed rename must restart the original container"
		fi

		rm -rf "$tmp"
	done
}

flow_test_recreate_and_usage_edges() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/eh_rec_d.XXXXXX")

	# No docker at all: an explicit recreate is an error (hooks soft-exit 0).
	chmod +x "$SCRIPT" 2>/dev/null
	out=$(
		PATH="$tmp" HINDSIGHT_CONFIG_FILE="$tmp/none.env" "$SCRIPT" recreate 2>&1
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')
	assert_eq "recreate(d): no docker exits 1" "1" "$rc"
	case "$out" in
	*"Docker is not available"*) pass "recreate(d): no docker says so" ;;
	*) fail "recreate(d): expected 'Docker is not available', got: $out" ;;
	esac

	# An unknown argument is a usage error, not a silent ensure.
	out=$(
		PATH="$tmp" HINDSIGHT_CONFIG_FILE="$tmp/none.env" "$SCRIPT" bogus 2>&1
		echo "exit=$?"
	)
	rc=$(printf '%s\n' "$out" | sed -n 's/^exit=//p')
	assert_eq "usage: an unknown argument exits 2" "2" "$rc"

	rm -rf "$tmp"
}
```

In the run section, after the last flow test call and a blank line, add:

```sh
echo "=== recreate ==="
flow_test_recreate_success
flow_test_recreate_refusals
flow_test_recreate_rolls_back
flow_test_recreate_command_failures
flow_test_recreate_and_usage_edges

```

(keep the existing `echo ""` / summary lines after it).

- [ ] **Step 2: Run to verify they fail**

Run: `sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|exit=' | head`
Expected: failures for every `recreate(...)` and `usage:` assertion (today `recreate` is just an ignored argument, so the script runs the normal ensure path).

- [ ] **Step 3: Implement**

(a) In the header comment (above `CONTAINER_NAME=`), after the paragraph about the legacy migration, add:

```sh
# Usage:
#   ensure-hindsight.sh            ensure the server is up (what the hook runs)
#   ensure-hindsight.sh recreate   replace the container with a fresh one built
#                                  from the current settings, keeping the old
#                                  one as "hindsight-prev" for rollback. Run it
#                                  by hand; hooks never call it.
```

(b) Directly after `report_platform_drift` add:

```sh
# verify_container_arch
# After a recreate: the new container's image must be the architecture that was
# asked for. Passes when no platform was resolved (nothing to compare).
verify_container_arch() {
	vca_want=$(platform_arch "$EFF_PLATFORM")
	[ -n "$vca_want" ] || return 0

	vca_have=$(container_image_arch "$CONTAINER_NAME")
	if [ "$vca_have" = "$vca_want" ]; then
		return 0
	fi

	echo "Error: the new container's image is '${vca_have:-unknown}' but '$vca_want' was requested" >&2
	return 1
}
```

(c) Replace the whole `wait_for_ready` function (including its comment block) with:

```sh
# wait_for_ready [SECONDS]
# Polls health until the server answers or a wall-clock deadline passes (default
# ~24s); warns and returns 1 if it never comes up. The deadline (not an attempt
# count) is what caps the wait below the 30s SessionStart hook timeout, so the
# hook returns its own warning rather than being killed at the boundary. Callers
# outside the hook (recreate) pass a longer deadline. --max-time bounds each
# probe's connect+read, so a server that binds the port but stalls on /health
# (the slow embedded-Postgres migration case) can't drag a single attempt past
# the budget.
wait_for_ready() {
	wfr_seconds="${1:-24}"
	debug "Waiting for server to be ready (up to ~${wfr_seconds} seconds)"
	wfr_deadline=$(($(date +%s) + wfr_seconds))
	while [ "$(date +%s)" -lt "$wfr_deadline" ]; do
		if curl -s --connect-timeout 1 --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
			debug "Server ready"
			return 0
		fi
		sleep 1
	done

	debug "Server did not become ready within the ~${wfr_seconds}s deadline"
	echo "Warning: Hindsight server did not start within ~${wfr_seconds} seconds" >&2
	return 1
}
```

(d) Directly after the `create_or_recreate` function add:

```sh
# recreate_container
# Explicit, operator-run replacement of the shared container (never called from
# a hook). Stops it cleanly, keeps it as "<name>-prev" for rollback, builds a
# new one from the current settings (platform, memory, key, ...), and verifies
# health and architecture. On any failure it rolls back: the new container is
# removed, the Postgres binaries are put back, and the old container is renamed
# back and started. Two containers must never run on the same data directory, so
# the rollback copy is set not to restart on its own.
recreate_container() {
	rc_prev="${CONTAINER_NAME}-prev"

	if ! docker_ready; then
		echo "Error: Docker is not available" >&2
		return 1
	fi

	resolve_config
	if ! require_api_key; then
		return 1
	fi
	resolve_platform

	rc_id=$(docker ps -aq -f "name=^${CONTAINER_NAME}$" 2>/dev/null)
	if [ -z "$rc_id" ]; then
		echo "Error: no '$CONTAINER_NAME' container to recreate (run without arguments to create one)" >&2
		return 1
	fi
	if [ -n "$(docker ps -aq -f "name=^${rc_prev}$" 2>/dev/null)" ]; then
		echo "Error: '$rc_prev' already exists; remove it first (it is the rollback copy from an earlier recreate)" >&2
		return 1
	fi

	echo "Stopping '$CONTAINER_NAME' (up to 60s for a clean Postgres shutdown)..."
	if ! docker stop -t 60 "$CONTAINER_NAME" >/dev/null 2>&1; then
		echo "Error: could not stop '$CONTAINER_NAME'" >&2
		return 1
	fi
	if ! docker rename "$CONTAINER_NAME" "$rc_prev"; then
		echo "Error: could not rename '$CONTAINER_NAME' to '$rc_prev'" >&2
		docker start "$CONTAINER_NAME" >/dev/null 2>&1
		return 1
	fi
	docker update --restart=no "$rc_prev" >/dev/null 2>&1

	if create_container &&
		wait_for_ready "${HINDSIGHT_RECREATE_WAIT_SECONDS:-180}" &&
		verify_container_arch; then
		echo "Recreated '$CONTAINER_NAME' (${EFF_PLATFORM:-docker default platform}). The previous container is kept, stopped, as '$rc_prev' for rollback."
		return 0
	fi

	echo "Recreate failed; rolling back to the previous container..." >&2
	docker stop -t 60 "$CONTAINER_NAME" >/dev/null 2>&1
	docker rm "$CONTAINER_NAME" >/dev/null 2>&1
	undo_guard
	docker rename "$rc_prev" "$CONTAINER_NAME" >/dev/null 2>&1
	docker update --restart=unless-stopped "$CONTAINER_NAME" >/dev/null 2>&1
	docker start "$CONTAINER_NAME" >/dev/null 2>&1
	return 1
}

# docker_ready
# Returns 0 when the docker CLI exists and the daemon answers.
docker_ready() {
	command -v docker >/dev/null 2>&1 || return 1
	docker info >/dev/null 2>&1
}
```

(e) Replace the whole `main` function with:

```sh
main() {
	case "${1:-}" in
	'') ;;
	recreate)
		recreate_container
		exit $?
		;;
	*)
		echo "Usage: ensure-hindsight.sh [recreate]" >&2
		exit 2
		;;
	esac

	debug "Starting"

	# Check Docker is available; soft-exit so SessionStart is never blocked.
	if ! docker_ready; then
		debug "Docker not found in PATH, or the daemon is not running/accessible"
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
```

- [ ] **Step 4: Run to verify everything passes**

Run: `sh -n scripts/ensure-hindsight.sh && sh scripts/test/test_ensure_hindsight.sh 2>&1 | grep -E '^FAIL|summary'`
Expected: only `=== summary: 164 passed, 0 failed ===`.

Also run `sh scripts/test/test_hs_python.sh 2>&1 | tail -1` (expect `23 passed, 0 failed`) and `ENSURE_HINDSIGHT_LIB=1 sh -c '. ./scripts/ensure-hindsight.sh; echo sourced-ok'` (expect `sourced-ok`; sourcing must define functions without running `main`).

- [ ] **Step 5: Sanity-check that the tests have teeth (optional but recommended)**

Temporarily break one behavior at a time and confirm the suite fails, then restore with `git checkout -- scripts/ensure-hindsight.sh` (commit first, or stash, so you do not lose work). Examples: delete the `undo_guard` line in `recreate_container` (rollback tests must fail); delete `--platform` from the `set --` block (flow(h) must fail); make `report_platform_drift` skip the `debug_enabled` check (flow(m) must fail).

- [ ] **Step 6: Commit**

```bash
git add scripts/ensure-hindsight.sh scripts/test/test_ensure_hindsight.sh
git commit -m "feat(ensure-hindsight): add the recreate subcommand with rollback"
```

---

### Task 6: Container status in `/hindsight-cc:memory-status`

**Files:**
- Create: `scripts/container_info.py`
- Create: `scripts/test/test_container_info.py`
- Modify: `scripts/get-status.py`
- Modify: `scripts/test/test_get_status.py`
- Modify: `commands/memory-status.md`

**Interfaces:**
- Produces: `container_info.describe_container(name="hindsight") -> List[str]` (never raises); `container_info.format_lines(ContainerInfo)`; `container_info.collect(name, daemon_arch)`; `ContainerInfo` dataclass. `get-status.py` prints `describe_container()` lines directly after the `Hindsight server:` line.

- [ ] **Step 1: Write the failing tests**

Create `scripts/test/test_container_info.py`:

```python
#!/usr/bin/env python3
"""Unit tests for container_info: pure formatting plus Docker calls stubbed out."""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

sys.path.insert(0, str(Path(__file__).parent.parent))

import container_info  # noqa: E402
from container_info import ContainerInfo  # noqa: E402


def make_info(**overrides: Any) -> ContainerInfo:
    fields: Dict[str, Any] = dict(
        name="hindsight",
        state="running",
        health="healthy",
        restart_count=0,
        image_ref="ghcr.io/vectorize-io/hindsight:0.8.6",
        image_arch="arm64",
        daemon_arch="arm64",
        memory_limit_bytes=4 * 2**30,
        memory_usage="1.2GiB / 4GiB",
    )
    fields.update(overrides)
    return ContainerInfo(**fields)


def stub_docker(monkeypatch, responses):
    """Make container_info._docker answer from {args-tuple: stdout-or-None}."""
    calls = []

    def fake(*args):
        calls.append(args)
        return responses.get(args)

    monkeypatch.setattr(container_info, "_docker", fake)
    return calls


INSPECT = json.dumps(
    [
        {
            "Image": "sha256:abc",
            "RestartCount": 2,
            "State": {"Status": "running", "Running": True, "Health": {"Status": "healthy"}},
            "Config": {"Image": "ghcr.io/vectorize-io/hindsight:0.8.6"},
            "HostConfig": {"Memory": 4294967296},
        }
    ]
)
IMAGE_INSPECT = json.dumps([{"Architecture": "arm64"}])
INFO_ARGS = ("info", "--format", "{{.Architecture}}")


class TestFormatLines:
    def test_native_container_has_no_emulation_warning(self):
        lines = container_info.format_lines(make_info())
        assert lines[0] == "Container: hindsight (running, healthy), restarts: 0"
        assert lines[1] == (
            "Image: ghcr.io/vectorize-io/hindsight:0.8.6 (arm64) on a arm64 Docker daemon"
        )
        assert lines[2] == "Memory: 1.2GiB / 4GiB (limit: 4.0GiB)"
        assert not any(line.startswith("EMULATED") for line in lines)

    def test_architecture_mismatch_adds_emulated_line_naming_the_fix(self):
        lines = container_info.format_lines(make_info(image_arch="amd64"))
        emulated = [line for line in lines if line.startswith("EMULATED")]
        assert len(emulated) == 1
        assert "amd64" in emulated[0] and "arm64" in emulated[0]
        assert "ensure-hindsight.sh recreate" in emulated[0]

    def test_unknown_architecture_is_not_flagged_as_emulated(self):
        lines = container_info.format_lines(make_info(image_arch=None))
        assert "(unknown)" in lines[1]
        assert not any(line.startswith("EMULATED") for line in lines)

    def test_no_limit_and_no_health_and_no_usage(self):
        lines = container_info.format_lines(
            make_info(health=None, memory_limit_bytes=0, memory_usage=None, state="exited")
        )
        assert lines[0] == "Container: hindsight (exited), restarts: 0"
        assert lines[2] == "Memory: n/a (limit: no limit)"


class TestDescribeContainer:
    def test_docker_unavailable(self, monkeypatch):
        stub_docker(monkeypatch, {})
        assert container_info.describe_container() == [
            "Container: unknown (docker is not available)"
        ]

    def test_container_not_found(self, monkeypatch):
        stub_docker(monkeypatch, {INFO_ARGS: "aarch64"})
        assert container_info.describe_container() == ["Container: 'hindsight' not found"]

    def test_full_path_reports_native_container(self, monkeypatch):
        stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "aarch64",
                ("inspect", "hindsight"): INSPECT,
                ("image", "inspect", "sha256:abc"): IMAGE_INSPECT,
                ("stats", "--no-stream", "--format", "{{.MemUsage}}", "hindsight"): "1.2GiB / 4GiB",
            },
        )
        lines = container_info.describe_container()
        assert lines[0] == "Container: hindsight (running, healthy), restarts: 2"
        assert "(arm64) on a arm64 Docker daemon" in lines[1]
        assert lines[2] == "Memory: 1.2GiB / 4GiB (limit: 4.0GiB)"
        assert len(lines) == 3

    def test_full_path_flags_an_emulated_container(self, monkeypatch):
        stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "aarch64",
                ("inspect", "hindsight"): INSPECT,
                ("image", "inspect", "sha256:abc"): json.dumps([{"Architecture": "amd64"}]),
            },
        )
        lines = container_info.describe_container()
        assert lines[-1].startswith("EMULATED")

    def test_stopped_container_skips_the_stats_call(self, monkeypatch):
        stopped = json.dumps(
            [
                {
                    "Image": "sha256:abc",
                    "State": {"Status": "exited", "Running": False},
                    "Config": {"Image": "img"},
                    "HostConfig": {},
                }
            ]
        )
        calls = stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "x86_64",
                ("inspect", "hindsight"): stopped,
                ("image", "inspect", "sha256:abc"): json.dumps([{"Architecture": "amd64"}]),
            },
        )
        lines = container_info.describe_container()
        assert lines[0] == "Container: hindsight (exited), restarts: 0"
        assert not any(call[0] == "stats" for call in calls)

    def test_garbage_inspect_output_is_treated_as_not_found(self, monkeypatch):
        stub_docker(monkeypatch, {INFO_ARGS: "aarch64", ("inspect", "hindsight"): "not json"})
        assert container_info.describe_container() == ["Container: 'hindsight' not found"]


class TestDockerWrapper:
    def test_missing_docker_binary_returns_none(self, monkeypatch):
        def boom(*_a, **_k):
            raise FileNotFoundError("docker")

        monkeypatch.setattr(container_info.subprocess, "run", boom)
        assert container_info._docker("info") is None

    def test_timeout_returns_none(self, monkeypatch):
        def slow(*_a, **_k):
            raise subprocess.TimeoutExpired(cmd="docker", timeout=5)

        monkeypatch.setattr(container_info.subprocess, "run", slow)
        assert container_info._docker("info") is None

    def test_nonzero_exit_returns_none(self, monkeypatch):
        done = subprocess.CompletedProcess(args=[], returncode=1, stdout="x", stderr="")
        monkeypatch.setattr(container_info.subprocess, "run", lambda *_a, **_k: done)
        assert container_info._docker("info") is None

    def test_success_returns_stripped_stdout(self, monkeypatch):
        done = subprocess.CompletedProcess(args=[], returncode=0, stdout=" aarch64\n", stderr="")
        monkeypatch.setattr(container_info.subprocess, "run", lambda *_a, **_k: done)
        assert container_info._docker("info") == "aarch64"
```

In `scripts/test/test_get_status.py`: add `import sys` to the imports, add these two lines after `SCRIPTS_DIR = Path(__file__).parent.parent`:

```python
# get-status.py imports its sibling modules by name, as it does when run directly.
sys.path.insert(0, str(SCRIPTS_DIR))
```

and append this class at the end of the file:

```python
class TestMainOutput:
    def test_main_prints_the_container_lines_after_the_server_line(self, monkeypatch, capsys):
        monkeypatch.setattr(get_status, "get_health_status", lambda: ("Reachable (HTTP 200)", False))
        monkeypatch.setattr(
            get_status,
            "describe_container",
            lambda: ["Container: hindsight (running, healthy), restarts: 0", "EMULATED: example"],
        )

        get_status.main()

        lines = capsys.readouterr().out.splitlines()
        server = lines.index("Hindsight server: Reachable (HTTP 200)")
        assert lines[server + 1] == "Container: hindsight (running, healthy), restarts: 0"
        assert lines[server + 2] == "EMULATED: example"
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/.venv/bin/pytest scripts/test/test_container_info.py scripts/test/test_get_status.py -q -p no:cacheprovider 2>&1 | tail -4`
Expected: collection errors, `ModuleNotFoundError: No module named 'container_info'`.

- [ ] **Step 3: Implement `container_info.py`**

Create `scripts/container_info.py`:

```python
#!/usr/bin/env python3
"""Read-only facts about the Hindsight Docker container, for the status command.

Stdlib only. Every Docker call is time-bounded and soft-fails (returns None), so
a missing docker CLI, a stopped daemon, or a missing container never raises.
"""

import json
import subprocess
from dataclasses import dataclass
from typing import List, Optional

CONTAINER_NAME = "hindsight"
DOCKER_TIMEOUT_SECONDS = 5

# `docker info` {{.Architecture}} values -> image `Architecture` values.
DAEMON_ARCH_TO_IMAGE_ARCH = {
    "aarch64": "arm64",
    "arm64": "arm64",
    "x86_64": "amd64",
    "amd64": "amd64",
}


@dataclass(frozen=True)
class ContainerInfo:
    name: str
    state: str  # "running", "exited", ...
    health: Optional[str]  # "healthy", "unhealthy", "starting", or None
    restart_count: int
    image_ref: str  # the image reference the container was created from
    image_arch: Optional[str]  # "arm64" / "amd64", None if unknown
    daemon_arch: Optional[str]  # same vocabulary, None if unknown
    memory_limit_bytes: int  # 0 means no limit
    memory_usage: Optional[str]  # `docker stats` text, e.g. "1.2GiB / 4GiB"


def _docker(*args: str) -> Optional[str]:
    """Run `docker <args>`; return stripped stdout, or None on any failure."""
    try:
        result = subprocess.run(
            ["docker", *args],
            capture_output=True,
            text=True,
            timeout=DOCKER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _inspect_json(*args: str) -> Optional[dict]:
    """Run a `docker ... inspect` and return the first JSON object, or None."""
    raw = _docker(*args)
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if isinstance(data, list) and data and isinstance(data[0], dict):
        return data[0]
    return None


def collect(name: str, daemon_arch: Optional[str]) -> Optional[ContainerInfo]:
    """Facts about container `name`, or None if it does not exist."""
    container = _inspect_json("inspect", name)
    if container is None:
        return None

    state = container.get("State") or {}
    health = (state.get("Health") or {}).get("Status")
    image = _inspect_json("image", "inspect", container.get("Image") or "")
    image_arch = (image or {}).get("Architecture")
    usage = None
    if state.get("Running"):
        usage = _docker("stats", "--no-stream", "--format", "{{.MemUsage}}", name)

    return ContainerInfo(
        name=name,
        state=state.get("Status") or "unknown",
        health=health,
        restart_count=int(container.get("RestartCount") or 0),
        image_ref=(container.get("Config") or {}).get("Image") or "unknown",
        image_arch=image_arch,
        daemon_arch=daemon_arch,
        memory_limit_bytes=int((container.get("HostConfig") or {}).get("Memory") or 0),
        memory_usage=usage or None,
    )


def _format_bytes(count: int) -> str:
    return f"{count / 2**30:.1f}GiB"


def format_lines(info: ContainerInfo) -> List[str]:
    """Human-readable status lines, with an EMULATED warning on arch mismatch."""
    status = info.state if not info.health else f"{info.state}, {info.health}"
    limit = _format_bytes(info.memory_limit_bytes) if info.memory_limit_bytes else "no limit"
    lines = [
        f"Container: {info.name} ({status}), restarts: {info.restart_count}",
        f"Image: {info.image_ref} ({info.image_arch or 'unknown'}) on a "
        f"{info.daemon_arch or 'unknown'} Docker daemon",
        f"Memory: {info.memory_usage or 'n/a'} (limit: {limit})",
    ]
    if info.image_arch and info.daemon_arch and info.image_arch != info.daemon_arch:
        lines.append(
            f"EMULATED: the container image is {info.image_arch} but the Docker daemon is "
            f"{info.daemon_arch}, so it runs under emulation (slower, more memory). "
            "Fix: run ensure-hindsight.sh recreate"
        )
    return lines


def describe_container(name: str = CONTAINER_NAME) -> List[str]:
    """Status lines for container `name`; never raises."""
    daemon_raw = _docker("info", "--format", "{{.Architecture}}")
    if daemon_raw is None:
        return ["Container: unknown (docker is not available)"]
    info = collect(name, DAEMON_ARCH_TO_IMAGE_ARCH.get(daemon_raw))
    if info is None:
        return [f"Container: '{name}' not found"]
    return format_lines(info)
```

- [ ] **Step 4: Wire it into `get-status.py`**

In `scripts/get-status.py` add the import after `from bank_utils import get_bank_id, get_project_dir`:

```python
from container_info import describe_container
```

and in `main()`, directly after the `print(f"Hindsight server: {health_display}")` line add:

```python
    for line in describe_container():
        print(line)
```

- [ ] **Step 5: Update the command doc**

In `commands/memory-status.md`, replace the paragraph under `## How To Handle Output` with:

```markdown
The output shows the project directory, memory bank ID, server health, and the
Docker container's state, image architecture, health, restart count and memory.
Display this in a clear format.

If a line starts with `EMULATED:`, the container image does not match the Docker
daemon's architecture (it runs under emulation: slower and heavier on memory).
Tell the user, and explain the fix: run
`${CLAUDE_PLUGIN_ROOT}/scripts/ensure-hindsight.sh recreate`. It needs the LLM
API key in the environment or in `~/.config/hindsight-cc/config.env`, keeps the
old container as `hindsight-prev` for rollback, and rolls back automatically if
the new container does not come up healthy. Do not run it without the user's
go-ahead, because it briefly stops the memory server.
```

- [ ] **Step 6: Run to verify they pass, plus lint and types**

```bash
./scripts/.venv/bin/pytest scripts/test -q -p no:cacheprovider 2>&1 | tail -1
./scripts/.venv/bin/ruff check scripts/container_info.py scripts/get-status.py scripts/test/test_container_info.py scripts/test/test_get_status.py
./scripts/.venv/bin/pyright scripts/container_info.py scripts/test/test_container_info.py 2>&1 | tail -1
/usr/bin/python3 -I -c "import sys; sys.path.insert(0,'scripts'); import container_info; print('py3.9 import ok')"
```

Expected: pytest = your Task 0 baseline plus 15 passed (14 in `test_container_info.py`, 1 in `test_get_status.py`), same skips; `All checks passed!`; `0 errors, 0 warnings, 0 informations`; `py3.9 import ok` (if `/usr/bin/python3` is the macOS system Python, this proves the hooks' interpreter can import it). Do **not** run `ruff format` on existing files; the repo does not enforce it.

- [ ] **Step 7: Commit**

```bash
git add scripts/container_info.py scripts/test/test_container_info.py scripts/get-status.py scripts/test/test_get_status.py commands/memory-status.md
git commit -m "feat(status): report container architecture, health and memory"
```

---

### Task 7: Documentation and version

**Files:**
- Modify: `commands/setup.md`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: the behavior implemented in Tasks 1-6 (document exactly that).

- [ ] **Step 1: `commands/setup.md`**

In the `## After` section, replace the bullet beginning `- If a container already exists, they may need to remove it...` (it runs through `...picks up the new config.`) with:

```markdown
- If a container already exists it keeps running with its old settings. To apply
  the new config, run `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-hindsight.sh recreate`
  (with the API key in the environment or `config.env`). It keeps the old
  container as `hindsight-prev` for rollback and rolls back automatically if the
  new one does not come up healthy. Or simply start a fresh session if no
  container exists yet.
```

- [ ] **Step 2: `README.md`**

(a) In the configuration table (the one with `HINDSIGHT_IMAGE` as its last row), append these rows, and add a sentence after the table that these settings are read when the container is created or recreated:

```markdown
| `HINDSIGHT_PLATFORM`        | Docker platform for the container: `linux/arm64` or `linux/amd64` | the Docker daemon's architecture |
| `HINDSIGHT_MEMORY_LIMIT`    | Container memory limit (`4g`, `4096m`, ...) or `none` | `4g`                                    |
| `HINDSIGHT_DATA_DIR`        | Host directory for the embedded Postgres data | `~/hindsight-data`                      |
```

(b) In `## Troubleshooting`, directly after the `### Server Issues` subsection, add (the outer fence below uses four backticks because the content contains a fenced block):

````markdown
### Architecture and Emulation

`/hindsight-cc:memory-status` shows the container's image architecture next to
the Docker daemon's. An `EMULATED:` line means the container runs under
emulation (for example an amd64 image on an Apple Silicon Mac), which is slower
and uses more memory. The plugin always passes `--platform` explicitly when it
creates the container, so this only happens to containers created some other way
or forced with `HINDSIGHT_PLATFORM`.

To replace the container with one built from the current settings:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/ensure-hindsight.sh recreate
```

It needs the LLM API key in the environment or in `config.env` (pass it from
your secret manager for that one command; never write it into a file in this
repo). It stops the server cleanly, keeps the old container stopped as
`hindsight-prev`, creates and verifies the new one, and rolls back automatically
on failure. Remove `hindsight-prev` with `docker rm hindsight-prev` once you are
satisfied. If a recreate is interrupted, `docker ps -a` shows `hindsight-prev`;
`docker rename hindsight-prev hindsight && docker start hindsight` restores it.

If the container exits with code 132 (illegal instruction) or restarts in a loop,
the session start reports it instead of retrying forever. As a fallback you can
run the amd64 image under emulation with
`HINDSIGHT_PLATFORM=linux/amd64 ensure-hindsight.sh recreate`, and please report
the Docker Desktop version and `docker logs hindsight` output.
````

- [ ] **Step 3: `CLAUDE.md`**

(a) In the `### Hindsight Integration` bullet list, add after the `**Data storage**` bullet:

```markdown
- **Container flags**: `ensure-hindsight.sh` always passes `--platform` (from the Docker daemon's architecture, overridable with `HINDSIGHT_PLATFORM`), `--restart unless-stopped`, `--stop-timeout 40`, `--shm-size=2g`, a 4g memory limit (`HINDSIGHT_MEMORY_LIMIT`), a health check, log rotation, and a stable worker ID. The LLM key is passed by name from the environment, never in argv.
- **Recreating**: `ensure-hindsight.sh recreate` (operator-run, never from hooks) stops the container, keeps it as `hindsight-prev`, creates and verifies a new one, and rolls back on failure. The embedded Postgres binaries in the data directory are architecture-specific; a mismatching `installation/` is parked as `installation.<arch>`, never deleted.
```

(b) Change the `scripts/ensure-hindsight.sh` bullet under `## Python Scripts` to:

```markdown
- `scripts/ensure-hindsight.sh` - Health-probe-first check that reuses or starts the Hindsight Docker container; reads `config.env` at container-create time; `recreate` subcommand replaces the container with rollback
```

and add this bullet after the `scripts/get-status.py` line:

```markdown
- `scripts/container_info.py` - Stdlib-only, read-only Docker facts (state, health, image architecture, memory) used by `get-status.py`
```

- [ ] **Step 4: `CHANGELOG.md`**

Insert above the newest `## [` heading:

```markdown
## [2.1.0] - 2026-10-08

### Added

- `HINDSIGHT_PLATFORM` (`linux/arm64` or `linux/amd64`) and
  `HINDSIGHT_MEMORY_LIMIT` settings, read from the environment or `config.env`.
  `HINDSIGHT_DATA_DIR` overrides the host directory for the Postgres data
  (default `~/hindsight-data`).
- `ensure-hindsight.sh recreate`: replaces the container with one built from the
  current settings, keeps the old one as `hindsight-prev`, verifies health and
  architecture, and rolls back automatically on failure.
- `/hindsight-cc:memory-status` now reports the container's state, image
  architecture, health, restart count and memory, and flags emulation.

### Changed

- The container is always created with an explicit `--platform` taken from the
  Docker daemon's architecture. Previously Docker silently reused whichever
  architecture a local image tag pointed at, so an amd64 tag on an arm64 host ran
  under emulation with only a discarded warning.
- The container now also gets `--restart unless-stopped`, `--stop-timeout 40`
  (the image needs up to 30 s to flush Postgres on shutdown), a health check,
  log rotation, a 4g memory limit, and a stable `HINDSIGHT_API_WORKER_ID`.
- The LLM API key is passed to Docker by name from the environment instead of on
  the command line, so it no longer appears in `ps` output.
- Embedded Postgres binaries of the wrong architecture in the data directory are
  moved aside as `installation.<arch>` (never deleted) when a container is created.
- A container that exited with code 132, 126 or 127, or is restarting in a loop,
  is reported with a suggested fix instead of being started again every session.
```

- [ ] **Step 5: Version**

Set `"version": "2.1.0"` in `.claude-plugin/plugin.json` and in the plugin entry inside `.claude-plugin/marketplace.json` (the entry whose `name` is `hindsight-cc`; leave the file's top-level marketplace `version` alone). Then:

```bash
python3 -c "import json; [json.load(open(f)) for f in ('.claude-plugin/plugin.json','.claude-plugin/marketplace.json')]; print('json ok')"
grep -n '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

Expected: `json ok`; `2.1.0` for the plugin in both files.

- [ ] **Step 6: Commit**

```bash
git add commands/setup.md README.md CLAUDE.md CHANGELOG.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs: document platform pinning, recreate, and new settings (2.1.0)"
```

---

### Task 8: Full verification and public-repo hygiene

**Files:** none modified (fix findings in the file that owns them and re-run).

- [ ] **Step 1: Public-repo scan of everything this branch adds**

Keep the names that must never appear in an **untracked** local file, one per line (ask the maintainer for the list; at minimum the employer name, internal project names, and bank IDs derived from private repositories). The local username is added automatically:

```bash
TERMS="$HOME/.hindsight-cc-private-terms"          # untracked, outside the repo
[ -f "$TERMS" ] || echo "Create $TERMS first (one name per line), then re-run this block"
PATTERN='(/Users/|/home/[a-z]|@[a-z0-9-]+\.(com|io|net|org)|sk-[A-Za-z0-9_-]{8,}|op://|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{12,}|session_[A-Za-z0-9]{10,})'
git diff main...HEAD --unified=0 | grep '^+' | grep -v '^+++' > "${TMPDIR:-/tmp}/added-lines.txt"
echo "== generic patterns (expect nothing; /home/hindsight/ is the container path and is fine)"
grep -n -i -E "$PATTERN" "${TMPDIR:-/tmp}/added-lines.txt" | grep -v -e '/home/hindsight/' -e '^[0-9]*:+PATTERN='
echo "== local username and private terms (expect nothing)"
grep -n -i -w -F -e "$USER" -f "$TERMS" "${TMPDIR:-/tmp}/added-lines.txt"
rm -f "${TMPDIR:-/tmp}/added-lines.txt"
```

Expected: no output under either heading. (`-w` matches whole words only, so a short term does not false-positive inside a longer word. This plan's own text contains the pattern; the `PATTERN=` filter drops that line.) Fix any hit in the file that owns it (replace with a placeholder), amend that task's commit or add a fix-up commit, and re-run until clean. Also confirm no tracked file contains a real key: `git grep -n -i -E 'api[_-]?key *= *[A-Za-z0-9]{16,}'` should print nothing.

- [ ] **Step 2: Run every suite**

```bash
sh -n scripts/ensure-hindsight.sh && echo "syntax ok"
sh scripts/test/test_ensure_hindsight.sh 2>&1 | tail -1
sh scripts/test/test_hs_python.sh 2>&1 | tail -1
./scripts/.venv/bin/pytest scripts/test -q -p no:cacheprovider 2>&1 | tail -1
./scripts/.venv/bin/ruff check scripts/container_info.py scripts/get-status.py scripts/test/test_container_info.py scripts/test/test_get_status.py
```

Expected: `syntax ok`; `=== summary: 164 passed, 0 failed ===`; `hs-python: 23 passed, 0 failed`; pytest = Task 0 baseline + 15 passed; `All checks passed!`.

- [ ] **Step 3: Confirm nothing was pushed and the tree is clean**

```bash
git status --short            # expect: nothing
git log --oneline main..HEAD  # expect: the eight commits from Tasks 0-7
git remote -v >/dev/null && git branch -vv | grep feat/container-platform-pinning
```

Expected: no upstream shown for the branch yet. If the maintainer's instructions for this run ask for a PR, push only this branch (plain `git push -u origin feat/container-platform-pinning`, no force) and open the PR against `main` now; otherwise **stop here and report; pushing and opening a PR are the maintainer's call.**

---

### Task 9: Live migration to native arm64 (supervised runbook)

**Run this only with the maintainer present, after Tasks 0-8 are green.** It stops the live memory server for a few minutes; Claude sessions' memory writes during that window are dropped (hooks fail silently by design). The commands below never print the API key. `<repo>` is your checkout of the `feat/container-platform-pinning` branch. Set `OP_ITEM` to the maintainer's secret-manager reference for the LLM key (do not paste it into any file in the repo).

**Files:** none in the repo. State changes are on the maintainer's machine only.

- [ ] **Step 1: Pre-flight (read-only)**

```bash
docker ps -a --filter name=hindsight --format '{{.Names}}  {{.Status}}  {{.Image}}'
docker image inspect "$(docker inspect -f '{{.Image}}' hindsight)" --format 'live container image arch={{.Architecture}}'
df -h ~ | tail -1                        # need roughly 3 GB free for the snapshot
docker run --rm alpine free -m | sed -n 1,2p   # VM memory headroom
ls -d ~/hindsight-data ~/hindsight-data/installation* 2>&1
for d in ~/hindsight-data/installation ~/hindsight-data/installation.*; do
  [ -d "$d" ] && printf '%s: ' "$d" && od -An -tx1 -j18 -N2 "$d"/*/bin/postgres   # 3e 00 = amd64, b7 00 = arm64
done
command -v op && op --version
```

Expected: the live container is `amd64` (that is the problem being fixed); `hindsight-prev` does **not** exist (if it does, resolve that first); enough disk; `installation` is amd64 (`3e 00`) and a saved `installation.arm64` (`b7 00`) may exist; `op` is present. Confirm `~/.config/hindsight-cc/config.env` has the provider and model you want (it is read for non-secret values; the key comes from the environment below).

- [ ] **Step 2: Stop gracefully and snapshot (the data is consistent while stopped)**

```bash
docker stop -t 60 hindsight
cp -R ~/hindsight-data ~/hindsight-data.pre-arm64-"$(date +%Y%m%d)"
du -sh ~/hindsight-data ~/hindsight-data.pre-arm64-*
```

Expected: `docker stop` returns after at most ~30 s; the snapshot is about the same size as the data directory.

- [ ] **Step 3: Recreate natively (key from the secret manager at run time, never printed)**

```bash
HINDSIGHT_API_LLM_API_KEY="$(op item get "$OP_ITEM" --fields password --reveal)" \
  sh <repo>/scripts/ensure-hindsight.sh recreate
```

Expected output (no key anywhere):
`Stopping 'hindsight' (up to 60s for a clean Postgres shutdown)...` then
`Recreated 'hindsight' (linux/arm64, memory 4g). The previous container is kept, stopped, as 'hindsight-prev' for rollback.`
When Postgres binaries were parked, a manual-rollback note follows (remove the new container, swap the binaries back, restore the old one).
Exit 0. If it prints `Recreate failed; rolling back...`, the original container is already running again under its old name and `installation` is restored; read the error above that line, fix it, and retry. Do not delete anything.

- [ ] **Step 4: Verify the new container**

```bash
docker inspect hindsight --format 'state={{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}'
docker image inspect "$(docker inspect -f '{{.Image}}' hindsight)" --format 'image arch={{.Architecture}}'
od -An -tx1 -j18 -N2 ~/hindsight-data/installation/*/bin/postgres     # expect b7 00
curl -s http://localhost:8888/health
python3 <repo>/scripts/get-status.py                                   # expect no EMULATED line
docker logs --tail 20 hindsight 2>&1 | grep -c -i 'illegal instruction'   # expect 0
```

Expected: `state=running health=healthy restarts=0 oom=false`; `image arch=arm64`; `b7 00`; `"status":"healthy"`; the status output shows the container as arm64 on an arm64 daemon; `0`. Then confirm real memories are served: run `/hindsight-cc:memory-search <a topic you know exists>` in a Claude session (or `python3 <repo>/scripts/search-memories.py "<topic>"`) and check results come back. Check the logs for `429`/`401` (a stale key): `docker logs --tail 200 hindsight 2>&1 | grep -c -E ' 429|401'` should be `0`.

- [ ] **Step 5: Index integrity after the architecture flip**

The data directory was written on arm64, then amd64, and now arm64 again. Cross-architecture reuse of a same-major-version Postgres directory is generally supported, but default `char` signedness differs between x86-64 and aarch64 and can affect some index types. First look (read-only), then rebuild; the credentials come from the instance file inside the container and are never printed:

```bash
docker exec -i hindsight python3 -I - <<'PY'
import json, os, subprocess
inst = json.load(open("/home/hindsight/.pg0/instances/hindsight/instance.json"))
psql = os.path.join(inst["installation_dir"], inst["version"], "bin", "psql")
env = dict(os.environ, PGPASSWORD=inst["password"])
def run(sql):
    r = subprocess.run([psql, "-w", "-h", "localhost", "-p", str(inst["port"]), "-U", inst["username"],
                        "-d", inst["database"], "-Atc", sql], env=env, capture_output=True, text=True)
    print((r.stdout or r.stderr).strip())
print("index methods in use:")
run("select am.amname, count(*) from pg_class c join pg_am am on am.oid = c.relam where c.relkind = 'i' group by 1 order by 1")
print("rebuilding all indexes (brief write locks)...")
run("REINDEX DATABASE " + inst["database"])
print("done")
PY
curl -s http://localhost:8888/health
```

Expected: a short table of index access methods, `done`, and a healthy response. Before running `REINDEX`, check it against the PostgreSQL 18 documentation for your version; it is cheap insurance on a ~1 GB database but takes brief write locks.

- [ ] **Step 6: Soak 24-48 hours, then settle the memory limit**

Check periodically:

```bash
docker stats --no-stream --format '{{.Name}} {{.MemUsage}} ({{.MemPerc}})' hindsight
docker inspect hindsight --format 'restarts={{.RestartCount}} oom={{.State.OOMKilled}} health={{.State.Health.Status}}'
docker exec hindsight ps -eo rss,comm --sort=-rss | head -3
```

Expected: native memory well below the old amd64 container's ~5.4 GiB, `oom=false`, `restarts=0`. If `oom=true` or restarts climb, raise the limit (`HINDSIGHT_MEMORY_LIMIT=6g`, supplied the same way as the key in Step 3, then `recreate` again) and record what the real workload needs so the default in `ensure-hindsight.sh` and the docs can be updated in a follow-up change.

- [ ] **Step 7: Retire the old state (only after the soak, and only with the maintainer's go-ahead)**

```bash
docker rm hindsight-prev                    # the rollback container
docker ps -a --format '{{.Names}}  {{.Status}}' | grep -i hindsight   # any other pre-migration leftovers
rm -rf ~/hindsight-data/installation.amd64  # parked amd64 Postgres binaries
rm -rf ~/hindsight-data.pre-arm64-*         # snapshots (and any older backups you no longer want)
```

Leftover pre-migration containers still carry the previous API key in their environment: remove them, and rotate that key if it is still live.

- [ ] **Step 8: Rollback (any time before Step 7)**

```bash
docker stop -t 60 hindsight && docker rm hindsight
mv ~/hindsight-data/installation ~/hindsight-data/installation.arm64   # park the arm64 binaries again
mv ~/hindsight-data/installation.amd64 ~/hindsight-data/installation   # restore the amd64 ones
docker rename hindsight-prev hindsight
docker update --restart=unless-stopped hindsight
docker start hindsight
```

Expected: the original (amd64) container is back, healthy, on its original data. If the data itself looks wrong, restore the snapshot: stop the container, move `~/hindsight-data` aside, and copy `~/hindsight-data.pre-arm64-<date>` back in its place.

- [ ] **Step 9: Report**

Record: the verification outputs from Step 4, the soak numbers from Step 6, and whether any follow-up is needed (the memory-limit default; aligning `pi-ndsight`'s container creation: image `0.7.2`, no `--platform`, and its compose file's container name). Do not push or open a PR unless the maintainer asks.
