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


def _is_tool_result(content) -> bool:
    return isinstance(content, list) and any(
        isinstance(part, dict) and part.get("type") == "tool_result" for part in content
    )


def _origin_kind(msg: dict):
    """The entry's origin.kind ("human", "peer", "task-notification", ...), or
    None for transcripts written before Claude Code recorded an origin."""
    origin = msg.get("origin")
    return origin.get("kind") if isinstance(origin, dict) else None


def _starts_turn(msg: dict, prev_role) -> bool:
    """Whether a non-tool-result user entry begins a turn.

    A human prompt always does. Messages from other agents, task notifications
    and auto-continuations start a turn when they arrive with the assistant
    idle (right after an assistant message, or first in the transcript); one
    arriving after a tool result was queued into the running turn. Without an
    origin, fall back to isMeta, which marks skill bodies and command expansions.
    """
    kind = _origin_kind(msg)
    if kind == "human":
        return True
    if kind is not None:
        return prev_role in (None, "assistant")
    return not msg.get("isMeta")


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

    # Find where the last turn starts.
    #
    # Claude Code records much more than the user's prompt as role="user": every
    # tool result, isMeta entries (skill bodies, slash-command expansions,
    # injected reminders), messages from other agents and task notifications.
    # Slicing at the last role=="user" entry would usually land on a tool result
    # and drop the user's question and every assistant message before the last.
    # See _starts_turn for which entries begin a turn.
    turn_start_idx = -1
    first_user_idx = -1
    prev_role = None
    for i, msg in enumerate(messages):
        inner = msg.get("message", {}) if isinstance(msg, dict) else {}
        if not isinstance(inner, dict) or not inner.get("role"):
            continue
        role = inner["role"]
        if role == "user":
            if first_user_idx == -1:
                first_user_idx = i
            if not _is_tool_result(inner.get("content")) and _starts_turn(msg, prev_role):
                turn_start_idx = i
        prev_role = role

    if turn_start_idx == -1:
        # No turn start anywhere, so no boundary to slice at: the whole
        # transcript is the turn. Slicing at the last tool result instead would
        # keep only the final assistant message.
        turn_start_idx = first_user_idx
        debug("No turn start found; retaining from the first user-role message")

    if turn_start_idx == -1:
        debug("No user message found in transcript")
        return

    recent_messages = messages[turn_start_idx:]
    debug(f"Processing {len(recent_messages)} messages from the last turn start")

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
        kind = _origin_kind(msg)
        if role == "user" and kind not in (None, "human"):
            # Peer messages and notifications are conversation, but not the
            # user's: label them by where they came from.
            role = kind
        elif msg.get("isMeta"):
            # Skill bodies and command expansions hold instructions, not
            # conversation; retaining them would attribute them to the user.
            continue
        content = inner.get("content", "")
        if isinstance(content, list):
            content = "\n".join(
                part["text"]
                for part in content
                if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str)
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
