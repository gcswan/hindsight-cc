#!/usr/bin/env python3
"""Integration tests for the developer/CLI scripts (search-memories, reflect).

These scripts are run as subprocesses under the *system* python3 (bare
`python3`, no venv) to prove they work on the stdlib-only interpreter the plugin
ships with. We cannot monkeypatch `hindsight_api` for a subprocess: when the
script runs as `python3 /abs/scripts/foo.py`, its own dir is sys.path[0] and
holds the *real* hindsight_api.py, which shadows any stub elsewhere on the path.
So, like test_hooks.py, we fake the network with a tiny loopback http.server and
point HINDSIGHT_BASE_URL at it, exercising the real hindsight_api code path.

The "server down" case needs no stub: we simply omit HINDSIGHT_BASE_URL so the
default localhost:8888 (nothing listening) makes the underlying call soft-fail.
"""

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))


class _StubHandler(BaseHTTPRequestHandler):
    """Serves configurable /recall and /reflect payloads; 200 for everything."""

    recall_results = []  # type: list
    reflect_payload = {}  # type: dict

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
        elif self.path.endswith("/reflect"):
            payload = type(self).reflect_payload
        else:
            payload = {"ok": True}
        self.wfile.write(json.dumps(payload).encode("utf-8"))


@pytest.fixture
def stub_server():
    """Start a loopback HTTP stub; yields (base_url, set_recall, set_reflect).

    Skips cleanly when the environment forbids binding a local socket (e.g. a
    command sandbox), consistent with test_hooks.py.
    """
    try:
        server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    except (PermissionError, OSError) as e:
        pytest.skip(f"cannot bind loopback socket in this environment: {e}")
    host, port = server.server_address
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def set_recall(results):
        _StubHandler.recall_results = results

    def set_reflect(payload):
        _StubHandler.reflect_payload = payload

    set_recall([])
    set_reflect({})
    try:
        yield f"http://{host}:{port}", set_recall, set_reflect
    finally:
        server.shutdown()
        server.server_close()


def _run(script_name, argv, base_url=None):
    """Run a CLI script under bare python3 with argv. Returns the proc."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    if base_url is not None:
        env["HINDSIGHT_BASE_URL"] = base_url
    return subprocess.run(
        ["python3", str(SCRIPTS_DIR / script_name), *argv],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


class TestSearchMemories:
    def test_prints_formatted_memories(self, stub_server):
        base_url, set_recall, _ = stub_server
        set_recall([{"text": "A"}, {"text": "B"}])
        proc = _run("search-memories.py", ["what", "did", "we", "decide"], base_url)
        assert proc.returncode == 0, proc.stderr
        assert "Found 2 relevant memories:" in proc.stdout
        assert "--- Memory 1 ---" in proc.stdout
        assert "A" in proc.stdout
        assert "--- Memory 2 ---" in proc.stdout
        assert "B" in proc.stdout

    def test_no_results_message(self, stub_server):
        base_url, set_recall, _ = stub_server
        set_recall([])
        proc = _run("search-memories.py", ["anything"], base_url)
        assert proc.returncode == 0, proc.stderr
        assert "No relevant memories found." in proc.stdout

    def test_empty_query_shows_usage_and_exits_1(self):
        proc = _run("search-memories.py", [])
        assert proc.returncode == 1
        assert "Usage: search-memories.py" in proc.stdout

    def test_server_down_reports_no_results(self):
        # No HINDSIGHT_BASE_URL -> default localhost:8888, nothing listening;
        # recall soft-fails to [] so the script reports no results, exit 0.
        proc = _run("search-memories.py", ["query"])
        assert proc.returncode == 0, proc.stderr
        assert "No relevant memories found." in proc.stdout


class TestReflect:
    def test_prints_text(self, stub_server):
        base_url, _, set_reflect = stub_server
        set_reflect({"text": "answer"})
        proc = _run("reflect.py", ["Should I use REST?"], base_url)
        assert proc.returncode == 0, proc.stderr
        assert "answer" in proc.stdout

    def test_prints_structured_output_when_present(self, stub_server):
        base_url, _, set_reflect = stub_server
        set_reflect({"text": "answer", "structured_output": {"choice": "REST"}})
        proc = _run("reflect.py", ["Which API?"], base_url)
        assert proc.returncode == 0, proc.stderr
        assert "answer" in proc.stdout
        assert "Structured Output" in proc.stdout
        assert '"choice": "REST"' in proc.stdout

    def test_no_structured_block_when_absent_or_null(self, stub_server):
        base_url, _, set_reflect = stub_server
        set_reflect({"text": "answer", "structured_output": None})
        proc = _run("reflect.py", ["q"], base_url)
        assert proc.returncode == 0, proc.stderr
        assert "Structured Output" not in proc.stdout

    def test_server_down_soft_fails_no_nonzero_exit(self):
        # reflect() returns None; script prints an error to stderr but exits 0.
        proc = _run("reflect.py", ["q"])
        assert proc.returncode == 0, proc.stderr
        assert "Error reflecting" in proc.stderr

    def test_invalid_response_schema_exits_1(self):
        proc = _run("reflect.py", ["q", "--response-schema", "{not json"])
        assert proc.returncode == 1
        assert "Invalid JSON in --response-schema" in proc.stderr

    def test_passes_args_through(self, stub_server):
        # Smoke test that the full argparse interface still parses.
        base_url, _, set_reflect = stub_server
        set_reflect({"text": "ok"})
        proc = _run(
            "reflect.py",
            ["q", "--budget", "high", "--context", "ctx", "--max-tokens", "100"],
            base_url,
        )
        assert proc.returncode == 0, proc.stderr
        assert "ok" in proc.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
