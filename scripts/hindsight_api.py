#!/usr/bin/env python3
"""
Stdlib-only REST client for the Hindsight memory server.

This module wraps the four Hindsight endpoints the plugin relies on using only
the Python standard library, so hook scripts can run under the system python3
with no virtualenv and no third-party imports (e.g. hindsight-client, httpx,
pydantic). Every function soft-fails: a server that is down, slow, or returning
garbage must never raise out of these functions, so a user's prompt is never
interrupted by a memory error.

Base URL comes from the HINDSIGHT_BASE_URL environment variable (read at call
time), defaulting to http://localhost:8888. Set HINDSIGHT_DEBUG=1 for verbose
stderr logging.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

DEFAULT_BASE_URL = "http://localhost:8888"
_DEBUG_PREFIX = "[hindsight-cc:hindsight_api]"


def _base_url() -> str:
    """Return the configured Hindsight base URL (read from env at call time)."""
    return os.environ.get("HINDSIGHT_BASE_URL", DEFAULT_BASE_URL).rstrip("/")


def _debug_enabled() -> bool:
    """True when HINDSIGHT_DEBUG is a truthy value (1/true/yes, any case)."""
    return os.environ.get("HINDSIGHT_DEBUG", "").strip().lower() in ("1", "true", "yes")


def debug(msg: str) -> None:
    """Print a debug message to stderr when HINDSIGHT_DEBUG is enabled."""
    if _debug_enabled():
        print(f"{_DEBUG_PREFIX} {msg}", file=sys.stderr)


def _quote_bank(bank_id: str) -> str:
    """URL-path-escape a bank ID (hyphen-safe; bank IDs need no real escaping).

    Coerces to str so a non-string bank_id can never raise out of a caller —
    the module's soft-fail guarantee must hold even for malformed input.
    """
    return urllib.parse.quote(str(bank_id), safe="-")


def _post_json(path: str, body: dict, timeout: float) -> Optional[dict]:
    """
    POST a JSON body to {base}{path} and return the parsed JSON response dict.

    Soft-fails: returns None on any network error, HTTP error, timeout, or
    invalid JSON response.
    """
    url = f"{_base_url()}{path}"
    try:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            debug(f"POST {url}: expected JSON object, got {type(parsed).__name__}")
            return None
        return parsed
    except Exception as e:
        debug(f"POST {url} failed: {type(e).__name__}: {e}")
        return None


def retain(
    bank_id: str,
    content: str,
    *,
    context: Optional[str] = None,
    async_: bool = True,
    timeout: float = 10.0,
) -> Optional[dict]:
    """
    Store a memory item in the given bank.

    POST /v1/default/banks/{bank_id}/memories with body
    {"items": [{"content": content[, "context": context]}], "async": async_}.

    Returns the parsed JSON response dict on success, None on any failure.
    """
    item: dict = {"content": content}
    if context is not None:
        item["context"] = context
    body = {"items": [item], "async": async_}
    path = f"/v1/default/banks/{_quote_bank(bank_id)}/memories"
    return _post_json(path, body, timeout)


def recall(
    bank_id: str,
    query: str,
    *,
    budget: str = "low",
    max_tokens: int = 2048,
    timeout: float = 2.5,
) -> list:
    """
    Recall relevant memories from the given bank.

    POST /v1/default/banks/{bank_id}/memories/recall with body
    {"query": query, "budget": budget, "max_tokens": max_tokens}.

    Returns the "results" list (list of dicts, each with a "text" key) on
    success; returns [] on any failure or when there are no results.
    """
    body = {"query": query, "budget": budget, "max_tokens": max_tokens}
    path = f"/v1/default/banks/{_quote_bank(bank_id)}/memories/recall"
    parsed = _post_json(path, body, timeout)
    if parsed is None:
        return []
    results = parsed.get("results")
    if not isinstance(results, list):
        debug("recall: response missing a list 'results' field")
        return []
    return results


def reflect(
    bank_id: str,
    query: str,
    *,
    budget: str = "low",
    context: Optional[str] = None,
    max_tokens: Optional[int] = None,
    response_schema: Optional[dict] = None,
    timeout: float = 60.0,
) -> Optional[dict]:
    """
    Reflect over the bank to synthesize an answer to a query.

    POST /v1/default/banks/{bank_id}/reflect with body
    {"query": query, "budget": budget}, adding "context", "max_tokens", and
    "response_schema" only when each is not None.

    Returns the parsed JSON response dict on success (answer is in the "text"
    field, not "answer"), None on any failure.
    """
    body: dict = {"query": query, "budget": budget}
    if context is not None:
        body["context"] = context
    if max_tokens is not None:
        body["max_tokens"] = max_tokens
    if response_schema is not None:
        body["response_schema"] = response_schema
    path = f"/v1/default/banks/{_quote_bank(bank_id)}/reflect"
    return _post_json(path, body, timeout)


def health(timeout: float = 2.0) -> bool:
    """
    Check server health.

    GET /health. Returns True if the request returns an HTTP 2xx status,
    False on any failure or timeout.
    """
    url = f"{_base_url()}/health"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
        return status is not None and 200 <= status < 300
    except Exception as e:
        debug(f"GET {url} failed: {type(e).__name__}: {e}")
        return False
