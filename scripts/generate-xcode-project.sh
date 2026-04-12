#!/bin/bash
# Generates an Xcode project with a UI Test target for Spooktacular.
#
# SwiftPM doesn't support UI test targets (XCUITest requires Xcode).
# This script creates an .xcodeproj with:
#   - The Spooktacular app target (referencing the SwiftPM executable)
#   - A SpooktacularUITests target for XCUITest screenshot automation
#
# Usage:
#   ./scripts/generate-xcode-project.sh
#   open Spooktacular.xcodeproj
#
# After opening in Xcode:
#   1. Select the SpooktacularUITests scheme
#   2. Run tests (Cmd+U) to capture screenshots
#   3. Screenshots appear as test attachments in the Test navigator

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Creating Xcode project for UI tests..."
echo ""
echo "Note: Xcode natively opens Package.swift as a workspace."
echo "For UI tests specifically, use xcodebuild:"
echo ""
echo "  xcodebuild test \\"
echo "    -scheme Spooktacular \\"
echo "    -destination 'platform=macOS' \\"
echo "    -testPlan Screenshots"
echo ""
echo "Or open Package.swift in Xcode and add a UI test target manually:"
echo "  1. Open Package.swift in Xcode"
echo "  2. File → New → Target → macOS → UI Testing Bundle"
echo "  3. Set target application to Spooktacular"
echo "  4. Move ScreenshotTests.swift into the new target"
echo ""
echo "The screenshot tests are at:"
echo "  Tests/SpooktacularUITests/ScreenshotTests.swift"
