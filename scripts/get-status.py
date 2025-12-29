#!/usr/bin/env python3
import os
import subprocess
import urllib.request


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    bank_id = "claude-code--" + project_dir.lstrip("/").replace("/", "-").lower() if project_dir else "unknown"

    print(f"Project directory: {project_dir}")
    print(f"Memory bank ID: {bank_id}")
    print()

    # Check Docker container
    try:
        result = subprocess.run(
            ["docker", "ps", "-f", "name=hindsight-2020", "--format", "{{.Status}}"],
            capture_output=True, text=True, timeout=5
        )
        if result.stdout.strip():
            print(f"Hindsight container: {result.stdout.strip()}")
        else:
            print("Hindsight container: Not running")
    except Exception as e:
        print(f"Docker check failed: {e}")

    # Check server health
    try:
        with urllib.request.urlopen("http://localhost:8888/health", timeout=2) as response:
            print(f"Hindsight server: Healthy (HTTP {response.status})")
    except Exception as e:
        print(f"Hindsight server: Unavailable ({e})")


if __name__ == "__main__":
    main()
