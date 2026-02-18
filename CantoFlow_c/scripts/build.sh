#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${PROJECT_DIR}"

echo "Building CantoFlow_c..."
swift build -c release

echo ""
echo "Build complete!"
echo "Binary location: ${PROJECT_DIR}/.build/release/cantoflow"
echo ""
echo "Run with:"
echo "  .build/release/cantoflow --project-root /path/to/cantoflow"
