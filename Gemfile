source "https://rubygems.org"

gem "fastlane"

# Danger enforces PR etiquette and runs SwiftLint on changed
# files only. Paired with the baseline SwiftLint lane in the
# Fastfile, this is the strangler-pattern that keeps existing
# demonstrably-safe force-unwraps from blocking PRs while every
# newly-introduced one fails the check run.
gem "danger"
gem "danger-swiftlint"
