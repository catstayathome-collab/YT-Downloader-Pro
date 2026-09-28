# Local Billing Database Verification

Current acceptance procedure and results (2026-09-28): see
`LOCAL_ECPAY_RECOVERY.md`. Task 7A.7 applied all six migrations from zero and
passed 135 backend tests (zero ignored) plus 51 pgTAP assertions. Use
`deno task test:billing:all` with both documented environment variables for
complete acceptance; the older pure-test command below omits database/vector
evidence and is not a replacement.

Historical Task 5 status: **locally verified on 2026-09-27**. All four migrations applied from
zero, 29 pgTAP assertions passed, and the combined Deno entitlement/database
suite passed 56 tests with zero failures and zero ignored tests. This is a
development-only procedure and does not authorize deployment or payment.

## Scope And Safety

- Use a dedicated throwaway Supabase CLI project in this checkout only.
- Never run `supabase link`, `db push`, `db reset --linked`, or deploy a function.
- Never substitute a remote database URL. The Deno integration tests reject
  non-loopback hosts before making any database writes.
- Use only synthetic Auth users and orders. Never use merchant credentials,
  real callbacks, card data, customer records, or media data.
- The injected test verifier returns a synthetic normalized notification; it
  does **not** validate an ECPay signature.

## Prerequisites

Use a Docker-compatible runtime, Supabase CLI, and Deno 2. The verified versions
were Supabase CLI 2.117.0, Deno 2.7.13, and the Supabase PostgreSQL image
17.6.1.167. The driver is pinned to postgres 3.4.9 in `deno.json` and `deno.lock`.
The checked-in `supabase/config.toml` uses `project_id = "ytdp-billing-local"`,
API port 55431, database port 55432, and shadow port 55430. Do not link it to any
cloud project. Migrations are append-only and apply in timestamp order.

The test connections are restricted to loopback. Docker may publish the local
stack's ports on all host interfaces by default; use a trusted local development
machine and stop the stack after testing. It has synthetic local credentials
and must never hold customer or production data.

## Verification

From the repository root:

```sh
supabase start
supabase status
```

Confirm that `supabase status` reports this project's **local** DB URL and
loopback host. `supabase db reset --local` destroys this project's local data;
run it only after confirming this is the dedicated throwaway project.

```sh
supabase db reset --local
supabase test db --local
```

From `supabase/`, provide the local DB URL from `supabase status` in the shell
only. Do not commit a URL or paste status output containing keys into issues:

```sh
export YTDP_LOCAL_BILLING_DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
deno task test:billing:db
deno test --allow-read=../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures,functions/entitlement/test-fixtures \
  functions/entitlement
deno lint functions/entitlement
deno fmt --check functions/entitlement deno.json deno.lock
```

The dedicated database task reports **13 passed, zero ignored**: one URL guard
test plus twelve database tests. It grants read access only to the local URL
variable and the specific `PG...` defaults read by the pinned driver, and network
access only to `127.0.0.1:55432`. Missing the URL fails the dedicated task; a
remote URL fails before connection or fixture creation. Changing the configured
port requires updating the task's network permission too.

It checks first
payment, rollback on event failure, independent-connection redelivery and
renewal, current-order exclusivity, cross-account event collision, and invalid
payment data. The unit suite intentionally ignores those DB tests when the URL
is absent; that is not database verification. Stop the local stack with
`supabase stop` after collecting evidence. Do not remove another project's
containers or volumes.

For a single combined run, use this command from `supabase/` with the same
local URL variable:

```sh
deno test \
  --allow-env=YTDP_LOCAL_BILLING_DATABASE_URL,PGSSL,PGSSLNEGOTIATION,PGIDLE_TIMEOUT,PGCONNECT_TIMEOUT,PGMAX_LIFETIME,PGMAX_PIPELINE,PGBACKOFF,PGKEEP_ALIVE,PGDEBUG,PGFETCH_TYPES,PGPUBLICATIONS,PGTARGET_SESSION_ATTRS,PGAPPNAME,PGTARGETSESSIONATTRS \
  --allow-net=127.0.0.1:55432 \
  --allow-read=../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures,functions/entitlement/test-fixtures \
  functions/entitlement
```

## Evidence And Implementation Notes

- RED: the original migrations failed five of 24 schema assertions because
  order owner, amount, currency, identifier, and provider were not immutable.
  The fourth migration adds an invoker trigger with a fixed `pg_catalog`
  search path; it does not introduce a `SECURITY DEFINER` function.
- GREEN: a fresh local reset applies all migrations; 29 schema assertions pass,
  including actual role-denied reads, unique-key violations, and foreign keys.
- Deno unit-only run: 44 passed; twelve DB tests intentionally ignored without
  database permissions. Combined run: 56 passed, zero ignored.
- Independent clients test first-charge replay, renewal replay, and two orders
  for the same account. A barrier before event insertion forces a cross-account
  uniqueness race and proves the losing transaction rolls back its subscription.
- Failed event insertion and current-order constraint errors roll back all
  preceding writes. Spoofed callback account IDs never override the private
  order owner; another account's row derives Free.
- Post-test counts for `auth.users`, `billing_orders`, `subscriptions`, and
  `subscription_events` were all zero. Fixtures clean themselves up and schema
  tests end in `ROLLBACK`. No customer data is used.
- `deno lint`, `deno fmt --check`, and `git diff --check` passed. This change
  touches no Swift source, so no new App package is needed for this backend task.

Task 6 can consume `createPostgresBillingRepository(sql)` and the existing
subscription policy for authenticated subscription/status and mock-provider
cancellation APIs. Every writer must lock the account before its order, preserve
the immutable order binding, and treat `reconcile` as a manual/reconciliation
path rather than a successful payment. The adapter does not create orders,
authenticate HTTP requests, or verify real provider signatures.

## Remaining Gates

The adapter is not wired into the deployed entitlement handler. Real payment
use still requires a reviewed ECPay verifier, order creation, callback
normalization and reconciliation, cancellation API, approved provider/product
terms, legal/accounting/licensing review, and a separate owner-approved launch
decision under `COMMERCIAL_FEASIBILITY.md`.
