# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.1] - 2026-10-09

### Fixed

- `retain-transcript.py` retained only a fraction of each turn. Claude Code
  records tool results as messages with `role="user"`, so slicing the transcript
  at the last `role=="user"` entry started the slice *after* the final tool
  result on any turn that used tools, dropping the user's prompt and every
  assistant message before the last one. Measured against the last turn of 384
  local transcripts, the old slice dropped the user's prompt in 83% of turns and
  about three quarters of each turn's messages never reached the server.
  The slice now starts at the user's prompt: the last `role="user"` entry that
  carries no `tool_result` part and is not an `isMeta` entry.
- `isMeta` entries (skill bodies loaded by the Skill tool, slash-command
  expansions, injected reminders) are `role="user"` messages too. They are no
  longer taken for the user's prompt, and are left out of the retained text,
  since they hold instructions rather than conversation.
- When a transcript has no user prompt at all, the whole transcript is retained
  from its first user-role entry, instead of only the tail after the last tool
  result.
- Transcript entries with no `message.role` (attachments, system records) were
  emitted as empty `unknown:` lines, and tool results and tool-call-only
  assistant messages as empty `user:` / `assistant:` lines, feeding noise to the
  extraction LLM. Lines with no text are now skipped.

## [2.1.0] - 2026-10-08

### Added

- `HINDSIGHT_PLATFORM` (`linux/arm64` or `linux/amd64`) and
  `HINDSIGHT_MEMORY_LIMIT` settings, read from the environment or `config.env`.
  `HINDSIGHT_DATA_DIR` overrides the host directory for the Postgres data
  (default `~/hindsight-data`).
- `HINDSIGHT_RECREATE_WAIT_SECONDS` (default 180, recreate only): how long
  `recreate` waits for the new server to answer before rolling back.
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
- A container that exited with code 132, 126 or 127, or is being restarted by
  Docker after a crash (possibly a loop), is reported with a suggested fix instead of being started
  again every session.

## [2.0.0] - 2026-06-04

Breaking infrastructure rewrite. The Docker container is renamed (causing a
one-time restart on upgrade) and the runtime now requires a system `python3` on
`PATH`.

### Added

- New `/hindsight-cc:setup` first-run wizard that configures the LLM provider,
  model, API key, and base URL, then writes `~/.config/hindsight-cc/config.env`.
- `ensure-hindsight.sh` reads `config.env` at container-create time with
  precedence: explicit env var > `config.env` > built-in default. Local
  providers (Ollama, LM Studio) need no API key.
- `scripts/hindsight_api.py`: a stdlib-only (urllib/json) REST client wrapping
  the Hindsight endpoints, with every call soft-failing.

### Changed

- **Breaking:** the shared Docker container is now named `hindsight` (was
  `hindsight-cc`) and is shared with the sibling pi-ndsight project (same
  `~/hindsight-data` volume and `claude-code--` bank prefix → shared memories).
  `ensure-hindsight.sh` performs a one-time migration off the old
  `hindsight-cc` container name, which restarts the server once.
- **Breaking:** hooks now run under the system `python3` instead of a
  virtualenv; a `python3` on `PATH` is now required.
- Hooks call the stdlib REST client directly; the `hindsight-client` package
  and `scripts/.venv` are no longer used at runtime.
- Re-enabled memory injection on `UserPromptSubmit`: recall is hard-bounded at
  ~2.5s and soft-fails to no injection.
- Prompt and transcript retention are now fire-and-forget (non-blocking).
- `SessionStart` runs only `ensure-hindsight.sh` (health-probe-first, reusing
  any already-running server); the `install-dependencies.sh` SessionStart hook
  was removed.
- `requirements.txt` is now dev-only (pytest/pyright/ruff); the runtime has no
  third-party dependencies.

### Removed

- Dropped the `hindsight-client` dependency and the runtime virtualenv.
  `install-dependencies.sh` remains in-repo for dev tooling but is no longer
  wired into any hook.

## [1.4.0] - 2026-06-04

### Changed

- Pin the Hindsight server image to `0.7.2` (was `0.1.16`).
- Run the container with `--shm-size=2g`. The embedded Postgres builds a
  `to_tsvector` GENERATED column during migrations, which needs >500MB of
  shared memory; Docker's default 64MB `/dev/shm` causes `DiskFull` crashes
  on first start and on upgrades over a non-trivial data set.

## [1.3.0] - 2026-01-06

### Added

- New `/hindsight-cc:reflect` slash command for AI-assisted decision support
- Reflection skill that analyzes past context to help with technical
  decisions and architectural choices
- Support for configurable budget levels (low, mid, high) to control
  reflection depth
- Optional context and max-tokens parameters for customized analysis

## [1.2.1] - 2026-01-05

### Changed

- Changed default LLM provider and model to OpenAI gpt-5-nano for improved
  speed

### Documentation

- Updated README with shell settings examples

## [1.1.1] - 2026-01-04

### Changed

- Improved memory-search skill description to be more concise and directive
- Clarified proactive invocation instructions in memory-search skill

## [1.1.0] - 2026-01-04

### Added

- User instructions to memory-status slash command for improved usability

### Changed

- Rewrote slash command descriptions to be more action-oriented
- Pinned Hindsight Docker image to specific version tag with `HINDSIGHT_IMAGE` override option

### Fixed

- Made plugin scripts POSIX-safe for better cross-platform compatibility
- Fixed `Callable` type annotation in bank_utils.py
- Added `.python-version` file to track Python version requirements

### Documentation

- Added privacy and data handling note to README
- Updated Python version badge in README

## [1.0.0] - 2025-12-31

### Added

- Initial marketplace release
- Persistent memory across Claude Code conversations using Hindsight vector database
- Automatic memory injection via `UserPromptSubmit` hook
- Automatic conversation storage via `Stop` hook
- Git-based memory bank isolation (same repo = same memories regardless of clone path)
- Path-based fallback for non-git projects
- Two slash commands:
  - `/hindsight-cc:memory-search` - Search the memory bank
  - `/hindsight-cc:memory-status` - Check server and project status
- Debug logging support via `HINDSIGHT_DEBUG=1`
- Automatic Docker container management for Hindsight server
- Python virtual environment isolation for dependencies
