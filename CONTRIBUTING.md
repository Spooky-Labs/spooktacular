# Contributing to Spooktacular

Thank you for your interest in contributing! This guide will help you get started.

## Development Setup

```bash
# Clone the repo
git clone https://github.com/Spooky-Labs/spooktacular.git
cd spooktacular

# Build
swift build

# Run tests
swift test

# Build the .app bundle
./build-app.sh
```

**Requirements:**
- macOS 14+ (Sonoma) on Apple Silicon
- Swift 6.2+ (Xcode 26+)
- GPG key configured for signed commits

## Branching Strategy

We follow [GitHub Flow](https://docs.github.com/en/get-started/quickstart/github-flow):

1. Create a feature branch from `main`
2. Make your changes
3. Open a PR against `main`
4. CI runs all tests automatically
5. Get a review from a code owner
6. Merge — Beta build goes to TestFlight automatically

## Commit Guidelines

- **Sign all commits** with GPG (`git commit -S`)
- Write clear, concise commit messages
- Use conventional format: `Fix X`, `Add Y`, `Update Z`
- Reference issues when applicable: `Fix #42`

## Code Standards

- **Swift 6 strict concurrency** — no warnings allowed
- **No force unwraps** in production code
- **Every error** must have `errorDescription` + `recoverySuggestion`
- **Every public type** must have DocC documentation
- **SpooktacularKit** must not import AppKit (use `KeyboardDriver` protocol)
- **CLI commands** must be thin wrappers — business logic lives in SpooktacularKit
- **Tests** must verify behavior, not just string contents

## Testing

```bash
# Run all tests
swift test

# Run a specific test suite
swift test --filter CloneManagerTests
```

Every PR must:
- Pass all existing tests
- Include tests for new functionality
- Not reduce test coverage of critical paths

## Architecture

```
SpooktacularKit (library) → spook (CLI) / Spooktacular (GUI) / spook-controller (K8s)
```

All business logic lives in `SpooktacularKit`. The CLI, GUI, and K8s controller are thin clients that parse input and call the library. See the [README](README.md#architecture) for the full diagram.

## Pull Request Process

1. Fill out the [PR template](.github/pull_request_template.md)
2. Ensure `swift test` passes locally
3. Update documentation if you changed public APIs
4. Request review from `@WikipediaBrown`

## Reporting Issues

- **Bugs**: Use the [bug report template](https://github.com/Spooky-Labs/spooktacular/issues/new?template=bug_report.yml)
- **Features**: Use the [feature request template](https://github.com/Spooky-Labs/spooktacular/issues/new?template=feature_request.yml)
- **Security**: See [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

---

Made with 🌲🌲🌲 in Cascadia
