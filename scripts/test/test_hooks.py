#!/usr/bin/env python3
"""Integration tests for the three hook scripts and hooks.json.

The hook scripts are executed as subprocesses under the *system* python3 (bare
`python3`, no venv) to prove they run on the stdlib-only interpreter the plugin
ships with. Network is faked with a tiny loopback http.server so no live
Hindsight server (and no Docker) is needed: we point HINDSIGHT_BASE_URL at the
ephemeral stub. This exercises the real hindsight_api.recall / retain code path
end-to-end -- importantly, it avoids the sys.path trap where a stub
`hindsight_api` module could never shadow the real one (the script's own dir is
always sys.path[0]).
"""

import importlib.util
import io
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))


class _StubHandler(BaseHTTPRequestHandler):
    """Returns a configurable recall payload; accepts everything else as 200.

    Each received request is recorded as (path, parsed_json_body_or_None) on the
    class-level `received` list so tests can assert what reached the server. The
    list is reset per test by the stub_server fixture.
    """

    recall_results = []  # type: list
    received = []  # type: list

    def log_message(self, *args):  # silence stderr noise during tests
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            return self.rfile.read(length)
        return b""

    def _record(self, raw):
        try:
            body = json.loads(raw) if raw else None
        except Exception:
            body = None
        type(self).received.append((self.path, body))

    def do_GET(self):
        raw = self._read_body()
        self._record(raw)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        raw = self._read_body()
        self._record(raw)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if self.path.endswith("/recall"):
            payload = {"results": type(self).recall_results}
        else:
            payload = {"ok": True}
        self.wfile.write(json.dumps(payload).encode("utf-8"))


@pytest.fixture
def stub_server():
    """Start a loopback HTTP stub; yields (base_url, set_recall_results).

    Skips cleanly when the environment forbids binding a local socket (e.g. a
    command sandbox), so the suite stays green there instead of erroring.
    """
    try:
        server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    except (PermissionError, OSError) as e:
        pytest.skip(f"cannot bind loopback socket in this environment: {e}")
    host, port = server.server_address
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def set_recall_results(results):
        _StubHandler.recall_results = results

    set_recall_results([])
    _StubHandler.received = []  # reset recorded requests per test
    try:
        yield f"http://{host}:{port}", set_recall_results
    finally:
        server.shutdown()
        server.server_close()


