---
description: Check Hindsight memory server status and current project info
allowed-tools: Bash
---

# Hindsight Memory Status Skill

## How To Execute

Run the following command to check the status of the Hindsight memory server and display information about the current project's memory bank:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/get-status.py
```

## How To Handle Output

The output shows the project directory, memory bank ID, server health, and the
Docker container's state, image architecture, health, restart count and memory.
Display this in a clear format.

If a line starts with `EMULATED:`, the container image does not match the Docker
daemon's architecture (it runs under emulation: slower and heavier on memory).
Tell the user, and explain the fix: run
`${CLAUDE_PLUGIN_ROOT}/scripts/ensure-hindsight.sh recreate`. It needs the LLM
API key in the environment or in `~/.config/hindsight-cc/config.env`, keeps the
old container as `hindsight-prev` for rollback, and rolls back automatically if
the new container does not come up healthy. Do not run it without the user's
go-ahead, because it briefly stops the memory server.

## Finally

Provide helpful yet concise instructions on accessing the projects memories in a
browser. Construct and display the memory bank url by substituting the returned
bank ID: `http://localhost:9999/banks/${BANK_ID}`
