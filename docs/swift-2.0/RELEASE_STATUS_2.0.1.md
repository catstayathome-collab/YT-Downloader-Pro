# macOS 2.0.1 Public Release Status

## Scope

This is the single status page for the free, no-account, no-payment macOS
2.0.1 release. It does not authorize publication and it does not cover Google
login, Apple login, Pro entitlement, ECPay, analytics, cloud history, or
external support submission.

Last reviewed: 2026-09-21

## Verified Internal Candidate

| Evidence | Result |
| --- | --- |
| Baseline source commit | `96678c8e04679e3e82b8fd37d723985cb0476560` |
| Internal app version | `2.0.1` |
| Architecture | Apple Silicon `arm64`; bundled yt-dlp is universal |
| Swift strict suite | 461 tests, 1 skipped, 0 failures |
| Python suite | 245 tests, 0 failures |
| Independent bundle verifier | Passed with no errors |
| Strict bundle signature check | Passed for the ad-hoc internal candidate |
| Internal ZIP SHA-256 | `b7b705dd8b3ed4884bb2b1279c01100b4f7634577c3235ff44e84f9b074a9f0c` |

The internal ZIP is not a public artifact. Its ad-hoc signature is useful only
for local bundle-integrity testing.

## Current Public Release Gates

| Gate | Status | Evidence or next action |
| --- | --- | --- |
| Frozen 2.0.1 feature scope | Pass | No login, payment, entitlement, analytics, sync, or external submission in release mode |
| Developer ID Application identity | Blocked | Xcode exposes only a Personal Team; `security find-identity` reports zero valid code-signing identities |
| Notarytool Keychain profile | Blocked | `YTDP_NOTARY` is absent |
| Developer ID build | Blocked | Requires paid-team identity, Team ID, and matching provisioning profile |
| Notarization and stapling | Blocked | Requires Developer ID build and notary profile |
| Gatekeeper and clean-Mac install | Blocked | Requires the exact stapled candidate |
| Source availability and license review | Blocked | `SOURCE_AVAILABILITY.md` remains incomplete for yt-dlp transitive source and static FFmpeg/LAME relinking obligations |
| Free-product legal/platform review | Blocked | Written review required for platform, copyright, acceptable-use, privacy, naming, and public claims |
| Public Traditional Chinese and English copy | In review | Payment and accountant review are not required for copy that contains no paid claims |
| Public update manifest | Blocked | `updates/macos.json` remains a non-release placeholder until the final signed artifact and checksum exist |
| `macos-v2.0.1` tag and GitHub Release | Blocked | Create only after every prior gate passes and the owner gives final Go |

## Apple-Independent Release Preparation

The following work is complete on `codex/public-macos-2.0.1`:

- `tools/macos-source-archives.json` pins the four top-level source archives,
  HTTPS locations, SHA-256 values, evidence files, and unresolved limitations;
- `scripts/create_macos_source_review_packet.py` creates deterministic,
  explicitly internal-only metadata or archive review packets and rejects
  missing or modified source inputs;
- `scripts/check_macos_public_release_readiness.py` reports the
  machine-verifiable release gates without leaking raw credential or Keychain
  errors;
- all four pinned top-level source archives were downloaded from their recorded
  HTTPS locations and matched the inventory SHA-256 values;
- `dist/YT-Downloader-Pro-2.0.1-source-review.zip` was generated locally with
  all four archives and SHA-256
  `d5e35ee450343bc6d6421616dd02055b3b9bb338c364579b8119bc985ef6ede4`;
- the preflight correctly remains blocked by the placeholder manifest, missing
  source-distribution approval, Developer ID identity, and notary profile.

These controls reduce accidental publication risk. They do not resolve the
legal, source-delivery, Apple signing, notarization, or clean-Mac gates.
The generated ZIP is ignored by Git and must remain an internal review artifact.

## Next Actions

1. Enroll or add an active paid Apple Developer Program team in Xcode, then
   create and install a `Developer ID Application` identity.
2. Create the `YTDP_NOTARY` Keychain profile without storing credentials in the
   repository, logs, or app bundle.
3. Obtain release-specific legal and licensing dispositions for the free
   candidate, including the exact source-delivery or relinking package.
4. Rebuild 2.0.1 from the final source commit with Developer ID, notarize and
   staple it, then rerun bundle, Gatekeeper, installation, and smoke tests.
5. Generate the final ZIP or DMG, checksum, release notes, and public manifest;
   compare every identifier before the final owner Go and publication.
