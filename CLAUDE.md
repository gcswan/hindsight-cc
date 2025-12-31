# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Claude Code plugin that provides persistent memory across conversations using the Hindsight vector database. The plugin automatically stores conversation context and injects relevant memories from past sessions.

## Setup and Installation

```bash
./setup.sh
```

This creates a Python virtual environment, installs dependencies (hindsight-client), makes scripts executable, and symlinks the plugin to `~/.claude/plugins/hindsight-2020`.

**Required environment variable**: `HINDSIGHT_API_LLM_API_KEY` must be set for Hindsight's LLM operations.

## Architecture

### Hook-Based System

The plugin operates through Claude Code hooks defined in `hooks/hooks.json`:

1. **SessionStart**: Runs `scripts/ensure-hindsight.sh` to start the Hindsight Docker container if not already running
2. **UserPromptSubmit**: Sequentially runs:
   - `scripts/retain-prompt.py` - Stores the user's prompt in the memory bank
   - `scripts/inject-memories.py` - Queries for relevant memories and injects them into the prompt
3. **Stop**: Runs `scripts/retain-transcript.py` to store the conversation transcript segment

### Memory Bank Isolation

Each project gets its own isolated memory bank based on git repository identity (when available) or project path. **The plugin auto-detects the project directory from git root or current working directory - no environment variables needed.**

**Git-based (preferred)**: Extracts owner/repo from git remote origin
- Any clone of `gcswan/hindsight-2020` → `claude-code--gcswan-hindsight-2020`
- Same memories across all paths: `/home/user/hindsight-2020`, `/mnt/work/hindsight-2020`, etc.

**Path-based (fallback)**: Uses last 2 path components when not in a git repo
- `/home/user/code/myapp` → `claude-code--code-myapp`
- `/projects/demo` → `claude-code--projects-demo`

This ensures working on the same repository from different paths shares the same memory bank.

### Hindsight Integration

- **Server**: Runs in Docker container `hindsight-2020`
- **API endpoint**: http://localhost:8888
- **UI**: http://localhost:9999
- **Data storage**: `~/hindsight-data/`
- **Python client**: Uses `hindsight-client` package (≥0.1.16)

### Memory Injection Format

Memories are injected into prompts as XML blocks:
```xml
<hindsight-memories>
memory text 1
memory text 2
</hindsight-memories>
```

## Python Scripts

All scripts follow a pattern of silently failing if Hindsight is unavailable. Set `HINDSIGHT_DEBUG=1` to enable verbose logging to stderr.

- `scripts/bank_utils.py` - Shared utility module for bank ID generation (git-based with path fallback)
- `scripts/ensure-hindsight.sh` - Checks for and starts Hindsight Docker container
- `scripts/retain-prompt.py` - Stores user prompts via `client.retain()`
- `scripts/inject-memories.py` - Queries and injects relevant memories via `client.recall()`
- `scripts/retain-transcript.py` - Stores conversation transcript segments from the last user message onwards
- `scripts/search-memories.py` - Manual search utility for testing
- `scripts/get-status.py` - Status checking utility

All Python scripts are executed via the venv: `${CLAUDE_PLUGIN_ROOT}/.venv/bin/python3`

### Debug Logging

All hook scripts support debug logging via the `HINDSIGHT_DEBUG` environment variable. When enabled, scripts output detailed information to stderr with prefixes like `[hindsight-2020:script-name]`.

## Slash Commands

Two user-invocable commands are defined in `commands/`:

- `/hindsight-2020:memory-search <query>` - Search the memory bank
- `/hindsight-2020:memory-status` - Check server and bank status

Both commands use the `Bash` tool and are documented in markdown files.

## Troubleshooting

Enable debug logging to see what the plugin is doing:
```bash
export HINDSIGHT_DEBUG=1
```

Check Docker container:
```bash
docker logs hindsight-2020
docker ps -f name=hindsight-2020
```

Check server health:
```bash
curl http://localhost:8888/health
```

Restart server:
```bash
docker restart hindsight-2020
```
