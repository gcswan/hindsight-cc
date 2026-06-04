#!/usr/bin/env python3
import sys

import hindsight_api
from bank_utils import get_bank_id


def main():
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else ""
    if not query:
        print("Usage: search-memories.py <query>")
        sys.exit(1)

    bank_id = get_bank_id()

    try:
        # Manual search command (not a latency-bounded hook): use a generous
        # call to preserve the richer prior behavior (old client default was
        # "mid"). recall soft-fails to [] on any server/network problem.
        results = hindsight_api.recall(
            bank_id, query, budget="mid", max_tokens=4096, timeout=10.0
        )

        if results:
            print(f"Found {len(results)} relevant memories:\n")
            for i, r in enumerate(results, 1):
                print(f"--- Memory {i} ---")
                print(r.get("text", ""))
                print()
        else:
            print("No relevant memories found.")
    except Exception as e:
        # recall already soft-fails to [], so this only catches a truly
        # unexpected error; keep it friendly and do not depend on any
        # third-party client.
        print(f"Error searching memories: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
