# Swift 2.0 Plan And Entitlement Architecture

## Current Boundary

The app implements three distinct sources of plan behavior:

1. Public/accountless startup is always Free.
2. Internal Test Pro is a compile-time development fixture available only in
   `YTDP_INTERNAL_TEST` builds.
3. A staging account may receive Pro only from a signed entitlement that passes
   the complete client verifier.

The entitlement server contract, local Edge Function, migrations, client,
verifier, cache, bridge, and policy integration exist and are tested. A pure
subscription model and private-table migration also exist, but they are not
wired to the live entitlement endpoint or deployed as billing infrastructure.
Payment, subscription purchase, provider cancellation, refunds, and account
deletion are not implemented. No paid-launch gate is cleared by this work.

## Build Channels

| Channel | Compile flag | Configuration | Internal plan switch |
| --- | --- | --- | --- |
| `public` | none | Forbidden | Not compiled |
| `internal-test` | `YTDP_INTERNAL_TEST` | Optional validated staging public material | Settings-only Free/Test Pro |

Public compilation ignores stale internal preferences. Missing, malformed, or
unknown values resolve to Free. `YTDPBuildChannel` in `Info.plist` is verifier
metadata; the compile flag remains the runtime authority.

## Enforcement Flow

`PlanController.currentPlan` creates one `FeaturePolicyContext` consumed at all
boundaries:

1. Views show allowed Free formats and locked Pro formats.
2. `DownloadStore` rejects disallowed batch, playlist, subtitle, and selected
   quality commands.
3. Queued/non-active work is reconciled when the effective plan changes.
4. `DownloadRunner` rechecks before helper launch and filesystem side effects.

Free permits MP3 and supported video formats up to 720p. Unknown/source/higher
quality fails closed. A downgrade lets already active work finish but restricts
non-active Pro-only jobs. An upgrade does not silently start queued work.

UI is not the security boundary. The store and runner checks must remain even
when presentation changes.

## Signed Grant Contract

The Edge Function returns one compact ES256 JWS with exact header and claim
schemas. The verifier rejects malformed tokens, unknown `kid`, non-ES256
algorithms, invalid signatures, unexpected fields, wrong issuer/audience/
subject, invalid UUID token IDs, unsupported schema, duplicate features,
invalid time windows, inconsistent plan/features/height/state, and grant
revision rollback.

The normal token life is 24 hours. A previously verified cached grant may be
used for at most 72 additional hours when refresh is unavailable. Cache restore
reverifies signature and claims before adoption. A network response receives no
expiry grace. Rejected or unavailable grants fail to a valid cache or Free;
account identity, email, local defaults, and UI state never grant Pro.

The app refreshes the current account when it becomes active. Independently of
network callbacks, a cancellable local deadline returns the effective plan to
Free at normal token expiry, or at the end of the 72-hour window when an
eligible cached grant is already being used. A stale deadline is scoped to its
account and operation ID and cannot revoke a newer grant.

Only `VerifiedEntitlement` can update `PlanController`. `DownloadStore` observes
that controller and applies the same policy to existing queued jobs.

## Subscription Model Under Development

`subscription.ts` is a side-effect-free backend policy model. Its source of
identity is the verified Supabase user UUID, never an email. A confirmed paid
period grants Pro until, but not including, `paid_through`. A provider-confirmed
cancellation stops renewal and keeps Pro through the paid period plus exactly
72 hours; a failed renewal keeps only already-paid access. Confirmed refunds
and revocations derive Free immediately. This 72-hour cancellation bonus is
distinct from the existing 72-hour offline *token-expiry* grace.

`202609250001_subscription_model.sql` defines private subscriptions and an
event-key ledger. It is committed source, not an applied staging migration.
The pure transition function returns `duplicate` for a known processed key and
`reconcile` for ambiguous ordering, such as a successful charge after a
confirmed cancellation. A future provider writer must verify its input and
atomically insert the unique event key and update the subscription under a
transaction; passing an in-memory set alone is not durable idempotency.
`is_current` permits one current order per user while retaining old orders for
later reconciliation. Account deletion must address legally required billing
retention before removing an `auth.users` row; the financial foreign key
intentionally restricts cascading deletion.

No entitlement JWS is issued from this subscription model yet. The next
entitlement-contract task must define signed paid-through and grace-end bounds,
then enforce them in server issuance and Swift verification. The current
staging grant table and 24-hour token plus offline-cache rules remain unchanged.

## Storage And Account Changes

The compact verified entitlement is stored in a separate device-only Keychain
record scoped by authentication environment. Access tokens remain memory-only.
The bridge preserves a same-account cache through reauthentication, but clears
the old grant before account replacement. Logout clears auth and entitlement
state and invalidates stale refresh work.

The server-side data model uses immutable Supabase user UUID subject identity
and monotonic `grant_revision`. Entitlement rows contain plan/features/height,
subscription state, validity, and revision only; they do not contain media
URLs, titles, paths, cookies, history, or downloaded files.

## Internal Test Pro

The internal preference key is `internal-test-selected-plan` and accepts only
`free` or `test-pro`. It must never appear in public UI, support reports,
exports, analytics, or production authorization. Internal Test Pro remains
separate from the signed staging plan and is not evidence of purchase.

## Packaging And Operations

`scripts/build_swift_2.sh` accepts `--auth-config` only for `internal-test`.
The config checker allows publishable material and P-256 public keys only. The
bundle verifier rejects any configuration in public builds, validates internal
configuration and file mode, scans resources for private material, and keeps
secret values out of its report.

Follow `SUPABASE_STAGING.md` for staging handoff and
`ENTITLEMENT_KEY_ROTATION.md` for signing-key lifecycle. Production Google,
Supabase, payment, billing, and publishing require separate dated evidence and
fresh owner approval.
