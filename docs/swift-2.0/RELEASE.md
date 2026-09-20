# Swift 2.0 Release

## Release Boundary

macOS Swift releases use `2.x`, tags such as `macos-v2.0.1`, and
`updates/macos.json`. Windows remains Python `1.8.x`, uses tags such as
`windows-v1.8.9`, and reads `updates/windows.json`. Never move the Windows
manifest, `version.txt`, or a Windows asset to announce a macOS Swift release.

The current repository helper set supports an arm64 internal candidate only.
Do not publish or label an Intel/universal app until yt-dlp, FFmpeg, FFprobe, and
QuickJS all contain x86_64 and arm64 slices from one reviewed provenance-aligned
toolchain.

## Deterministic Assembly

The build script accepts a three-component version, an explicit signing mode,
and an explicit RFC3339 UTC SBOM creation time. Use the actual candidate evidence
timestamp; do not silently reuse the helper inventory date. For the current
internal candidate:

```bash
./scripts/build_swift_2.sh \
  --version 2.0.1 \
  --architectures arm64 \
  --sbom-created '<UTC-RFC3339-candidate-timestamp>' \
  --unsigned-test
```

`--unsigned-test` means no Developer ID identity is used. The app is still
ad-hoc signed so nested code and bundle integrity can be tested.

Outputs:

```text
dist/YT Downloader Pro 2.app
dist/YT-Downloader-Pro-2.0.1-macOS-arm64-internal.zip
dist/swift-2.0-bundle-report.json
```

The script performs these steps in order:

1. Validate every source helper and every requested architecture before deleting
   an existing candidate.
2. Run the complete strict Swift suite.
3. release-build `YTDownloaderPro2` for `arm64-apple-macosx13.0` in
   `build/swift-2.0/arm64`.
4. Assemble a fresh app with one main executable and exactly four helpers.
5. Copy `AppIcon.icns`, notices, the source-availability index, exact license
   texts, `AppMetadata.json`, the source catalog, and compiled
   English/Japanese/Traditional Chinese resources.
6. Set executable/resource modes and remove only `com.apple.quarantine` from
   copied app files. Repository helpers are not modified.
7. Sign all four helpers.
8. Validate the canonical helper/license inventory and generate an SPDX 2.3
   SBOM from the final signed helper bytes.
9. Sign the outer app last, protecting the SBOM and all resources.
10. Run the fail-closed verifier and write deterministic JSON.
11. Create a sorted ZIP with fixed timestamps and preserved POSIX modes.

Assembly and archive metadata are deterministic for the same signed bundle.
Swift compiler output, Developer ID secure timestamps, and Apple notarization
responses are toolchain/external inputs and are not claimed to be reproducible
across environments.

## Bundle Layout

```text
YT Downloader Pro 2.app/
  Contents/
    Info.plist
    MacOS/YT Downloader Pro 2
    Helpers/
      yt-dlp_macos
      ffmpeg
      ffprobe
      qjs
    Resources/
      AppIcon.icns
      AppMetadata.json
      Localizable.xcstrings
      SBOM.spdx.json
      SOURCE_AVAILABILITY.md
      THIRD_PARTY_NOTICES.md
      ThirdPartyLicenses/
      en.lproj/Localizable.strings
      ja.lproj/Localizable.strings
      zh-Hant.lproj/Localizable.strings
```

`Info.plist` must contain short version and bundle version `2.0.1`, minimum
macOS `13.0`, executable `YT Downloader Pro 2`, and identifier
`com.tachouweng.ytdownloaderpro2`.

## Independent Internal Verification

```bash
python3 -m unittest tests.test_swift_sbom tests.test_swift_bundle -v
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.1 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json
codesign --verify --deep --strict --verbose=2 \
  'dist/YT Downloader Pro 2.app'
unzip -l 'dist/YT-Downloader-Pro-2.0.1-macOS-arm64-internal.zip'
```

Execute the copied helpers, never the repository inputs, for final evidence:

```bash
'dist/YT Downloader Pro 2.app/Contents/Helpers/yt-dlp_macos' --version
'dist/YT Downloader Pro 2.app/Contents/Helpers/ffmpeg' -version
'dist/YT Downloader Pro 2.app/Contents/Helpers/ffprobe' -version
'dist/YT Downloader Pro 2.app/Contents/Helpers/qjs' --help
```

The verifier also checks lipo slices, deployment targets, system-only dynamic
dependencies, FFmpeg/FFprobe agreement, all signatures, symlink/inode aliases,
extra executables, required resources, absence of writable app state, exact SBOM
helper hashes, and agreement between executed helper versions and SBOM package
versions.

The SBOM and source index are technical release evidence, not legal approval.
Before a commercial release, complete the legal gate in
`docs/swift-2.0/SBOM_AND_LICENSES.md` and the repository's legal review brief.

Prove the unsupported request fails before assembly:

```bash
./scripts/build_swift_2.sh \
  --version 2.0.1 \
  --architectures universal \
  --sbom-created '<UTC-RFC3339-candidate-timestamp>' \
  --unsigned-test
```

The command must exit nonzero and name the missing x86_64 helper slice. It must
not create a universal app or mix older binaries.

## Developer ID Candidate

List identities and set the exact Application identity:

```bash
security find-identity -v -p codesigning
IDENTITY='Developer ID Application: Example Name (TEAMID)'
TEAM_ID='TEAMID1234'
PROFILE='/absolute/path/to/YT-Downloader-Pro-Developer-ID.provisionprofile'
```

Build with hardened runtime and secure timestamps:

