#!/usr/bin/env python3
import json
import os
import sys

import hindsight_api
from bank_utils import get_bank_id

DEBUG = os.environ.get("HINDSIGHT_DEBUG", "").lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[hindsight-cc:retain-prompt] {msg}", file=sys.stderr)


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

    content = input_data.get("prompt", "")
    if isinstance(content, list):
        content = "\n".join(
            part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
        ).strip()
    elif not isinstance(content, str):
        content = str(content)

    debug(f"Content length: {len(content)} chars")

    # Read all of stdin and build `content` BEFORE detaching: the child must
    # not touch stdin. retain_detached returns instantly and soft-fails.
    hindsight_api.retain_detached(bank_id, content)
    debug("Dispatched detached retain")


if __name__ == "__main__":
    main()
