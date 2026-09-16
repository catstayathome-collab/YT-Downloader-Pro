# YT Downloader Pro Operations Runbook

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 operations design |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-15 |
| Scope | macOS Swift 2.x local app and future approved account services |
| Launch rule | Required drills and evidence must pass before paid launch |

This runbook defines operational controls for credential rotation, backups,
incident response, refund and cancellation handling, and service shutdown. It
does not approve production ECPay setup, Google OAuth setup, email, ticketing,
support vendors, production billing, public release publishing, or any other
external account action.

## 1. Phase 1 Operating Boundary

Current allowed work is limited to documentation, local macOS Swift 2.x tests,
local mock contracts, and evidence gathering. The current app must remain local
first: media URLs, titles, cookies, local paths, thumbnails, downloaded files,
and detailed diagnostics are not operator-service data by default.

Before any production service is enabled, this runbook needs dated evidence for:

- named operational owner and backup owner;
- production and staging secret inventory with rotation owners;
- backup and restore tests using synthetic data only;
- incident drill records for privacy, payment, credential, and availability
  scenarios;
- cancellation and refund workflow tests after provider/legal review;
- shutdown workflow and user communication checklist.

No verbal assurance, dashboard screenshot, or generic vendor capability is
sufficient by itself. Each launch gate needs a linked file, ticket, drill log, or
signed professional response.

## 2. Credential Rotation

Production secrets must live outside the repository, release archive, app
bundle, logs, screenshots, support tickets, and test fixtures. The app may store
user session material only in macOS Keychain after an approved account design.

Credential classes to inventory before backend work:

| Credential | Intended location | Rotation trigger |
| --- | --- | --- |
| Google OAuth client configuration | Managed environment or provider console | Provider change, suspected exposure, app redirect change |
| ECPay HashKey/HashIV and merchant settings | Managed secret store | Provider guidance, suspected exposure, environment split |
| Backend database credentials | Managed secret store | Personnel change, deployment incident, scheduled rotation |
| Entitlement signing keys | Managed key service with offline recovery plan | Key compromise, algorithm migration, scheduled rotation |
| Support vendor API tokens | Managed secret store | Vendor change, staff access change, incident |
| Apple signing credentials | macOS keychain/profile with restricted access | Certificate change, machine loss, personnel change |

Rotation rules:

- Separate development, staging, and production credentials and data.
- Never reuse production secrets in local development or CI fixtures.
- Record rotation date, owner, affected services, verification command, rollback
  path, and customer impact.
- Rotate suspected-exposed secrets immediately; do not wait for a scheduled
  window.
- After rotation, verify old credentials are rejected and new credentials work
  only in the intended environment.
- Treat repository privacy changes as independent from rotation; making a repo
  private does not revoke a secret.

Required drill: rotate a staging-only synthetic secret, prove the old value is
invalid, run the dependent smoke test, and record the evidence without revealing
the secret value.

## 3. Backup And Restore

Backups are for operator account, subscription, consent, and support records
only after those services are approved. They must not include local user media
activity by default.

Backup rules:

- Encrypt production databases and backups at rest.
- Keep backup access restricted to operational owners with MFA.
- Use synthetic data for development restore tests.
- Define retention and expiry for each backup class before collection begins.
- Exclude browser cookies, media files, local paths, security-scoped bookmarks,
  full diagnostics, and optional history sync unless a separately approved sync
  design explicitly requires them.
- Account deletion must create a backup-expiry record so deleted data ages out
  of restore media after the approved legal hold period.

Restore rules:

- Restore to an isolated environment first.
- Verify row counts, subscription state, audit-log continuity, and deletion
  exclusions before promoting any restored service.
- Reconcile payment-provider state after restore; do not grant entitlement from
  stale local database state alone.
- Run privacy checks proving no media activity entered restored operator data.

Required drill: restore a synthetic staging backup, reconcile synthetic billing
records, verify a deleted account remains excluded or marked for expiry, and
record the evidence.

## 4. Incident Response

Incident response must protect users before reputation, support speed, or paid
feature availability. Paid priority rules never delay privacy, security,
copyright, cancellation, incorrect-charge, or account-recovery reports.

Severity levels:

| Severity | Example | Initial action |
| --- | --- | --- |
| Critical | Credential leak, unauthorized billing, sensitive support data exposure | Stop affected path, rotate or revoke, preserve evidence, notify owner |
| High | Backend outage blocking paid entitlements or cancellation | Freeze risky transitions, post status, reconcile once stable |
| Medium | Sanitized support preview regression or diagnostics overcollection risk | Disable affected submission path, patch and verify before re-enable |
| Low | Documentation mismatch without data exposure | Correct docs and add regression evidence |

Incident record fields:

- incident ID, start time, reporter, severity, and owner;
- affected systems and data classes;
- containment actions and exact timestamps;
- credential rotations or access revocations performed;
- customer-impact assessment without listing media activity;
- legal/accounting/provider notification decision;
- corrective tests, deployment, and closure evidence.

Required drills:

- staged ECPay secret exposure with rotation and callback verification;
- entitlement signing-key compromise with free fallback and reissue plan;
- support payload redaction regression with submission disabled;
- backend outage during cancellation request with idempotent replay.

## 5. Cancellation And Refund Handling

Cancellation and refund policy must be approved by counsel, accountant, ECPay,
and the owner before paid launch. Until then, this section is an engineering
workflow target, not a public promise. Public-facing refund and cancellation
draft requirements are tracked in `PUBLIC_POLICY_DRAFTS.md`.

Cancellation rules:

- Cancellation is a first-class account action, not only a support ticket.
- The backend must stop future recurring billing through the approved ECPay
  mechanism before account deletion removes account data.
- The workflow is idempotent; repeated cancellation requests produce one final
  provider action and one user-visible confirmation.
- The user receives the paid-through date, cancellation reference, and support
  route without revealing payment secrets.
- Deleting the app, clearing local history, logging out, or disconnecting Google
  must not be described as subscription cancellation.

Refund rules:

- Refund eligibility, partial-period treatment, upstream-breakage handling, and
  dispute effects require legal/provider/accounting approval.
- Staff need least-privilege roles, MFA, and audited approval for refund actions.
- Refund processing uses provider/internal references only; support must never
  request full card numbers, CVV, bank credentials, passwords, cookie exports,
  or identity-document images.
- Entitlement state must reconcile with the provider after refund, chargeback,
  duplicate callback, or failed callback.

Required test: after approval, run ECPay sandbox or approved test-environment
cases for cancellation, refund, duplicate callback, callback loss, and
reconciliation. No production transaction is authorized by this runbook.

## 6. Service Shutdown

Shutdown is required if payment-provider approval fails, legal review returns a
No-Go, a required license obligation cannot be met, or the service cannot meet
privacy/support commitments at the approved price.

Shutdown rules:

- Stop new purchases first.
- Preserve local free functionality and safety updates when feasible.
- Give users clear notice of timeline, export options, cancellation status, and
  refund route after legal/provider review.
- Cancel renewals or provide exact user action steps according to the approved
  payment-provider mechanism.
- Keep support, privacy, security, and refund contact routes open for the
  legally required period.
- Preserve only legal/accounting/dispute/security evidence with restricted
  access and deletion schedule.
- Do not remove public source-availability or license notices needed for prior
  binary recipients.

Required drill: table-top a provider rejection after beta, including purchase
freeze, user notice, renewal cancellation, export/deletion availability,
support staffing, and final data-retention schedule.

## 7. Evidence Register

Maintain an internal evidence register before paid launch:

| Evidence | Minimum content |
| --- | --- |
| Rotation drill | Secret class, environment, old-value rejection proof, smoke test |
| Restore drill | Backup ID, restore target, reconciliation result, privacy exclusion check |
| Incident drill | Scenario, timestamps, containment, communications, corrective tests |
| Cancellation test | Provider test reference, idempotency proof, paid-through display |
| Refund test | Provider test reference, entitlement transition, audit entry |
| Shutdown drill | Trigger, public notice draft, cancellation/export/deletion sequence |

The register must not store secret values, full payment data, media URLs,
download titles, local paths, cookies, raw diagnostics, or downloaded files.

## 8. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- Production ECPay configuration, checkout, recurring billing, refund, or
  cancellation actions.
- Production Google OAuth, backend auth, entitlement signing, or account
  recovery.
- Support vendor selection, email sending, ticket submission, or attachment
  upload.
- Cloud history synchronization, analytics, crash reporting, or status-page
  vendor setup.
- Public release publishing, repository visibility changes, or production
  incident communications.
- Windows commercial implementation.