```bash
./scripts/build_swift_2.sh \
  --version 2.0.1 \
  --architectures arm64 \
  --sbom-created '<UTC-RFC3339-candidate-timestamp>' \
  --signing-identity "$IDENTITY" \
  --team-id "$TEAM_ID" \
  --provisioning-profile "$PROFILE"
```

The profile must authorize the exact application identifier
`TEAMID.com.tachouweng.ytdownloaderpro2` and the matching default Keychain
access group. The profile allowlist may express that authorization as the exact
identifier or as a same-Team trailing wildcard such as `TEAMID.*`; the app's
signed entitlements are always emitted as exact identifiers. The script
validates the profile before compiling, emits only the three required
authentication entitlements, embeds the profile, signs each helper with
`--options runtime --timestamp`, generates the SBOM, then signs the outer app
with the generated entitlements. The verifier checks every helper and the app
for a `Developer ID Application` authority and the exact Team ID, then
cross-checks the signed entitlements against the embedded profile before it
executes helper code. Do not use `codesign --deep` to create a release
signature; `--deep` is a verification option here.

Inspect and assess the candidate:

```bash
codesign -dv --verbose=4 'dist/YT Downloader Pro 2.app'
codesign -d --entitlements :- 'dist/YT Downloader Pro 2.app'
security cms -D -i 'dist/YT Downloader Pro 2.app/Contents/embedded.provisionprofile'
codesign --verify --deep --strict --verbose=2 'dist/YT Downloader Pro 2.app'
spctl --assess --type execute --verbose=4 'dist/YT Downloader Pro 2.app'
```

Before notarization, `spctl` may reject an otherwise valid Developer ID build
because no ticket exists. Record that as expected, not as a pass.

## Notarization And Stapling

Create a keychain profile once with Apple credentials according to the local
release account policy. This document uses `YTDP_NOTARY` as the profile name.

Submit the exact ZIP produced by the Developer ID build:

```bash
xcrun notarytool submit \
  'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.zip' \
  --keychain-profile YTDP_NOTARY \
  --wait
xcrun stapler staple 'dist/YT Downloader Pro 2.app'
xcrun stapler validate 'dist/YT Downloader Pro 2.app'
```

After stapling, regenerate the ZIP from the stapled app and rerun verification:

```bash
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.1 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json \
  --signing-mode developer-id \
  --expected-team-id "$TEAM_ID" \
  --report dist/swift-2.0-bundle-report.json \
  --archive dist/YT-Downloader-Pro-2.0.1-macOS-arm64.zip
```

Do not publish unless `notarytool`, `stapler validate`, strict codesign, Gatekeeper
assessment, and an installed launch all pass for this exact candidate.

## DMG

Task 15 does not create a DMG automatically. After the stapled app passes real
device acceptance, create and sign one explicitly:

```bash
hdiutil create \
  -volname 'YT Downloader Pro 2' \
  -srcfolder 'dist/YT Downloader Pro 2.app' \
  -ov -format UDZO \
  'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.dmg'
codesign --force --sign "$IDENTITY" --timestamp \
  'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.dmg'
xcrun notarytool submit \
  'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.dmg' \
  --keychain-profile YTDP_NOTARY \
  --wait
xcrun stapler staple 'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.dmg'
xcrun stapler validate 'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.dmg'
```

Mount, drag to `/Applications`, launch, and run a bundled-helper health check on
the installed copy. Record DMG and ZIP checksums separately.

## Manifest And Checksum

Choose the final published asset first, then compute its checksum:

```bash
shasum -a 256 'dist/YT-Downloader-Pro-2.0.1-macOS-arm64.zip'
```

Generate the checked-in manifest from explicit final values:

```bash
python3 scripts/create_macos_manifest.py \
  --version 2.0.1 \
  --minimum-macos 13.0.0 \
  --release-url 'https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/tag/macos-v2.0.1' \
  --download-url 'https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/download/macos-v2.0.1/YT-Downloader-Pro-2.0.1-macOS-arm64.zip' \
  --sha256 '<64-lowercase-hex-from-shasum>' \
  --published-at '<UTC-RFC3339-timestamp>' \
  --release-notes '<short-release-summary>' \
  --output updates/macos.json
python3 -m json.tool updates/macos.json
```

The filename, manifest URL, uploaded asset, checksum, minimum OS, and release
notes must agree byte-for-byte with the final candidate.

## Tag And GitHub Release Gate

Before publishing, record and compare:

```bash
git rev-parse HEAD
git rev-parse macos-v2.0.1
git status --short
```

The intended commit must contain the source, docs, manifest, and release build
instructions; the worktree must be clean. The tag, GitHub Release target,
packaged plist version, asset names, checksums, and manifest URLs must all agree.
Publishing an asset, creating or moving a tag, and changing the update manifest
are separately authorized release operations and are not performed by the build
script. A reviewed source branch may be pushed independently without announcing
an installable public release.

## Rollback

If a candidate fails before publication, discard the candidate assets, correct
the source, increment the candidate evidence, rebuild from a clean worktree, and
repeat every gate. Never replace helper slices inside a previously signed app.

If a public release must be withdrawn:

1. Mark the GitHub Release unavailable or remove the bad asset without moving an
   existing immutable tag to different source.
2. Restore `updates/macos.json` to the last known-good signed release, or publish
   a higher fixed macOS version. Never point it at the Windows release.
3. Verify the restored manifest checksum and URLs through the Contents API.
4. Preserve the failed candidate, notarization log, checksums, and diagnostic
   report privately for root-cause analysis.
5. Announce the supported rollback/fixed version and rerun the full checklist.
