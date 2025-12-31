---
description: Check Hindsight memory server status and current project info
allowed-tools: Bash
---

# Memory Status

Check the status of the Hindsight memory server and display information about the current project's memory bank.

## Usage

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 ${CLAUDE_PLUGIN_ROOT}/scripts/get-status.py
```

## Output Fields

|Field|Description|
|---|---|
|Project directory|Auto-detected from git root or current working directory|
|Memory bank ID|Unique identifier for this project's memory storage|
|Hindsight container|Docker container status (e.g., "Up 2 hours")|
|Hindsight server|HTTP health check result|

## Example Output - Healthy

```text
Project directory: /home/user/code/myproject
Memory bank ID: claude-code--user-myproject

Hindsight container: Up 2 hours
Hindsight server: Healthy (HTTP 200)
```

## Example Output - Unhealthy

```text
Project directory: /home/user/code/myproject
Memory bank ID: claude-code--user-myproject

Hindsight container: Not running
Hindsight server: Unavailable (<urlopen error [Errno 111] Connection refused>)
```

## Troubleshooting

If the server is unavailable:

1. **Start the container**: `./scripts/ensure-hindsight.sh`
2. **Check container logs**: `docker logs hindsight-cc`
3. **Restart if needed**: `docker restart hindsight-cc`
4. **Verify API key**: Ensure `HINDSIGHT_API_LLM_API_KEY` is set
