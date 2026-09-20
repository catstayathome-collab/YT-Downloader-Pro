# YT Downloader Pro Public Copy And Localization Review

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for internal Phase 1 review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-19 |
| Scope | macOS Swift 2.x public copy, Traditional Chinese, and English review |
| Launch rule | No public publication without counsel, accountant, provider, localization, and owner approval |

This document defines the internal review criteria for landing-page copy,
public policy summaries, app-facing purchase text, support text, launch posts,
and FAQ wording before any public or paid YT Downloader Pro release. It is not
legal advice, not a translation approval, not a public source of truth, and not
authorization to publish a website, send email, submit provider forms, change
repository visibility, accept payment, or release software.

## 1. Review Boundary

Phase 1 may prepare review checklists, sample wording, and copy inventories
only. Public Traditional Chinese or English text must not ship until:

- Taiwan counsel approves the legal, copyright, privacy, consumer, complaint,
  cancellation, refund, and marketing claim wording;
- an accountant approves any tax, invoice, seller identity, receipt, retention,
  refund, and chargeback wording;
- ECPay or the selected payment provider approves product, recurring billing,
  cancellation, refund, fee, settlement, and merchant-category disclosures;
- licensing counsel approves source-availability, notice, and third-party
  component statements for the exact release artifact;
- a bilingual reviewer checks Traditional Chinese and English consistency;
- the owner signs a final Go decision linking the dated evidence.

No localized copy may imply that a translation softened or expanded the
approved English or Chinese commitment. If the two languages differ, the review
record must identify which version controls and why counsel accepted the
difference.

## 2. Copy Inventory

Before review, collect the exact text or screenshots for every public or
purchase-adjacent surface:

- landing page, waitlist, pricing table, FAQ, and product screenshots;
- Terms of Use, Acceptable Use Policy, Privacy Policy, refund and cancellation
  pages, complaint process, support policy, and source-availability notices;
- checkout, renewal, cancellation, refund, failed-payment, and receipt text;
- app onboarding, login, entitlement, paywall, error, diagnostics, export,
  deletion, update, and shutdown text;
- support intake category labels, privacy warnings, and diagnostic consent;
- Instagram profile link copy, launch posts, captions, story frames, and reels;
- repository or release-page copy if a public support surface is approved.

Screenshots and copy packets must exclude credentials, ECPay HashKey/HashIV,
Merchant ID, bank details, identity documents, media URLs, download titles,
local paths, cookies, raw diagnostics, and downloaded media.

## 3. Claim Review Criteria

Every public claim must be traceable to approved evidence:

| Claim type | Required evidence before publication |
| --- | --- |
| Paid availability | Provider approval, legal review, accountant review, owner Go |
| Price or renewal | Provider terms, tax/invoice guidance, refund/cancellation review |
| Download capability | Tested release candidate and bounded upstream-risk language |
| Legal permission | Counsel-approved user-responsibility and acceptable-use wording |
| Privacy posture | `PRIVACY_DATA_MAP.md`, implemented Swift behavior, counsel review |
| Support response | Measured support capacity and approved asynchronous support target |
| Source availability | License review for exact artifact and delivery mechanism |
| Platform support | Tested macOS release matrix and distribution evidence |

Disallowed claims include official YouTube affiliation, guaranteed downloads,
guaranteed upstream availability, legal permission to download all content,
false scarcity, hidden recurring terms, unlimited priority support, unlimited
refunds, or claims that deleting the app cancels a subscription.

## 4. Localization Rules

Traditional Chinese and English copy must preserve the same user commitments:

- price, renewal cadence, cancellation route, paid-through access, refund
  route, and support scope must match exactly after provider/accounting review;
- legal and acceptable-use wording must keep the same permission limits,
  copyright warnings, complaint route, and no-affiliation statements;
- privacy wording must preserve the local-first boundary: media URLs, titles,
  local output paths, browser cookies, downloaded files, thumbnails, detailed
  diagnostics, and local history are not operator-service data by default;
- source-availability and license notices must not overstate compliance before
  counsel approves the exact release artifact and delivery mechanism;
- button labels and short UI strings must not compress away required recurring
  billing, cancellation, refund, privacy, or diagnostic-consent meaning;
- colloquial social posts may be friendlier, but must not add broader promises
  than the reviewed policy and website copy.

If localization requires shorter wording, keep the full approved disclosure one
tap or one link away on the same flow before the user makes a purchase,
submission, cancellation, refund, export, or deletion decision.

## 5. Required Checks

Before publication, record evidence for:

- side-by-side Traditional Chinese and English copy review;
- counsel disposition for legal, platform, copyright, consumer, privacy,
  complaint, marketing, cancellation, refund, and shutdown claims;
- accountant disposition for tax, invoice, seller identity, refund,
  chargeback, settlement, and retention wording;
- provider disposition for product description, recurring terms, cancellation,
  refund, merchant category, fees, limits, settlement, and support disclosures;
- licensing disposition for helper-bundle notices, source-availability copy,
  warranty disclaimers, and release notes;
- owner approval of the exact versions to publish.
- release-candidate review metadata proving the referenced app version,
  screenshots, release notes, source-availability text, and support copy match
  the exact internal candidate under review.

Keep privileged advice and confidential provider responses in the restricted
evidence store. This repository should retain only review metadata, version
identifiers, dates, and non-secret disposition summaries.

## 6. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- publishing landing pages, pricing pages, policies, support pages, launch
  posts, release pages, source-availability statements, or localized copy;
- submitting public copy or product descriptions to ECPay, counsel, accountant,
  localization vendors, support vendors, or email providers;
- production checkout, recurring billing, cancellation, refund, support email,
  external forms, or vendor setup;
- public release publishing, repository visibility changes, or public source
  availability claims;
- Windows commercial implementation.
