#!/usr/bin/env python3
"""Unit tests for hindsight_api.py (stdlib-only REST client)."""

import json
import sys
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

import hindsight_api


def _mock_response(payload, status=200):
    """Build a urlopen() return value usable as a `with ... as resp:` context manager."""
    resp = MagicMock()
    resp.read.return_value = json.dumps(payload).encode("utf-8")
    resp.status = status
    resp.getcode.return_value = status
    cm = MagicMock()
    cm.__enter__.return_value = resp
    cm.__exit__.return_value = False
    return cm


def _request_body(mock_urlopen):
    """Extract and JSON-parse the body of the Request passed to urlopen."""
    req = mock_urlopen.call_args.args[0]
    return json.loads(req.data)


def _request_url(mock_urlopen):
    """Return the full URL of the Request passed to urlopen."""
    return mock_urlopen.call_args.args[0].full_url


class TestRetain:
    def test_url_and_default_body(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"ok": True}),
        ) as m:
            result = hindsight_api.retain("claude-code--demo", "hello")

        assert result == {"ok": True}
        assert (
            _request_url(m)
            == "http://localhost:8888/v1/default/banks/claude-code--demo/memories"
        )
        body = _request_body(m)
        # The JSON key must be literally "async" (not "async_").
        assert "async" in body
        assert body["async"] is True
        assert "async_" not in body
        assert body["items"][0]["content"] == "hello"
        # context omitted when not provided
        assert "context" not in body["items"][0]

    def test_context_included_only_when_given(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({}),
        ) as m:
            hindsight_api.retain("bank", "c", context="ctx", async_=False)
        body = _request_body(m)
        assert body["items"][0]["context"] == "ctx"
        assert body["async"] is False

    def test_content_type_header_and_method(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({}),
        ) as m:
            hindsight_api.retain("bank", "c")
        req = m.call_args.args[0]
        assert req.get_method() == "POST"
        assert req.headers.get("Content-type") == "application/json"

    def test_soft_fail_returns_none(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=OSError("boom"),
        ):
            assert hindsight_api.retain("bank", "c") is None


class TestRetainDetached:
    """Tests for the fire-and-forget retain helper.

    We never let os.fork return 0 here: that would send the test process down
    the child path into os._exit(0) and kill pytest. We only exercise the
    parent path (fork returns a fake pid) and the fork-unavailable fallback.
    """

    def test_parent_path_does_not_retain_in_process(self):
        # fork returns a nonzero pid -> we are the "parent" -> return at once,
        # without performing the retain in this process.
        with patch("hindsight_api.os.fork", return_value=12345):
            with patch("hindsight_api.retain") as mock_retain:
                assert hindsight_api.retain_detached("bank", "content") is None
        mock_retain.assert_not_called()

    def test_fork_unavailable_falls_back_to_synchronous_retain(self):
        with patch("hindsight_api.os.fork", side_effect=OSError("no fork")):
            with patch("hindsight_api.retain", return_value={"ok": True}) as mock_retain:
                assert hindsight_api.retain_detached("bank", "content") is None
        mock_retain.assert_called_once()
        args, kwargs = mock_retain.call_args
        assert args[0] == "bank"
        assert args[1] == "content"
        assert kwargs.get("timeout") == 2.0

    def test_fork_unavailable_and_sync_retain_raising_does_not_propagate(self):
        with patch("hindsight_api.os.fork", side_effect=OSError("no fork")):
            with patch("hindsight_api.retain", side_effect=RuntimeError("boom")):
                # Must soft-fail: no exception escapes.
                assert hindsight_api.retain_detached("bank", "content") is None

    def test_context_forwarded_in_fallback(self):
        with patch("hindsight_api.os.fork", side_effect=OSError("no fork")):
            with patch("hindsight_api.retain") as mock_retain:
                hindsight_api.retain_detached("bank", "c", context="ctx")
        _, kwargs = mock_retain.call_args
        assert kwargs.get("context") == "ctx"


