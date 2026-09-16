# YT Downloader Pro Public Policy Drafts

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 policy draft scaffold |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-16 |
| Scope | macOS Swift 2.x validation, future public website, and support surface |
| Launch rule | Counsel, accountant, provider, and owner approval required before publication |

This document defines the policy topics and evidence YT Downloader Pro must
prepare before a paid public launch. It is not legal advice, not a public Terms
of Use, not an approved Privacy Policy, and not authorization to publish a
release, accept payment, submit provider forms, send email, or change repository
visibility.

## 1. Drafting Boundary

Phase 1 policy work may create internal drafts and review checklists only.
Public-facing text must not be published until:

- Taiwan counsel approves the Terms of Use, Acceptable Use Policy, Privacy
  Policy, refund and cancellation rules, complaint process, and marketing claims;
- an accountant confirms tax, invoice, refund, and retention obligations;
- ECPay or the selected provider approves the disclosed product, recurring
  billing model, cancellation path, refund handling, and merchant category;
- the owner signs a final Go decision that links to the dated evidence.

No policy draft may imply official YouTube affiliation, guaranteed download
rights, guaranteed upstream availability, or paid availability before launch
gates close.

## 2. Terms Of Use Draft Requirements

The Terms draft must cover:

- product identity, owner contact route, supported platform, and outside-App-
  Store distribution;
- local-first media processing and the user's responsibility to download only
  content they own, have permission to use, or are legally allowed to preserve;
- free and Pro feature descriptions without weakening safety, privacy,
  diagnostics, updates, or critical recovery for free users;
- account creation, authentication, entitlement checks, and the rule that Google
  identity is not the billing authority;
- subscription renewal, cancellation, paid-through access, refund route, service
  changes, and shutdown handling after provider/legal review;
- support scope, asynchronous response target, excluded emergency support, and
  upstream-breakage limitations;
- license and third-party component notices, including release-specific source
  availability where required;
- limitation, suspension, termination, governing-law, dispute, and contact
  language reviewed by counsel.

The Terms draft must not ask users to waive non-waivable consumer rights or
hide recurring-charge, cancellation, refund, source-availability, or privacy
terms in secondary pages.

## 3. Acceptable Use Draft Requirements

The Acceptable Use Policy draft must state that YT Downloader Pro is intended
for authorized preservation and personal workflows, not for infringement,
account abuse, platform evasion, harassment, credential theft, or resale of
downloaded media.

At minimum, it must address:

- copyright and user-authorization responsibilities;
- prohibition on sharing cookies, account credentials, payment credentials, or
  identity documents with support;
- prohibition on using the product to access content without permission or to
  defeat access controls in a way counsel disallows;
- complaint intake for copyright, misuse, privacy, security, payment, and
  account-recovery issues;
- suspension or termination triggers for abuse, fraud, chargeback abuse,
  support harassment, or legal risk;
- preservation of critical support routes for security, privacy, payment,
  cancellation, copyright, and account recovery regardless of Pro status.

## 4. Privacy Policy Draft Requirements

The Privacy Policy draft must be derived from `PRIVACY_DATA_MAP.md` and the
implemented macOS Swift 2.x boundaries, not from generic SaaS copy.

It must distinguish:

- local app data that stays on the user's Mac by default;
- account identity data needed for authentication and entitlement;
- billing references and subscription state handled with ECPay or the approved
  provider, excluding full card or bank credential storage;
- user-reviewed support submissions and optional attachments;
- local export and deletion controls;
- any future approved analytics, crash reporting, or history synchronization.

The draft must say that media URLs, titles, local output paths, browser cookies,
downloaded files, thumbnails, detailed diagnostics, and local history are not
operator-service data by default. If a future feature changes that boundary, it
requires a separate approved design, opt-in controls, retention rule, export and
deletion path, and updated public notice.

## 5. Refund And Cancellation Draft Requirements

Refund and cancellation language must stay provider-reviewed and test-backed.
Before publication, the project needs evidence for:

- how a user cancels recurring billing and receives a confirmation reference;
- the paid-through date or immediate-end rule;
- refund eligibility, partial-period treatment, upstream service breakage,
  duplicate billing, chargebacks, and incorrect-charge routing;
- payment-provider reconciliation after cancellation, refund, failed callback,
  duplicate callback, and chargeback;
- what happens when the user deletes local history, deletes the app, logs out,
  disconnects Google, or requests account deletion;
- support escalation for users who cannot access the account route.

Deleting the local app, clearing local history, or removing downloaded media
must never be described as cancelling a subscription.

## 6. Complaint And Notice Process

The public support surface must provide separate intake for:

- download or analysis failures;
- app bugs and feature suggestions;
- subscription, cancellation, refund, and incorrect-charge issues;
- privacy and account data requests;
- security reports;
- copyright, authorization, misuse, or legal complaints.

Security, privacy, copyright, cancellation, incorrect-charge, and account-
recovery reports bypass paid-priority routing. Public issue trackers are not
confidential support channels and must warn users not to post URLs, receipts,
emails, paths, diagnostics, cookies, tokens, screenshots, or downloaded media.

## 7. Marketing And Website Claims

Landing-page and public-release copy must stay honest and narrow:

- no false scarcity, fake countdowns, guaranteed compatibility, guaranteed
  downloads, official YouTube relationship, legal-permission claims, or hidden
  recurring-charge terms;
- clearly state that users are responsible for having rights or permission for
  the content they download;
- distinguish waitlist, closed beta, free features, and paid features;
- disclose important limits, supported platform, support scope, privacy posture,
  cancellation route, refund route, and source-availability notices where
  applicable.

## 8. Evidence Register

Before publication, maintain an internal register with:

| Evidence | Minimum content |
| --- | --- |
| Legal review | Reviewer, date, policy version, issues, final disposition |
| Accountant review | Tax, invoice, refund, retention, and entity guidance |
| Provider review | Product disclosure, merchant category, recurring billing, refund and cancellation answers |
| Owner approval | Signed Go decision linking reviewed policy versions |
| Localization check | Traditional Chinese and English consistency if both are published |
| Website check | Final published copy matches approved versions |
| Support route check | Intake categories, privacy warning, and escalation routing verified |

The evidence register must not include secret values, full payment data, media
URLs, download titles, local paths, cookies, raw diagnostics, or downloaded
files.

## 9. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- publishing Terms, Acceptable Use Policy, Privacy Policy, refund rules, or
  cancellation rules as final public commitments;
- production ECPay configuration, checkout, recurring billing, cancellation, or
  refund actions;
- support email, ticket submission, external forms, or vendor setup;
- public release publishing, repository visibility changes, or public source-
  availability claims;
- Windows commercial implementation.
