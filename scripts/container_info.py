#!/usr/bin/env python3
"""Read-only facts about the Hindsight Docker container, for the status command.

Stdlib only. Every Docker call is time-bounded and soft-fails (returns None), so
a missing docker CLI, a stopped daemon, or a missing container never raises.
"""

import json
import subprocess
from dataclasses import dataclass
from typing import List, Optional

CONTAINER_NAME = "hindsight"
DOCKER_TIMEOUT_SECONDS = 5

# `docker info` {{.Architecture}} values -> image `Architecture` values.
DAEMON_ARCH_TO_IMAGE_ARCH = {
    "aarch64": "arm64",
    "arm64": "arm64",
    "x86_64": "amd64",
    "amd64": "amd64",
}


@dataclass(frozen=True)
class ContainerInfo:
    name: str
    state: str  # "running", "exited", ...
    health: Optional[str]  # "healthy", "unhealthy", "starting", or None
    restart_count: int
    image_ref: str  # the image reference the container was created from
    image_arch: Optional[str]  # "arm64" / "amd64", None if unknown
    daemon_arch: Optional[str]  # same vocabulary, None if unknown
    memory_limit_bytes: int  # 0 means no limit
    memory_usage: Optional[str]  # `docker stats` text, e.g. "1.2GiB / 4GiB"


def _docker(*args: str) -> Optional[str]:
    """Run `docker <args>`; return stripped stdout, or None on any failure."""
    try:
        result = subprocess.run(
            ["docker", *args],
            capture_output=True,
            text=True,
            timeout=DOCKER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _inspect_json(*args: str) -> Optional[dict]:
    """Run a `docker ... inspect` and return the first JSON object, or None."""
    raw = _docker(*args)
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if isinstance(data, list) and data and isinstance(data[0], dict):
        return data[0]
    return None


def collect(name: str, daemon_arch: Optional[str]) -> Optional[ContainerInfo]:
    """Facts about container `name`, or None if it does not exist."""
    container = _inspect_json("inspect", name)
    if container is None:
        return None

    state = container.get("State") or {}
    health = (state.get("Health") or {}).get("Status")
    image = _inspect_json("image", "inspect", container.get("Image") or "")
    image_arch = (image or {}).get("Architecture")
    usage = None
    if state.get("Running"):
        usage = _docker("stats", "--no-stream", "--format", "{{.MemUsage}}", name)

    return ContainerInfo(
        name=name,
        state=state.get("Status") or "unknown",
        health=health,
        restart_count=int(container.get("RestartCount") or 0),
        image_ref=(container.get("Config") or {}).get("Image") or "unknown",
        image_arch=image_arch,
        daemon_arch=daemon_arch,
        memory_limit_bytes=int((container.get("HostConfig") or {}).get("Memory") or 0),
        memory_usage=usage or None,
    )


def _format_bytes(count: int) -> str:
    return f"{count / 2**30:.1f}GiB"


def format_lines(info: ContainerInfo) -> List[str]:
    """Human-readable status lines, with an EMULATED warning on arch mismatch."""
    status = info.state if not info.health else f"{info.state}, {info.health}"
    limit = _format_bytes(info.memory_limit_bytes) if info.memory_limit_bytes else "no limit"
    lines = [
        f"Container: {info.name} ({status}), restarts: {info.restart_count}",
        f"Image: {info.image_ref} ({info.image_arch or 'unknown'}) on a "
        f"{info.daemon_arch or 'unknown'} Docker daemon",
        f"Memory: {info.memory_usage or 'n/a'} (limit: {limit})",
    ]
    if info.image_arch and info.daemon_arch and info.image_arch != info.daemon_arch:
        lines.append(
            f"EMULATED: the container image is {info.image_arch} but the Docker daemon is "
            f"{info.daemon_arch}, so it runs under emulation (slower, more memory). "
            "Fix: run ensure-hindsight.sh recreate"
        )
    return lines


def describe_container(name: str = CONTAINER_NAME) -> List[str]:
    """Status lines for container `name`; never raises."""
    daemon_raw = _docker("info", "--format", "{{.Architecture}}")
    if daemon_raw is None:
        return ["Container: unknown (docker is not available)"]
    info = collect(name, DAEMON_ARCH_TO_IMAGE_ARCH.get(daemon_raw))
    if info is None:
        return [f"Container: '{name}' not found"]
    return format_lines(info)
