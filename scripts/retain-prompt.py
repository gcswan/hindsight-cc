#!/usr/bin/env python3
import json
import os
import sys


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    bank_id = "claude-code--" + project_dir.lstrip("/").replace("/", "-").lower() if project_dir else ""

    input_data = json.load(sys.stdin)
    content = input_data.get("prompt", "")

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
