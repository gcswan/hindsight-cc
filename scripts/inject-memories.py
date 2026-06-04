#!/usr/bin/env python3
import json
import os
import sys

import hindsight_api
from bank_utils import extract_prompt, get_bank_id

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

    prompt = extract_prompt(input_data)
    debug(f"prompt: {prompt[:100]}{'...' if len(prompt) > 100 else ''}")
    debug(f"Query length: {len(prompt)} chars")

    # recall() is hard-bounded at 2.5s and soft-fails to [] -- this is the only
    # step the user waits on.
    results = hindsight_api.recall(bank_id, prompt, budget="low", timeout=2.5)

    memories = [
        r["text"] for r in results if isinstance(r, dict) and r.get("text")
    ]
    debug(f"Found {len(memories)} memories")

    if memories:
        memory_block = "<hindsight-memories>\n" + "\n".join(memories) + "\n</hindsight-memories>"
        print(memory_block)
        debug("Injected memories into prompt")
    else:
        debug("No relevant memories found")


if __name__ == "__main__":
    main()
