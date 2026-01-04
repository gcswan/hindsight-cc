---
description: Search the Hindsight memory bank for this project to find precedence for the task at hand
allowed-tools: Bash
argument-hint: [query]
---

# Hindsight Mermory Search Skill

## How to Execute

Run the following command to search your project's memory bank. nd.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 ${CLAUDE_PLUGIN_ROOT}/scripts/search-memories.py $ARGUMENTS
```

If no query is provided, ask the user what they want to search for.

## How to Handle Output

The script will return relevant memories from the memory bank. Provide a summary of the memories, highlighting any prior key decisions, lessons learned, patterns observed, or any additional context.
