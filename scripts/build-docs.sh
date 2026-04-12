#!/bin/bash
# Generates DocC documentation for SpooktacularKit.
#
# Usage:
#   ./scripts/build-docs.sh              Generate docs (archive)
#   ./scripts/build-docs.sh --serve      Generate + preview at localhost:8080
#   ./scripts/build-docs.sh --static     Generate for GitHub Pages (into docs/api/)
#
# The --static flag writes to docs/api/ so DocC coexists with
# the marketing site at docs/index.html. GitHub Pages serves both.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ "${1:-}" == "--static" ]]; then
    echo "Generating static documentation into docs/api/..."
    rm -rf docs/api
    swift package --allow-writing-to-directory ./docs/api \
        generate-documentation \
        --target SpooktacularKit \
        --output-path ./docs/api \
        --transform-for-static-hosting \
        --hosting-base-path spooktacular/api
    echo "✓ Static docs generated at docs/api/"
    echo "  Live at: https://spooktacular.app/api/documentation/spooktacularkit/"

elif [[ "${1:-}" == "--serve" ]]; then
    echo "Building and previewing documentation..."
    swift package --disable-sandbox \
        preview-documentation \
        --target SpooktacularKit

else
    echo "Generating documentation..."
    swift package \
        generate-documentation \
        --target SpooktacularKit
    echo "✓ Documentation generated."
    echo "  Run with --serve to preview, or --static for GitHub Pages."
fi
