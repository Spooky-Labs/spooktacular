# Code signing & the signed CI pipelines

Spooktacular already uses [fastlane](https://fastlane.tools) end-to-end for CI,
following fastlane's own [recommended GitHub Actions
pattern](https://docs.fastlane.tools/best-practices/continuous-integration/github/):

- **`match`** ([sync_code_signing](https://docs.fastlane.tools/actions/sync_code_signing/))
  stores certificates + provisioning profiles in a **separate private git repo**
  (`Spooky-Labs/spooktacular-certificates`), encrypted with `MATCH_PASSWORD`.
  Configured in `fastlane/Matchfile`.
- **App Store Connect API key** auth (not an Apple ID) so CI never hits interactive 2FA.
- **`setup_ci`** provisions an ephemeral keychain on the runner and forces `match`
  into **`readonly`** mode so CI can never mint or revoke certs. Runs in
  `before_all` (`fastlane/Fastfile`).
- Thin, SHA-pinned workflow drivers (`.github/workflows/{beta,release}.yml`).

**None of the code needs changing to sign.** The signed pipelines are red only
because the cert repo has never been populated and the CI secrets are not set.
This is a one-time bootstrap that requires an Apple Developer account, so it can
only be done by a maintainer — the steps are below.

## Which pipelines need signing

| Workflow | Trigger | Needs match certs? |
|---|---|---|
| `ci.yml` (Lint, Test & Build, Xcode compile-check) | PR + push `main` | **No** — the required gate; `build-app.sh` uses an ad-hoc fallback and the Xcode job only compiles. Green today. |
| `beta.yml` → *UI Tests (screenshots)* | push `main` | **No** — signing is forced off (`CODE_SIGNING_ALLOWED=NO`); screenshot capture never installs the app. Green without certs. |
| `beta.yml` → *TestFlight* | push `main` | **Yes** |
| `release.yml` (App Store promote + notarized GitHub release) | push tag `v*` | **Yes** |

## One-time bootstrap (maintainer, needs an Apple Developer account)

1. **Create the private cert repo** `Spooky-Labs/spooktacular-certificates`
   (empty is fine — `match` populates it). It must be private.

2. **Create an App Store Connect API key**
   (App Store Connect → Users and Access → Integrations → App Store Connect API,
   role *App Manager*). Download the `.p8` once; note the **Key ID** and **Issuer ID**.

3. **Populate the cert repo locally** (run-write mode; needs the API key + a
   `MATCH_PASSWORD` you choose and keep):
   ```bash
   export MATCH_PASSWORD='<a-strong-passphrase>'
   export APPLE_API_KEY_ID='<key id>'
   export APPLE_API_ISSUER_ID='<issuer id>'
   export APPLE_API_KEY_P8="$(cat AuthKey_XXXX.p8)"
   # Generates + encrypts both profiles project.yml references
   # ("match Development com.spooktacular.app macos" and the AppStore one):
   bundle exec fastlane match development --platform macos --readonly false
   bundle exec fastlane match appstore    --platform macos --readonly false
   ```

4. **Set the GitHub repo secrets** (Settings → Secrets and variables → Actions):
   | Secret | Value |
   |---|---|
   | `MATCH_PASSWORD` | the passphrase from step 3 |
   | `MATCH_GIT_BASIC_AUTHORIZATION` | `base64` of `<gh-user>:<PAT with repo scope>` for the cert repo |
   | `APPLE_API_KEY_ID` | Key ID from step 2 |
   | `APPLE_API_ISSUER_ID` | Issuer ID from step 2 |
   | `APPLE_API_KEY_P8` | full contents of the `.p8` |
   | `FASTLANE_CONTACT_PHONE` | a real reachable number (Apple rejects fictional ones in beta review) |

   `MATCH_GIT_BASIC_AUTHORIZATION`:
   `echo -n 'your-gh-user:ghp_yourPAT' | base64`

After that, `beta.yml`'s TestFlight job and `release.yml` will have everything
they need. `ci.yml` and the screenshots job never do.

## Open decision — TestFlight trigger

`beta.yml` currently uploads to **TestFlight on every merge to `main`**. Once
certs exist, Apple enforces a per-app-per-day upload limit (the `ITMS-90382`
counter), so a busy `main` will start getting rejected. Options, pick one:

- **Only on release tags** — move the TestFlight job to `push: tags: ['v*']`
  (alongside `release.yml`), so merges to `main` run tests + the sign-free
  screenshots only. Avoids rate limits; recommended for most teams.
- **Manual dispatch** — add `workflow_dispatch` so a build uploads only when you
  click *Run*.
- **Keep every `main` push** — as-is.

The screenshots job stays on every `main` push regardless (that's how UI
regressions get caught early), and it no longer needs certs.
