# Local Subscription Management API (Task 6)

## Scope And Wiring

This is an in-process HTTP handler tested against a disposable local PostgreSQL
database and a mock provider. It is **not a deployed Edge Function**, payment
page, real cancellation service, or new Swift UI. No merchant keys, real
payments, cloud migration, or production accounts were used. Paid launch
remains No-Go under `COMMERCIAL_FEASIBILITY.md`.

Composition:

1. `createBillingAPI` validates the HTTP request and obtains the user UUID from
   an injected `verifyAccessToken`. A real runtime must verify the bearer with
   Supabase Auth; decoding an unverified JWT or trusting an email is insufficient.
2. `createBillingManagement` coordinates the durable command and provider call.
3. `createPostgresBillingManagementRepository(sql)` handles local transactions.
4. `createMockBillingProvider()` returns synthetic confirmations without network
   access. The service rejects a provider whose mode is not `mock`.

`billing_management_database_test.ts` is the executable composition example:
it sends actual `Request` objects through the handler, with a synthetic verified
identity. It does not repeat the Google OAuth browser smoke test. The existing
deployed entitlement `index.ts` remains unchanged and reads staging grants.

## HTTP Contract

All routes are POST, use `Content-Type: application/json` and
`Authorization: Bearer <access token>`, and return `Cache-Control: no-store`.
Body size is capped at 1024 bytes including streamed bodies. Query parameters
and unknown body fields are rejected. Do not send account IDs, email, price,
plan, cancellation time, or entitlement claims from a client.

| Route | Exact request fields | Successful response |
| --- | --- | --- |
| `/billing/status` | `{ "schema": 1 }` | `mode`, `price`, derived `access`, owned `operations` |
| `/billing/checkout` | `{ "schema": 1, "requestID": "UUID" }` | `mode`, `price`, durable `operation` |
| `/billing/cancel` | `{ "schema": 1, "requestID": "UUID", "orderID": "..." }` | `mode`, `price`, durable `operation`; already-cancelled orders return status |

Generate a request UUID once per user action and retain it across network
retries. Order IDs are 1-20 ASCII letters/digits/underscore/hyphen. UUIDs are
normalized to lowercase. The price is server-owned `TWD`, `amountMinor: 8000`
(NT$80) for the planned monthly product. No checkout URL is issued by the mock.

Operation fields: `id`, `requestID`, `orderID`, `kind` (`checkout`/`cancel`),
`state` (`pending`/`succeeded`/`unknown`). `succeeded` on a checkout means only
that the mock accepted creation, **not that payment succeeded**. Status is not
a signed entitlement and must never directly unlock Pro in the App.

| HTTP | Meaning |
| --- | --- |
| 200 | Completed mock operation or status read |
| 202 | Pending or uncertain operation; do not claim payment/cancellation success |
| 400 | Invalid body, schema, headers, size, or query |
| 401 | Missing/invalid bearer or invalid verified UUID |
| 404 | Unknown route, missing order, or another account's order |
| 405 | Unsupported method; `Allow: POST` |
| 409 | `request_conflict`, `existing_order`, or `operation_exists` |
| 503 | Redacted internal failure; preserve request ID and inspect status |

## Transactions And Recovery

The account row is locked before its financial rows, consistent with Task 5.
Order identity and price remain immutable. A new operation is persisted before
calling the provider; order creation and operation creation commit together.
The provider call occurs outside the transaction, with an abortable deadline
(default five seconds). Confirmation is then persisted in another transaction.

Repeated or simultaneous requests with the same account/request ID return the
stored operation. Reusing a key for another command/order returns conflict.
Different keys cannot create two initial orders or two cancellation operations.
The operation foreign key also binds order and account together at SQL level.
Anonymous/authenticated database clients have no direct table privileges.

