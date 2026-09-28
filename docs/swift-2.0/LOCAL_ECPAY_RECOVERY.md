# Local ECPay Recovery

Updated 2026-09-28. Task 7A.1-7 implemented and verified locally.
No provider transport, deployable endpoint, schedule,
production credentials or financial action is included.

## Trust And Transaction Boundaries

`validateMockQuery` accepts only the documented synthetic mock envelope. It is
not a real ECPay query authenticator. `normalizeAioPayment` handles previously
verified callbacks with trusted order/period inputs. Both yield normalized facts;
neither receipt of a callback nor a browser redirect grants Pro by itself.

`createPostgresBillingReconciliationRepository(sql)` exposes:

- `snapshot(userID, operationID)`: a locked, account-bound read, or null.
- `apply(snapshot, evidence, observedAt)`: applied, duplicate, needs_review,
  stale or unavailable. Caller must supply only validated internal evidence.

The future endpoint must authenticate its caller before invoking the internal
runner, which loads the owned operation, queries outside a transaction, then
applies validated evidence. It must not accept arbitrary
client JSON as RecoveryEvidence or client-selected URLs. The repository copies
input objects before yielding and reloads actual state under locks.

Lock order is account -> owned order -> operation. The state token covers account,
operation identity/state/timestamps, subscription state/revision, current order
and expected price. A changed token returns stale without a financial write.
Shared `applyVerifiedBillingEvent` runs on the existing connection, never starts
a nested transaction, and never catches exceptions that require rollback.

Every evidence payment is checked against the order price, ledger ownership and
stored facts digest before selecting a new payment. Conflicting facts or a legacy
null digest require review. Only proven equal committed payments are filtered out.
At most one missing payment is written per transaction. Refresh the snapshot and
repeat with the same evidence to resume a batch. A succeeded checkout remains
eligible for missed-renewal recovery. Once no payments remain, the policy may
confirm checkout or cancellation. Cancellation/event/operation/audit commit as
one transaction; terminal-state policy remains authoritative.

## Bounded Mock Runner

`runRecoveryBatch(userID, operationIDs, dependencies)` is an internal helper,
not an authentication endpoint. The caller must supply an authenticated user ID.
Dependencies include the repository, `MockBillingQuery` with `mode: "mock"`,
trusted order loader, period resolver and clock. No create/cancel/refund transport
is accepted. The helper never calls global `fetch`.

Input is limited to 20 UUIDs before deduplication; IDs are canonicalized and
processed sequentially. Missing or foreign operations/orders are not queried.
Each operation is queried once. A five-second query deadline aborts the lookup;
late success or rejection cannot trigger writes. Timer injection is an internal
test seam. This deadline covers the query, not trusted local repository/loader
calls, which are not raced against timers that could leave late database writes.

Validated evidence is applied with refreshed snapshots, at most 121 times per
operation (120 payments plus final confirmation). Stale, review, unavailable,
duplicate, unchanged or cycling state stops processing. Each payment transaction
commits independently so a restart can skip an already committed prefix safely.
Tests simulate losing the first commit response and recover only the remaining
payments. Already-succeeded checkout operations can still recover renewals.

Results report the last repository outcome, not a summary of all writes. A
`duplicate` result can follow successful recovery of missing renewals. Neither
that result nor `applied` is an entitlement token; read committed subscription
state to derive access. No automatic retry loop or schedule is installed.

## Audit And Compatibility

Migration `20260928000100_billing_recovery.sql` adds a nullable event facts digest
and private recovery audit table. Existing events are not assigned guessed hashes.
The audit has an operation/account foreign key, bounded enums/digests, RLS,
restricted client privileges and a unique operation/evidence/state tuple. It has
no raw callback, card, email, secret or free-text error column and no cascade delete.

Evidence hashes contain only canonical validated business facts and exclude
observation time. An unchanged retry cannot create duplicate audit records.
`duplicate` can mean an already audited review result, not successful payment;
never infer Pro access from this return value. Actual access comes from committed
subscription state. Exceptions map to bounded unavailable/needs_review responses.

The existing callback wrapper accepts an optional internal factsDigest. New 7A
adapters must compute it from normalized facts; never accept it from HTTP input.
Old no-digest callers retain their legacy behavior. Any event insertion race
throws before the outer transaction returns, rolling back subscription writes.

