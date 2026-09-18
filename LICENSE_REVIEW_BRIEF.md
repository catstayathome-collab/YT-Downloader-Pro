# YT Downloader Pro License Review Brief

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for independent license counsel review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-18 |
| Scope | macOS Swift 2.x helper bundle, SBOM, notices, and source-delivery plan |
| Decision rule | No paid or public release without written license guidance |

This brief gives license counsel the current macOS Swift 2.x helper-bundle
facts needed to review open-source obligations before any paid or public
distribution. It is not legal advice, not a source-availability offer, not a
public notice, and not authorization to publish a release, change repository
visibility, accept payment, submit provider forms, send email, or perform any
external account action.

## 1. Requested Work Product

Please provide dated written guidance that:

- identifies the reviewed app version, helper versions, bundle layout, SBOM,
  source index, notices, and distribution assumptions;
- states whether the planned macOS Swift 2.x distribution model is compatible
  with the obligations of the bundled helper set;
- defines the exact notice, license-text, source-availability, written-offer,
  relinking, object-file, and retention obligations for each release artifact;
- identifies what must be published with the app, what may remain in a private
  development repository, and what must be available to binary recipients;
- lists build, checksum, signature, and archive evidence required before each
  public release;
- states what future helper, dependency, signing, packaging, or repository
  visibility changes require a new review.

Verbal guidance, a general license FAQ, or an SBOM consistency test does not
satisfy the paid-launch gate. The final advice should cite the exact release
candidate and evidence files reviewed.

## 2. Current Bundle Facts

The current macOS product line is the Swift `2.x` app. Windows commercial work
is paused and should not be reviewed as part of this brief unless the owner
separately approves a Windows scope.

The Swift app bundles local command-line helpers under
`YT Downloader Pro 2.app/Contents/Helpers/`:

| Helper | Current purpose | Current evidence file |
| --- | --- | --- |
| `yt-dlp_macos` | Media metadata and download execution | `tools/macos-helper-inventory.json` |
| `ffmpeg` | Merge, conversion, and media post-processing | `tools/macos-helper-inventory.json` |
| `ffprobe` | Media probing and helper parity | `tools/macos-helper-inventory.json` |
| `qjs` | Local JavaScript challenge execution for yt-dlp EJS | `tools/macos-helper-inventory.json` |

Release packaging copies the helper files, signs the copied helper binaries,
generates `Contents/Resources/SBOM.spdx.json`, copies license texts and
notices, then signs the outer app. Repository helper files are not modified
during assembly.

The current technical evidence set includes:

- `tools/macos-helper-inventory.json` for reviewed helper names, versions,
  suppliers, declared and concluded SPDX license expressions, canonical helper
  hashes, architectures, license files, and static-link relationships;
- `scripts/generate_swift_sbom.py` and `tests/test_swift_sbom.py` for
  deterministic SPDX 2.3 generation and fail-closed inventory checks;
- `scripts/check_swift_bundle.py` for packaged app verification against the
  independently reviewed inventory;
- `docs/swift-2.0/SBOM_AND_LICENSES.md` for maintenance rules and known
  commercial-release blockers;
- `THIRD_PARTY_NOTICES.md` for human-readable helper notices;
- `SOURCE_AVAILABILITY.md` for a technical source index that is explicitly
  incomplete for public or paid distribution.

## 3. Known License Concerns For Review

Counsel should review these issues for the exact release candidate:

1. The yt-dlp project source is dedicated under the Unlicense, but its official
   macOS standalone executable is a PyInstaller-distributed aggregate that
   upstream describes as GPL-3.0-or-later. The app currently bundles that
   standalone helper rather than rebuilding yt-dlp from source.
2. FFmpeg and FFprobe are represented as LGPL-2.1-or-later in the current
   macOS helper inventory, with LAME represented as LGPL-2.0-or-later and
   statically linked into the bundled FFmpeg/FFprobe helpers.
3. QuickJS is represented as MIT-licensed and bundled as `qjs`.
4. The SPDX SBOM currently inventories the top-level helper toolchain plus the
   known static LAME relationship. It does not expand every transitive
   component inside the yt-dlp standalone aggregate into separate SPDX packages.
