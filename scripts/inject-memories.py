#!/usr/bin/env python3
import json
import os
import sys


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    bank_id = "claude-code--" + project_dir.lstrip("/").replace("/", "-").lower() if project_dir else ""

    input_data = json.load(sys.stdin)
    prompt = input_data.get("prompt", "")

    try:
        from hindsight_client import Hindsight

        client = Hindsight(base_url="http://localhost:8888")
        response = client.recall(bank_id=bank_id, query=prompt)
        client.close()

        memories = [r.text for r in response.results]
        if memories:
            memory_block = "<hindsight-memories>\n" + "\n".join(memories) + "\n</hindsight-memories>"
            print(memory_block)
    except Exception:
        # Silently fail if Hindsight is unavailable
        pass


if __name__ == "__main__":
    main()
