# hindsight-2020

A Claude Code plugin that provides persistent memory across conversations using the [Hindsight](https://github.com/vectorize-io/hindsight) vector database.

## Features

- **Automatic Memory Injection**: Relevant context from past conversations is automatically injected into your prompts
- **Prompt Retention**: User prompts are stored for future semantic search
- **Transcript Retention**: Complete conversation segments are stored at session end
- **Per-Project Isolation**: Each project has its own memory bank
- **Automatic Server Management**: Hindsight Docker container starts automatically when you begin a session

## Requirements

- Docker installed and running
- Python 3.10+
- `HINDSIGHT_API_LLM_API_KEY` environment variable set (for Hindsight's LLM operations)

## Installation

Install the plugin via the Claude Marketplace and enable it for your project. Then install dependencies from this repo:

```bash
./scripts/install-dependencies.sh
```

This creates the Python venv under `scripts/.venv` and installs dependencies.

Make sure `HINDSIGHT_API_LLM_API_KEY` is set in your environment.

## Usage

Once installed, the plugin works automatically:

1. **On session start**: Hindsight server starts if not already running
2. **On each prompt**: Your prompt is stored, and relevant memories are injected
3. **On session end**: The conversation transcript is stored

### Slash Commands

- `/hindsight-2020:memory-search <query>` - Search your project's memory bank
- `/hindsight-2020:memory-status` - Check server status and bank info

## How It Works

### Memory Bank System

Each project gets its own isolated memory bank based on git repository identity (when available) or project path. **The plugin auto-detects the project directory from git root or current working directory - no environment variables needed.**

**Git-based (preferred)**: Extracts owner/repo from git remote origin
- Any clone of `gcswan/hindsight-2020` → `claude-code--gcswan-hindsight-2020`
- Same memories across all paths: `/home/user/hindsight-2020`, `/mnt/work/hindsight-2020`, etc.

**Path-based (fallback)**: Uses last 2 path components when not in a git repo
- `/home/user/code/myapp` → `claude-code--code-myapp`
- `/projects/demo` → `claude-code--projects-demo`

This ensures working on the same repository from different paths shares the same memory bank.

### Hook Flow

1. **SessionStart**: Starts Hindsight server if not running
2. **UserPromptSubmit**:
   - Stores the prompt for future search
   - Queries for relevant memories and injects them
3. **Stop**: Stores the conversation transcript

### Memory Format

Memories are injected as:

```xml
<hindsight-memories>
memory text 1
memory text 2
</hindsight-memories>
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HINDSIGHT_API_LLM_API_KEY` | API key for Hindsight LLM operations | (required) |
| `HINDSIGHT_API_LLM_MODEL` | LLM model for Hindsight | `gpt-4o-mini` |
| `HINDSIGHT_DEBUG` | Enable debug logging (`1`, `true`, or `yes`) | (disabled) |

### Data Storage

Memory data is stored in `~/hindsight-data/`.

### Server Ports

- API: <http://localhost:8888>
- UI: <http://localhost:9999>

## Troubleshooting

### Enable debug logging

Set `HINDSIGHT_DEBUG=1` to see detailed output from all plugin operations:

```bash
export HINDSIGHT_DEBUG=1
```

Debug messages are prefixed with the script name and written to stderr:

```
[hindsight-2020:ensure-hindsight] Starting
[hindsight-2020:ensure-hindsight] Server already running
[hindsight-2020:retain-prompt] Starting
[hindsight-2020:retain-prompt] Detected project directory: /home/user/code/hindsight-2020
[hindsight-2020:retain-prompt] Using git-based ID: gcswan-hindsight-2020
[hindsight-2020:retain-prompt] Bank ID: claude-code--gcswan-hindsight-2020
[hindsight-2020:retain-prompt] Content length: 42 chars
[hindsight-2020:retain-prompt] Successfully retained prompt
[hindsight-2020:inject-memories] Found 3 memories
[hindsight-2020:inject-memories] Injected memories into prompt
```

### Server not starting

Check Docker logs:

```bash
docker logs hindsight-2020
```

### Check server health

```bash
curl http://localhost:8888/health
```

### Restart server

```bash
docker restart hindsight-2020
```

### View container status

```bash
docker ps -f name=hindsight-2020
```

## Debug Mode

### Standard claude code debug mode

  claude --debug

### Debug specific categories (hooks, API calls)

  claude --debug "hooks,api"

### Exclude telemetry/stats noise

  claude --debug "!statsig,!file"

  1. View Logs While Running

  Once Claude Code starts, all debug output appears in your terminal. For your hindsight-2020 plugin specifically:

  Option A: Combined Claude + Plugin Debug
  export HINDSIGHT_DEBUG=1  # Enable your plugin's debug logging
  claude --debug "hooks"     # Enable Claude Code hook debugging

  This shows:

- Which hooks are executing (SessionStart, UserPromptSubmit, Stop)
- Your plugin's debug messages: [hindsight-2020:inject-memories], [hindsight-2020:retain-prompt], etc.
- Hook success/failure status

## License

MIT
