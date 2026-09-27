# Task 7A Local ECPay Verification And Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify candidate AIO notifications and recover mock billing operations locally without duplicate access grants or repeated financial actions.

**Architecture:** Separate form/MAC verification, normalization against trusted order/period facts, and read-only query recovery. Reuse the subscription policy and PostgreSQL transaction adapter. Query outside transactions; apply validated evidence under account-first locks with stale-state checks and an atomic audit.

**Tech Stack:** TypeScript, Deno 2, Web Crypto, pinned `postgres@3.4.9`, local Supabase/PostgreSQL 17, pgTAP. No new runtime dependency or external transport.

**Spec:** `docs/superpowers/specs/2026-09-27-ecpay-local-verification-recovery-design.md` (owner approved for planning on 2026-09-27).

## Global Constraints

- Only local fixtures and loopback PostgreSQL; no real merchant secrets, ECPay sandbox/production calls, hosted routes, cloud migrations, scheduler, Swift UI, or Windows changes.
- Preserve Task 6 `mode: "mock"`, initial checkout restrictions and deployed `index.ts` unchanged.
- Creating or recovering checkout is not payment and never independently grants Pro.
- Exact amounts: whole TWD `80` becomes `amountMinor: 8000`; expected price remains server-owned.
- Preserve paid-through plus exactly 72 hours after confirmed cancellation; do not extend offline access beyond signed access end.
- Raw input cap 65,536 bytes, maximum 128 fields. Additional local parser limits: decoded field name 64 UTF-8 bytes and value 8,192 UTF-8 bytes. Treat these as conservative candidate limits, not provider promises.
- Recovery batch maximum 20 distinct operation UUIDs, sequential lookups, five-second deadline per lookup, maximum query body 65,536 bytes and 120 authorization records. Exceeding limits requires review, never truncated granting.
- No guess for authorization ID, paid period, cancellation effective time or ambiguous provider outcomes.
- No raw notification/query body, email, card fragments, auth codes, MAC inputs, keys or bearer tokens in persistent audit or errors.
- Small commits only after focused GREEN and review; never commit disabled guards used for mutation tests.

## Review Focus

1. Encoded duplicate keys and case collisions must not pass MAC validation with a different parser interpretation (Task 2).
2. Same authorization with changed facts must require review, not silently become an idempotent success (Tasks 3 and 5).
3. Month-end/leap-year periods and query timestamps must not introduce invented subscription duration (Tasks 3 and 4).
4. A webhook/refund arriving during query must invalidate stale recovery writes (Task 5).
5. Crash after the first recovered payment and late query completion after timeout must not duplicate grants or mutate after return (Tasks 5 and 6).

## Working Directory And Verification Commands

Use the existing worktree `/Users/ouoosu/Documents/Codex/YT downloader Pro/.worktrees/main-release`, not the older root checkout. Read `COMMERCIAL_FEASIBILITY.md`, the spec, and Git status before execution. Verify baseline includes `60d043d`; preserve unrelated changes. Do not create another worktree unless isolation becomes necessary.

Commands below run in `supabase/` unless marked ROOT. Pure tests have no network/env permissions. Fixture-reading tests use `--allow-read=functions/entitlement/test-fixtures/ecpay`.

For DB tests, use the existing `deno task test:billing:db` after adding the new DB test path to that task. Set only the dedicated local URL:

```sh
YTDP_LOCAL_BILLING_DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres' deno task test:billing:db
```

The full-suite task added in Task 7 must run this exact permission set:

```sh
deno test --allow-env=YTDP_LOCAL_BILLING_DATABASE_URL,PGSSL,PGSSLNEGOTIATION,PGIDLE_TIMEOUT,PGCONNECT_TIMEOUT,PGMAX_LIFETIME,PGMAX_PIPELINE,PGBACKOFF,PGKEEP_ALIVE,PGDEBUG,PGFETCH_TYPES,PGPUBLICATIONS,PGTARGET_SESSION_ATTRS,PGAPPNAME,PGTARGETSESSIONATTRS --allow-net=127.0.0.1:55432 --allow-read=../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures,functions/entitlement/test-fixtures functions/entitlement
```

