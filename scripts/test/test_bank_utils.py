#!/usr/bin/env python3
"""Unit tests for bank_utils.py"""

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from bank_utils import (
    get_bank_id,
    get_git_remote_id,
    get_path_based_id,
    get_project_dir,
)


class TestGetProjectDir:
    """Tests for get_project_dir() function."""

    def test_returns_git_root_when_in_git_repo(self):
        """When in a git repo, returns the git root directory."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "/home/user/my-repo\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_project_dir()
            assert result == "/home/user/my-repo"

    def test_returns_cwd_when_not_in_git_repo(self):
        """When not in a git repo, returns current working directory."""
        mock_result = MagicMock()
        mock_result.returncode = 128  # Git error code for not in repo

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            with patch("bank_utils.os.getcwd", return_value="/tmp/not-a-repo"):
                result = get_project_dir()
                assert result == "/tmp/not-a-repo"

    def test_returns_cwd_on_git_timeout(self):
        """When git command times out, falls back to cwd."""
        with patch(
            "bank_utils.subprocess.run", side_effect=subprocess.TimeoutExpired("git", 2)
        ):
            with patch("bank_utils.os.getcwd", return_value="/home/user/project"):
                result = get_project_dir()
                assert result == "/home/user/project"

    def test_returns_cwd_when_git_not_installed(self):
        """When git is not installed, falls back to cwd."""
        with patch("bank_utils.subprocess.run", side_effect=FileNotFoundError()):
            with patch("bank_utils.os.getcwd", return_value="/projects/demo"):
                result = get_project_dir()
                assert result == "/projects/demo"

    def test_strips_whitespace_from_git_output(self):
        """Git output whitespace is stripped."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "  /path/to/repo  \n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_project_dir()
            assert result == "/path/to/repo"


class TestGetGitRemoteId:
    """Tests for get_git_remote_id() function."""

    def test_ssh_format_github(self):
        """SSH format: git@github.com:owner/repo.git -> owner-repo"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "git@github.com:owner/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result) as run_mock:
            result = get_git_remote_id("/project")
            assert result == "owner-repo"
            run_mock.assert_called_once_with(
                ["git", "-C", "/project", "remote", "get-url", "origin"],
                capture_output=True,
                text=True,
                timeout=2,
            )

    def test_ssh_format_without_git_suffix(self):
        """SSH format without .git suffix."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "git@github.com:owner/repo\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_https_format_github(self):
        """HTTPS format: https://github.com/owner/repo.git -> owner-repo"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "https://github.com/owner/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_https_format_without_git_suffix(self):
        """HTTPS format without .git suffix."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "https://github.com/owner/repo\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_https_with_username(self):
        """HTTPS format with username: https://user@github.com/owner/repo.git"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "https://username@github.com/owner/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_custom_domain_ssh(self):
        """SSH with custom domain: git@gitlab.example.com:owner/repo.git"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "git@gitlab.example.com:owner/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_custom_domain_https(self):
        """HTTPS with custom domain: https://gitlab.example.com/owner/repo.git"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "https://gitlab.example.com/owner/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "owner-repo"

    def test_nested_paths_returns_last_two_components(self):
        """Nested paths: git@github.com:org/team/repo.git -> team-repo"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "git@github.com:org/team/repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "team-repo"

    def test_single_component_path(self):
        """Single component: git@github.com:repo.git -> repo"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "git@github.com:repo.git\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result == "repo"

    def test_returns_none_on_git_error(self):
        """Returns None when git command fails."""
        mock_result = MagicMock()
        mock_result.returncode = 128

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result is None

    def test_returns_none_on_empty_url(self):
        """Returns None when git remote URL is empty."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "\n"

        with patch("bank_utils.subprocess.run", return_value=mock_result):
            result = get_git_remote_id("/project")
            assert result is None

    def test_returns_none_on_timeout(self):
        """Returns None when git command times out."""
        with patch(
            "bank_utils.subprocess.run", side_effect=subprocess.TimeoutExpired("git", 2)
        ):
            result = get_git_remote_id("/project")
            assert result is None

    def test_returns_none_when_git_not_installed(self):
        """Returns None when git is not installed."""
        with patch("bank_utils.subprocess.run", side_effect=FileNotFoundError()):
            result = get_git_remote_id("/project")
            assert result is None


class TestGetPathBasedId:
    """Tests for get_path_based_id() function."""

    def test_normal_path_with_multiple_components(self):
        """/home/user/code/myapp -> code-myapp"""
        result = get_path_based_id("/home/user/code/myapp")
        assert result == "code-myapp"

    def test_deep_nested_path(self):
        """Deep nested path uses last 2 components."""
        result = get_path_based_id("/a/b/c/d/e/f/g")
        assert result == "f-g"

    def test_root_level_path(self):
        """Root-level path: /tmp -> /-tmp (/ and tmp are the 2 parts)"""
        result = get_path_based_id("/tmp")
        assert result == "/-tmp"

    def test_two_component_path(self):
        """Two components: /projects/demo -> projects-demo"""
        result = get_path_based_id("/projects/demo")
        assert result == "projects-demo"

    def test_path_with_trailing_slash(self):
        """Trailing slashes are handled."""
        # Path normalizes this
        result = get_path_based_id("/home/user/project/")
        assert result == "user-project"

    def test_relative_path(self):
        """Relative paths are handled."""
        result = get_path_based_id("foo/bar")
        assert result == "foo-bar"


