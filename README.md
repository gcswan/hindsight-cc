# 2020

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

```bash
./setup.sh
```

This creates the Python venv, installs dependencies, and symlinks the plugin to `~/.claude/plugins/2020`.

Make sure `HINDSIGHT_API_LLM_API_KEY` is set in your environment.

## Usage

Once installed, the plugin works automatically:

1. **On session start**: Hindsight server starts if not already running
2. **On each prompt**: Your prompt is stored, and relevant memories are injected
3. **On session end**: The conversation transcript is stored

### Slash Commands

- `/2020:memory-search <query>` - Search your project's memory bank
- `/2020:memory-status` - Check server status and bank info

## How It Works

### Memory Bank System

Each project gets isolated memory based on `CLAUDE_PROJECT_DIR`:
```
/home/user/projects/myapp → claude-code--home-user-projects-myapp
```

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

### Data Storage

Memory data is stored in `~/hindsight-data/`.

### Server Ports

- API: http://localhost:8888
- UI: http://localhost:9999

## Troubleshooting

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

## License

MIT
