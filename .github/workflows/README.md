# GitHub Actions workflows

## `release.yml` — Developer ID notarization pipeline

Builds, signs, notarizes, and staples both distributable artifacts:

- `Shotfuse.app` (menubar app, bundle id `dev.friquelme.shotfuse`)
- `shot` (CLI binary)

Pipeline, in order:

1. Check out the repo.
2. Select Xcode and install XcodeGen.
3. Generate the `App` and `CLI` Xcode projects from their `project.yml` files.
4. Mint an ephemeral keychain password (`uuidgen`) and build a throwaway
   keychain on the runner.
5. Decode the Developer ID `.p12` from secrets and import it into the
   keychain with `apple-tool:`, `apple:`, and `codesign:` partition access.
6. `xcodebuild archive` the `App` scheme with
   `OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"` — hardened
   runtime is non-negotiable per SPEC §1.
7. `xcodebuild -exportArchive` with a generated
   `ExportOptions.plist` (`method=developer-id`) to get a signed
   `Shotfuse.app`.
8. Archive the `shot` scheme the same way and re-sign the binary
   standalone (tool targets don't round-trip cleanly through
   `-exportArchive`).
9. `ditto -c -k --keepParent` the `.app`, submit with
   `xcrun notarytool submit --wait`, then `xcrun stapler staple` +
   `stapler validate`.
10. Zip the `shot` binary, submit for notarization, and re-verify with
    `codesign --verify` and `spctl --assess` (bare Mach-O binaries can't
    be stapled — Gatekeeper pulls the ticket online).
11. Upload the stapled `.app` zip and the signed `shot` binary as
    workflow artifacts. On tag pushes (`v*`), also create a GitHub
    Release and attach them.
12. Always delete the runner keychain at the end.

Triggers:

- `push` on any `v*` tag — this is what `v0.1.0` will trip.
- `workflow_dispatch` — manual runs from the Actions tab for dry-runs.

## Required secrets

Set these under **Settings → Secrets and variables → Actions** in GitHub.

| Secret | What it is | How to get it |
| --- | --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` | Export the certificate from **Keychain Access → My Certificates** as a `.p12`, then `base64 -i cert.p12 \| pbcopy` and paste. |
| `MACOS_CERTIFICATE_PWD` | Password used when exporting the `.p12` | You set this during export. |
| `APPLE_ID` | Apple ID email used for notarization | Your developer-account login (e.g. `you@example.com`). |
| `APPLE_TEAM_ID` | 10-character Team ID | `xcrun altool --list-providers -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"` or **Apple Developer → Membership**. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool` | Generate at <https://appleid.apple.com/> → **Sign-In and Security → App-Specific Passwords**. |

`KEYCHAIN_PWD` is intentionally **not** a secret — the workflow generates
it with `uuidgen` per run. It only protects the ephemeral runner
keychain, which is deleted when the job ends.

## Dry-run instructions

You can exercise the workflow end-to-end without cutting a release:

1. Push a branch containing `.github/workflows/release.yml` (no tag).
2. Go to **Actions → release → Run workflow** and select your branch
   from the dropdown (`workflow_dispatch`).
3. The run will archive, sign, notarize, and staple using the same
   secrets as a tagged release, but the **Create GitHub Release** step
   is skipped (it's gated on `startsWith(github.ref, 'refs/tags/v')`).
4. Download the `shotfuse-release` artifact from the run summary and
   verify locally:

   ```bash
   unzip shotfuse-release.zip
   xcrun stapler validate Shotfuse.app
   spctl --assess --type execute --verbose=4 Shotfuse.app
   codesign --verify --strict --verbose=2 shot
   ```

When `stapler validate` prints `The validate action worked!` and
`spctl --assess` prints `source=Notarized Developer ID`, the dry-run
passes.

## Status

**This workflow has not yet been exercised against a real Developer
ID certificate — the first dry-run will validate it.** Acceptance per
beads `hq-6a4` is dry-run success plus `stapler validate` passing on
the produced `Shotfuse.app`. File any issues uncovered during the
dry-run against a follow-up beads ticket before tagging `v0.1.0`.
