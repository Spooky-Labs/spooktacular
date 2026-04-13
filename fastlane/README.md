fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac test

```sh
[bundle exec] fastlane mac test
```

Run all unit tests

### mac build

```sh
[bundle exec] fastlane mac build
```

Build the .app bundle (release)

### mac package

```sh
[bundle exec] fastlane mac package
```

Package the .app into a signed .pkg for App Store submission

### mac signing

```sh
[bundle exec] fastlane mac signing
```

Sync code-signing certificates and profiles via match

### mac notarize_app

```sh
[bundle exec] fastlane mac notarize_app
```

Notarize the .app for direct distribution

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Build, package, and upload to TestFlight

### mac release

```sh
[bundle exec] fastlane mac release
```

Build, notarize, and submit to the App Store

### mac homebrew

```sh
[bundle exec] fastlane mac homebrew
```

Build, notarize, and package for Homebrew distribution

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Capture and process App Store screenshots

### mac generate_docs

```sh
[bundle exec] fastlane mac generate_docs
```

Generate DocC documentation

### mac lint

```sh
[bundle exec] fastlane mac lint
```

Validate App Store metadata

### mac register_app

```sh
[bundle exec] fastlane mac register_app
```

Register app identifier in Apple Developer Portal and App Store Connect

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
