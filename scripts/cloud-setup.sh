#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 --version
git --version
if [[ -f "$repo_dir/CheckBot 首页/scripts/test-developer-toolkit.cjs" ]]; then
  node --version
fi
python3 "$repo_dir/scripts/cloud-check.py"
# No application services or third-party dependencies are needed on Linux.
# Apple SDK builds/tests and the xcrun-based Developer Tools suite require Mac.