Exit 0, zero failures and zero ignored database tests are required. Import/connection/permission failures are not valid behavioral RED evidence once a test target exists.

## File Map

All TypeScript names below are under `supabase/functions/entitlement/`.

| Unit | Files | Ownership |
| --- | --- | --- |
| Checksum | `ecpay_aio_checksum.ts`, `_test.ts` | AIO canonicalization only |
| Notification | `ecpay_aio_notification.ts`, `_test.ts` | Strict decoding and verified candidate facts |
| Normalization | `ecpay_billing_normalizer.ts`, `_test.ts` | Trusted order/period binding and stable IDs |
| Recovery decision | `billing_reconciliation.ts`, `_test.ts` | Pure evidence-to-decision rules |
| Persistence | `postgres_billing_reconciliation_repository.ts`, `billing_reconciliation_database_test.ts` | Stale guard, atomic audit and event application |
| Runner | `billing_reconciliation_runner.ts`, `_test.ts` | Bounded mock lookups; no mutation transport |
| Existing edits | `billing_event_processor.ts`, its test and in-memory fixture; `postgres_billing_repository.ts`; `test-fixtures/local_database.ts`; `supabase/deno.json` | Shared event application, facts fingerprint, cleanup, test tasks |
| SQL | `supabase/migrations/202609270002_billing_recovery.sql`, `supabase/tests/billing_recovery.sql` | Additive audit/fingerprint schema |
| Fixtures/docs | `test-fixtures/ecpay/{README.md,checksum-vectors.json,notifications.json,queries.json}`; `docs/swift-2.0/LOCAL_ECPAY_RECOVERY.md` | Synthetic provenance and reproducible handoff |

`_test.ts` means the complete matching basename, e.g. `ecpay_aio_checksum_test.ts`. Do not introduce a deployable function entrypoint.

## Shared Contracts

Define each type in its owning module, export it, and import it elsewhere; do not duplicate definitions.

- Task 2: `CandidatePayment = Readonly<{ merchantID: string; orderID: string; authorizationID: string; occurredAt: string; amountTWD: string; outcome: "paid" | "failed"; simulated: boolean }>`; `VerifiedCandidate` is a module-private-symbol-branded CandidatePayment. Only the verifier constructs it. Unsupported/missing facts produce a bounded rejection, not a partially verified object.
- Task 3: `TrustedOrderFacts = Readonly<{ userID: string; merchantID: string; orderID: string; currency: "TWD"; amountMinor: number }>`; `PeriodResolver = (identity: {merchantID: string; orderID: string; authorizationID: string}) => Promise<{from: string; through: string} | null>`.
- Task 3: `NormalizedPayment = { notification: VerifiedBillingNotification; factsDigest: string }`; `NormalizationResult = {kind: "payment"; value: NormalizedPayment} | {kind: "needs_review"; reason: string}`. Reasons are fixed exported literals, never provider text.
- Task 4: `RecoverySnapshot = { userID: string; operation: BillingOperation; subscription: SubscriptionRow | null; stateToken: string }`. The token hashes canonical current-order identity, full relevant subscription state/revision and operation state/update timestamp; it is computed by the repository, not a caller authority.
- Task 4: `RecoveryEvidence = {kind: "unavailable" | "not_found"} | {kind: "order"; merchantID: string; orderID: string; complete: boolean; execution: "active" | "cancelled" | "ended"; cancelledAt: string | null; payments: readonly NormalizedPayment[]}`. This is an internal validated mock-query result, never accepted as client JSON.
- Task 4: `RecoveryDecision = {kind: "needs_review"; reason: RecoveryReason} | {kind: "checkout_confirmed"} | {kind: "payments"; payments: readonly NormalizedPayment[]} | {kind: "cancellation"; occurredAt: string}`. Fixed `RecoveryReason`: `unavailable`, `not_found`, `invalid_evidence`, `incomplete_history`, `conflicting_facts`, `missing_period`, `missing_cancel_time`, `policy_conflict`, `still_active`, `stale_snapshot`.
- Task 5: `RecoveryResult = "applied" | "duplicate" | "needs_review" | "stale" | "unavailable"`; repository `snapshot(userID, operationID): Promise<RecoverySnapshot | null>` and `apply(snapshot, evidence, observedAt): Promise<RecoveryResult>`.

