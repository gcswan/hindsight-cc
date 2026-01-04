---
description: Check Hindsight memory server status and current project info
allowed-tools: Bash
---

# Hindsight Memory Status Skill

## How To Execute

Run the following command to check the status of the Hindsight memory server and display information about the current project's memory bank:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 ${CLAUDE_PLUGIN_ROOT}/scripts/get-status.py
```

## How To Handle Output

The output will show a table with project directory, memory bank ID, Hindsight container status, and server health status. Display this information to the user in a clear format.

## Finally

Provide helpful yet concise instructions on accessing the projects memories in a
browser. Construct and display the memory bank url by substituting the returned
bank ID: `http://localhost:9999/banks/${BANK_ID}`
