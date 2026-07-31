# Releasing Kuri

The root release version is `build.zig.zon`. Keep `npm/package.json` in sync.
A `v*` tag starts `.github/workflows/release.yml`, which builds the four
published targets, signs/notarizes macOS artifacts, publishes a GitHub Release,
and updates the `release-channel` branch.

## GitHub Actions prerequisites

The root build imports the private `justrach/nanostore` repository through the
sibling path `../nanostore`. Set a repository secret named `NANOSTORE_PAT` with
read-only access to that repository. The workflows pin the dependency to the
commit currently used for this release; update the pin deliberately when the
Kuri integration changes.

macOS release jobs require these repository secrets:

- `APPLE_CERTIFICATE`: base64-encoded Developer ID Application `.p12`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_PASSWORD` (an Apple app-specific password)

The workflow intentionally fails when either dependency access or Apple
credentials are missing instead of publishing an unnotarized artifact with a
misleading manifest.

## Local macOS notarization

`notary-local` is not a Kuri dependency or a currently available CLI. The
supported local path is Apple's `xcrun notarytool`; use a pre-configured
keychain profile and submit a zip containing the signed binaries:

```sh
xcrun notarytool submit /tmp/kuri-macos-arm.zip \
  --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun notarytool submit /tmp/kuri-macos-x86.zip \
  --keychain-profile "$NOTARYTOOL_PROFILE" --wait
```

Only package artifacts after notarization is accepted. Record the submission
IDs and status in the release notes or release log; do not claim local
notarization merely because `codesign` succeeded.
