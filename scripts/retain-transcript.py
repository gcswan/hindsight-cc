#!/usr/bin/env python3
import json
import os
import sys

import hindsight_api
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
    except (OSError, ValueError) as e:
        # OSError covers FileNotFoundError/PermissionError/IsADirectoryError;
        # ValueError covers json.JSONDecodeError and UnicodeDecodeError (text-mode
        # open hitting non-UTF-8 bytes). Soft-fail so the Stop hook never raises.
        debug(f"Failed to read transcript: {e}")
        return

    if not messages:
        debug("No messages in transcript")
        return

    # Find the last user PROMPT index.
    #
    # Claude Code records tool results as messages with role="user", so the last
    # role=="user" entry is usually a tool result rather than something the user
    # typed. Slicing there would drop the user's question and every assistant
    # message before the final one. isMeta entries (skill bodies, slash-command
    # expansions, injected reminders) are role="user" too, and are not typed by
    # the user either. Only entries that are neither count as a real prompt.
    last_user_idx = -1
    first_any_user_idx = -1
    for i in range(len(messages) - 1, -1, -1):
        msg = messages[i]
        inner = msg.get("message", {}) if isinstance(msg, dict) else {}
        if not isinstance(inner, dict) or inner.get("role") != "user":
            continue
        first_any_user_idx = i
        if msg.get("isMeta"):
            continue
        content = inner.get("content", "")
        if isinstance(content, list) and any(
            isinstance(part, dict) and part.get("type") == "tool_result"
            for part in content
        ):
            continue
        last_user_idx = i
        break

    if last_user_idx == -1:
        # No prompt anywhere, so no turn boundary to slice at: the whole
        # transcript is the turn. Slicing at the last tool result instead would
        # keep only the final assistant message.
        last_user_idx = first_any_user_idx
        debug("No user prompt found; retaining from the first user-role message")

    if last_user_idx == -1:
        debug("No user message found in transcript")
        return

    # Get messages from last user prompt onwards
    recent_messages = messages[last_user_idx:]
    debug(f"Processing {len(recent_messages)} messages from last user prompt")

    # Format transcript section
    lines = []
    for msg in recent_messages:
        if not isinstance(msg, dict):
            continue
        inner = msg.get("message", {})
        if not isinstance(inner, dict):
            continue
        # Transcripts interleave non-message records (attachments, system
        # records). Skip anything without a role rather than emitting an
        # `unknown:` line, which would only feed noise to the extraction LLM.
        role = inner.get("role")
        if not role:
            continue
        # isMeta entries hold instructions (skill bodies, command expansions),
        # not conversation; retaining them would attribute them to the user.
        if msg.get("isMeta"):
            continue
        content = inner.get("content", "")
        if isinstance(content, list):
            content = "\n".join(
                part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
            ).strip()
        elif not isinstance(content, str):
            content = json.dumps(content, ensure_ascii=True)
        content = content.strip()
        # Tool results and tool-call-only assistant messages have no text parts;
        # an empty `role: ` line is pure noise.
        if not content:
            continue
        lines.append(f"{role}: {content}")

    transcript = "\n".join(lines)
    debug(f"Formatted transcript: {len(transcript)} chars")
    if not transcript:
        debug("Turn has no text to retain")
        return

    # `transcript` is fully built from stdin above before detaching; the child
    # must not touch stdin. retain_detached returns instantly and soft-fails.
    hindsight_api.retain_detached(bank_id, transcript)
    debug("Dispatched detached retain")


if __name__ == "__main__":
    main()