## Task 1: Independently Verified AIO Checksum

Execution status (2026-09-27): COMPLETE. RED/GREEN and mutation evidence,
source provenance and reproduction commands are in
`supabase/functions/entitlement/test-fixtures/ecpay/README.md`.
Ruling: official vectors remain outside Git due to their redistribution
restriction; the committed JSON is a pinned source manifest, not copied vectors.
The acceptance command therefore supplies `YTDP_AIO_VECTOR_FILE` and explicit
read/env permissions as documented in that README. Final regression: 76 Deno
tests (none ignored) and 39 pgTAP assertions passed. Tasks 2-7 remain pending.

**Files:** checksum module/test and checksum fixture provenance files.
**Produces:** `computeAioMac(fields: Readonly<Record<string,string>>, credentials: {hashKey: string; hashIV: string}): Promise<string>`; `verifyAioMac(...same arguments): Promise<boolean>` (reads `CheckMacValue` from fields).

- [ ] Pin the official AIO reference and one official SDK revision or published expected digest. Record source URL, revision/content digest, public-test provenance and expected output in fixture README. Never fill expected output from our implementation. If independent evidence cannot be obtained, stop this task and report the source blocker.
- [ ] RED: write `official_vector_matches`, `tampered_value_fails`, `field_order_is_irrelevant`, `unicode_and_reserved_punctuation`, `malformed_mac_fails`. Assertions: computed MAC equals the independently recorded digest; a changed value or key yields false; order permutation gives identical MAC; absent/nonhex/wrong-length MAC is false.
- [ ] Run `deno test --allow-read=functions/entitlement/test-fixtures/ecpay functions/entitlement/ecpay_aio_checksum_test.ts`; verify missing implementation RED first, then behavioral failures during implementation.
- [ ] GREEN: implement only pinned AIO sorting/encoding/casing and Web Crypto SHA-256. Exclude only `CheckMacValue`. Preserve original values until the algorithm's canonicalization step; compare fixed-length digest bytes without early exit.
- [ ] REFACTOR: isolate canonical encoding helper; rerun the same command and `deno lint functions/entitlement/ecpay_aio_checksum.ts`. Temporarily bypass MAC comparison: tampering test must fail, then restore and rerun GREEN.
- [ ] Commit only Task 1 files: `test(billing): pin AIO checksum vectors and verifier`.

## Task 2: Bounded First-Payment And Renewal Verifier

Execution status (2026-09-28): implementation and local verification complete.
Nine RED tests failed against a rejecting stub; all nine passed after implementation.
Bypassing merchant equality made the wrong-merchant test fail; guard restored.
Full regression: 85 Deno tests, zero failed/ignored; 39 pgTAP assertions passed.
Lint and diff checks passed. Review performed in-session, not independently.
Field profile/provenance and limitations are recorded in the fixture README.
Task 3-7 and real 7B integration remain pending; see ECPAY_7B_READINESS.md.

**Files:** notification module/test, `notifications.json`, fixture README.
**Consumes:** Task 1 checksum functions.
**Produces:** `verifyAioNotification(request: Request, route: "first" | "renewal", config: {merchantID: string; hashKey: string; hashIV: string}): Promise<VerifiedCandidate>`; throws only a fixed `InvalidAioNotification` error with a reason enum.

