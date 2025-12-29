#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Setting up 2020 plugin..."

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

# Install dependencies
echo "Installing Python dependencies..."
.venv/bin/pip install --upgrade pip -q
.venv/bin/pip install -r requirements.txt -q

# Make scripts executable
chmod +x scripts/*.sh scripts/*.py

# Symlink to Claude plugins directory
PLUGINS_DIR="$HOME/.claude/plugins"
mkdir -p "$PLUGINS_DIR"

if [ -L "$PLUGINS_DIR/2020" ]; then
    rm "$PLUGINS_DIR/2020"
elif [ -d "$PLUGINS_DIR/2020" ]; then
    echo "Warning: $PLUGINS_DIR/2020 exists and is not a symlink. Remove it manually if needed."
fi

ln -sf "$SCRIPT_DIR" "$PLUGINS_DIR/2020"

echo ""
echo "Done! Plugin installed to ~/.claude/plugins/2020"
echo ""
echo "Make sure HINDSIGHT_API_LLM_API_KEY is set in your environment."
