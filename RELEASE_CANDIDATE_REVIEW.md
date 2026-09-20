# YT Downloader Pro Release Candidate Review

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for internal Phase 1 release-candidate evidence review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-20 |
| Scope | macOS Swift 2.x release-candidate evidence only |
| Launch rule | No public or paid release without dated professional and owner approval |

This document defines the internal evidence packet needed before any macOS
Swift 2.x release candidate can be treated as publishable. It is not legal
advice, not a source-availability offer, not publication approval, not payment
approval, and not authorization to submit provider forms, send email, change
repository visibility, publish a release, accept payment, or perform another
external account action.

## 1. Review Boundary

Phase 1 may assemble local evidence, run tests, and record review metadata for
internal release candidates only. A release candidate remains No-Go for public
or paid distribution until all launch gates in `COMMERCIAL_FEASIBILITY.md` are
closed with dated evidence and fresh owner approval.

Windows commercial release work remains paused. Windows artifacts, helper
updates, update manifests, signing plans, and public-support surfaces must not
be included in this review unless the owner separately approves a Windows scope.

The review packet must exclude:

- production ECPay secrets, Merchant ID, HashKey, HashIV, bank details, and
  payment credentials;
- Apple signing private keys, provisioning secrets, API keys, and notarization
  credentials;
- Google OAuth secrets, backend credentials, support-vendor tokens, and email
  credentials;
- customer records, waitlist exports, support tickets, identity documents,
  media URLs, download titles, local paths, browser cookies, raw diagnostics,
  screenshots with personal data, and downloaded media.

## 2. Candidate Identity

Each candidate must have one immutable review record:

| Field | Required value |
| --- | --- |
| Candidate ID | Internal build identifier, version, and commit SHA |
| Product line | macOS Swift 2.x only |
| Build environment | macOS version, Xcode/Swift version, architecture, and build host class |
| Artifact names | App bundle, ZIP or DMG, update manifest, SBOM, notices, and source packet names |
| Artifact hashes | SHA-256 for every file proposed for distribution |
| Signing status | Developer ID, hardened runtime, nested helper signing, notarization, and stapling result |
| Verification date | Date and reviewer for each evidence class |
| Final disposition | Internal-only, rejected, held for external review, or approved after owner Go |

Never overwrite a candidate record under the same ID. If any artifact changes,
create a new candidate ID and rerun the affected evidence.

## 3. Required Evidence

Before external review or publication, collect evidence for:

- strict macOS Swift 2.x tests with strict concurrency and warnings as errors;
- repository helper inventory and SBOM checks from `tests.test_swift_sbom`;
- packaged-app verification through `scripts/check_swift_bundle.py` against
  `tools/macos-helper-inventory.json`;
- Developer ID signing, hardened runtime, notarization, stapling, and
  Gatekeeper assessment for the exact artifact;
- installed-app smoke tests on clean supported Macs, including first launch,
  update-check presentation, single-download analysis, cancellation, local
  history, diagnostics preview, export preview, and deletion preview;
- release-specific third-party notices, license texts, SBOM, and
  `SOURCE_AVAILABILITY.md` review status;
- public-copy and localization review for release notes, download pages,
  update dialogs, support text, source-availability notices, and screenshots;
- privacy/operations review for support payloads, data export, deletion,
  credential rotation, incident response, cancellation, refund, shutdown, and
  backup evidence;
- rollback evidence proving the previous known-good artifact and update
  manifest remain available if publication is later approved.

Passing a build, notarization, or SBOM check proves only that the internal
candidate is technically assembled. It does not clear legal, accounting,
payment-provider, license, privacy, localization, support, or owner-approval
gates.

## 4. Source Availability And License Check

The candidate packet must separate three classes of material:

| Class | Examples | Publication status |
| --- | --- | --- |
| Public bundle material | License texts, third-party notices, SBOM, approved source-availability text | Publish only after counsel approves the exact candidate |
| Restricted evidence | Counsel guidance, provider/accountant responses, private build records | Keep restricted; record only metadata in the repository |
| Excluded material | Secrets, customer data, media activity, raw diagnostics, signing keys | Never include in candidate packets |

`SOURCE_AVAILABILITY.md` is currently incomplete for public or paid
distribution. A candidate cannot be marked publishable until counsel approves
the source-delivery plan for the exact yt-dlp standalone aggregate,
FFmpeg/FFprobe/LAME integration, QuickJS bundle, notices, retention period, and
delivery mechanism.

If counsel requires a public source archive, written offer, object-file package,
relinking package, or public repository, record the exact file names, hashes,
hosting location, retention rule, and owner approval before publication. Do not
infer that a private repository, internal SBOM, or local source index satisfies
binary-recipient obligations.

## 5. Clean-Mac Acceptance

At least one reviewer must install the exact signed and stapled candidate on
clean supported Macs before final Go. The record should include:

- macOS version, CPU architecture, and whether the machine had prior app data;
- artifact hash, notarization ticket evidence, and Gatekeeper assessment;
- first-launch result, helper execution result, and update-check behavior;
- local privacy checks proving no support, analytics, sync, email, vendor,
  payment, or backend network path was added without approval;
- known issues, rollback decision, and whether the candidate is internal-only
  or ready for external professional review.

Clean-Mac testing must not use customer data, production payment credentials,
production OAuth credentials, support-vendor credentials, or media that the
owner is not authorized to use for testing.

## 6. Decision Record

Record only non-confidential review metadata in this repository:

| Evidence | Status |
| --- | --- |
| Candidate ID and commit | Not available |
| Strict Swift suite | Not available |
| SBOM/license tests | Not available |
| Packaged-app verifier | Not available |
| Developer ID signing | Not available |
| Notarization and stapling | Not available |
| Clean-Mac smoke tests | Not available |
| License counsel disposition | Not started |
| Taiwan legal disposition | Not started |
| Accounting disposition | Not started |
| Payment-provider disposition | Not started |
| Public-copy/localization disposition | Not started |
| Privacy/operations disposition | Not started |
| Owner final decision | No-Go pending dated evidence |

Keep privileged advice, confidential provider replies, signing logs containing
account identifiers, and detailed support or customer evidence in the restricted
evidence store. Repository entries should be version identifiers, dates,
reviewer roles, non-secret hashes, and non-confidential disposition summaries.

## 7. Stop Conditions

The candidate must remain internal-only or be rejected if:

- the source-availability or relinking plan remains incomplete;
- counsel, accountant, payment provider, licensing counsel, privacy reviewer,
  localization reviewer, or the owner has not approved the exact candidate;
- notarization, stapling, Gatekeeper, bundle verification, strict tests, or
  clean-Mac smoke tests fail;
- public copy implies official YouTube affiliation, guaranteed downloads,
  guaranteed legal permission, hidden recurring terms, or paid availability
  before launch gates close;
- support, export, deletion, analytics, sync, email, billing, or backend paths
  collect more user data than the reviewed local-first boundary allows;
- publication would require repository visibility changes, provider setup,
  billing enablement, email, vendor setup, or another external account action
  without fresh explicit owner approval.

## 8. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- public or paid distribution of a macOS release candidate;
- production checkout, recurring billing, ECPay setup, refund, or cancellation
  actions;
- public source-availability claims, repository visibility changes, release
  publishing, or update-manifest publication;
- public Terms, Acceptable Use, Privacy Policy, refund, cancellation, support,
  marketing, launch, or localized-copy publication;
- support email, ticket submission, external forms, analytics, sync, crash
  reporting, or vendor setup;
- Windows commercial implementation.