- [ ] Before accepting fixtures, record exact first/renewal field mappings from the official AIO docs/SDK in README, including authorization identity, amount, timestamp and simulation-field presence rules. Never treat the renewal page's inconsistent generic YAML as a third accepted schema. An unresolved required mapping must reject that fixture and block its positive test.
- [ ] RED tests: `rejects_encoded_duplicate_and_case_collision` asserts `MerchantID` plus encoded-equivalent or case variant rejects; `rejects_bad_utf8_percent_and_double_decode` rejects invalid input; `stream_over_limit_is_cancelled` observes reader cancellation after 65,536 bytes; `field_limits_apply` tests 128/129 fields and name/value boundaries.
- [ ] Add positive route fixtures plus tests for missing/wrong merchant, signed unknown fields, tampered unknown fields, conflicting amount aliases, invalid calendar dates, noninteger amount/reference, wrong method/content type, and simulated payments. Assertions: verified output contains no card/auth-code/email/raw fields; simulated candidate cannot become a paid event in Task 3.
- [ ] Run `deno test --allow-read=functions/entitlement/test-fixtures/ecpay functions/entitlement/ecpay_aio_notification_test.ts`; confirm RED, implement strict one-time form decoding and route-specific mapping, then rerun GREEN.
- [ ] Interpret documented local wall-clock timestamps explicitly as candidate Asia/Taipei UTC+08:00, validate date components by round-trip, never use host timezone or `Date.parse` on slash-form dates. Numeric validation rejects exponent/sign/fraction/overflow before conversion.
- [ ] Mutation check: bypass merchant equality; wrong-merchant test must fail. Restore, format/lint touched files and rerun both Task 1-2 tests.
- [ ] Commit: `feat(billing): verify bounded AIO notification candidates`.

## Task 3: Trusted Normalization And Replay Identity

Execution status (2026-09-28): implemented in `ecpay_billing_normalizer.ts`.
RED: six failing tests against empty/rejecting stubs; three conservative rejection
tests already passed. GREEN: ten focused tests, including an additional RED/GREEN
regression for order mutation while awaiting the period resolver. Mutation check:
removing expected-amount equality produced a paid event and failed the mismatch
test; guard restored. Full Deno regression: 95 passed, zero failed/ignored;
pgTAP: 39 passed. Lint/format/diff checks required before commit.
Review performed in-session; no independent reviewer was available.

Ruling: allow a null period resolver and return bounded `period_unavailable`,
rather than inventing a schedule. Strict ISO instants with explicit offsets are
canonicalized to UTC; calendar rollover and timezone-free dates reject.
Period lookup receives only merchant/order/authorization identifiers, never
callback counters or account fields. No provider transport, HTTP endpoint,
database writes or Pro grants are introduced by this task. Task 4-7 remain pending.

**Files:** normalizer module/test; synthetic schedule cases in fixture README/test.
**Consumes:** VerifiedCandidate, existing VerifiedBillingNotification and trusted server facts.
**Produces:** `normalizeAioPayment(candidate: VerifiedCandidate, order: TrustedOrderFacts | null, resolvePeriod: PeriodResolver): Promise<NormalizationResult>`; `authorizationEventKey(merchantID, orderID, authorizationID): Promise<string>`; `paymentFactsDigest(notification: VerifiedBillingNotification): Promise<string>`.

