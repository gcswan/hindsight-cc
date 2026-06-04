# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Claude Code plugin that provides persistent memory across conversations using the Hindsight vector database. The plugin automatically stores conversation context and injects relevant memories from past sessions.

## Setup and Installation

The plugin runtime is stdlib-only. Hooks run under the system `python3` (Python 3.x on `PATH`, macOS/Linux) and import only the standard library plus the bundled `scripts/hindsight_api.py` REST client. There is no virtualenv to create and no third-party package (`hindsight-client`) to install at runtime.

First-run path: invoke the `/hindsight-cc:setup` slash command. It is a wizard that asks for an LLM provider/model/API key/base URL and writes `~/.config/hindsight-cc/config.env`, which `ensure-hindsight.sh` reads when it creates the Hindsight container.

`scripts/install-dependencies.sh` still exists for dev convenience (creating `scripts/.venv` for tests/lint/typecheck) but is NOT wired into any hook.

LLM credentials: the Hindsight server needs an LLM configured for its memory operations. The value is resolved with precedence `explicit env var > ~/.config/hindsight-cc/config.env > built-in default`. Cloud providers (OpenAI, Anthropic, Gemini, Groq) need an API key (`HINDSIGHT_API_LLM_API_KEY`); local providers (Ollama, LM Studio) need a base URL instead and no key.

## Architecture

### Hook-Based System

The plugin operates through Claude Code hooks defined in `hooks/hooks.json`:

1. **SessionStart**: Runs `scripts/ensure-hindsight.sh` (health-probe-first: reuses any already-running server, otherwise starts the Docker container)
2. **UserPromptSubmit**: Sequentially runs:
   - `scripts/retain-prompt.py` - Stores the user's prompt in the memory bank (fire-and-forget, non-blocking)
   - `scripts/inject-memories.py` - Queries for relevant memories and injects them into the prompt (injection is enabled; recall is hard-bounded at ~2.5s and soft-fails to no injection)
3. **Stop**: Runs `scripts/retain-transcript.py` to store the conversation transcript segment (fire-and-forget, non-blocking)

### Memory Bank Isolation

Each project gets its own isolated memory bank based on git repository identity (when available) or project path. **The plugin auto-detects the project directory from git root or current working directory - no environment variables needed.**

**Git-based (preferred)**: Extracts owner/repo from git remote origin
- Any clone of `gcswan/hindsight-cc` → `claude-code--gcswan-hindsight-cc`
- Same memories across all paths: `/home/user/hindsight-cc`, `/mnt/work/hindsight-cc`, etc.

**Path-based (fallback)**: Uses last 2 path components when not in a git repo
- `/home/user/code/myapp` → `claude-code--code-myapp`
- `/projects/demo` → `claude-code--projects-demo`

This ensures working on the same repository from different paths shares the same memory bank.

### Hindsight Integration

- **Server**: Runs in Docker container `hindsight` (shared with the sibling pi-ndsight project — same `~/hindsight-data` volume and same `claude-code--` bank prefix, so memories are shared between them). `ensure-hindsight.sh` performs a one-time migration off the old `hindsight-cc` container name.
- **API endpoint**: http://localhost:8888
- **UI**: http://localhost:9999
- **Data storage**: `~/hindsight-data/`
- **Client**: Stdlib-only REST client `scripts/hindsight_api.py` (urllib/json) — no `hindsight-client` dependency

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

- `scripts/hindsight_api.py` - Stdlib-only REST client (urllib/json) wrapping the Hindsight endpoints; all functions soft-fail so a prompt is never interrupted by a memory error
- `scripts/bank_utils.py` - Shared utilities for bank ID generation (git-based with path fallback) and `extract_prompt` (normalizes the hook stdin payload)
- `scripts/ensure-hindsight.sh` - Health-probe-first check that reuses or starts the Hindsight Docker container; reads `config.env` at container-create time
- `scripts/retain-prompt.py` - Stores user prompts via `hindsight_api.retain_detached()`
- `scripts/inject-memories.py` - Queries and injects relevant memories via `hindsight_api.recall()`
- `scripts/retain-transcript.py` - Stores conversation transcript segments from the last user message onwards
- `scripts/reflect.py` - Backs the `/hindsight-cc:reflect` command (AI-assisted decision support)
- `scripts/search-memories.py` - Manual search utility for testing
- `scripts/get-status.py` - Status checking utility

Hook and CLI scripts are run by the system `python3` directly, e.g. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/...`. No virtualenv is used at runtime.

### Debug Logging

All hook scripts support debug logging via the `HINDSIGHT_DEBUG` environment variable. When enabled, scripts output detailed information to stderr with prefixes like `[hindsight-cc:script-name]`.

## Slash Commands

User-invocable commands are defined in `commands/`:

- `/hindsight-cc:setup` - First-run wizard: configure the LLM provider/model/key/base URL and write `~/.config/hindsight-cc/config.env`
- `/hindsight-cc:memory-search <query>` - Search the memory bank
- `/hindsight-cc:memory-status` - Check server and bank status
- `/hindsight-cc:reflect` - AI-assisted decision support over past context

The commands are documented in markdown files in `commands/`.

## Troubleshooting

Enable debug logging to see what the plugin is doing:
```bash
export HINDSIGHT_DEBUG=1
```

Check Docker container:
```bash
docker logs hindsight
docker ps -f name=hindsight
```

Check server health:
```bash
curl http://localhost:8888/health
```

Restart server:
```bash
docker restart hindsight
```
