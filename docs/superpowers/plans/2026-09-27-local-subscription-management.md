# Task 6: Local Subscription Management APIs

Scope: authenticated status, checkout and cancellation handlers with a mock
provider and the Task 5 PostgreSQL repository. No hosted deployment, real
payment call, or Swift UI change.

## Contract

- POST `/billing/status`: `{ "schema": 1 }`.
- POST `/billing/checkout`: `{ "schema": 1, "requestID": "UUID" }`.
- POST `/billing/cancel`: `{ "schema": 1, "requestID": "UUID", "orderID": "..." }`.
- Verified bearer subject is the only account authority. Unknown fields,
  caller-selected price/plan/user, excessive bodies, and invalid IDs fail closed.
- Price is server-owned TWD 8000 minor units (NT$80), monthly. Creating a checkout
  never grants Pro. Mock checkout returns metadata only, not a payment URL.
- Persist each operation before contacting the provider. Concurrent/repeated
  requests with the same account/request ID return the existing operation.
  Reusing that key for a different command returns conflict.
- Provider calls occur outside transactions. Timeout/uncertain outcome retains
  a durable pending/unknown operation and unchanged subscription. Same-key
  replay does not call the provider again; Task 7 reconciliation must recover
  interrupted operations before enabling real payments.
- Cancellation success is persisted with its subscription event and revision in
  one transaction. Merely requesting cancellation never grants the bonus. The
  existing paid-through plus 72-hour policy remains authoritative.
- Preserve Task 5's conservative current-order policy: no replacement checkout
  while any prior order exists. Abandoned checkouts, re-subscription, refunds,
  and order expiry need reviewed provider reconciliation before enabling real
  commerce; return a clear conflict rather than silently creating a second order.
- Cancellation must name the caller's current order. Cross-account/missing order
  has the same response. An already confirmed cancellation is idempotent.
- `private.billing_operations` stores identifiers, kind/state and timestamps
  only. No tokens, email, raw provider payload, or card information.

## Implementation And TDD

1. Write handler tests for authentication, exact request schemas, byte limits,
   and bounded error responses. Implement pure dependency-injected handler.
2. Add an append-only private operation migration; write real PostgreSQL tests
   for order binding, idempotency, status isolation, and creation without Pro.
   Implement management repository and mock-provider protocol.
3. Write cancellation tests for confirmation, 72-hour deadline, duplicate calls,
   pending/timeout, wrong-account access, SQL rollback and concurrent requests.
   Reuse the transaction adapter and subscription transition policy.
4. Run all entitlement tests against a fresh local database, pgTAP, lint, format,
   diff checks; review writes and concurrency. Document operation recovery and
   HTTP contracts, commit locally, stop the test stack.

## Files

- `supabase/functions/entitlement/billing_api.ts`, `billing_api_test.ts`
- `supabase/functions/entitlement/billing_management.ts`
- `supabase/functions/entitlement/mock_billing_provider.ts`
- `supabase/functions/entitlement/postgres_billing_management_repository.ts`
- `supabase/functions/entitlement/billing_management_database_test.ts`
- `supabase/functions/entitlement/postgres_billing_repository.ts` (reuse its
  transaction-scoped adapter, without changing the Task 5 contract)
- `supabase/functions/entitlement/test-fixtures/local_database.ts`
- `supabase/migrations/202609270001_billing_operations.sql`
- `supabase/tests/billing_operations.sql`
- `docs/swift-2.0/LOCAL_SUBSCRIPTION_API.md` and architecture handoff.

Commits: HTTP contract; durable mock-provider commands and schema; final evidence.

## Completion Evidence (2026-09-27)

- [x] HTTP contract: missing-module RED, then five passing handler tests.
- [x] Durable operations: missing-table pgTAP RED, then applied additive migration.
- [x] Checkout/cancellation and rollback/race coverage: 22 focused DB tests pass.
- [x] Clean local rebuild: five migrations; 39 pgTAP and 70 Deno tests pass,
  zero skipped database tests.
- [x] Local-only boundaries and Task 7 recovery handoff documented in
  `docs/swift-2.0/LOCAL_SUBSCRIPTION_API.md`.
