#!/bin/bash
set -euo pipefail
# Run through agent-storage so the real 10k/100k fixtures stay on the selected volume.
# Measure the unchanged latency budgets with production-style optimization.
# The ordinary safety suite remains unoptimized for diagnostics.
export MAXPLORER_TEST_OPTIMIZED=1
export MAXPLORER_SEARCH_PERFORMANCE=1
export MAXPLORER_TEST_FILTER=search
exec "$(dirname "$0")/test-file-operations.sh"
