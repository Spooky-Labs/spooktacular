# Code hygiene

How Spooktacular keeps source comments honest and the public
API surface minimal. Apply these principles when reviewing PRs;
revisit during periodic cleanup passes.

## Principles

### 1. Present-tense docs, no phase pointers

Comments describing **what the code does today** beat comments
describing **what phase of the build introduced it**. Phase
numbers in source belong to the PR description and the git log,
not the file.

| Bad | Good |
|---|---|
| `// Phase 3 of the SEP migration removed the PEM-on-disk fallback.` | `// The PEM-on-disk fallback is gone — SEP-bound keys are non-extractable.` |
| `// Phase 7 ships the unsigned pkg. Phase 2's CA work will plumb in productsign.` | `// The pkg is unsigned. Run productsign for distribution-grade signing.` |
| `// `MDMCommand` lives in MDMCommand.swift.` | (delete; the compiler knows) |

**Why:** every reader has to decide whether "Phase 3" refers to
work that already shipped, is in flight, or got skipped. The
git history is the source of truth for vintage; the source file
is the source of truth for present behavior.

### 2. One name per concept

A `typealias` that renames a public type for one call site is
indirection without benefit. Same for "convenience wrappers"
that auto-mint values production never needs.

| Bad | Good |
|---|---|
| `typealias BuiltPackage = MDMUserDataBuiltPackage` (in a protocol whose only impl returns the full name) | `func buildPkg(...) -> MDMUserDataBuiltPackage` |
| `register(...) -> UUID` (auto-mints) + `store(id: UUID, ...)` (caller-supplied) coexisting; tests pick one, production picks the other | One method. If callers genuinely need to mint up front, expose the mintable form and let callers wrap. |

**Why:** two methods invite two-vendor drift. Tests and
production diverge, then someone reads `register` in tests and
re-introduces a usage in production, and now you can't simplify
without breaking both call sites.

### 3. Dead error cases hide live ones

When a code path is removed, its error case in the corresponding
`enum Error` should follow. Leaving `case chownFailed(reason:)`
after the `chown` path was ripped means every future reader
spends time wondering how it can fire — and may write defensive
code that catches a case that's truly unreachable.

**Why:** unreachable error cases bias defensive code toward
catching the impossible while leaving the possible uncaught.

### 4. Vestigial constants follow their consumers

If `foo()` is the only caller of `fooConstant`, removing `foo()`
should remove `fooConstant` too. Public constants left dangling
after their consumer disappears become attractive nuisances —
new code wires up to them, the dead path comes back.