class TestRecall:
    def test_url_and_body_and_results(self):
        payload = {"results": [{"id": "1", "text": "memory one"}], "extra": 1}
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response(payload),
        ) as m:
            results = hindsight_api.recall("bank", "what happened")

        assert (
            _request_url(m)
            == "http://localhost:8888/v1/default/banks/bank/memories/recall"
        )
        body = _request_body(m)
        assert body["query"] == "what happened"
        assert body["budget"] == "low"
        assert body["max_tokens"] == 2048
        assert results == [{"id": "1", "text": "memory one"}]

    def test_custom_budget_and_max_tokens(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"results": []}),
        ) as m:
            hindsight_api.recall("bank", "q", budget="high", max_tokens=100)
        body = _request_body(m)
        assert body["budget"] == "high"
        assert body["max_tokens"] == 100

    def test_returns_empty_list_on_failure(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=urllib.error.URLError("down"),
        ):
            assert hindsight_api.recall("bank", "q") == []

    def test_returns_empty_list_when_no_results_field(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"other": 1}),
        ):
            assert hindsight_api.recall("bank", "q") == []

    def test_default_timeout_is_2_5s_hard_bound(self):
        """recall() forwards its 2.5s default timeout to urlopen (keyword arg)."""
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"results": []}),
        ) as m:
            hindsight_api.recall("bank", "q")
        # _post_json calls urlopen(req, timeout=timeout) -> keyword arg.
        assert m.call_args.kwargs["timeout"] == 2.5


class TestReflect:
    def test_url_and_optional_fields_omitted(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"text": "an answer", "based_on": []}),
        ) as m:
            result = hindsight_api.reflect("bank", "why")

        assert (
            _request_url(m) == "http://localhost:8888/v1/default/banks/bank/reflect"
        )
        body = _request_body(m)
        assert body == {"query": "why", "budget": "low"}
        assert "context" not in body
        assert "max_tokens" not in body
        assert "response_schema" not in body
        assert result["text"] == "an answer"

    def test_optional_fields_included_when_given(self):
        schema = {"type": "object"}
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({"text": "x"}),
        ) as m:
            hindsight_api.reflect(
                "bank",
                "q",
                context="ctx",
                max_tokens=500,
                response_schema=schema,
            )
        body = _request_body(m)
        assert body["context"] == "ctx"
        assert body["max_tokens"] == 500
        assert body["response_schema"] == schema

    def test_returns_none_on_failure(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=TimeoutError(),
        ):
            assert hindsight_api.reflect("bank", "q") is None


class TestHealth:
    def test_returns_true_on_2xx(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({}, status=200),
        ) as m:
            assert hindsight_api.health() is True
        assert _request_url(m) == "http://localhost:8888/health"

    def test_returns_false_on_non_2xx(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            return_value=_mock_response({}, status=503),
        ):
            assert hindsight_api.health() is False

    def test_returns_false_on_http_error(self):
        # urllib raises HTTPError for status >= 400 rather than returning it.
        err = urllib.error.HTTPError(
            url="http://localhost:8888/health",
            code=503,
            msg="Service Unavailable",
            hdrs=None,
            fp=None,
        )
        with patch("hindsight_api.urllib.request.urlopen", side_effect=err):
            assert hindsight_api.health() is False

    def test_returns_false_when_urlopen_raises(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=OSError("connection refused"),
        ):
            assert hindsight_api.health() is False


class TestSoftFailNeverPropagates:
    """Prove no function lets an exception escape, returning its empty value."""

    def test_all_functions_soft_fail(self):
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=ValueError("unexpected"),
        ):
            assert hindsight_api.retain("bank", "c") is None
            assert hindsight_api.recall("bank", "q") == []
            assert hindsight_api.reflect("bank", "q") is None
            assert hindsight_api.health() is False

    def test_non_string_bank_id_does_not_raise(self):
        """A malformed (non-str) bank_id must soft-fail, not raise out of the call."""
        with patch(
            "hindsight_api.urllib.request.urlopen",
            side_effect=OSError("down"),
        ):
            assert hindsight_api.retain(None, "c") is None
            assert hindsight_api.recall(None, "q") == []
            assert hindsight_api.reflect(None, "q") is None


class TestBaseUrlOverride:
    def test_env_override_is_honored(self):
        with patch.dict(
            hindsight_api.os.environ, {"HINDSIGHT_BASE_URL": "http://example.com:1234"}
        ):
            with patch(
                "hindsight_api.urllib.request.urlopen",
                return_value=_mock_response({"results": []}),
            ) as m:
                hindsight_api.recall("bank", "q")
            assert _request_url(m).startswith("http://example.com:1234/")

    def test_trailing_slash_is_stripped(self):
        with patch.dict(
            hindsight_api.os.environ, {"HINDSIGHT_BASE_URL": "http://example.com/"}
        ):
            with patch(
                "hindsight_api.urllib.request.urlopen",
                return_value=_mock_response({}),
            ) as m:
                hindsight_api.health()
            assert _request_url(m) == "http://example.com/health"
