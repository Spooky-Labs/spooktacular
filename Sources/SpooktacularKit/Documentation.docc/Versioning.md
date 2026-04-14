# Versioning & Release Schedule

Understand what version numbers mean and what to expect from each release.

## Overview

Spooktacular follows [Semantic Versioning 2.0.0](https://semver.org).
Every part of the version number communicates specific guarantees
to enterprise teams integrating Spooktacular into their infrastructure.

### Version Format

```
MAJOR.MINOR.PATCH[-PRERELEASE]

1.0.0-rc1    Release candidate (test in staging)
1.0.0        Stable release (safe for production)
1.1.0        Feature release (backward-compatible)
1.1.1        Bug fix (upgrade immediately)
2.0.0        Breaking change (migration guide provided)
```

### What Each Part Means

**MAJOR** — Breaking changes to the CLI, `config.json` schema, or
VM bundle format. We provide migration guides and at least one
release candidate before shipping.

**MINOR** — New features that are backward-compatible. Your existing
VMs, scripts, and CI configurations continue working.

**PATCH** — Bug fixes and security patches. No behavior changes.
Ships within 48 hours of confirmed fix.

**Pre-release tags:**
- `-alpha.N` — Early development. APIs may change.
- `-beta.N` — Feature-complete. APIs stable, may have bugs.
- `-rc.N` — Production-ready candidate. If clean for 1 week,
  ships as stable.

### Compatibility Guarantees

These are part of the public API and follow semver:

- **CLI command names and flags** — renaming is a major bump
- **`--json` output schemas** — removing fields is a major bump
- **`config.json` format** — removing fields is a major bump
- **VM bundle structure** — old bundles readable indefinitely

Adding new flags, JSON fields, or config keys is a minor bump.

### Release Process

```
Feature branch → PR → CI (360+ tests) → Review → Merge
    → TestFlight (automatic on main)
    → GitHub Release + App Store (automatic on tag)
    → Notarized Homebrew zip (automatic on tag)
    → DocC docs update (automatic on main)
```

### Pinning Versions

For CI pipelines and infrastructure-as-code:

```bash
# Homebrew
brew install --cask spooktacular@1.0

# Direct download (specific version)
curl -L https://github.com/Spooky-Labs/spooktacular/releases/download/v1.0.0/Spooktacular.app.zip
```

## Topics

### Related

- <doc:GettingStarted>
- <doc:EC2MacDeployment>
