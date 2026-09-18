# Swift 2.0 SBOM And License Maintenance

## Purpose And Boundary

Every macOS Swift 2.x candidate must carry machine-readable component evidence
and the license texts needed to review the exact bundled helper set. This process
reduces accidental omissions; it does not decide whether a commercial product
is legally permitted. A qualified lawyer must review the final distribution
model, source-delivery method, notices, and any copyleft obligations before a
paid release is enabled. `LICENSE_REVIEW_BRIEF.md` tracks the counsel-facing
questions and restricted evidence record for that review.

## Canonical Inputs

`tools/macos-helper-inventory.json` is the single reviewed inventory for the
macOS helper toolchain. Each component records:

- component name, version, supplier, upstream HTTPS location, and source notes;
- declared and concluded SPDX license expressions;
- exact SHA-256 values and architectures for owned helper executables;
- exact SHA-256 values for every bundled license text;
- static-link relationships for components such as LAME.

The inventory must own exactly these helper names once:

```text
yt-dlp_macos
ffmpeg
ffprobe
qjs
```

Do not edit a helper in place and then merely update its hash. For any helper
change, record the upstream release, verify its official checksum or reproducible
source build, inspect architecture and dynamic dependencies, update the matching
license evidence, and review the complete inventory diff.

## Why Two Helper Hashes Exist

macOS code signing changes executable bytes. Therefore a release has two valid
hash layers:

1. The inventory records the reviewed repository helper before candidate
   re-signing.
2. `Contents/Resources/SBOM.spdx.json` records the helper after it is copied and
   signed for that exact app candidate.

`scripts/generate_swift_sbom.py` validates layer 1 through
`--source-helper-root`, reads layer 2 through `--helper-root`, and writes both
values into the SPDX document. Generate the SBOM after signing nested helpers
but before signing the outer app. Generating it earlier produces stale hashes;
generating it after outer signing invalidates the app signature.

## yt-dlp License Distinction

The yt-dlp project source is dedicated under the Unlicense. The official macOS
standalone executable is built with PyInstaller and includes additional
GPL-licensed components. Upstream describes that distributed combined executable
as GPL version 3 or later. For that reason the bundle carries all three of these
files from the exact `2026.07.04` upstream tag:

```text
GPL-3.0-or-later.txt
yt-dlp-Unlicense.txt
yt-dlp-THIRD_PARTY_LICENSES.txt
```

Do not replace this with only the short yt-dlp Unlicense text. When yt-dlp is
upgraded, retrieve the exact tag's release checksum, source archive, Unlicense,
and `THIRD_PARTY_LICENSES.txt`, then update all pinned hashes together.

## Generation And Verification

For a repository-level inventory check:

```bash
python3 -m unittest tests.test_swift_sbom -v
```

The production build runs the generator automatically. Its relevant order is:

```text
copy helpers -> sign helpers -> generate SBOM -> sign app -> verify app -> ZIP
```

The fail-closed verifier requires the SPDX file, exact license set, source index,
and notices. It compares every SPDX helper checksum with the packaged bytes and
compares each executable's reported version with the matching SPDX package.

```bash
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.0 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json
```

The inventory argument is mandatory. The verifier checks repository source
helper hashes and repository license hashes first, then compares the SBOM and
bundle resources against that independently reviewed input. A self-consistent
replacement SBOM/license pair is therefore rejected.

## Scope And Known Limits

The SPDX document inventories the top-level helper toolchain plus the known
static LAME dependency. The exact yt-dlp aggregate license file is bundled to
cover the transitive components included by its official standalone executable;
those transitive components are not expanded into separate SPDX packages by this
generator. Expanding them is future audit work and may be required by counsel or
a distributor.

## Public Distribution Blocker

The current source index is not a complete corresponding-source distribution.
In particular, the official yt-dlp standalone aggregate includes Python,
readline, and other transitive components listed in its exact upstream license
aggregate. The current FFmpeg/LAME static-link delivery also does not include an
application object/relinking package. Until counsel defines and approves the
required complete-source and relinking delivery, this repository may produce
internal candidates only. Passing the build or verifier does not clear this
blocker.

`SOURCE_AVAILABILITY.md` is a reproducible technical index. It is deliberately
not described as a legal written offer. Counsel must determine whether hosting
source archives, providing an offer, or another delivery mechanism is required
for the planned distribution.

## Commercial Release Gate

Do not enable paid distribution until all of the following are written and
reviewed for the exact candidate:

1. Legal confirmation of the yt-dlp standalone GPL obligations and compatibility
   with the proprietary app distribution model.
2. A compliant source-availability procedure that remains available for the
   required period.
3. Confirmation that FFmpeg/LAME build options and relinking/source obligations
   are satisfied.
4. Final notices, privacy terms, payment-provider approval, Developer ID signing,
   notarization, and installed-device acceptance evidence.

An SBOM test passing proves internal consistency only. It is not permission to
publish, charge users, or change repository visibility.