class TestGetBankId:
    """Tests for get_bank_id() function."""

    def test_git_based_id_preferred(self):
        """Git-based ID is used when available."""
        with patch("bank_utils.get_project_dir", return_value="/home/user/repo"):
            with patch("bank_utils.get_git_remote_id", return_value="owner-repo"):
                result = get_bank_id()
                assert result == "claude-code--owner-repo"

    def test_path_based_fallback(self):
        """Falls back to path-based ID when git unavailable."""
        with patch("bank_utils.get_project_dir", return_value="/home/user/code/myapp"):
            with patch("bank_utils.get_git_remote_id", return_value=None):
                result = get_bank_id()
                assert result == "claude-code--code-myapp"

    def test_default_fallback_on_empty_project_dir(self):
        """Returns default when project directory is empty."""
        with patch("bank_utils.get_project_dir", return_value=""):
            result = get_bank_id()
            assert result == "claude-code--default"

    def test_default_fallback_on_project_detection_exception(self):
        """Returns default when project detection raises exception."""
        with patch("bank_utils.get_project_dir", side_effect=Exception("error")):
            result = get_bank_id()
            assert result == "claude-code--default"

    def test_prefix_added(self):
        """Bank ID always has 'claude-code--' prefix."""
        with patch("bank_utils.get_project_dir", return_value="/tmp"):
            with patch("bank_utils.get_git_remote_id", return_value=None):
                result = get_bank_id()
                assert result.startswith("claude-code--")

    def test_returns_lowercase(self):
        """Bank ID is always lowercase."""
        with patch("bank_utils.get_project_dir", return_value="/Home/User/MyRepo"):
            with patch("bank_utils.get_git_remote_id", return_value="Owner-REPO"):
                result = get_bank_id()
                assert result == "claude-code--owner-repo"
                assert result == result.lower()

    def test_debug_callback_receives_messages(self):
        """Debug callback is called with log messages."""
        messages = []

        def capture_debug(msg):
            messages.append(msg)

        with patch("bank_utils.get_project_dir", return_value="/home/user/project"):
            with patch("bank_utils.get_git_remote_id", return_value="owner-repo"):
                get_bank_id(debug_callback=capture_debug)

        assert len(messages) > 0
        assert any("project" in msg.lower() for msg in messages)

    def test_debug_callback_none_is_safe(self):
        """None debug_callback doesn't cause errors."""
        with patch("bank_utils.get_project_dir", return_value="/tmp"):
            with patch("bank_utils.get_git_remote_id", return_value=None):
                result = get_bank_id(debug_callback=None)
                assert result is not None


class TestIntegration:
    """Integration tests combining multiple functions."""

    def test_full_git_flow(self):
        """Test complete flow with git repo detection."""
        git_root_result = MagicMock()
        git_root_result.returncode = 0
        git_root_result.stdout = "/home/user/my-project\n"

        git_remote_result = MagicMock()
        git_remote_result.returncode = 0
        git_remote_result.stdout = "git@github.com:myorg/my-project.git\n"

        def mock_run(cmd, **_kwargs):
            _ = _kwargs
            if "rev-parse" in cmd:
                return git_root_result
            elif "remote" in cmd:
                return git_remote_result
            return MagicMock(returncode=1)

        with patch("bank_utils.subprocess.run", side_effect=mock_run):
            result = get_bank_id()
            assert result == "claude-code--myorg-my-project"

    def test_full_path_fallback_flow(self):
        """Test complete flow falling back to path-based ID."""
        # Git root succeeds but remote fails
        git_root_result = MagicMock()
        git_root_result.returncode = 0
        git_root_result.stdout = "/home/user/code/localproject\n"

        git_remote_result = MagicMock()
        git_remote_result.returncode = 128  # No remote

        def mock_run(cmd, **_kwargs):
            _ = _kwargs
            if "rev-parse" in cmd:
                return git_root_result
            elif "remote" in cmd:
                return git_remote_result
            return MagicMock(returncode=1)

        with patch("bank_utils.subprocess.run", side_effect=mock_run):
            result = get_bank_id()
            assert result == "claude-code--code-localproject"

    def test_no_git_at_all_flow(self):
        """Test complete flow when git is not available."""
        with patch("bank_utils.subprocess.run", side_effect=FileNotFoundError()):
            with patch("bank_utils.os.getcwd", return_value="/projects/myapp"):
                result = get_bank_id()
                assert result == "claude-code--projects-myapp"
