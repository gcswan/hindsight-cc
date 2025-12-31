#!/bin/bash
#
# Manual Testing Script for 2020 Plugin
#
# This script provides interactive verification of the plugin's functionality.
# Debug mode is enabled automatically.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON="$PLUGIN_DIR/.venv/bin/python3"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== 2020 Plugin Manual Test ===${NC}"
echo ""

# Export debug mode
export HINDSIGHT_DEBUG=1

# Auto-detect bank ID using bank_utils (no CLAUDE_PROJECT_DIR needed)
BANK_ID=$("$PYTHON" -c "
import sys
sys.path.insert(0, '$PLUGIN_DIR/scripts')
from bank_utils import get_bank_id, get_project_dir
print(get_bank_id())
")

PROJECT_DIR=$("$PYTHON" -c "
import sys
sys.path.insert(0, '$PLUGIN_DIR/scripts')
from bank_utils import get_project_dir
print(get_project_dir())
")

echo -e "${YELLOW}Configuration:${NC}"
echo "  Project Dir: $PROJECT_DIR"
echo "  Bank ID: $BANK_ID"
echo ""

# Test 1: Check Hindsight status
echo -e "${BLUE}[1/5] Checking Hindsight Status${NC}"
if $PYTHON "$SCRIPT_DIR/get-status.py"; then
    echo ""
else
    echo -e "${RED}Status check failed${NC}"
    exit 1
fi

# Test 2: Ensure Hindsight is running
echo -e "${BLUE}[2/5] Ensuring Hindsight Server${NC}"
if "$SCRIPT_DIR/ensure-hindsight.sh"; then
    echo -e "${GREEN}Server is running${NC}"
else
    echo -e "${RED}Failed to start server${NC}"
    exit 1
fi
echo ""

# Test 3: Retain a test prompt
echo -e "${BLUE}[3/5] Retaining Test Prompt${NC}"
TEST_CONTENT="Manual test $(date +%s): The quick brown fox jumps over the lazy dog"
echo "{\"prompt\": \"$TEST_CONTENT\"}" | $PYTHON "$SCRIPT_DIR/retain-prompt.py"
echo -e "${GREEN}Prompt retained${NC}"
echo ""

# Wait for indexing
echo -e "${YELLOW}Waiting 3 seconds for indexing...${NC}"
sleep 3

# Test 4: Recall memories
echo -e "${BLUE}[4/5] Recalling Memories${NC}"
RECALL_RESULT=$(echo '{"prompt": "quick brown fox"}' | $PYTHON "$SCRIPT_DIR/inject-memories.py" 2>&1)
echo "$RECALL_RESULT"
if echo "$RECALL_RESULT" | grep -q "<hindsight-memories>"; then
    echo -e "${GREEN}Memories successfully injected!${NC}"
else
    echo -e "${YELLOW}No memories returned (may need more time to index)${NC}"
fi
echo ""

# Test 5: Search memories directly
echo -e "${BLUE}[5/5] Searching Memory Bank${NC}"
$PYTHON "$SCRIPT_DIR/search-memories.py" "quick brown fox"
echo ""

# Summary
echo -e "${BLUE}=== Test Complete ===${NC}"
echo ""
echo -e "${YELLOW}Verify in Hindsight UI:${NC} http://localhost:9999"
echo -e "${YELLOW}Look for bank:${NC} $BANK_ID"
