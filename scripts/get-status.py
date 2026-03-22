#!/usr/bin/env python3
import errno
import urllib.error
import urllib.request

from bank_utils import get_bank_id, get_project_dir


HEALTH_URL = "http://localhost:8888/health"
UI_URL_TEMPLATE = "http://localhost:9999/banks/{bank_id}"


def is_blocked_probe_error(exc: Exception) -> bool:
    if isinstance(exc, PermissionError):
        return True

    if isinstance(exc, urllib.error.URLError):
        reason = exc.reason
        if isinstance(reason, PermissionError):
            return True
        if isinstance(reason, OSError) and reason.errno in {errno.EPERM, errno.EACCES}:
            return True

    if isinstance(exc, OSError) and exc.errno in {errno.EPERM, errno.EACCES}:
        return True

    return False


def get_health_status() -> tuple[str, bool]:
    """Returns (display message, is_blocked)."""
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=2) as response:
            return f"Reachable (HTTP {response.status})", False
    except Exception as exc:
        if is_blocked_probe_error(exc):
            return "Unknown (HTTP probe blocked by environment)", True
        return f"Unavailable ({exc})", False


def main():
    project_dir = get_project_dir()
    bank_id = get_bank_id()
    health_display, blocked = get_health_status()

    print(f"Project directory: {project_dir}")
    print(f"Memory bank ID: {bank_id}")
    print(f"Hindsight server: {health_display}")
    print(f"Memory browser: {UI_URL_TEMPLATE.format(bank_id=bank_id)}")

    if blocked:
        print("Note: This status command cannot reach localhost from its current environment.")
        print("That does not necessarily mean the Hindsight server is down.")


if __name__ == "__main__":
    main()
