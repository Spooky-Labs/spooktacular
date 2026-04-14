# Versioning & Release Schedule

Spooktacular follows [Semantic Versioning 2.0.0](https://semver.org) with
clearly defined pre-release stages. This document explains what every
part of a version number means and what to expect from each release type.

## Version Format

```
MAJOR.MINOR.PATCH[-PRERELEASE]

Examples:
  0.4.0        Development release
  1.0.0-rc1    Release candidate 1 for v1.0.0
  1.0.0        Stable release
  1.1.0        Feature release
  1.1.1        Patch release (bug fix)
```

### MAJOR (1.x.x)

Incremented when we make **breaking changes** to the public API, CLI
interface, VM bundle format, or configuration schema. Enterprise teams
pinning to a major version can upgrade minor and patch versions without
risk.

**What breaks:** command syntax changes, config.json schema changes,
removed commands, renamed flags, changed default behavior.

**Promise:** We will not ship a major version bump without a migration
guide and at least one release candidate.

### MINOR (x.1.x)

Incremented when we add **new features** that are backward-compatible.
Existing VMs, scripts, and CI configurations continue to work unchanged.

**Examples:** new CLI commands, new provisioning modes, new network
modes, GUI improvements, new templates.

### PATCH (x.x.1)

Incremented for **bug fixes** and security patches. No new features,
no behavior changes. Safe to upgrade immediately.

**Examples:** crash fixes, error message improvements, documentation
corrections, dependency updates.

### Pre-release Tags

**`-alpha.N`** — Early development. APIs may change between alphas.
Not recommended for production. Useful for testing new features.

**`-beta.N`** — Feature-complete for the target release. APIs are
stable but may have bugs. Suitable for staging environments.

**`-rc.N`** (Release Candidate) — Production-ready candidate. No
known bugs. If no issues are found within the testing period, this
becomes the stable release. **Enterprise teams should test RCs in
their staging environment before the stable release ships.**

## Current Status

| Version | Stage | Date | Notes |
|---------|-------|------|-------|
| 0.1.0 | Development | 2026-04-12 | Foundation: VM lifecycle, GUI, CLI |
| 0.2.0 | Development | 2026-04-12 | Enterprise blockers: stop, capacity, IP, SSH |
| 0.3.0 | Development | 2026-04-12 | Feature complete: service, snapshots, templates |
| 0.4.0 | Development | 2026-04-12 | Code quality: naming, errors, logging, Fastlane |
| 1.0.0-rc1 | Release Candidate | Upcoming | First production candidate |
| 1.0.0 | Stable | Upcoming | First stable release |

**0.x.x versions** are development releases. The API may change between
minor versions. Use in production at your own discretion.

**1.0.0** will be the first stable release with a commitment to
semantic versioning guarantees.

## Release Schedule

We do not follow a fixed calendar schedule. Releases ship when they
are ready — not on arbitrary deadlines. However, we follow these
principles:

**Patch releases** ship within 48 hours of a confirmed bug fix.

**Minor releases** ship when a meaningful set of features is complete
and tested. Typically every 2–4 weeks during active development.

**Major releases** ship only when necessary (breaking changes). We
provide at least 2 weeks of release candidate testing before a major
stable release.

**Release candidates** remain in testing for a minimum of 1 week.
If issues are found, we ship additional RCs (rc2, rc3, etc.) until
the build is clean.

## Release Process

Every release follows the same pipeline:

```
Feature branch → PR → CI (360+ tests) → Code review → Merge to main
    ↓
Push to main → TestFlight beta (automatic)
    ↓
Tag vX.Y.Z → GitHub Release + App Store submission (automatic)
    ↓
Notarized .app.zip for Homebrew (automatic)
```

**What CI checks on every PR:**
- `swift test --parallel` — all unit tests must pass
- `swift build -c release` — release build must compile clean
- `.app` bundle structure verification

**What ships on every tag:**
- GitHub Release with `.app.zip` (notarized)
- TestFlight build (via Fastlane pilot)
- App Store submission (via Fastlane deliver)
- DocC documentation update (via GitHub Pages)

## Compatibility Guarantees

### VM Bundle Format

The `.vm` bundle directory structure (`config.json`, `disk.img`,
platform artifacts) is versioned separately from the tool. If we
change the bundle format, we will:

1. Support reading old bundles indefinitely
2. Provide automatic migration on first access
3. Document the changes in release notes

### CLI Interface

Command names, flag names, and `--json` output schemas are part of
the public API. Changes to these follow semver:

- Adding a new flag: minor version bump
- Renaming a flag: major version bump
- Changing JSON output structure: major version bump
- Adding a new JSON field: minor version bump

### Configuration Files

`config.json` fields follow the same rules as CLI flags. New fields
are additive (minor bump). Removing or renaming fields requires a
major bump with migration.

## How to Pin Versions

**Homebrew:**
```bash
brew install --cask spooktacular@1.0
```

**GitHub Actions:**
```yaml
- uses: spooky-labs/setup-spooktacular@v1
```

**Direct download:**
```bash
curl -L https://github.com/Spooky-Labs/spooktacular/releases/download/v1.0.0/Spooktacular.app.zip
```

## Reporting Issues

If you find a bug in a release:
1. Check the [release notes](https://github.com/Spooky-Labs/spooktacular/releases)
   to see if it's already fixed in a newer version
2. Open an [issue](https://github.com/Spooky-Labs/spooktacular/issues)
   with your version number, macOS version, and steps to reproduce
3. Patch releases ship within 48 hours of confirmed fixes
