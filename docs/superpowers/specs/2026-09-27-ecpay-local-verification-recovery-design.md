# Task 7A: Local ECPay Verification And Recovery

Status: owner approved design for implementation planning on 2026-09-27;
the implementation plan still requires review before execution.
Date: 2026-09-27.
Baseline: Task 6, commit `f0d6eeb`, branch
`codex/supabase-staging-integration`.

## Intent And Boundaries

Prepare the existing subscription backend to distinguish authentic candidate
AIO notifications from invalid or ambiguous input, and recover local pending
operations without repeating a financial action. The owner approved AIO
credit-card recurring payments as a candidate specification for local work,
not as a confirmed merchant entitlement or authorized live payment product.

Success means reproducible offline fixture tests and local PostgreSQL recovery
tests, with no accidental Pro grant, repeated paid period, or guessed outcome.
Existing Free, signed entitlement and paid-through-plus-72-hour rules remain.

Excluded: real merchant secrets, ECPay sandbox or production requests, cloud
migrations, public webhook hosting, payment pages, Swift UI, refunds initiated
by this service, automatic resubscription, scheduled jobs, and Windows work.
No change to the deployed entitlement entrypoint or Task 6 mock provider mode.
Written provider/product approval and fresh deployment approval remain gates.

## Source Basis

Read on 2026-09-27; sources describe candidate AIO behavior, not our account's
eligibility:

