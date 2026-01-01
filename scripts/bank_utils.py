#!/usr/bin/env python3
"""
Shared utilities for bank ID generation.

This module provides consistent bank ID generation across all hindsight-cc plugin scripts,
using git repository identity when available, with graceful fallback to path-based IDs.
"""

import os
import re
import subprocess
from pathlib import Path
from typing import Callable, Optional


def get_project_dir() -> str:
    """
    Auto-detect project directory

    Tries to find git repository root first, falls back to current working directory.

    Returns:
        Absolute path to project directory

    Examples:
        In git repo: Returns git root (e.g., "/home/user/code/hindsight-cc")
        Not in git repo: Returns cwd (e.g., "/tmp/test-project")
    """
    try:
        # Try to get git repository root
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
        )

        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (
        subprocess.TimeoutExpired,
        subprocess.CalledProcessError,
        FileNotFoundError,
    ):
        pass

    # Fall back to current working directory
    return os.getcwd()


def get_git_remote_id(project_dir: str) -> Optional[str]:
    """
    Extract owner/repo from git remote URL.

    Supports multiple git remote URL formats:
    - SSH: git@github.com:owner/repo.git
    - HTTPS: https://github.com/owner/repo.git
    - SSH with custom domain: git@gitlab.example.com:owner/repo.git
    - HTTPS with custom domain: https://gitlab.example.com/owner/repo.git
    - GitHub URLs with username: https://username@github.com/owner/repo.git
    - Nested paths: git@github.com:org/team/repo.git (returns "team-repo")

    Args:
        project_dir: Absolute path to project directory

    Returns:
        "owner-repo" string if git repo with remote found, None otherwise
    """
    try:
        # Run git command in project directory using -C flag
        result = subprocess.run(
            ["git", "-C", project_dir, "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=2,
        )

        if result.returncode != 0:
            return None

        url = result.stdout.strip()
        if not url:
            return None

        # Remove .git suffix
        url = re.sub(r"\.git$", "", url)

        # Pattern 1: SSH format (git@domain:path)
        ssh_match = re.match(r"^git@[^:]+:(.+)$", url)
        if ssh_match:
            path = ssh_match.group(1)
            parts = path.split("/")
            # Use last 2 components for owner/repo
            if len(parts) >= 2:
                return f"{parts[-2]}-{parts[-1]}"
            elif len(parts) == 1:
                return parts[0]

        # Pattern 2: HTTPS format (https://domain/path)
        https_match = re.match(r"^https?://(?:[^@]+@)?[^/]+/(.+)$", url)
        if https_match:
            path = https_match.group(1)
            parts = path.split("/")
            # Use last 2 components for owner/repo
            if len(parts) >= 2:
                return f"{parts[-2]}-{parts[-1]}"
            elif len(parts) == 1:
                return parts[0]

        return None

    except (
        subprocess.TimeoutExpired,
        subprocess.CalledProcessError,
        FileNotFoundError,
    ):
        # Git not available, not in git repo, or timeout
        return None
    except Exception:
        # Any other error - fail gracefully
        return None


def get_path_based_id(project_dir: str) -> str:
    """
    Generate fallback bank ID from last 2 path components.

    Examples:
        /home/user/code/myproject -> code-myproject
        /tmp/hindsight-cc-manual-test -> tmp-hindsight-cc-manual-test
        /single -> single-single (edge case: duplicate)

    Args:
        project_dir: Absolute path to project directory

    Returns:
        Hyphen-separated string from last 2 path components
    """
    path = Path(project_dir)
    parts = path.parts

    if len(parts) >= 2:
        # Use last 2 components
        return f"{parts[-2]}-{parts[-1]}"
    elif len(parts) == 1:
        # Edge case: single component (e.g., "/tmp")
        # Duplicate it to maintain consistency
        return f"{parts[0]}-{parts[0]}"
    else:
        # Edge case: empty path
        return "unknown-unknown"


def get_bank_id(debug_callback: Optional[Callable[[str], None]] = None) -> str:
    """
    Generate bank ID for Hindsight memory storage.

    Auto-detects project directory (no CLAUDE_PROJECT_DIR dependency).

    Priority:
    1. Try git remote owner/repo extraction
    2. Fall back to last 2 path components
    3. Default to "claude-code--default" if project detection fails

    Args:
        debug_callback: Optional function to call with debug messages

    Returns:
        Bank ID string with "claude-code--" prefix

    Examples:
        Git repo: "claude-code--gcswan-hindsight-cc"
        Non-git: "claude-code--code-hindsight-cc"
        Detection fails: "claude-code--default"
    """

    def debug(msg: str):
        """Internal debug helper."""
        if debug_callback:
            debug_callback(msg)

    # Auto-detect project directory
    try:
        project_dir = get_project_dir()
        debug(f"Detected project directory: {project_dir}")
    except Exception as e:
        debug(f"Failed to detect project directory: {e}")
        return "claude-code--default"

    if not project_dir:
        debug("No project directory available, using default")
        return "claude-code--default"

    # Normalize path (resolve symlinks, remove trailing slashes)
    try:
        project_dir = str(Path(project_dir).resolve())
    except Exception:
        # Path resolution failed, use as-is
        pass

    # Try git-based ID first
    git_id = get_git_remote_id(project_dir)
    if git_id:
        debug(f"Using git-based ID: {git_id}")
        result = f"claude-code--{git_id}"
    else:
        # Fall back to path-based ID
        path_id = get_path_based_id(project_dir)
        debug(f"Using path-based ID: {path_id}")
        result = f"claude-code--{path_id}"

    # Ensure lowercase for consistency
    return result.lower()
