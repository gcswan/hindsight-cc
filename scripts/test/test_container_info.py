#!/usr/bin/env python3
"""Unit tests for container_info: pure formatting plus Docker calls stubbed out."""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

sys.path.insert(0, str(Path(__file__).parent.parent))

import container_info  # noqa: E402
from container_info import ContainerInfo  # noqa: E402


def make_info(**overrides: Any) -> ContainerInfo:
    fields: Dict[str, Any] = dict(
        name="hindsight",
        state="running",
        health="healthy",
        restart_count=0,
        image_ref="ghcr.io/vectorize-io/hindsight:0.8.6",
        image_arch="arm64",
        daemon_arch="arm64",
        memory_limit_bytes=4 * 2**30,
        memory_usage="1.2GiB / 4GiB",
    )
    fields.update(overrides)
    return ContainerInfo(**fields)


def stub_docker(monkeypatch, responses):
    """Make container_info._docker answer from {args-tuple: stdout-or-None}."""
    calls = []

    def fake(*args):
        calls.append(args)
        return responses.get(args)

    monkeypatch.setattr(container_info, "_docker", fake)
    return calls


INSPECT = json.dumps(
    [
        {
            "Image": "sha256:abc",
            "RestartCount": 2,
            "State": {"Status": "running", "Running": True, "Health": {"Status": "healthy"}},
            "Config": {"Image": "ghcr.io/vectorize-io/hindsight:0.8.6"},
            "HostConfig": {"Memory": 4294967296},
        }
    ]
)
IMAGE_INSPECT = json.dumps([{"Architecture": "arm64"}])
INFO_ARGS = ("info", "--format", "{{.Architecture}}")


class TestFormatLines:
    def test_native_container_has_no_emulation_warning(self):
        lines = container_info.format_lines(make_info())
        assert lines[0] == "Container: hindsight (running, healthy), restarts: 0"
        assert lines[1] == (
            "Image: ghcr.io/vectorize-io/hindsight:0.8.6 (arm64) on a arm64 Docker daemon"
        )
        assert lines[2] == "Memory: 1.2GiB / 4GiB (limit: 4.0GiB)"
        assert not any(line.startswith("EMULATED") for line in lines)

    def test_architecture_mismatch_adds_emulated_line_naming_the_fix(self):
        lines = container_info.format_lines(make_info(image_arch="amd64"))
        emulated = [line for line in lines if line.startswith("EMULATED")]
        assert len(emulated) == 1
        assert "amd64" in emulated[0] and "arm64" in emulated[0]
        assert "ensure-hindsight.sh recreate" in emulated[0]

    def test_unknown_architecture_is_not_flagged_as_emulated(self):
        lines = container_info.format_lines(make_info(image_arch=None))
        assert "(unknown)" in lines[1]
        assert not any(line.startswith("EMULATED") for line in lines)

    def test_no_limit_and_no_health_and_no_usage(self):
        lines = container_info.format_lines(
            make_info(health=None, memory_limit_bytes=0, memory_usage=None, state="exited")
        )
        assert lines[0] == "Container: hindsight (exited), restarts: 0"
        assert lines[2] == "Memory: n/a (limit: no limit)"


class TestDescribeContainer:
    def test_docker_unavailable(self, monkeypatch):
        stub_docker(monkeypatch, {})
        assert container_info.describe_container() == [
            "Container: unknown (docker is not available)"
        ]

    def test_container_not_found(self, monkeypatch):
        stub_docker(monkeypatch, {INFO_ARGS: "aarch64"})
        assert container_info.describe_container() == ["Container: 'hindsight' not found"]

    def test_full_path_reports_native_container(self, monkeypatch):
        stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "aarch64",
                ("inspect", "hindsight"): INSPECT,
                ("image", "inspect", "sha256:abc"): IMAGE_INSPECT,
                ("stats", "--no-stream", "--format", "{{.MemUsage}}", "hindsight"): "1.2GiB / 4GiB",
            },
        )
        lines = container_info.describe_container()
        assert lines[0] == "Container: hindsight (running, healthy), restarts: 2"
        assert "(arm64) on a arm64 Docker daemon" in lines[1]
        assert lines[2] == "Memory: 1.2GiB / 4GiB (limit: 4.0GiB)"
        assert len(lines) == 3

    def test_full_path_flags_an_emulated_container(self, monkeypatch):
        stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "aarch64",
                ("inspect", "hindsight"): INSPECT,
                ("image", "inspect", "sha256:abc"): json.dumps([{"Architecture": "amd64"}]),
            },
        )
        lines = container_info.describe_container()
        assert lines[-1].startswith("EMULATED")

    def test_stopped_container_skips_the_stats_call(self, monkeypatch):
        stopped = json.dumps(
            [
                {
                    "Image": "sha256:abc",
                    "State": {"Status": "exited", "Running": False},
                    "Config": {"Image": "img"},
                    "HostConfig": {},
                }
            ]
        )
        calls = stub_docker(
            monkeypatch,
            {
                INFO_ARGS: "x86_64",
                ("inspect", "hindsight"): stopped,
                ("image", "inspect", "sha256:abc"): json.dumps([{"Architecture": "amd64"}]),
            },
        )
        lines = container_info.describe_container()
        assert lines[0] == "Container: hindsight (exited), restarts: 0"
        assert not any(call[0] == "stats" for call in calls)

    def test_garbage_inspect_output_is_treated_as_not_found(self, monkeypatch):
        stub_docker(monkeypatch, {INFO_ARGS: "aarch64", ("inspect", "hindsight"): "not json"})
        assert container_info.describe_container() == ["Container: 'hindsight' not found"]


class TestDockerWrapper:
    def test_missing_docker_binary_returns_none(self, monkeypatch):
        def boom(*_a, **_k):
            raise FileNotFoundError("docker")

        monkeypatch.setattr(container_info.subprocess, "run", boom)
        assert container_info._docker("info") is None

    def test_timeout_returns_none(self, monkeypatch):
        def slow(*_a, **_k):
            raise subprocess.TimeoutExpired(cmd="docker", timeout=5)

        monkeypatch.setattr(container_info.subprocess, "run", slow)
        assert container_info._docker("info") is None

    def test_nonzero_exit_returns_none(self, monkeypatch):
        done = subprocess.CompletedProcess(args=[], returncode=1, stdout="x", stderr="")
        monkeypatch.setattr(container_info.subprocess, "run", lambda *_a, **_k: done)
        assert container_info._docker("info") is None

    def test_success_returns_stripped_stdout(self, monkeypatch):
        done = subprocess.CompletedProcess(args=[], returncode=0, stdout=" aarch64\n", stderr="")
        monkeypatch.setattr(container_info.subprocess, "run", lambda *_a, **_k: done)
        assert container_info._docker("info") == "aarch64"
