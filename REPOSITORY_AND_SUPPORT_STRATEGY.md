# YT Downloader Pro Repository And Support Strategy

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 governance decision proposal |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-08-26 |
| Scope | Source visibility, public releases, updates, feedback, and support |

No repository visibility, release endpoint, or support system is changed by
this document. Each external change requires a reviewed migration checklist and
fresh owner approval.

## 1. Decision

Adopt a two-surface model before paid backend work begins:

1. A private development repository contains active macOS source, future paid
   backend code, entitlement policy, security design, compliance evidence, and
   internal operations.
2. A public release/support surface contains signed binaries or download links,
   release notes, checksums, platform-specific update manifests, public status,
   user documentation, and a privacy-safe support entry point.

The current repository should not be made private impulsively. Previously
published source and clones cannot be made secret retroactively, public forks
may remain public, and existing update/release workflows can break. Migration
occurs only after the inventory and gates in this document are complete.

Repository privacy protects future operational and proprietary work. It is not
a substitute for secret management, legal compliance, code signing, license
compliance, or security review.

## 2. Recommended Repository Layout

### Private development repository

Recommended name: `YT-Downloader-Pro` or a renamed internal equivalent.

Contains:

- `swift-2.0/` macOS application source and tests;
- future account, billing, entitlement, support, and admin services;
- build and release automation without production secret values;
- architecture, threat models, incident runbooks, and compliance drafts;
- dependency lock files and Software Bill of Materials generation;
- internal issue and pull-request history.

Production secrets remain in a managed secret store and CI environment, never
in Git history, workflow logs, release archives, app bundles, or documentation.

### Public release and support repository or website

Recommended separate name: `YT-Downloader-Pro-Releases` if GitHub is used.

Contains only reviewed public material:

- signed and notarized macOS release artifacts or links;
- detached checksums/signature metadata;
- `updates/macos.json` and later `updates/windows.json` as separate manifests;
- release notes, supported macOS versions, known issues, and rollback guidance;
- public privacy policy, terms, acceptable-use policy, refund/cancellation
  policy, third-party notices, and source-availability notices;
- status and support links.

It must not contain the paid backend, private keys, ECPay values, OAuth secrets,
customer tickets, download history, private diagnostics, or compliance evidence.

### License-source delivery

Private development does not remove open-source obligations. For each binary
release, create a release-specific license inventory and legal decision about
Corresponding Source. Where required, provide source to binary recipients using
a reviewed source archive, public source repository, or valid written-offer
process. Do not assume that a private repository by itself satisfies GPL or
other license requirements.

## 3. Visibility Migration Gates

Before changing the current GitHub repository to private:

- [ ] Confirm its live visibility, owner, default branch, collaborators, forks,
      stars/watchers, Pages, Discussions, Issues, Actions, environments,
      packages, webhooks, deploy keys, releases, tags, and branch protections.
- [ ] Identify every app update URL, README link, website link, release link,
      and support link that depends on the public repository.
- [ ] Export or preserve public release notes and required source/license
      material.
- [ ] Create and test the public release/support surface first.
- [ ] Confirm both macOS and Windows manifests remain independently reachable
      without private GitHub authentication.
- [ ] Run a complete secret-history scan and rotate anything that may have been
      exposed. Making a repository private does not rotate a secret.
- [ ] Obtain legal approval for the release-specific source delivery plan.
- [ ] Test update checks from an older clean app against the replacement public
      manifest.
- [ ] Record a rollback plan and exact repository settings.
- [ ] Obtain fresh owner approval for the visibility change.

GitHub documents that changing public visibility can detach public forks,
remove stars/watchers, affect GitHub Pages, and change security-feature
availability. Exact consequences must be reviewed against the live repository
immediately before migration.

## 4. Branch And Release Governance

- Protect `main`; require pull requests, passing tests, and at least one
  documented review before production release.
- Use `codex/` for autonomous development branches unless a release workflow
  specifies another prefix.
- Keep macOS Swift `2.x` and Windows Python `1.8.x` release artifacts and update
  manifests separate.
- Tag releases with unambiguous platform/version naming when product lines can
  differ, for example `macos-v2.0.1` and `windows-v1.8.8`.
- A public manifest points only to signed reviewed artifacts and includes
  version, minimum OS, architecture, checksum, release notes, and rollout state.
- Never rewrite or replace a published release asset under the same version.
- Preserve the previous known-good artifact and a documented rollback path.

Windows development remains paused until the macOS product and commercial
requirements are stable, as approved by the product owner.

## 5. In-App Feedback Feature

Add `Help > Send Feedback` and a matching Settings/Support entry. The action
opens a first-party HTTPS support form or portal. It must not silently send a
diagnostic report when clicked.

