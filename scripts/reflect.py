#!/usr/bin/env python3
import argparse
import json
import os
import sys

import hindsight_api
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

    result = hindsight_api.reflect(
        bank_id,
        args.query,
        budget=args.budget,
        context=args.context,
        max_tokens=(args.max_tokens if args.max_tokens != 4096 else None),
        response_schema=response_schema,
    )

    if result is None:
        # Silent failure - reflect soft-fails to None; don't exit nonzero to
        # match the other scripts' behavior.
        debug("reflect returned None (server unavailable or error)")
        print("Error reflecting: Hindsight reflection unavailable.", file=sys.stderr)
        return

    # Answer is in the "text" field (not "answer").
    print(result.get("text", ""))

    structured = result.get("structured_output")
    if structured:
        print("\n--- Structured Output ---")
        print(json.dumps(structured, indent=2))


if __name__ == "__main__":
    main()