- [ ] RED: `same_authorization_has_same_key_across_routes` asserts first/renewal facts produce the same ID; changed merchant/order/reference differs. Hash JSON tuple `["aio-auth-v1", merchantID, orderID, authorizationID]` with SHA-256, prefix `aio-v1:`; length <=128.
- [ ] RED: assert strict `"80"` -> 8000, mismatch/overflow/simulation/missing order/wrong merchant -> needs_review; forged custom user fields never alter owner. Failure candidate returns needs_review, not an invented failed period or refund.
- [ ] RED: `trusted_period_only` asserts exact explicit Jan31/Feb-end/leap-year fixtures preserved; missing resolver or invalid/reversed period -> needs_review. Callback counts/timestamps never establish the paid period.
- [ ] Run `deno test functions/entitlement/ecpay_billing_normalizer_test.ts`; implement minimal mapping and canonical digest of version, order, event key, kind, occurredAt, currency, amount and both period bounds (UTC ISO strings), then rerun GREEN.
- [ ] Test changed amount/period/time gives a different facts digest even with the same authorization ID. Temporarily bypass amount matching to verify RED; restore and format/lint.
- [ ] Commit: `feat(billing): bind AIO payments to trusted order periods`.

## Task 4: Pure Query Validation And Recovery Decisions

**Files:** `billing_reconciliation.ts`, its test, `queries.json`, fixture README.
**Consumes:** Task 3 normalization/digests and existing `transitionSubscription`.
**Produces:** shared recovery types; `validateMockQuery(raw: Uint8Array, order: TrustedOrderFacts, resolvePeriod: PeriodResolver): Promise<RecoveryEvidence>`; `decideRecovery(snapshot: RecoverySnapshot, evidence: RecoveryEvidence): RecoveryDecision`.

- [ ] RED: query parser rejects invalid/oversized JSON, duplicate JSON keys, >120 authorizations, wrong merchant/order, ambiguous field aliases, conflicting repeated authorization IDs, and incomplete history. Use a tested strict JSON duplicate-key approach; do not silently rely on last-key-wins `JSON.parse`. Unknown card fields are discarded, never audited.
- [ ] Query boundary is mock-only: query evidence is not authenticated by a callback MAC. Document that a real transport's response authenticity is a 7B gate. Reuse shared validated fact mapping without casting raw JSON to the branded VerifiedCandidate.
- [ ] RED table tests assert unavailable/not-found/incomplete/active-cancel -> needs_review; found checkout without paid evidence -> checkout_confirmed; exact contiguous missing paid periods -> payments; cancelled without effective time or after paid-through -> needs_review. Query observation time never substitutes for cancellation time.
- [ ] RED: terminal refunded/revoked/cancelled state is never reactivated. Duplicate equal authorization records deduplicate; contradictory records require review before applying any event. Missing history before a future payment yields needs_review, not a skipped period.
- [ ] Run `deno test --allow-read=functions/entitlement/test-fixtures/ecpay functions/entitlement/billing_reconciliation_test.ts`; implement deterministic rules and rerun GREEN. Query payments sort by trusted period start, not receipt order; exact duplicates may be offered to the ledger for idempotent replay.
- [ ] Cancellation evidence can include unpaid replay work: return payments first; after those are committed, a fresh snapshot/decision may yield cancellation. Each stage must pass the existing policy independently; never bundle guessed history with a cancellation bonus.
- [ ] Commit: `feat(billing): define conservative mock reconciliation decisions`.

## Task 5: Atomic Recovery And Conflicting-Fact Protection

**Files:** new reconciliation repository/DB test/migration/pgTAP files; existing processor, transaction adapters, processor test doubles and local fixture cleanup; `supabase/deno.json` DB task.
**Consumes:** Task 4 types/decisions and `createPostgresBillingTransaction`.
**Produces:** `createPostgresBillingReconciliationRepository(sql: postgres.Sql)` implementing snapshot/apply. Shared `applyVerifiedBillingEvent(tx: BillingEventTransaction, notification: VerifiedBillingNotification, factsDigest?: string): Promise<BillingEventResult>`; outer caller owns transaction and handles rollback exceptions.