### Ticket categories

- Download failure
- Bug or crash
- Feature suggestion
- Subscription or payment
- Privacy or account
- Copyright, authorization, or misuse report

### Default submitted fields

- user-selected category;
- user-written subject and description;
- app version and release channel;
- macOS version and CPU architecture;
- app locale;
- optional normalized error category and local incident reference.

### Excluded by default

- source URL, video ID, title, channel, thumbnail, or playlist;
- destination path, username, browser profile, or local history;
- browser cookies, authorization headers, PO Tokens, signatures, or media URLs;
- full stdout/stderr, full diagnostics, screenshots, or downloaded files;
- payment secrets, identity documents, full card/bank data, or passwords.

The form displays the exact automatically added fields before submission. Logs
or screenshots use separate opt-in controls, are sanitized locally, and receive
a final preview. The user can remove every optional attachment.

## 6. Support Routing And Service Definition

Free support:

- public documentation, FAQ, known issues, release notes, and status page;
- asynchronous community/self-service path;
- security, privacy, payment, and copyright reports remain directly reachable.

Pro support:

- asynchronous priority queue for product-use and download-failure tickets;
- target initial human response defined in business hours after staffing data
  exists;
- no promise of immediate response, guaranteed download, guaranteed upstream
  compatibility, or resolution of content-rights restrictions.

Paid priority must never delay security vulnerabilities, privacy incidents,
incorrect charges, cancellation, account recovery, or legal complaints. Those
categories route by severity and obligation rather than subscription tier.

At NT$80 per month, support must be intentionally bounded. Measure ticket rate,
median handling time, repeat contacts, resolution category, and self-service
deflection without tracking users' media activity.

## 7. Support Security And Privacy Controls

- Require HTTPS, CSRF protection, bot/rate controls, and attachment malware
  scanning.
- Authenticate account/payment tickets, but allow a separate route for privacy,
  security, copyright, and pre-purchase reports.
- Apply least-privilege roles and audit every ticket access and billing action.
- Never ask for an account password, Google authorization code, cookie export,
  PO Token, identity-document image, or full payment credential in support.
- Use case numbers rather than download URLs as internal references.
- Define retention by category; do not retain ordinary diagnostics forever.
- Support deletion requests while preserving only records legally required for
  tax, payment disputes, security, or legal claims.
- Document incident escalation and credential-rotation procedures in
  `OPERATIONS_RUNBOOK.md`.

The detailed field inventory and retention decisions remain governed by
`PRIVACY_DATA_MAP.md`. Public Terms, Acceptable Use, Privacy Policy, refund,
cancellation, complaint, and marketing-claim drafting gates are governed by
`PUBLIC_POLICY_DRAFTS.md`. Helper-bundle, SBOM, notice, and source-delivery
review gates are governed by `LICENSE_REVIEW_BRIEF.md`.

## 8. Public Issue Tracker Boundary

If a public GitHub issue tracker is enabled, it is for reproducible product
bugs and feature requests only. The issue template must warn users not to post
URLs, download history, paths, emails, receipts, account information, cookies,
tokens, diagnostics, or screenshots containing personal data.

Payment, privacy, account, copyright, security, and private diagnostics must go
to the first-party support portal. Public issue content is not treated as a
confidential support channel.

## 9. Delivery Sequence

1. Complete legal, payment-provider, privacy, and license reviews.
2. Inventory the live GitHub repository and all public dependencies.
3. Define public release/support hosting and test both update manifests.
4. Create private development and public release/support boundaries.
5. Implement the feedback UI against a non-production test endpoint.
6. Add local redaction, preview, deletion, routing, retention, and abuse tests.
7. Pilot support with closed testers and measure support cost.
8. Obtain owner approval before repository visibility changes or public launch.

## 10. Acceptance Criteria

- An older public app can check for an update without private-repository access.
- A clean Mac can download and verify the current signed public artifact.
- macOS and Windows update manifests cannot overwrite or misroute each other.
- No production secret exists in any repository or app bundle.
- Every binary release has a license inventory and approved source-delivery
  record.
- Feedback submission shows a preview and transmits no excluded field by
  default.
- Sanitization tests cover URLs, paths, cookies, tokens, signatures, headers,
  diagnostics, and screenshots/attachments.
- Critical support categories bypass subscription-tier priority.
- Repository migration and rollback are documented and owner-approved.

## 11. References

- [GitHub: Setting repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
- [GitHub: About repositories](https://docs.github.com/en/repositories/creating-and-managing-repositories/about-repositories)
- [GNU GPLv3 quick guide](https://www.gnu.org/licenses/quick-guide-gplv3.pdf)
- [yt-dlp README and licensing notes](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)
