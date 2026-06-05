#!/usr/bin/env python3
"""Unit tests for get-status.py is_blocked_probe_error branch logic.

The script's filename has a hyphen, so it is not importable by name; we load it
via importlib from its file path.
"""

import errno
import importlib.util
import urllib.error
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent.parent


def _load_get_status():
    """Load get-status.py (hyphenated filename) as a module via importlib."""
    path = SCRIPTS_DIR / "get-status.py"
    spec = importlib.util.spec_from_file_location("get_status_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


get_status = _load_get_status()
is_blocked = get_status.is_blocked_probe_error


class TestIsBlockedProbeError:
    def test_bare_permission_error_is_blocked(self):
        assert is_blocked(PermissionError()) is True

    def test_urlerror_wrapping_permission_error_is_blocked(self):
        assert is_blocked(urllib.error.URLError(PermissionError())) is True

    def test_urlerror_wrapping_oserror_eacces_is_blocked(self):
        reason = OSError(errno.EACCES, "permission denied")
        assert is_blocked(urllib.error.URLError(reason)) is True

    def test_urlerror_wrapping_oserror_eperm_is_blocked(self):
        reason = OSError(errno.EPERM, "operation not permitted")
        assert is_blocked(urllib.error.URLError(reason)) is True

    def test_bare_oserror_eperm_is_blocked(self):
        assert is_blocked(OSError(errno.EPERM, "operation not permitted")) is True

    def test_bare_oserror_eacces_is_blocked(self):
        assert is_blocked(OSError(errno.EACCES, "permission denied")) is True

    def test_plain_value_error_is_not_blocked(self):
        assert is_blocked(ValueError("nope")) is False

    def test_urlerror_normal_down_is_not_blocked(self):
        assert is_blocked(urllib.error.URLError("normal down")) is False
