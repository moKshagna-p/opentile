# Releasing OpenTile

## Signing status

The existing v0.3.1 release uses Apple Development signing and is not notarized.
This distribution mode may require users to grant permissions again after updates.
Do not describe it as Developer ID signed or notarized.

`scripts/prepare-release.sh` currently requires a Developer ID Application
certificate and the existing Sparkle key in Keychain. It intentionally rejects
Apple Development and ad hoc builds. Until Developer ID signing is configured,
the existing development-signed release process remains a manual maintainer step;
the CI ZIP must not be substituted for the signed update archive.

## Checklist

1. Choose a new semantic version and a strictly higher build number than the last
   published release. Update the defaults in `scripts/package.sh` and user docs.
2. Run `scripts/test.sh` and build/package the exact commit intended for release.
   Complete the relevant [manual checks](CONTRIBUTING.md#manual-checks), including
   updating an existing installation and checking permissions and Sparkle updates.
3. With Developer ID configured, prepare artifacts using:

   ```sh
   OPENTILE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
     scripts/prepare-release.sh VERSION BUILD_NUMBER
   ```

   Keep the same signing team and the Sparkle key matching
   `scripts/sparkle-public-key.txt`. The script prepares artifacts under
   `.build/releases/vVERSION/`; it does not notarize or publish them.
4. Verify the ZIP checksum with `shasum -a 256 -c SHA256.txt` from the release
   directory. Inspect the app signature and confirm the appcast version, build
   number, download URL, and Sparkle signature correspond to the final archive.
   Do not modify the ZIP after generating its appcast and checksum.
5. Commit the release changes, create the matching `vVERSION` tag on that commit,
   and push the commit and tag. Wait for the tag's `Build macOS app` run to pass.
6. Create a GitHub draft release for that tag. Upload the versioned app ZIP,
   `appcast.xml`, and `SHA256.txt` together. State the signing/notarization status
   and user-visible changes accurately in the release notes.
7. Check all assets before publishing the draft as the latest release. The app
   fetches `releases/latest/download/appcast.xml`, so publishing makes the update
   discoverable to installed users. Verify the published links and update check.

## Automation boundary

Version tags automatically run tests and create an ad hoc development artifact.
CI has read-only repository permissions and does not publish GitHub releases.
Public release signing remains local, where the signing keys already live.
A future publishing workflow needs a deliberate signing/notarization setup and a
protected release environment before it can safely replace these manual steps.
