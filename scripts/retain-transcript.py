#!/usr/bin/env python3
import json
import os
import sys
from bank_utils import get_bank_id

DEBUG = os.environ.get("HINDSIGHT_DEBUG", "").lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[hindsight-cc:retain-transcript] {msg}", file=sys.stderr)


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
    transcript_path = input_data.get("transcript_path", "")

    if not transcript_path:
        debug("No transcript_path provided")
        return

    debug(f"Reading transcript from: {transcript_path}")

    # Read the JSONL transcript file
    messages = []
    try:
        with open(os.path.expanduser(transcript_path), 'r') as f:
            for line in f:
                if line.strip():
                    messages.append(json.loads(line))
        debug(f"Read {len(messages)} messages from transcript")
    except (FileNotFoundError, json.JSONDecodeError) as e:
        debug(f"Failed to read transcript: {e}")
        return

    if not messages:
        debug("No messages in transcript")
        return

    # Find the last user message index
    last_user_idx = -1
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("message", {}).get("role") == "user":
            last_user_idx = i
            break

    if last_user_idx == -1:
        debug("No user message found in transcript")
        return

    # Get messages from last user prompt onwards
    recent_messages = messages[last_user_idx:]
    debug(f"Processing {len(recent_messages)} messages from last user prompt")

    # Format transcript section
    lines = []
    for msg in recent_messages:
        inner = msg.get("message", {})
        role = inner.get("role", "unknown")
        content = inner.get("content", "")
        if isinstance(content, list):
            content = "\n".join(
                part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
            ).strip()
        elif not isinstance(content, str):
            content = json.dumps(content, ensure_ascii=True)
        lines.append(f"{role}: {content}")

    transcript = "\n".join(lines)
    debug(f"Formatted transcript: {len(transcript)} chars")

    try:
        from hindsight_client import Hindsight

        debug("Connecting to Hindsight server")
        client = Hindsight(base_url="http://localhost:8888")
        client.retain(bank_id=bank_id, content=transcript)
        client.close()
        debug("Successfully retained transcript")
    except Exception as e:
        debug(f"Failed to retain transcript: {e}")
        # Silently fail if Hindsight is unavailable
        pass


if __name__ == "__main__":
    main()
