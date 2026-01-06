# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
