# hindsight-cc


![Python 3.13+](https://img.shields.io/badge/python-3.13+-blue.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Docker Required](https://img.shields.io/badge/docker-required-blue.svg)

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

**IMPORTANT**
Set the LLM provider API token before installing in claude code 

```bash
export HINDSIGHT_API_LLM_API_KEY=OPENAI_API_KEY
```

## Usage

Once installed, the plugin works automatically:

1. **On session start**: Dependencies are installed and Hindsight server is started if not already running
2. **On each prompt**: Your prompt is stored, and relevant memories are injected
3. **On session end**: The conversation transcript is stored

### Slash Commands

- `/hindsight-cc:memory-search <query>` - Search your project's memory bank
- `/hindsight-cc:memory-status` - Check server status and bank info

## How It Works

### Memory Bank System

Each project gets its own isolated memory bank based on git repository identity (when available) or project path. **The plugin auto-detects the project directory from git root or current working directory - no environment variables needed.**

**Git-based (preferred)**: Extracts owner/repo from git remote origin

- Any clone of `gcswan/hindsight-cc` → `claude-code--gcswan-hindsight-cc`
- Same memories across all paths: `/home/user/hindsight-cc`, `/mnt/work/hindsight-cc`, etc.

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
| -------- | ----------- | ------- |
| `HINDSIGHT_API_LLM_API_KEY` | API key for Hindsight LLM operations | (required) |
| `HINDSIGHT_API_LLM_MODEL` | LLM model for Hindsight | `gpt-4o-mini` |
| `HINDSIGHT_DEBUG` | Enable debug logging (`1`, `true`, or `yes`) | (disabled) |
| `HINDSIGHT_IMAGE` | Docker image for Hindsight server | `ghcr.io/vectorize-io/hindsight:0.1.16` |

### Data Storage

Memory data is stored in `~/hindsight-data/`.

### Data Handling & Privacy

- Prompts and transcript segments are stored locally in the Hindsight data directory.
- Hindsight may send stored content to its configured LLM provider for embeddings and recall; avoid retaining sensitive or regulated data if you do not want it transmitted.

### Server Ports

- API: <http://localhost:8888>
- UI: <http://localhost:9999>

## Troubleshooting

### Debug Logging

Enable debug logging to see detailed output from plugin operations:

```bash
export HINDSIGHT_DEBUG=1
```

Debug messages are prefixed with the script name and written to stderr:

```text
[hindsight-cc:retain-prompt] Detected project directory: /home/user/code/hindsight-cc
[hindsight-cc:retain-prompt] Bank ID: claude-code--gcswan-hindsight-cc
[hindsight-cc:inject-memories] Found 3 memories
```

For combined Claude Code and plugin debugging:

```bash
export HINDSIGHT_DEBUG=1
claude --debug "hooks"
```

This shows hook execution, plugin debug messages, and success/failure status.

### Server Issues

Check server health:

```bash
curl http://localhost:8888/health
```

View container status:

```bash
docker ps -f name=hindsight-cc
```

Check container logs:

```bash
docker logs hindsight-cc
```

Restart the server:

```bash
docker restart hindsight-cc
```

## Testing

Run tests and checks from the repo root using the scripts venv:

```bash
./scripts/.venv/bin/pytest scripts/test
./scripts/.venv/bin/ruff check scripts/test/test_bank_utils.py
./scripts/.venv/bin/pyright scripts/test/test_bank_utils.py
```

## License

MIT
