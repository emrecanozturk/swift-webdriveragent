#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_docs=(
  README.md
  docs/ARCHITECTURE.md
  docs/API_REFERENCE.md
  docs/BUILD_AND_SIGNING.md
  docs/COMPATIBILITY.md
  docs/FEATURE_MATRIX.md
  docs/OPERATIONS.md
  docs/SECURITY_MODEL.md
  docs/ANALYSIS.md
  docs/wiki/Home.md
  docs/wiki/_Sidebar.md
  docs/wiki/_Footer.md
)

for path in "${required_docs[@]}"; do
  if [ ! -s "$path" ]; then
    echo "Missing or empty doc: $path" >&2
    exit 1
  fi
done

if rg -n 'TODO|FIXME|/Users/' README.md docs .github Config examples; then
  echo "Documentation contains TODO/FIXME/local path residue." >&2
  exit 1
fi

echo "Documentation checks passed."
