#!/usr/bin/env python3
import argparse
import json
import os
import sys
from bank_utils import get_bank_id

DEBUG = os.environ.get("HINDSIGHT_DEBUG", "").lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[hindsight-cc:reflect] {msg}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Reflect using Hindsight for decision-making and analysis"
    )
    parser.add_argument("query", help="Question or decision to reflect upon")
    parser.add_argument(
        "--budget",
        default="low",
        choices=["low", "mid", "high"],
        help='Budget level: "low", "mid", or "high" (default: low)',
    )
    parser.add_argument(
        "--context", default=None, help="Additional context for the reflection"
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=4096,
        help="Maximum tokens for the response (default: 4096)",
    )
    parser.add_argument(
        "--response-schema",
        default=None,
        help="JSON Schema for structured output (as JSON string)",
    )

    args = parser.parse_args()

    # Parse response_schema if provided
    response_schema = None
    if args.response_schema:
        try:
            response_schema = json.loads(args.response_schema)
            debug(f"Parsed response schema: {response_schema}")
        except json.JSONDecodeError as e:
            print(f"Error: Invalid JSON in --response-schema: {e}", file=sys.stderr)
            sys.exit(1)

    # Get bank ID
    bank_id = get_bank_id(debug_callback=debug)
    debug(f"Bank ID: {bank_id}")
    debug(f"Query: {args.query}")
    debug(f"Budget: {args.budget}")
    debug(f"Context: {args.context}")
    debug(f"Max tokens: {args.max_tokens}")

    try:
        from hindsight_client import Hindsight

        client = Hindsight(base_url="http://localhost:8888")

        # Build kwargs for reflect call
        kwargs = {
            "bank_id": bank_id,
            "query": args.query,
            "budget": args.budget,
        }

        # Only add optional parameters if they're not None
        if args.context is not None:
            kwargs["context"] = args.context
        if args.max_tokens != 4096:
            kwargs["max_tokens"] = args.max_tokens
        if response_schema is not None:
            kwargs["response_schema"] = response_schema

        debug(f"Calling reflect with: {kwargs}")
        response = client.reflect(**kwargs)
        client.close()

        # Print the reflection output to stdout
        if hasattr(response, "text"):
            print(response.text)
        elif isinstance(response, dict) and "text" in response:
            print(response["text"])
        elif isinstance(response, str):
            print(response)
        else:
            # Fallback: print the response as-is
            print(response)

    except Exception as e:
        debug(f"Failed to reflect: {e}")
        print(f"Error reflecting: {e}", file=sys.stderr)
        # Silent failure - don't exit with error code to match other scripts


if __name__ == "__main__":
    main()
