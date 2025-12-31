#!/usr/bin/env python3
import os
import sys
from bank_utils import get_bank_id


def main():
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else ""
    if not query:
        print("Usage: search-memories.py <query>")
        sys.exit(1)

    bank_id = get_bank_id()

    try:
        from hindsight_client import Hindsight

        client = Hindsight(base_url="http://localhost:8888")
        response = client.recall(bank_id=bank_id, query=query)
        client.close()

        if response.results:
            print(f"Found {len(response.results)} relevant memories:\n")
            for i, result in enumerate(response.results, 1):
                print(f"--- Memory {i} ---")
                print(result.text)
                print()
        else:
            print("No relevant memories found.")
    except Exception as e:
        print(f"Error searching memories: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
