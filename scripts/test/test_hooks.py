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

import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))


class _StubHandler(BaseHTTPRequestHandler):
    """Returns a configurable recall payload; accepts everything else as 200."""

    recall_results = []  # type: list

    def log_message(self, *args):  # silence stderr noise during tests
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)

    def do_GET(self):
        self._read_body()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        self._read_body()
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
    """Start a loopback HTTP stub; yields (base_url, set_recall_results)."""
    server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    host, port = server.server_address
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def set_recall_results(results):
        _StubHandler.recall_results = results

    set_recall_results([])
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

    def test_missing_transcript_path_exits_zero(self):
        proc = _run_hook("retain-transcript.py", {})
        assert proc.returncode == 0
        assert proc.stdout == ""

    def test_malformed_stdin_does_not_crash(self):
        proc = _run_hook("retain-transcript.py", "garbage")
        assert proc.returncode == 0
        assert proc.stdout == ""


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