- [Periodic notifications](https://developers.ecpay.com.tw/16549/): initial and
  subsequent authorization notifications use separate return endpoints;
  verify the checksum and distinguish simulated payments. Missed subsequent
  notifications require query-based reconciliation.
- [Recurring order query](https://developers.ecpay.com.tw/16584/): query results
  expose authorization details and recurring execution state. Query data is
  not interchangeable with callback data.
- [Recurring order operations](https://developers.ecpay.com.tw/16618/): candidate
  recurring-order management reference. No mutation transport is built in 7A.
- [AIO checksum reference](https://developers.ecpay.com.tw/2902/): use the AIO
  canonicalization, not a similarly named invoice, logistics, or ECTicket MAC.

The English checksum link returned 404 during research; the Chinese AIO
reference and a pinned official SDK/test vector must be checked before the
checksum implementation is accepted. Conflicts between prose, YAML, and SDK
examples become explicit rejected/needs-review fixtures, not permissive parsing.

## Architecture

Keep three trust boundaries separate:

1. Raw form -> verified candidate notification. Only the verifier has access
   to injected test HashKey/HashIV. No database writes occur here.
2. Verified notification + private order/period facts -> normalized event.
   Reuse `processBillingNotification` and its atomic event/subscription writer.
3. Injected mock query result -> validated recovery evidence -> transactional
   recovery of the existing operation. A query is never a new checkout or cancel.

Proposed focused modules in `supabase/functions/entitlement/`:

| Module | Responsibility |
| --- | --- |
| `ecpay_aio_checksum.ts` | AIO SHA-256 canonicalization and fixed-length MAC comparison |
| `ecpay_aio_notification.ts` | Bounded form decoding, route-specific field validation, merchant checks |
| `ecpay_billing_normalizer.ts` | Order/amount/authorization identity and trusted period binding |
| `billing_reconciliation.ts` | Pure decision over validated query evidence and local state |
| `postgres_billing_reconciliation_repository.ts` | Atomic recovery, conditional updates, audit evidence |
| `test-fixtures/ecpay/` | Synthetic first/renewal/query fixtures with provenance notes |

Prefer existing transaction adapters and subscription policy over a parallel
state machine. Any interface additions must leave Task 4-6 tests passing.
These are internal modules, not new deployable endpoints.

## Notification Verification

- Accept only the expected POST form content type, at most 65,536 bytes while
  streaming, at most 128 fields, and bounded field names/values.
- Reject malformed percent encoding/UTF-8, duplicate decoded field names,
  case-colliding names, missing required fields, unsafe numeric values, invalid
  dates and oversized values. Decode once; never trim or normalize a value
  before MAC calculation unless required by the pinned AIO algorithm.
- Include every received field except the checksum field in MAC calculation.
  Unknown signed fields cannot select identity, period or plan; contradictory
  recognized aliases are rejected rather than picking one.
- Verify expected merchant ID and SHA-256 MAC before semantic normalization.
  Reject malformed MACs; compare equal-length digest bytes without an early
  exit. Runtime security claims remain subject to JavaScript implementation
  limits; do not promise cryptographic timing guarantees for arbitrary JS.
- Use independent known-answer vectors from a pinned official source as well
  as synthetic tampering cases. A test that signs and verifies with the same
  implementation is insufficient evidence of compatibility.
- A simulated payment never produces `payment_succeeded`. If the field is
  absent, follow the reviewed route schema; absence alone is neither proof of
  simulation nor proof that the remaining notification is valid.
- Route-specific adapters preserve the distinction between first payment and
  renewal. Do not lowercase all field names to hide protocol differences.

Only sanitized identifiers and reason codes leave this boundary. Do not log
raw bodies, keys, MAC inputs, card fragments, authorization codes, or emails.

## Normalization And Periods

Account authority remains the immutable private order owner, never custom
callback fields, email, or a client-provided UUID. Expected currency is TWD;
strict integer whole-TWD input 80 becomes internal minor units 8000. Reject
fractions, exponents, signs, overflow, and mismatched expected amounts.

Canonical authorization identity is a versioned namespace binding merchant,
merchant order and authorization reference. First-payment, renewal and query
adapters must map the same authorization to the same key. Hash an unambiguous
structured tuple to stay within the existing 128-character ledger limit.
Neither notification arrival time nor `TotalSuccessTimes` alone is an event ID.
Missing/conflicting authorization evidence yields `needs_review`.

For 7A, paid periods come from explicit trusted local fixture schedules bound
to order and authorization, not from client fields or inferred callback dates.
The resolver returns a unique period or `needs_review`; never invent a 30-day
month. Real anchor dates, end-of-month treatment, delayed charges, finite
execution limits and failed-period recovery remain 7B contract gates. Tests
use explicit month-end/leap-year schedules to prove the resolver respects
trusted boundaries without claiming these fixtures describe ECPay scheduling.

Unknown order, period gaps, contradictory facts, partial refund and ambiguous
failures leave subscription access unchanged. Safe contiguous missing payments
may be replayed oldest-first using the existing event writer. Persist progress
per event: a crash after one replay must be safe to resume. Cancelled/refunded/
revoked subscriptions cannot be reactivated by an old successful notification.

## Durable Recovery

The runner accepts an injected mock-only read interface and a bounded batch of
local operation IDs; it cannot accept a caller-selected URL or financial action.
No external transport is supplied. Each lookup has a deadline and bounded
result size; failure or incomplete history preserves uncertainty.

Read a local snapshot, query outside a transaction, then lock account before
order/operation and recheck the snapshot's relevant state/revision. Stale results
must be discarded or reevaluated, never overwrite a newer webhook/refund.
Do not use a transaction lock to cover a network request.

| Evidence | Outcome |
| --- | --- |
| Mock query unavailable, malformed, wrong merchant/order | Keep pending/unknown; record bounded reason |
| Query says not found | Needs review; no automatic resend, deletion or replacement order |
| Checkout creation established, no payment established | May mark creation succeeded; never grant Pro |
| Complete verified payment facts and trusted period | Apply through existing event ledger, once |
| Cancel operation and confirmed cancellation with trustworthy effective time | Atomically update subscription/event/operation if policy accepts |
| Cancelled status without effective time, or time after paid-through | Needs review; do not substitute query time |
| Active provider order despite local cancellation request | Keep unresolved; do not issue another cancellation |
| Newer local terminal state or conflicting facts | Needs review; no reactivation or bonus |

Recovery must support pending and unknown operations without relaxing the
normal request replay path. A dedicated recovery method records evidence and
updates operation state atomically; merely calling Task 6 `finish` again is
insufficient because it intentionally ignores non-pending operations.

Add one additive migration for private recovery audit records, storing only
operation/account binding, evidence digest, observation time, result and a
bounded reason enum. Enforce owner consistency, RLS and denied client grants.
Same evidence/current state must not produce duplicate audit or financial
effects. No raw response storage. Account/order records remain immutable.

The migration does not authorize deleting old orders. Task 6's conservative
restriction on creating a replacement checkout stays until 7B lifecycle rules
are verified. This is an explicit non-release limitation.

## TDD Acceptance Groups

1. Checksum/parser: independent vector, Unicode and punctuation encoding,
   reordered fields, tampered value/key, duplicate keys, malformed UTF-8,
   excessive bodies, missing merchant and wrong merchant.
2. Normalization: first/renewal/query convergence, simulated payment exclusion,
   80-to-8000 conversion, untrusted account fields, missing period, gaps and
   duplicate authorization references with contradictory facts.
3. Recovery decisions: all table rows above, stale snapshots, cancelled/refunded
   state, exact paid-through and 72-hour boundaries, repeated query evidence.
4. Real local PostgreSQL: simultaneous workers, callback/recovery race, rollback
   after subscription write, restart after partial replay, wrong-account access,
   audit uniqueness and denied anon/authenticated direct access.
5. Regression: all entitlement/billing tests with no ignored DB cases, pgTAP,
   format/lint/diff checks. Local fixture rows removed and containers stopped.

Mutation checks must demonstrate that disabled MAC/merchant/amount checks,
duplicate-event protection and revision guards fail the corresponding tests.
No test output or documentation may claim live ECPay interoperability from
synthetic evidence alone.

## Review And Delivery Gate

This document records the approved local-only direction and proposed detailed
contracts. Next: owner reviews this written spec, then a separate implementation
plan gives exact RED/GREEN commands, files and commit-sized tasks. Only after
plan review and execution-method selection does product implementation begin.

7B requires written product/merchant eligibility, the exact API agreement,
real callback/query identity and period semantics, approved sandbox execution,
secret management and hosted operational review. 7A clears none of those gates.
