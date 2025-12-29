#!/usr/bin/env python3
import json
import os
import sys


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    bank_id = "claude-code--" + project_dir.lstrip("/").replace("/", "-").lower() if project_dir else ""

    input_data = json.load(sys.stdin)
    transcript_path = input_data.get("transcript_path", "")

    if not transcript_path:
        return

    # Read the JSONL transcript file
    messages = []
    try:
        with open(os.path.expanduser(transcript_path), 'r') as f:
            for line in f:
                if line.strip():
                    messages.append(json.loads(line))
    except (FileNotFoundError, json.JSONDecodeError):
        return

    if not messages:
        return

    # Find the last user message index
    last_user_idx = -1
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("message", {}).get("role") == "user":
            last_user_idx = i
            break

    if last_user_idx == -1:
        return

    # Get messages from last user prompt onwards
    recent_messages = messages[last_user_idx:]

    # Format transcript section
    lines = []
    for msg in recent_messages:
        inner = msg.get("message", {})
        role = inner.get("role", "unknown")
        content = inner.get("content", "")
        lines.append(f"{role}: {content}")

    transcript = "\n".join(lines)

    try:
        from hindsight_client import Hindsight

        client = Hindsight(base_url="http://localhost:8888")
        client.retain(bank_id=bank_id, content=transcript)
        client.close()
    except Exception:
        # Silently fail if Hindsight is unavailable
        pass


if __name__ == "__main__":
    main()
