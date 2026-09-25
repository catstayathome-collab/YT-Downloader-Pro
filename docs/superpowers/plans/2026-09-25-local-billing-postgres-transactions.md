# Local Billing PostgreSQL Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that the Task 4 billing notification contract can update a real local PostgreSQL database atomically, idempotently, and without crossing account boundaries.

**Architecture:** Keep `processBillingNotification` responsible for verified, normalized events and subscription transitions. Implement its `BillingEventRepository` interface with parameterized PostgreSQL queries inside one database transaction. Serialize by authenticated account and order, then persist the subscription before its foreign-keyed event. A second independent database connection must see exactly one outcome for concurrent delivery.

**Tech Stack:** Deno 2, pinned `npm:postgres@3.4.9` with `prepare: false`, Supabase CLI local PostgreSQL/Auth, pgTAP, existing Deno tests.

**Spec:** `docs/swift-2.0/ENTITLEMENT_ARCHITECTURE.md`, especially "Subscription Model Under Development"; `COMMERCIAL_FEASIBILITY.md` Phase 1 and Paid Launch Gates.

## Global Constraints

- macOS Swift 2.x commercial preparation only; do not modify Windows or the public Free build.
- Local throwaway PostgreSQL only. Never run `supabase link`, `db push`, `db reset --linked`, deploy an Edge Function, or use production/staging credentials in this task.
- No real ECPay callback, merchant credentials, checkout, charge, refund, or cancellation action.
- The Task 4 `BillingNotificationVerifier` remains injected; passing a test verifier is not proof of provider authenticity.
- Preserve the three committed migration files and add a new migration for schema changes. Never rewrite an applied or potentially applied migration.
- Store no raw callback, card data, email, media URL, title, local file path, cookie, or access token in billing tables or diagnostics.
- Do not claim Task 5 complete until migrations, pgTAP, Deno integration tests, and the existing entitlement test suite pass against the same revision.

## Review Focus

1. Two independent database connections receive the same charge at once: one applies it, the other returns duplicate, and only one event/revision exists. Covered by Task 5.3.
2. A unique event key is reused for a different order: do not acknowledge it as a normal duplicate or grant the second account. Covered by Task 5.3.
3. Event insertion fails after first-payment subscription insertion: neither write survives. Covered by Task 5.2.
4. A user already has another current order: a new order must not silently replace it or leave two current subscriptions. Covered by Task 5.4.
5. An authenticated or anonymous database role attempts to read private financial tables: access is denied. Covered by Task 5.1.

## File Map

| File | Responsibility |
| --- | --- |
| `supabase/config.toml` | Local-only Supabase CLI project configuration; no secrets or remote project reference |
| `supabase/tests/billing_schema.sql` | pgTAP assertions for migrations, constraints, RLS, and private grants |
| `supabase/migrations/202609250003_billing_order_integrity.sql` | Append-only billing order immutability or constraints justified by a failing database test |
| `supabase/functions/entitlement/postgres_billing_repository.ts` | Parameterized, transaction-scoped implementation of `BillingEventRepository` |
| `supabase/functions/entitlement/postgres_billing_repository_test.ts` | Local PostgreSQL integration and concurrency tests using two independent connections |
| `supabase/functions/entitlement/billing_event_processor.ts` | Required contract changes for same-order replay, cross-order collision, and current-order checks |
| `supabase/functions/entitlement/billing_event_processor_test.ts` | Regression test for the changed duplicate contract |
| `supabase/deno.json`, `supabase/deno.lock` | Pin the selected PostgreSQL driver and lock resolution |
| `.gitignore` | Ignore Supabase CLI-generated local state only |
| `docs/swift-2.0/LOCAL_BILLING_DB_TEST.md` | Reproduction, safe cleanup, limitations, and evidence commands |
| `docs/swift-2.0/ENTITLEMENT_ARCHITECTURE.md` | Mark Task 5's real local-DB evidence separately from live deployment |

## Shared Interface Decisions

The following is the **end-of-Task-5** transaction contract. Introduce its
methods incrementally in Tasks 5.3 and 5.4, with their tests in the same
commits; Task 5.2 starts from the existing Task 4 interface:

```ts
type BillingEventTransaction = Readonly<{
  authorizationForOrder(orderID: string): Promise<BillingOrderAuthorization | null>;
  currentSubscription(orderID: string): Promise<SubscriptionRow | null>;
  currentOrderForUser(userID: string): Promise<string | null>;
  eventOrderID(provider: "ecpay", eventKey: string): Promise<string | null>;
  insertEventOnce(
    provider: "ecpay", event: SubscriptionEvent, subscriptionID: string,
  ): Promise<"inserted" | { existingOrderID: string }>;
  saveSubscription(row: SubscriptionRow): Promise<string>;
}>;
```

`authorizationForOrder` obtains a row lock on the authenticated account before
locking its billing order; every writer uses the same order. After locking, it
re-reads the order and verifies the immutable owner and amount. A known event
key for the same order is `duplicate`; a known key for a different order is
`reconcile`. An insert-time conflict throws a typed error so the transaction
rolls back *before* its existing order is classified. If `currentSubscription`
is null but `currentOrderForUser` returns a different order, return `reconcile`
without writing. Task 6 will decide whether and when a later order may replace
an older one.

