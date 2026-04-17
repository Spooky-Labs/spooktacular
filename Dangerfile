# Spooktacular Dangerfile
#
# Runs on every pull request via `.github/workflows/ci.yml` (the
# `danger` job). Invoked through `bundle exec fastlane danger`.
#
# Responsibilities:
#
#   1. SwiftLint — strict rules (force_cast, force_try,
#      force_unwrapping) are enforced on the PR's changed files
#      only, via the `danger-swiftlint` plugin. Existing
#      demonstrably-safe force-unwraps in the baseline codebase
#      don't block PRs; every new one fails the check. Matches
#      the strangler-pattern documented in `.swiftlint.yml`.
#
#   2. PR hygiene — require a meaningful description, flag
#      missing tests alongside new Source-target code, warn on
#      unusually large diffs, and nudge contributors toward a
#      CHANGELOG entry for user-facing Source changes.
#
# The `inline_mode: true` flag on `swiftlint.lint_files` posts
# violations as inline comments on the PR diff so reviewers
# don't have to hunt through raw log output.

# ──────────────────────────────────────────────────────────
# 1. SwiftLint on changed files only
# ──────────────────────────────────────────────────────────

swiftlint.config_file = ".swiftlint.yml"
swiftlint.strict = true
# Only fail on rules a contributor can fix by editing their diff.
# Baseline violations in un-touched files stay out of scope.
swiftlint.lint_files(inline_mode: true, fail_on_error: true)

# ──────────────────────────────────────────────────────────
# 2. PR hygiene
# ──────────────────────────────────────────────────────────

# A terse PR is hard to review. Require enough context to justify
# the change.
if github.pr_body.length < 20
  warn("This PR's description is very short — please explain the change and its motivation so reviewers don't have to read the diff to understand the why.")
end

# Large PRs fragment review. Flag but don't fail — some refactors
# legitimately need scale.
if git.lines_of_code > 1000
  warn("This PR touches #{git.lines_of_code} lines. Consider splitting into smaller, reviewable chunks if it isn't a coordinated refactor.")
end

# CHANGELOG hygiene — anything under `Sources/` that changes
# user-visible behavior should surface in the changelog. Not a
# hard block; a reviewer can override if the change is purely
# internal.
source_changes = (git.modified_files + git.added_files).any? { |f| f.start_with?("Sources/") }
changelog_touched = git.modified_files.include?("CHANGELOG.md") || git.added_files.include?("CHANGELOG.md")
if source_changes && !changelog_touched
  warn("No CHANGELOG.md update detected. If this PR changes user-visible behavior, please add an entry to the `[Unreleased]` section.")
end

# Tests alongside new code — if a new .swift file lands under
# `Sources/` with no matching test file, flag it. The rule is
# advisory so refactors that extract internal helpers aren't
# blocked.
added_source_files = git.added_files.select { |f| f.start_with?("Sources/") && f.end_with?(".swift") }
missing_tests = added_source_files.reject do |src|
  base = File.basename(src, ".swift")
  (git.added_files + git.modified_files).any? { |f| f.start_with?("Tests/") && f.include?(base) }
end
missing_tests.each do |src|
  warn("New source file `#{src}` has no accompanying test under `Tests/`. Reference-architecture bar: add one unless the file is a pure value type.")
end

# Merge commits in a PR branch force-rebase; keep history linear
# so `git bisect` and `git log` read cleanly.
merge_commits = git.commits.select { |c| c.parents.count > 1 }
if merge_commits.any?
  warn("This PR contains #{merge_commits.count} merge commit(s). Please rebase onto main so history stays linear.")
end
