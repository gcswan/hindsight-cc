# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
