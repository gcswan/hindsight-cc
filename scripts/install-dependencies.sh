#!/bin/bash

set -e

# Script works from scripts/ directory where venv lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Debug helper - only outputs if HINDSIGHT_DEBUG is set
debug() {
    if [[ "${HINDSIGHT_DEBUG:-}" =~ ^(1|true|yes)$ ]]; then
        echo "[hindsight-cc:install-dependencies] $*" >&2
    fi
}

soft_fail() {
    debug "$*"
    exit 0
}

# Quick check: Is everything already set up?
if [ -x ".venv/bin/python3" ] && \
   .venv/bin/python3 -c "import hindsight_client" 2>/dev/null; then
    debug "Dependencies already installed, skipping setup"
    exit 0
fi

debug "Setting up hindsight-cc plugin..."

# Check Python version (requires 3.10+)
python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
if [[ -z "$python_version" ]]; then
    soft_fail "python3 not found"
fi

major=$(echo "$python_version" | cut -d. -f1)
minor=$(echo "$python_version" | cut -d. -f2)
if [[ "$major" -lt 3 ]] || [[ "$major" -eq 3 && "$minor" -lt 10 ]]; then
    soft_fail "Python 3.10+ required (found $python_version)"
fi
debug "Python version: $python_version"

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    debug "Creating virtual environment..."
    if ! python3 -m venv .venv; then
        soft_fail "Failed to create virtual environment; skipping setup"
    fi
fi

# Install dependencies
debug "Installing Python dependencies..."
if ! .venv/bin/pip install --upgrade pip -q; then
    soft_fail "Failed to upgrade pip; skipping setup"
fi
if ! .venv/bin/pip install -r requirements.txt -q; then
    soft_fail "Failed to install requirements; skipping setup"
fi

# Make scripts executable
chmod +x *.sh *.py 2>/dev/null || true

