# YT Downloader Pro Accounting Review Brief

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for independent Taiwan accountant review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-17 |
| Jurisdiction focus | Taiwan tax, invoice, seller registration, and records |
| Decision rule | No paid launch without written accounting guidance |

This brief gives an accountant the current product and commercial facts needed
to evaluate tax, invoice, business-registration, refund, record-retention, and
entity questions. It is not tax, accounting, legal, payment-provider, or launch
advice. It does not authorize production billing, ECPay configuration, public
sales, email, release publishing, or another external account action.

## 1. Requested Work Product

Please provide dated written guidance that:

- identifies the reviewed product description, pricing, expected payment flow,
  seller identity, and launch assumptions;
- separates tax registration, invoice, receipt, bookkeeping, refund,
  chargeback, entity, and retention conclusions;
- states the revenue or activity thresholds that change the operator's duties;
- lists mandatory checkout, invoice, record, reconciliation, or reporting
  controls before paid launch;
- identifies questions that must be coordinated with counsel or ECPay;
- states what future changes require a new accounting review.

A verbal discussion or general website link is useful background, but it does
not satisfy the paid-launch gate.

## 2. Product And Pricing Facts

YT Downloader Pro is a desktop application developed for macOS in Swift. A
separate Windows Python edition exists, but Windows commercial work is paused.
The app runs media analysis and downloads locally on the user's Mac; the
operator does not currently proxy, host, retain, or process downloaded media on
a server.

The proposed offer under review is:

- Free: single-video downloads up to 720p and core safety/reliability updates.
- Pro: NT$80 per month for higher available resolutions when the source offers
  them, batch URLs, playlists, advanced subtitles, presets, full retry, optional
  history synchronization, and asynchronous priority support.
- Payments: ECPay recurring credit-card service, subject to written product and
  merchant approval.
- Identity: Google OpenID Connect or another reviewed account-recovery path;
  Google identity does not decide billing status.
- Distribution: direct website download outside the Mac App Store.

No checkout, production entitlement backend, public paid release, or recurring
charge flow has been enabled. Current project status is Conditional Go for
validation and No-Go for paid public launch.

## 3. Seller And Entity Questions

Please answer:

1. May the operator start as an individual seller for this proposed subscription
   service, or is business/company registration required before the first paid
   transaction?
2. Which seller name, tax identity, business address, contact route, and invoice
   information must appear on checkout, receipt, invoice, Terms, Privacy Policy,
   and support pages?
3. Which sales, transaction count, recurring-revenue, or activity thresholds
   require tax registration, business registration, company formation, or other
   status changes?
4. How should the operator plan for the NT$80/month price if 50, 100, 250, 500,
   625, 1,000, or more subscribers are reached?
5. Does selling through ECPay as an individual seller change, reduce, or merely
   report the operator's independent tax and invoice duties?
6. Are there insurance, liability, bookkeeping, or tax reasons to form an entity
   before paid launch even if an individual seller model is technically allowed?

## 4. Tax And Invoice Questions

Please answer:

1. Which tax categories apply to a Taiwan-based operator selling recurring
   desktop software subscriptions to domestic and possible overseas users?
2. When must business tax, income tax, withholding, or other filings begin?
3. What invoice, e-invoice, receipt, or proof-of-payment must be issued for each
   recurring payment?
4. How should recurring payments, failed payments, duplicate callbacks, refunds,
   partial refunds, chargebacks, reserves, and settlement timing be booked?
5. How should ECPay fees, refund fees, chargeback fees, Apple Developer fees,
   hosting, monitoring, support tools, code-signing costs, and helper-license
   compliance costs be categorized?
6. What information is required for customers who need company tax IDs or
   reimbursement receipts?
7. What records are needed to prove subscription consent, payment authorization,
   cancellation, refund, and paid-through dates?
8. How should foreign-currency costs or non-Taiwan customers be handled if they
   appear after launch?

## 5. Refund, Cancellation, And Reconciliation Questions

Refund and cancellation policy must also be reviewed by counsel and ECPay. From
an accounting perspective, please answer:

1. What accounting records are needed when a user cancels renewal but retains
   paid-through access?
2. How should full-period, partial-period, goodwill, duplicate-charge,
   incorrect-charge, upstream-breakage, and chargeback refunds be recorded?
3. What monthly reconciliation is required between ECPay transactions, backend
   entitlement state, invoices/receipts, bank settlement, and bookkeeping?
4. Which refund or chargeback events require invoice correction, allowance,
   credit note, or other customer-facing document?
5. What evidence should be retained for disputes without storing full card
   numbers, CVV values, bank credentials, identity documents, media URLs,
   download titles, local paths, browser cookies, or raw diagnostics?

## 6. Retention And Deletion Questions

The app is designed to keep media activity local by default. The operator's
future backend should not receive download URLs, titles, local paths, browser
cookies, downloaded files, thumbnails, detailed diagnostics, or local history
unless a separately approved feature changes that boundary.

Please answer:

1. What retention periods apply to invoices, receipts, ECPay transaction
   references, subscription consent, refunds, chargebacks, support billing
   questions, tax records, and accounting workpapers?
2. What data must be preserved when a user requests account deletion?
3. What data may or should be deleted promptly after cancellation, refund,
   account closure, or a failed payment?
4. What backup-retention and deletion-aging rules are acceptable for accounting
   evidence?
5. Which retention rules must be disclosed in the Privacy Policy, Terms,
   cancellation policy, or data-deletion workflow?

## 7. Materials To Review

Before final Go, the accountant should review current versions of:

- `COMMERCIAL_FEASIBILITY.md`.
- `PAYMENT_PROVIDER_QUESTIONS.md` and any actual ECPay response.
- `LEGAL_REVIEW_BRIEF.md` and counsel's final non-privileged decision summary.
- `PRIVACY_DATA_MAP.md`.
- `PUBLIC_POLICY_DRAFTS.md`.
- `OPERATIONS_RUNBOOK.md`.
- Pricing page, checkout copy, refund/cancellation language, invoices/receipts,
  and support billing workflow before publication.

Do not include ECPay HashKey, HashIV, Merchant ID, bank credentials, identity
documents, full card data, Google credentials, Apple signing credentials, media
URLs, download titles, local file paths, cookies, or raw diagnostics in the
review packet unless the accountant explicitly requests a secure channel and the
owner separately approves that transfer.

## 8. Evidence Record

Do not store confidential accounting advice in a future public repository.
Record only decision metadata here and keep detailed guidance in a restricted
evidence store.

| Field | Value |
| --- | --- |
| Accountant/firm | Not selected |
| Engagement date | Not started |
| Materials supplied | Not supplied |
| Guidance date | Not available |
| Registration required before launch | Unknown |
| Invoice process approved | Unknown |
| Retention guidance received | Unknown |
| Mandatory changes | Unknown |
| Re-review triggers | Unknown |
| Restricted evidence location | Not available |
| Owner final decision | No-Go pending accounting guidance |

## 9. Primary References

- [Taiwan Ministry of Finance: Online transaction tax regulations](https://www.etax.nat.gov.tw/etwmain/tax-info/network-transaction-taxtation-area/regulation)
- [Taiwan Ministry of Finance: Notes for domestic online sellers](https://www.etax.nat.gov.tw/etwmain/tax-info/network-transaction-taxtation-area/seller/notice)
- [ECPay recurring and subscription service](https://www.ecpay.com.tw/IntroRecurringPayment/)
- [ECPay recurring-payment management](https://support.ecpay.com.tw/16214/)