5. The current source index is a reproducible provenance aid only. It does not
   claim to provide complete corresponding source for every transitive
   component or an approved relinking/object-file package for static library
   obligations.
6. A private development repository or internal SBOM does not by itself satisfy
   any source, notice, license, or written-offer obligation owed to binary
   recipients.

## 4. Questions For Counsel

Please answer:

1. May the proprietary Swift app be distributed with the current helper
   architecture, or must any helper be replaced, rebuilt, dynamically linked,
   isolated, or distributed separately?
2. What exact obligations apply to distributing the official `yt-dlp_macos`
   standalone executable inside the app bundle?
3. Is the current FFmpeg/FFprobe/LAME static-link arrangement acceptable for the
   planned distribution, and what relinking, object-file, source, or build
   script delivery is required?
4. Does the app need a public source repository, a release-specific source
   archive, a written offer, same-server source hosting, or another delivery
   mechanism for any component?
5. Which notices, license texts, source links, checksum records, build
   configuration records, and warranty disclaimers must appear in the app, on
   the download page, in release notes, and in public policy pages?
6. How long must any source archives, written offers, notices, and release
   records remain available after a binary release?
7. What evidence must be retained privately for each release without exposing
   secrets, payment data, user data, media URLs, local paths, cookies, or raw
   diagnostics?
8. What changes require re-review, including helper upgrades, rebuilt helpers,
   new JavaScript runtimes, package-manager dependencies, universal binaries,
   repository visibility changes, release-hosting changes, or paid-backend code?

## 5. Materials To Review

Before final Go, counsel should review current versions of:

- `COMMERCIAL_FEASIBILITY.md`.
- `LEGAL_REVIEW_BRIEF.md`.
- `PUBLIC_POLICY_DRAFTS.md`.
- `REPOSITORY_AND_SUPPORT_STRATEGY.md`.
- `THIRD_PARTY_NOTICES.md`.
- `SOURCE_AVAILABILITY.md`.
- `docs/swift-2.0/SBOM_AND_LICENSES.md`.
- `tools/macos-helper-inventory.json`.
- `tools/FFMPEG_BUILD_INFO.md` and `tools/QUICKJS_BUILD_INFO.md`.
- `tools/licenses/`.
- `scripts/generate_swift_sbom.py`, `scripts/check_swift_bundle.py`, and
  `tests/test_swift_sbom.py`.
- The exact signed, notarized, and stapled release candidate before any public
  distribution.

Do not include credentials, Apple signing keys, payment-provider secrets,
Google OAuth secrets, customer records, media URLs, download titles, local file
paths, browser cookies, raw diagnostics, downloaded media, or private legal
advice in a public source-delivery package.

## 6. Evidence Record

Do not store confidential legal advice in a future public repository. Record
only decision metadata here and keep detailed guidance in a restricted evidence
store.

| Field | Value |
| --- | --- |
| Counsel/firm | Not selected |
| Engagement date | Not started |
| Release candidate reviewed | Not available |
| Materials supplied | Not supplied |
| Guidance date | Not available |
| Distribution model approved | Unknown |
| Source-delivery plan approved | Unknown |
| Notice package approved | Unknown |
| Required release blockers | Unknown |
| Re-review triggers | Unknown |
| Restricted evidence location | Not available |
| Owner final decision | No-Go pending license guidance |

## 7. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- public or paid distribution of a macOS release candidate;
- production checkout, recurring billing, ECPay setup, refund, or cancellation
  actions;
- repository visibility changes or public source-availability claims;
- public Terms, Acceptable Use, Privacy Policy, refund, cancellation, or
  marketing publication;
- Windows commercial implementation.

## 8. Primary References

- [yt-dlp README licensing notes](https://github.com/yt-dlp/yt-dlp/blob/master/README.md).
- [FFmpeg License and Legal Considerations](https://ffmpeg.org/legal.html).
- [QuickJS licensing notes](https://bellard.org/quickjs/).
- [SPDX specifications](https://spdx.dev/use/specifications/).
- [CycloneDX specification overview](https://cyclonedx.org/specification/overview/).