The order-lock query sequence is parameterized and fixed: read the private
order to learn its owner, lock that `auth.users` row with `FOR UPDATE`, lock the
same private order with `FOR UPDATE`, then compare its owner/amount/currency to
the first read. Event insertion uses `INSERT ... ON CONFLICT DO NOTHING
RETURNING event_id`; if no row returns, query the existing event joined to its
subscription to learn the recorded order ID. Neither a unique conflict nor a
cross-order collision may commit a prior subscription update.

## Task 5.1: Reproducible Local Database And Schema Tests

**Consumes:** `202609230001_account_entitlements.sql`, `202609250001_subscription_model.sql`, `202609250002_billing_orders.sql`.

**Produces:** a local stack that applies every migration from zero, plus pgTAP tests that exercise actual PostgreSQL constraints and permissions.

- [ ] Check `git status`, the Phase 1 decision, installed `supabase` CLI, and a Docker-compatible runtime. At planning time only Deno is installed; installation and image download require a separate local setup step. Do not use the linked cloud project as a substitute.
- [ ] Add `supabase/config.toml` via `supabase init` only if it does not exist. Keep local ports distinct from other Supabase projects. Add `.temp/` and `.branches/` under `supabase/` to `.gitignore` if generated. Never commit local secrets.
- [ ] Write `supabase/tests/billing_schema.sql` with pgTAP assertions for the three private tables, unique `(provider, provider_order_id)` and `(provider, provider_event_key)`, `one_current_subscription_per_user`, the event-to-subscription foreign key, and denial of `SELECT` to `anon` and `authenticated`. Assert that updating an existing order's `user_id`, `expected_currency`, or `expected_amount_minor` raises an error. Use a test transaction and local synthetic `auth.users` fixtures; do not insert personal data.
- [ ] Run `supabase start`, then `supabase db reset --local` **only after confirming this is the dedicated throwaway local project**. Run `supabase test db --local`. Record the intended RED result for any missing guarantee rather than weakening the test.
- [ ] Add `202609250003_billing_order_integrity.sql` with a `BEFORE UPDATE` trigger that rejects changes to `provider`, `provider_order_id`, `user_id`, `expected_currency`, or `expected_amount_minor`; keep the function in `private` and use a fixed `search_path`. Re-run local reset and pgTAP; the migrations must apply cleanly in order.
- [ ] Review the migration SQL for `SECURITY DEFINER`, schema grants, and dangerous default permissions. A direct database role for the later repository must remain server-only; client JWTs and the Swift app must never access `private` billing tables.
- [ ] Commit only local schema/test harness files after GREEN, e.g. `test(billing): prove local schema constraints and access denial`.

## Task 5.2: First Payment And Transaction Rollback

**Consumes:** `BillingEventRepository`, `BillingEventTransaction`, `processBillingNotification`, `transitionSubscription` in `supabase/functions/entitlement/`.

**Produces:** `createPostgresBillingRepository(sql)` implementing the existing transaction callback on one PostgreSQL connection. `sql` is a server-only Postgres.js client; creation does not read environment variables or connect automatically.

- [ ] Add the exact import mapping `"postgres": "npm:postgres@3.4.9"` to `supabase/deno.json`; regenerate and commit `deno.lock`. Construct the test client with `postgres(localURL, { prepare: false, max: 2 })` and close it in `finally`.
- [ ] Read the local database URL from `supabase status` and pass it through `YTDP_LOCAL_BILLING_DATABASE_URL` in the test shell only. The test must parse the URL and refuse any host other than `127.0.0.1`, `::1`, or `localhost` before inserting fixtures.
- [ ] Write an integration test in `postgres_billing_repository_test.ts` that inserts a synthetic local Auth user and a matching private billing order, injects a deterministic verifier, then calls `processBillingNotification` for `payment_succeeded`. Assert one `private.subscriptions` row (`revision=1`, correct user/period) and one `private.subscription_events` row linked by `subscription_id`.
- [ ] Run the focused Deno test with only local database permissions, for example `deno test --allow-env=YTDP_LOCAL_BILLING_DATABASE_URL --allow-net=127.0.0.1 functions/entitlement/postgres_billing_repository_test.ts`. Verify RED because the repository does not exist. Reject URLs whose host is not loopback before any test writes.
- [ ] Implement `transaction(work)` with `sql.begin(async (tx) => ...)`; the function must return only after COMMIT, and any thrown error must ROLLBACK. Use parameterized tagged queries only. `authorizationForOrder` reads the private order and locks the account then order as described above. `currentSubscription` reads by provider/order. `saveSubscription` inserts or updates and returns its real UUID. `insertEventOnce` initially implements Task 4's boolean interface, writing the event after the subscription exists; Task 5.3 extends it to return the conflicting order ID.
- [ ] Add a second test that deliberately makes event insertion fail after `saveSubscription` (for example, a test-only overlength event value passed directly to the repository). Assert zero subscription and event rows after the rejected transaction. Do not alter production SQL to inject a test failure.
- [ ] Run focused RED, minimal GREEN, refactor, then `deno lint` and `deno fmt --check` on changed files. Commit, e.g. `feat(billing): persist first payment in one postgres transaction`.