def _run_hook(script_name, stdin_obj, base_url=None):
    """Run a hook script under bare python3, feeding JSON stdin. Returns proc."""
    env = {"PATH": _env_path()}
    if base_url is not None:
        env["HINDSIGHT_BASE_URL"] = base_url
    stdin_data = stdin_obj if isinstance(stdin_obj, str) else json.dumps(stdin_obj)
    return subprocess.run(
        ["python3", str(SCRIPTS_DIR / script_name)],
        input=stdin_data,
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def _env_path():
    import os

    return os.environ.get("PATH", "/usr/bin:/bin")


def _poll_received(predicate, timeout=5.0, interval=0.05):
    """Poll _StubHandler.received until predicate matches a request or timeout.

    Returns the matching (path, body) tuple, or None if it never arrives. Used
    to observe the ASYNCHRONOUS detached (forked) retain landing on the stub.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        for item in list(_StubHandler.received):
            if predicate(item):
                return item
        time.sleep(interval)
    return None


class TestInjectMemories:
    def test_prints_memory_block_when_results(self, stub_server):
        base_url, set_results = stub_server
        set_results([{"text": "mem A"}, {"text": "mem B"}])
        proc = _run_hook(
            "inject-memories.py", {"prompt": "what did we decide"}, base_url
        )
        assert proc.returncode == 0
        expected = "<hindsight-memories>\nmem A\nmem B\n</hindsight-memories>\n"
        assert proc.stdout == expected

    def test_prints_nothing_when_no_results(self, stub_server):
        base_url, set_results = stub_server
        set_results([])
        proc = _run_hook("inject-memories.py", {"prompt": "anything"}, base_url)
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_skips_results_missing_text(self, stub_server):
        base_url, set_results = stub_server
        set_results([{"text": "keep"}, {"id": "no-text"}, {"text": ""}])
        proc = _run_hook("inject-memories.py", {"prompt": "q"}, base_url)
        assert proc.returncode == 0
        assert proc.stdout == "<hindsight-memories>\nkeep\n</hindsight-memories>\n"

    def test_no_server_prints_nothing_and_exits_zero(self):
        # No HINDSIGHT_BASE_URL -> default localhost:8888, nothing listening.
        proc = _run_hook("inject-memories.py", {"prompt": "q"})
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_malformed_stdin_does_not_crash(self):
        proc = _run_hook("inject-memories.py", "not json at all")
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_empty_stdin_exits_zero(self):
        proc = _run_hook("inject-memories.py", "")
        assert proc.returncode == 0
        assert proc.stdout == ""


class TestRetainPrompt:
    def test_normal_input_exits_zero_no_stdout(self, stub_server):
        base_url, _ = stub_server
        proc = _run_hook("retain-prompt.py", {"prompt": "remember this"}, base_url)
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_list_prompt_parts(self, stub_server):
        base_url, _ = stub_server
        prompt = [{"type": "text", "text": "hello"}, {"type": "image"}]
        proc = _run_hook("retain-prompt.py", {"prompt": prompt}, base_url)
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_no_server_exits_zero(self):
        proc = _run_hook("retain-prompt.py", {"prompt": "x"})
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_malformed_stdin_does_not_crash(self):
        proc = _run_hook("retain-prompt.py", "}{ not json")
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_detached_retain_actually_reaches_server(self, stub_server):
        """C1: prove the fire-and-forget (forked) retain lands on the server.

        The retain runs in a detached os.fork() child, so it arrives
        asynchronously after the parent has already returned. We poll the stub's
        recorded requests until the POST to /memories shows up.
        """
        base_url, _ = stub_server
        proc = _run_hook(
            "retain-prompt.py", {"prompt": "remember THIS-token"}, base_url
        )
        # Parent must return promptly with empty stdout (detachment didn't block
        # and didn't pollute the injected-prompt channel).
        assert proc.returncode == 0
        assert proc.stdout == ""

        match = _poll_received(
            lambda item: item[0].endswith("/memories")
        )
        assert match is not None, "detached retain never reached the server"
        path, body = match
        assert path.endswith("/memories")
        assert body is not None
        assert body["items"][0]["content"] == "remember THIS-token"
        assert body["async"] is True
        # Path looks like /v1/default/banks/<bank>/memories with a real bank id.
        segments = path.strip("/").split("/")
        bank_segment = segments[segments.index("banks") + 1]
        assert bank_segment.startswith("claude-code--")


class TestRetainTranscript:
    def _write_transcript(self, tmp_path):
        path = tmp_path / "transcript.jsonl"
        lines = [
            {"message": {"role": "user", "content": "earlier"}},
            {"message": {"role": "assistant", "content": "reply"}},
            {"message": {"role": "user", "content": "the last question"}},
            {"message": {"role": "assistant", "content": [
                {"type": "text", "text": "the last answer"},
            ]}},
        ]
        path.write_text("\n".join(json.dumps(line) for line in lines))
        return path

    def test_normal_input_exits_zero_no_stdout(self, tmp_path, stub_server):
        base_url, _ = stub_server
        transcript = self._write_transcript(tmp_path)
        proc = _run_hook(
            "retain-transcript.py",
            {"transcript_path": str(transcript)},
            base_url,
        )
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_no_server_exits_zero(self, tmp_path):
        transcript = self._write_transcript(tmp_path)
        proc = _run_hook(
            "retain-transcript.py", {"transcript_path": str(transcript)}
        )
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_detached_retain_reaches_server_with_message_text(
        self, tmp_path, stub_server
    ):
        """C1: the transcript's message text lands on the server (async fork)."""
        base_url, _ = stub_server
        transcript = self._write_transcript(tmp_path)
        proc = _run_hook(
            "retain-transcript.py",
            {"transcript_path": str(transcript)},
            base_url,
        )
        assert proc.returncode == 0
        assert proc.stdout == ""

        match = _poll_received(lambda item: item[0].endswith("/memories"))
        assert match is not None, "detached retain never reached the server"
        path, body = match
        content = body["items"][0]["content"]
        # Transcript is sliced from the last user message onwards.
        assert "the last question" in content
        assert "the last answer" in content

    def test_missing_transcript_path_exits_zero(self):
        proc = _run_hook("retain-transcript.py", {})
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_malformed_stdin_does_not_crash(self):
        proc = _run_hook("retain-transcript.py", "garbage")
        assert proc.returncode == 0
        assert proc.stdout == ""


def _load_script_module(filename, mod_name):
    """Load a hyphenated script (e.g. inject-memories.py) via importlib."""
    path = SCRIPTS_DIR / filename
    spec = importlib.util.spec_from_file_location(mod_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestInjectMemoriesRecallArgs:
    """C2: inject-memories.py must call recall with timeout=2.5 and budget=low."""

    def test_main_passes_hard_timeout_and_low_budget(self, monkeypatch):
        inject = _load_script_module("inject-memories.py", "inject_under_test")

        recorded = {}

        def fake_recall(bank_id, query, **kwargs):
            recorded["bank_id"] = bank_id
            recorded["query"] = query
            recorded["kwargs"] = kwargs
            return []

        # The script calls hindsight_api.recall; both the script's module and
        # this test share the same imported hindsight_api object.
        monkeypatch.setattr(inject.hindsight_api, "recall", fake_recall)
        monkeypatch.setattr(
            sys, "stdin", io.StringIO(json.dumps({"prompt": "hello there"}))
        )

        inject.main()

        assert recorded["query"] == "hello there"
        assert recorded["kwargs"].get("timeout") == 2.5
        assert recorded["kwargs"].get("budget") == "low"


class TestHooksJson:
    @pytest.fixture
    def hooks(self):
        path = SCRIPTS_DIR.parent / "hooks" / "hooks.json"
        return json.loads(path.read_text()), path.read_text()

    def test_parses_as_json(self, hooks):
        data, _ = hooks
        assert "hooks" in data

    def test_session_start_only_ensure_hindsight(self, hooks):
        data, _ = hooks
        entries = data["hooks"]["SessionStart"]
        assert len(entries) == 1
        cmds = entries[0]["hooks"]
        assert len(cmds) == 1
        assert cmds[0]["command"].endswith("/scripts/ensure-hindsight.sh")
        assert "install-dependencies" not in cmds[0]["command"]

    def test_no_install_dependencies_in_session_start(self, hooks):
        _, raw = hooks
        # The install-dependencies hook entry must be gone from SessionStart.
        data = json.loads(raw)
        for entry in data["hooks"]["SessionStart"]:
            for h in entry["hooks"]:
                assert "install-dependencies" not in h["command"]

    def test_user_prompt_submit_order(self, hooks):
        data, _ = hooks
        entries = data["hooks"]["UserPromptSubmit"]
        assert len(entries) == 1
        cmds = entries[0]["hooks"]
        assert len(cmds) == 2
        assert cmds[0]["command"] == "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/retain-prompt.py"
        assert cmds[1]["command"] == "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/inject-memories.py"

    def test_stop_runs_retain_transcript(self, hooks):
        data, _ = hooks
        entries = data["hooks"]["Stop"]
        assert len(entries) == 1
        cmds = entries[0]["hooks"]
        assert len(cmds) == 1
        assert cmds[0]["command"] == "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/retain-transcript.py"

    def test_no_venv_anywhere(self, hooks):
        _, raw = hooks
        assert ".venv" not in raw

    def test_matcher_present_and_command_shape(self, hooks):
        data, _ = hooks
        for event in ("SessionStart", "UserPromptSubmit", "Stop"):
            for entry in data["hooks"][event]:
                assert entry["matcher"] == ""
                for h in entry["hooks"]:
                    assert h["type"] == "command"
                    assert isinstance(h["command"], str)
