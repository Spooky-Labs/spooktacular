#!/bin/bash
# Generates DocC documentation for SpooktacularKit.
#
# Usage:
#   ./scripts/build-docs.sh              Generate docs
#   ./scripts/build-docs.sh --serve      Generate + preview at localhost:8080
#   ./scripts/build-docs.sh --static     Generate for static hosting (GitHub Pages)
#
# Output: .build/docs/SpooktacularKit.doccarchive

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ "${1:-}" == "--static" ]]; then
    echo "Generating static documentation..."
    swift package --allow-writing-to-directory ./docs \
        generate-documentation \
        --target SpooktacularKit \
        --output-path ./docs \
        --transform-for-static-hosting \
        --hosting-base-path SpooktacularKit
    echo "✓ Static docs generated at ./docs/"
    echo "  Deploy to GitHub Pages or any static host."

elif [[ "${1:-}" == "--serve" ]]; then
    echo "Building and previewing documentation..."
    swift package --disable-sandbox \
        preview-documentation \
        --target SpooktacularKit
    # This opens a local server at http://localhost:8080

else
    echo "Generating documentation..."
    swift package \
        generate-documentation \
        --target SpooktacularKit
    echo "✓ Documentation generated."
    echo "  Run with --serve to preview, or --static for GitHub Pages."
fi
