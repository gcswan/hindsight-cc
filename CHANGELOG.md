# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-12-31

### Added
- Initial marketplace release
- Persistent memory across Claude Code conversations using Hindsight vector database
- Automatic memory injection via `UserPromptSubmit` hook
- Automatic conversation storage via `Stop` hook
- Git-based memory bank isolation (same repo = same memories regardless of clone path)
- Path-based fallback for non-git projects
- Two slash commands:
  - `/hindsight-2020:memory-search` - Search the memory bank
  - `/hindsight-2020:memory-status` - Check server and project status
- Debug logging support via `HINDSIGHT_DEBUG=1`
- Automatic Docker container management for Hindsight server
- Python virtual environment isolation for dependencies