| Interruption | Durable result | Access consequence |
| --- | --- | --- |
| Order/operation insertion fails | Both roll back | None |
| Crash after prepare, before provider call | `pending` | None |
| Provider returns pending | `pending` | None |
| Timeout, exception, malformed provider outcome | `unknown` | None |
| Confirmation received, final DB transaction fails | Prior `pending` remains | Subscription/event writes roll back |
| Cancellation confirmed and accepted by policy | `succeeded` + event + new revision atomically | Paid-through plus 72 hours |
| Confirmation conflicts with current order/state/time | `unknown` | No speculative access change |

This provides at-most-one provider invocation by this request path, **not an
exactly-once guarantee across an external payment network**. Replaying pending
or unknown commands intentionally does not call the provider again. Task 7 must
query/reconcile provider state by stable operation/order identity and recover
these records, including a crash before any provider request was sent. Never
delete a pending record and retry under a new UUID as a recovery shortcut.

Cancellation is accepted only for the caller's current active/payment-failed
order. Already-confirmed cancellation is idempotent. The existing policy does
not apply a cancellation dated after paid-through; such a confirmation becomes
`unknown` for reconciliation rather than silently granting 72 more hours.
Refund/revocation still removes derived Pro. The cancellation bonus does not
stack with offline entitlement grace, which is bounded by the signed access end.

Conservative limitation: any existing order blocks a new checkout, even an
abandoned or expired one. Re-subscription and checkout expiry are not released
features; safe replacement needs the reviewed Task 7 provider lifecycle. This
restriction prevents accidental duplicate recurring subscriptions during local
development but must be resolved before real customer checkout.

## Verification

Use the prerequisites and dedicated local stack from `LOCAL_BILLING_DB_TEST.md`.
Never point the harness at staging/production. `supabase migration up --local`
applies the additive migration without resetting the database. Use
`supabase db reset --local` only for the verified disposable test project.

From the worktree root:

```sh
supabase start
supabase migration up --local
supabase test db
```

From `supabase/`, run the focused database tests:

```sh
YTDP_LOCAL_BILLING_DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres' deno task test:billing:db
```

The complete suite uses the same `--allow-env` and `--allow-net` flags as that
task, plus `--allow-read=../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures,functions/entitlement/test-fixtures`,
and targets `functions/entitlement`. The integration harness fails when env
permission is granted but the URL is missing; without env permission database
tests are skipped, which is **not** sufficient Task 6 evidence.

Verified 2026-09-27 after rebuilding the empty local database:

- All five migrations applied from scratch.
- 39 pgTAP assertions passed.
- 70 combined Deno tests passed, zero failures and zero ignored tests.
- Focused DB suite: 22 passed, including Task 5 regression coverage.
- New coverage includes account isolation, rejected client-selected authority,
  request replay, concurrent keys, fixed price, checkout without Pro, cancellation
  boundaries, timeout/uncertainty, SQL rollback, and fresh-handler replay.
- Changed TypeScript passes Deno lint/format; patch passes `git diff --check`.
- Review was performed in-session; no independent reviewer tool was available.

Stop the local stack with `supabase stop` after testing. The CLI's default Docker
port binding is not restricted to loopback; use only synthetic data on a trusted
machine/network, and do not leave the stack running for production service.

## Task 7 Handoff

Before enabling a real provider, establish the approved ECPay product/API and
merchant/product authorization, signature verification and canonical callback
mapping, stable per-period event keys, operation reconciliation, cancellation
confirmation semantics, checkout expiry/re-subscription, and missing-notification
recovery. Test provider amount-unit conversion: our `8000` minor units are
NT$80, not a value to forward blindly to a gateway expecting whole TWD.

Later deployment must supply real verified authentication, private DB access,
rate limiting, bounded request timeouts, observability without secrets, and
switch entitlement issuance to subscriptions without fallback to legacy Pro
grants. Swift subscription UI and real end-to-end signed-grant checks remain
separate work. No Task 6 result authorizes external deployment or real charges.
