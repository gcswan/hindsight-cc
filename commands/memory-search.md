---
description: Search memory bank for past context and decisions relevant to current task or query
allowed-tools: Bash
argument-hint: [query]
---

# Hindsight Mermory Search Skill

## How to Execute

Run the following command to search your project's memory bank. When a user directly calls this skill with a query, pass the query as an argument. When invoked proactively by Claude, summarize the current session context as the search query.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 ${CLAUDE_PLUGIN_ROOT}/scripts/search-memories.py $ARGUMENTS
```

If no query is provided, ask the user what they want to search for.

## How to Handle Output

The script will return relevant memories from the memory bank. Provide a summary of the memories, highlighting any prior key decisions, lessons learned, patterns observed, or any additional context.