- [ ] RED SQL: add pgTAP tests for private recovery audit, denied anon/authenticated access, owner-binding FK, bounded enums/digests and same evidence/state uniqueness. Run ROOT `supabase test db supabase/tests/billing_recovery.sql`, expect missing schema failure.
- [ ] Add one migration: `private.billing_recovery_audit` with UUID PK, operation/account composite FK, 64-hex evidence/state digests, timestamptz observed_at, bounded result/reason; unique `(operation_id, evidence_digest, state_digest)`. Add required composite unique operation/account key. Add nullable 64-hex `facts_digest` to `subscription_events` for legacy compatibility; never backfill guessed facts. RLS on, revoke anon/authenticated. No raw columns or cascade deletion.
- [ ] ROOT `supabase migration up --local`; rerun pgTAP GREEN. Update fixture cleanup to remove audit before operations. Add DB test path to existing focused task, preserving its permission list.
- [ ] RED DB tests: known digest+same facts is duplicate; same event ID+changed digest requires review without revision change; legacy event with no digest requires review for new 7A requests. Existing Task 4-6 no-digest behavior remains compatible.
- [ ] Extract existing event policy/write block into `applyVerifiedBillingEvent`; add transaction read `eventFactsDigest(provider,eventKey): Promise<string|null>` and optional digest argument to `insertEventOnce`. Distinguish absent event via existing `eventOrderID`. Update all test repositories; keep outer processor verification/errors unchanged. Add optional `factsDigest?: string` to the internal processor dependencies (not HTTP input), validated as 64 lowercase hex; 7A supplies the computed digest from Task 3. All new callback/query writes compare/store it in the same transaction. No nested `sql.begin` inside recovery.
- [ ] RED DB tests: two workers for one pending/unknown cancellation produce one event/revision; callback versus recovery gives one paid-period grant; refund while lookup is pending produces stale with no overwrite; SQL failure after subscription write rolls back audit/event/operation together. Run focused DB command and record behavioral RED before implementing these guards.
- [ ] GREEN repository: lock account first, then order/operation; recompute state token; mismatches return stale without financial writes. Reevaluate evidence against locked state. Apply at most one recovered payment per transaction through shared helper, audit atomically, retain unresolved operation until fresh decision confirms completion. For cancellation commit event+operation success+audit together. Unknown -> succeeded is allowed only through this evidence-checked path, not normal request replay.
- [ ] Before selecting the next payment, check every evidence payment against the ledger: matching key/order/digest is already applied; changed or missing legacy digest requires review. Remove proven duplicates from the decision input, then select the first remaining contiguous period. When no unapplied payments remain, evaluate checkout/cancellation with an empty payment list. This prevents a resumed batch from repeatedly selecting its already-committed first event. Add `replay_skips_committed_prefix_and_finalizes` assertions to the DB suite.
- [ ] For multiple payments the runner repeats snapshot/apply on the same evidence until no unapplied contiguous payments remain; detect no-progress/review and stop. Checkout may become succeeded before all payments arrive, so snapshots/recovery must also permit succeeded checkout operations for missed-payment reconciliation; success is not a reason to skip financial history.
- [ ] Audit's evidence digest hashes only validated canonical business facts, never raw/card fields. Exclude observation time so identical repeated observations deduplicate. Store pre-state digest; do not alter financial state for identical already-applied evidence. Concurrency conflicts roll back or return duplicate, never a partial commit.
- [ ] GREEN focused DB suite and pgTAP. Mutation checks: disable digest comparison, event uniqueness handling and state-token guard one at a time; corresponding tests must fail. Restore and rerun GREEN.
- [ ] Commit: `feat(billing): recover operations with atomic evidence and replay guards`.

## Task 6: Bounded Read-Only Recovery Runner

**Files:** runner module/test and additions to recovery DB test.
**Consumes:** Tasks 4-5.
**Produces:** `MockBillingQuery = {mode: "mock"; lookup(orderID: string, signal: AbortSignal): Promise<Uint8Array>}`; `runRecoveryBatch(userID: string, operationIDs: readonly string[], dependencies): Promise<ReadonlyArray<{operationID: string; result: RecoveryResult}>>`. Dependencies: repository, query, trusted order loader, PeriodResolver and injected `now(): Date`. No create/cancel/refund function is accepted.