**Example:** `DiskInjector.daemonLabel` +
`DiskInjector.guestScriptPath` survived after Guest Tools'
provisioner pkg took over LaunchDaemon ownership. Removed in
[`ee11dda5`](https://github.com/Spooky-Labs/spooktacular/commit/ee11dda5)
along with their sole consumer
`generateLaunchDaemonPlist()`.

### 5. Stale docstring claims are bugs

A docstring that says "Until persistence ships, this command
can only see devices that enrolled during the currently-running
`serve`" is a bug if persistence has, in fact, shipped. The
user reads the docstring and concludes the command is broken
when it isn't.

**Fix:** treat docstring drift like any other regression.
When you change behavior, update the documented contract in
the same commit.

### 6. Match the scope of test names to the test, not the build phase

Test docstrings like "Regression guard for Phase 2 of the
Secure-Enclave migration" reference the build phase that
introduced the regression-prone change. After that phase ships,
the phase reference is just noise. Rewrite the docstring to
describe **what the test guards against**, not **when it was
written**.

## The "silent test skip" anti-pattern

Tests that wrap their setup in `do { ... } catch { return }` to
handle missing fixtures often disguise real bugs. A path rename,
a deleted file, a CI environment change — anything that *should*
fail the test gets silently skipped. The test reports green, but
the assertion body never ran.

We hit this concretely: a `DocConsistencyTests` test was reading
`Sources/spook-controller/NodeManager.swift` after the controller
target had been renamed. The catch block swallowed
`fileReadNoSuchFile` and returned early. Green CI was lying.

**Fix:** make the test FAIL when its premise breaks. Either let
the throw propagate (the function already declares `throws`), or
use `try XCTSkipUnless` with an explicit reason that lands in the
test report. A skip-gracefully catch only earns its keep when the
fixture genuinely is optional across environments — and even
then, the reason should be logged via `Issue.record`, not
swallowed.

## Two-name-prefix drift in docs

User-facing docs that document env vars, binary names, or
deployment paths are part of the product contract. When code
renames a symbol, every doc that mentions it needs the same
edit in the same PR. Otherwise the doc starts lying.

We hit this concretely: env vars renamed from `SPOOK_*` to
`SPOOKTACULAR_*` years ago, but ~10 docs still listed the old
short prefix. Operators following the docs would set variables
the daemon didn't read, then get misleading "X is missing"
errors naming yet a third variable. Similarly, binary renames
from `spook-controller` to `spooktacular-controller` were
incomplete — log lines, Prometheus job labels, K8s deployment
docs all carried the old name.

**Verify** before recommending env vars in a doc:

```sh
# Are there env vars in docs that don't exist in code?
grep -rhoE 'SPOOK[A-Z_]+|SPOOKTACULAR_[A-Z_]+' docs | sort -u \
  > /tmp/doc-envs.txt
grep -rhoE 'env\["[A-Z_]+"\]|environment\["[A-Z_]+"\]' Sources \
  | sed 's/env\["//; s/environment\["//; s/"\]//' | sort -u \
  > /tmp/code-envs.txt
comm -23 /tmp/doc-envs.txt /tmp/code-envs.txt
# Names in this output are documented but unused — either typos,
# stale rename targets, or wholly fictional.
```

## Periodic cleanup checklist

Run this every quarter or when a major build phase completes.

```sh
# Find Phase-N references — most should be replaced with
# present-tense descriptions.
grep -rn 'Phase [0-9]' Sources Tests | grep -v '\.build/'

# Find "Until X ships" / "later phase" / "Phase X will land"
# — forward-looking promises that have either shipped or
# should be removed.
grep -rnE 'Until.*ships|later phase|Phase [0-9]+ will' \
  Sources Tests | grep -v '\.build/'

# Find trailing "// X lives in Y.swift" pointer comments —
# the compiler already knows.
grep -rnE '^/// .* lives in .*\.swift\.$' Sources Tests \
  | grep -v '\.build/'

# Find typealiases inside types — most are indirection.
grep -rn 'typealias' Sources | grep -v '\.build/'

# Find silent test skips that disguise real failures as passes.
grep -rB 2 -A 3 'catch {$' Tests | grep -B 4 'return$\|skip gracefully'

# Find docs that reference dead source paths (rename targets).
grep -rn 'Sources/spook-controller\|Sources/spooktacular-agent' \
  Sources Tests docs

# For each protocol with a small number of conforming types,
# ask: does it earn its keep? Single-conformer protocols are
# almost always premature flexibility.
```

## Worked examples

The cleanup pass that produced this doc removed **~200 lines**
of dead code and surfaced **three user-impact bugs** across 18
commits. Highlights:

| Category | Commit | What |
|---|---|---|
| **Dead code** | [`de07cbd5`](https://github.com/Spooky-Labs/spooktacular/commit/de07cbd5) | MDM cleanup — drops dead `MDMContentStore.register()`, the `BuiltPackage` typealias, Phase-N pointers across 14 EmbeddedMDM files. |
| **Dead code** | [`ee11dda5`](https://github.com/Spooky-Labs/spooktacular/commit/ee11dda5) | DiskInjector cleanup (closes #85) — rips vestigial LaunchDaemon plist generator + `chownFailed` error case. |
| **Doc rewrite** | [`64b74d1f`](https://github.com/Spooky-Labs/spooktacular/commit/64b74d1f) | docs/MDM.md — adds architecture map, on-disk state layout, per-removal simplification log. |
| **Doc rot** | [`a4d6c958`](https://github.com/Spooky-Labs/spooktacular/commit/a4d6c958) | Phase-N sweep across the rest of the codebase. |
| **User-impact bug** | [`639f7d86`](https://github.com/Spooky-Labs/spooktacular/commit/639f7d86) | `GuestAgentError.notConnected` suggested `sudo spooktacular-agent --install-daemon` — a binary that no longer exists. |
| **User-impact bug** | [`e9211449`](https://github.com/Spooky-Labs/spooktacular/commit/e9211449) | `spook doctor --strict` item 11 validated the deleted `SPOOKTACULAR_AUDIT_SIGNING_KEY` file-path env var — inverting the pass/fail signal vs. production reality. |
| **User-impact bug** | [`bae8ad08`](https://github.com/Spooky-Labs/spooktacular/commit/bae8ad08) | `DocConsistencyTests.tlsDefaultConsistency` silently no-op'd for months due to a stale source path. |
| **Doc bulk rename** | [`51c54ca92`](https://github.com/Spooky-Labs/spooktacular/commit/51c54ca92) | 31 distinct env-var prefix renames across 7 deployment / runbook / observability docs. |

See `git log --grep=cleanup` for the full list with per-change
rationale.

## Out of scope

This doc is not:

- **A style guide.** Indentation, naming, file layout are
  enforced by SwiftLint + the existing code conventions; this
  doc covers semantic hygiene, not syntactic style.
- **A refactoring playbook.** Refactors that change behavior
  belong in their own PR with tests; this doc covers
  doc-and-dead-code cleanup that is provably behavior-neutral.
- **A code-review checklist.** A reviewer's first job is
  correctness; hygiene is a follow-up, not a gate.

## See also

- [`docs/MDM.md`](MDM.md) — the embedded MDM doc, includes a
  per-removal simplification log for the largest cleanup pass.
- `git log --oneline` — vintage of every change, with PR rationale
  in the commit body.