## Verification

Run `supabase start`, `supabase migration up --local`, and `supabase test db`
from this worktree. From `supabase/`, run the focused database suite with:

```sh
YTDP_LOCAL_BILLING_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/postgres deno task test:billing:db
```

For full acceptance, obtain the pinned external checksum file using
`supabase/functions/entitlement/test-fixtures/ecpay/README.md`, then run from
`supabase/`:

```sh
YTDP_AIO_VECTOR_FILE=/tmp/ytdp-ecpay-vectors.json \
YTDP_LOCAL_BILLING_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/postgres \
deno task test:billing:all
deno lint functions/entitlement
deno fmt --check deno.json functions/entitlement/billing_recovery_database_test.ts
```

The task intentionally grants the two required environment variables: missing
values fail instead of silently ignoring database or official-vector tests.
Read permission for the external vector is limited to the displayed `/tmp` file;
do not supply a different path without explicitly updating the read allowlist.
The official source is revision `ae964f75b69ec90e1c205b136364ab6587fc328c`, raw
SHA-256 `19500d60f3db8da3a9c31760e48b2102b233e4e8a9a5a594edd680deb8358301`.
Only its five SHA256 non-formula vectors are evaluated; MD5, invoice, logistics
and ECTicket profiles are excluded. Restricted source stays outside Git and
release archives. Mock query fixtures are original synthetic data, not proof of
ECPay sandbox interoperability.

Before the acceptance reset, inspect row counts for `auth.users` and private
`billing_orders`, `subscriptions`, `subscription_events`, `billing_operations`,
`billing_recovery_audit`. All must be zero in this dedicated throwaway project.
Then run `supabase db reset --local` and `supabase test db` from the worktree root,
followed by the full task above. Never reset unexplained data or a linked project.

Database tests must not be ignored.
Tests inject audit SQL failure and prove subscription/event/operation rollback;
temporary triggers/functions are removed in finally blocks. Fixture cleanup
deletes audit rows before operations. Never reset or clean a non-test database.

Latest full run: 135 Deno tests, zero failed/ignored; 51 pgTAP assertions,
after all six migrations applied from an empty local database.
The focused billing database suite passed 38 tests. Task 7A.6 adds 12 runner
tests and three real-database scenarios. Nine initial runner tests failed against
the empty stub before implementation. Deadline and apply-limit mutations also
failed as expected and were restored, in addition to Task 7A.5's three guard
mutation checks. Review was
in-session, not independent. No App packaging, push, cloud migration or billing
activation occurred. Written provider approval and fresh external-action approval
remain required for 7B.

## Task 7A.7 Scenario And Handoff

The real-Postgres lifecycle fixture covers successful mock checkout remaining
Free, first payment, duplicate notification, recovery of a missed renewal,
unknown cancellation remaining unconfirmed, verified cancellation recovery,
Pro until one millisecond before paid-through plus 72 hours, and Free exactly
at that boundary. A separate database scenario proves forged merchant facts,
simulation and foreign-account recovery preserve the paid revision. A temporary
72 -> 71 hour mutation failed the lifecycle test; it was restored before the
full successful run. Existing handler/JWS tests cover signed entitlement claims
and their hard expiry separately; this is not a live App/browser/payment test.

No production behavior was changed in Task 7A.7. The two new integration tests
initially passed on existing code; the mutation provides negative regression
evidence, not a claim that a new production bug was found. The complete task
also fails when required environment values are empty (expected negative run).

Review was in-session because no independent reviewer was available. Review
covered internal-only mock query injection, trusted account/order/period inputs,
atomic replay and stale guards, bounded recovery, signing tests, unchanged
deployed entrypoint and absence of new provider network transports. This local
review does not replace external security review or provider approval.

Follow `ECPAY_7B_READINESS.md` before any real transport or deployment. Real
provider query authenticity, billing-anchor mapping and cancellation-effective
time remain unverified. Do not infer these from synthetic periods. Existing
deployed entitlement source must not be silently switched or fall back to legacy
Pro grants. The next approved integration must verify the signed token and App
downgrade behavior, with separate deployment authorization. No unattended
financial recovery schedule is authorized.
