#!/usr/bin/env python3
import json
import os
import sys


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    bank_id = "claude-code--" + project_dir.lstrip("/").replace("/", "-").lower() if project_dir else "claude-code--default"

    try:
        input_data = json.load(sys.stdin)
    except Exception:
        return

    content = input_data.get("prompt", "")
    if isinstance(content, list):
        content = "\n".join(
            part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
        ).strip()
    elif not isinstance(content, str):
        content = str(content)

    try:
        from hindsight_client import Hindsight

        client = Hindsight(base_url="http://localhost:8888")
        client.retain(bank_id=bank_id, content=content)
        client.close()
    except Exception:
        # Silently fail if Hindsight is unavailable
        pass


if __name__ == "__main__":
    main()
