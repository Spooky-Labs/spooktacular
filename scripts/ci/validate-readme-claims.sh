#!/bin/bash
# validate-readme-claims.sh — fails CI if README's public-facing
# numeric claims drift from the underlying code.
#
# Currently audits two claims:
#
#   1. README's "XYZ tests" badge matches the total printed by
#      `swift test` in the `Test run with XYZ tests`-style
#      summary that Swift 6.0+ emits.
#
#   2. README's "ASVS 108 pass / 0 fail" figure matches the
#      count of `PASS` lines in `docs/OWASP_ASVS_AUDIT.md`.
#
# Exit non-zero on any drift, printing a diff of claimed vs
# actual so the PR author can either update README or fix the
# code that changed the counts.
#
# Usage:
#   scripts/ci/validate-readme-claims.sh [swift-test-output-file]
#
# The first argument (optional) is a file containing the raw
# output of `swift test --parallel`; CI runs
# `swift test | tee test-output.txt` before calling this script
# so the file exists. If the argument is absent, the script
# runs `swift test` itself — useful when a human invokes the
# script locally to sanity-check before opening a PR.

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

readme="$PROJECT_DIR/README.md"
asvs="$PROJECT_DIR/docs/OWASP_ASVS_AUDIT.md"
test_output="${1:-}"

fail=0

# ─────────────────────────────────────────────────────────────
# Claim 1 — Tests badge
# ─────────────────────────────────────────────────────────────
if [[ -z "$test_output" ]]; then
    test_output="$(mktemp -t readme-claims-XXXXXX).txt"
    swift test --parallel 2>&1 | tee "$test_output" >/dev/null || true
fi

# Sum every "Test Suite 'All tests' passed … Executed N tests"
# line. Swift Testing prints `Test run with XYZ tests passed`
# while XCTest emits `Executed XYZ tests`. Handle both.
actual_tests=$(
    {
        grep -oE 'Test run with [0-9]+ tests' "$test_output" \
            | grep -oE '[0-9]+' \
            || true
        grep -oE 'Executed [0-9]+ tests' "$test_output" \
            | grep -oE '[0-9]+' \
            || true
    } | awk 'BEGIN {s=0} {s+=$1} END {print s}'
)

# The README renders the count inside the badge URL, e.g.
# `Tests-424_passing-22c55e.svg`. Pull the integer out of that
# canonical location.
claimed_tests=$(
    grep -oE 'Tests-[0-9]+_passing' "$readme" \
        | head -n 1 \
        | grep -oE '[0-9]+' \
        || true
)
# Secondary claim: the "Run 424 tests" line in the Building
# from Source section.
claimed_tests_docs=$(
    grep -oE 'swift test[[:space:]]+#[[:space:]]*Run[[:space:]]+[0-9]+[[:space:]]+tests' "$readme" \
        | grep -oE '[0-9]+' \
        | head -n 1 \
        || true
)
# Third claim: the "N tests + release build" row in the CI/CD
# table further down.
claimed_tests_cicd=$(
    grep -oE '\| [0-9]+ tests \+ release build' "$readme" \
        | grep -oE '[0-9]+' \
        | head -n 1 \
        || true
)

if [[ -z "$actual_tests" || "$actual_tests" == "0" ]]; then
    echo "::warning::could not parse a test count from swift test output; skipping claim 1"
else
    for claim in "$claimed_tests" "$claimed_tests_docs" "$claimed_tests_cicd"; do
        [[ -z "$claim" ]] && continue
        if [[ "$claim" != "$actual_tests" ]]; then
            echo "::error::README claims $claim tests but swift test ran $actual_tests"
            fail=1
        fi
    done
fi

# ─────────────────────────────────────────────────────────────
# Claim 2 — ASVS "N pass / M fail"
# ─────────────────────────────────────────────────────────────
if [[ -f "$asvs" ]]; then
    # Count lines that begin with `| PASS` or `| ✓ ` in a
    # markdown table row. Match both forms (some rows use the
    # literal word, others the check glyph).
    actual_pass=$(grep -cE '^\|[[:space:]]*(PASS|✓)' "$asvs" || true)
    actual_fail=$(grep -cE '^\|[[:space:]]*(FAIL|✗)' "$asvs" || true)

    claimed_pass=$(
        grep -oE '[0-9]+ pass / [0-9]+ fail' "$readme" \
            | head -n 1 \
            | awk '{print $1}' \
            || true
    )
    claimed_fail=$(
        grep -oE '[0-9]+ pass / [0-9]+ fail' "$readme" \
            | head -n 1 \
            | awk '{print $4}' \
            || true
    )

    if [[ -n "$claimed_pass" && "$claimed_pass" != "$actual_pass" ]]; then
        echo "::error::README claims ASVS $claimed_pass pass, audit shows $actual_pass"
        fail=1
    fi
    if [[ -n "$claimed_fail" && "$claimed_fail" != "$actual_fail" ]]; then
        echo "::error::README claims ASVS $claimed_fail fail, audit shows $actual_fail"
        fail=1
    fi
else
    echo "::notice::$asvs not found; skipping claim 2"
fi

if [[ $fail -eq 0 ]]; then
    echo "✓ README claims match reality (tests=$actual_tests)"
fi

exit $fail