- [ ] RED tests: >20 IDs/invalid UUID rejects before lookup; duplicate IDs queried once; wrong-account/missing operation not queried; nonmock mode rejected; five-second fake-clock timeout returns unavailable without unhandled rejection or later writes.
- [ ] RED: three contiguous mock authorizations, interruption after first applied payment, restart -> final revision increments only for remaining periods. Already-succeeded checkout can recover a missed renewal. Query exception/invalid/incomplete response leaves access unchanged.
- [ ] Run `deno test --allow-read=functions/entitlement/test-fixtures/ecpay functions/entitlement/billing_reconciliation_runner_test.ts`; implement sequential bounded runner. Race the lookup against abort/deadline; late result has no attached write path. Query once per operation; refresh snapshot between per-event transactions. Maximum 121 apply attempts (120 payments plus final operation/cancellation decision); no progress stops with needs_review.
- [ ] Assert no payment mutation transport exists and no global `fetch` is called in all successful/error cases. Run focused DB suite for restart integration and all pure tests GREEN.
- [ ] Commit: `feat(billing): orchestrate bounded mock-only recovery`.

## Task 7: End-To-End Regression And Maintainer Handoff

**Files:** `supabase/deno.json`, `docs/swift-2.0/LOCAL_ECPAY_RECOVERY.md`, architecture/Task 6 handoff docs; progress checkboxes in this plan.

- [ ] Add `test:billing:all` task with the exact full-suite command above. Run with local DB URL; database tests must not be ignored. Add any missing end-to-end fixture case before declaring completion.
- [ ] Exercise first payment -> duplicate -> missing renewal recovered -> cancellation uncertainty -> confirmed recovery -> paid-through+72h end -> Free. Assert wrong-account/forged/simulation cases leave revision unchanged; mocked checkout success alone stays Free. Use the real local DB plus existing signed-entitlement tests, not a live Google/browser/payment test.
- [ ] On the dedicated local project, first verify fixtures are empty. ROOT `supabase db reset --local`, `supabase test db`; from supabase run `YTDP_LOCAL_BILLING_DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres' deno task test:billing:all`. Expect every migration applies and all tests pass with zero ignored. Do not reset a database containing unexplained user data.
- [ ] Run `deno lint functions/entitlement`, `deno fmt --check` on all changed TypeScript/JSON, ROOT `git diff --check`. Inspect exported trust boundaries, removed guard mutations, absence of network entrypoints/secrets, and untracked files. Seek an independent reviewer if available; otherwise record in-session review explicitly.
- [ ] Document exact test totals, source vector provenance, commands, fixture exclusions, recovery limitations and 7B gates. Do not reuse Task 6's historical 70/39 counts as current results or label fixtures as sandbox interoperability.
- [ ] Verify test users/orders/subscriptions/events/operations/audits all return to zero; ROOT `supabase stop`. No automatic schedule, push, merge, release, or App packaging.
- [ ] Commit: `docs(billing): record local AIO recovery verification and handoff`.

## Execution Handoff

Seven reviewable tasks; each starts RED, ends GREEN/REFACTOR and a scoped local commit. Tasks 1-4 define the interfaces used by 5-6; Task 7 is integration evidence. Preserve the previously selected native execution approach after owner review of this plan. Approval to execute this plan does not authorize Task 7B or any payment-provider account action.

Plan self-review: all spec acceptance groups map to Tasks 1-7; five review-focus cases are explicitly assigned. The concrete parser/runner limits above are local fail-closed choices. Provider field mapping/vector provenance must be independently established in Tasks 1-2 before accepting compatibility tests. The only trusted period/cancellation facts remain synthetic local inputs; no production scheduling rule is inferred.