## Task 5.3: Durable Idempotency And Collision Handling

**Consumes:** the repository from Task 5.2 and the existing provider/event unique constraint.

**Produces:** unambiguous results for same-order redelivery versus cross-order event-key collision.

- [ ] Write a test that starts two independent PostgreSQL clients/repositories and sends the same verified first payment concurrently. Assert results are one `applied` and one `duplicate`, with exactly one event and revision 1. A single in-process queue is not acceptable evidence.
- [ ] Write a test that reuses a previously recorded provider event key for a *different* private order. Assert `reconcile`, unchanged second-user subscription, and no second event. Add the corresponding in-memory regression to `billing_event_processor_test.ts` before changing the interface.
- [ ] Replace `eventExists` with `eventOrderID` and change `insertEventOnce` to the exact Shared Interface Decisions contract. The processor may classify `duplicate` only when the verified notification's order matches that recorded event; a different order is `reconcile`. If an insert races after the subscription write, throw a typed outcome so the transaction rolls back before classifying the conflict. Update the Task 4 in-memory fake to enforce the same rule.
- [ ] Use database row locks and the unique index; test a renewal race as well as first-payment redelivery. Verify no lost revision and no repeated extension of `paid_through`. Keep the `eventKey` provider-neutral; the actual ECPay per-period key derivation belongs to Task 7 after its product/API choice is confirmed.
- [ ] Run the focused integration tests, the Task 4 in-memory tests, and the full `functions/entitlement` Deno suite. Commit, e.g. `fix(billing): distinguish replay from cross-order event collision`.

## Task 5.4: Account Isolation, Current-Order Policy, And Handoff

**Consumes:** the account UUID from private `billing_orders`, the current-order unique index, and `deriveSubscriptionAccess`.

**Produces:** an explicit fail-closed outcome for conflicting orders and a reproducible local handoff to Task 6.

- [ ] Test a callback that claims another user ID; the database order owner must win. Test an unbound order, wrong amount/currency, malformed paid period, and a preexisting subscription owned by another account. Each must leave financial rows and Pro access unchanged.
- [ ] Test two different current orders for one user. Add `currentOrderForUser` to the processor and both repositories; before a first-payment save, return `reconcile` if it names another current order. Until Task 6 defines re-subscribe and overlap rules, preserve the existing current order; never silently switch it. Confirm the partial new subscription/event is rolled back if the unique index rejects it.
- [ ] Test that `private.subscriptions` returns at most one `is_current=true` row per user and that a query for user A cannot produce user B's paid period. Do not switch the deployed entitlement handler from legacy staging grants in Task 5.
- [ ] Document the local-only commands, the expected output, the absence of real ECPay signature verification, local test-data cleanup, and the exact no-deployment boundary in `LOCAL_BILLING_DB_TEST.md`. Update `ENTITLEMENT_ARCHITECTURE.md` to say the Postgres adapter is locally tested but not deployed or wired to payment.
- [ ] From the `supabase/` directory run `deno test --allow-read=../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures,functions/entitlement/test-fixtures functions/entitlement` for all unit tests; run the loopback-only integration tests separately. Run `supabase test db --local`, `deno lint`, `deno fmt --check`, and `git diff --check`. Record counts and any unavailable prerequisite. If no local PostgreSQL run occurred, label Task 5 incomplete.
- [ ] Review only this task's staged diff, commit the final documentation/test change, and leave the branch clean. Do not push, link a project, or deploy as part of Task 5.

## Execution Handoff

Task 5 is complete only when a fresh local Supabase database applies all migrations and passes pgTAP, the Deno tests exercise actual PostgreSQL with two independent connections, and the existing entitlement suite remains green. The current machine has Deno but lacks Supabase CLI, a container runtime, and `psql`; those prerequisites must be addressed before claiming database evidence.

Task 6 may then build authenticated subscription/checkout/cancellation APIs against this tested repository using a mock provider. Task 7 must establish the approved ECPay product/API, stable provider event identity, signed callback normalization, and missed-notification reconciliation before any real payment behavior is enabled. No Task 5 result changes the paid-launch No-Go decision.

## Primary Technical References

- [Supabase local CLI workflow](https://supabase.com/docs/guides/local-development/cli-workflows): local migration/reset boundaries and the distinct destructive `--linked` target.
- [Supabase CLI reference](https://supabase.com/docs/reference/cli/supabase-db-schema-declarative): local `test db` and pgTAP execution.
- [Supabase Edge Function PostgreSQL connection guide](https://supabase.com/docs/guides/functions/connect-to-postgres): direct server-side clients and transaction-pooler constraints.
- [Postgres.js transaction documentation](https://github.com/porsager/postgres#transactions): a transaction-scoped connection and automatic rollback when the callback throws.
