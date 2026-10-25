#!/bin/bash
set -euo pipefail
# Run through agent-storage so the real 10k/100k fixtures stay on the selected volume.
export MAXPLORER_SEARCH_PERFORMANCE=1
export MAXPLORER_TEST_FILTER=search
exec "$(dirname "$0")/test-file-operations.sh"
