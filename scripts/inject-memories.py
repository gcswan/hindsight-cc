#!/usr/bin/env python3
import json
import os
import sys
from bank_utils import get_bank_id

DEBUG = os.environ.get("HINDSIGHT_DEBUG", "").lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[hindsight-cc:inject-memories] {msg}", file=sys.stderr)


def main():
    debug("Starting")
    bank_id = get_bank_id(debug_callback=debug)
    debug(f"Bank ID: {bank_id}")

    try:
        input_data = json.load(sys.stdin)
        debug(f"Received input keys: {list(input_data.keys())}")
    except Exception as e:
        debug(f"Failed to parse input: {e}")
        return

    prompt = input_data.get("prompt", "")
    if isinstance(prompt, list):
        prompt = "\n".join(
            part.get("text", "") for part in prompt if isinstance(part, dict) and part.get("type") == "text"
        ).strip()
    elif not isinstance(prompt, str):
        prompt = str(prompt)

    debug(f"prompt: {prompt[:100]}{'...' if len(prompt) > 100 else ''}")
    debug(f"Query length: {len(prompt)} chars")

    try:
        from hindsight_client import Hindsight

        debug("Connecting to Hindsight server")
        client = Hindsight(base_url="http://localhost:8888")
        response = client.recall(bank_id=bank_id, query=prompt)
        client.close()

        memories = [r.text for r in response.results]
        debug(f"Found {len(memories)} memories")
        if memories:
            memory_block = "<hindsight-memories>\n" + "\n".join(memories) + "\n</hindsight-memories>"
            print(memory_block)
            debug("Injected memories into prompt")
        else:
            debug("No relevant memories found")
    except Exception as e:
        debug(f"Failed to recall memories: {e}")
        # Silently fail if Hindsight is unavailable
        pass


if __name__ == "__main__":
    main()
