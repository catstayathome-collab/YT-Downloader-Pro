# AIO Checksum Test Provenance

## Mock Query Contract (Task 7A.4)

`queries.json` is original synthetic data, deliberately not an ECPay API schema.
Its mode must be mock. Order responses carry exact merchant/order identity,
complete history flag, active/cancelled/ended execution status, an explicit
nullable cancellation instant and at most 120 authorization records. Each record
contains authorization ID, whole-TWD amount, ISO timestamp, paid outcome and a
false simulation flag. Missing/failed/ambiguous records cannot be interpreted
as successful charges. Real query authenticity and field mapping remain 7B gates.

UTF-8 JSON is bounded to 65,536 bytes and nesting depth 32. JSON.parse checks
grammar; a separate bounded structural walk rejects decoded duplicate and
case-colliding keys (including escaped keys and nested objects) before the parsed
object is used. Unknown fields reject except explicitly discarded card4no,
card6no, auth_code and email fields. None survive into validated evidence.
Malformed input yields unavailable without raw error text. Incomplete history
is retained as such and always yields needs_review.

The shared normalizer is used only after mock fields are validated, never by
casting a query object to the branded callback candidate. Order facts are copied
before awaiting the period resolver. Payments are sorted by trusted period start;
identical authorization facts deduplicate, contradictions reject the whole query.

Decision policy reuses transitionSubscription on local copies only. No writes,
network request, checkout, refund or cancellation command exists here. Gaps or
overlaps stop the batch; terminal subscriptions cannot reactivate. A cancellation
requires an explicit time accepted by the policy after any missing payments.
Missing payments are offered first, then a fresh snapshot can propose cancellation.

Previously paid records are still offered for atomic ledger verification in
Task 5. The repository must filter only digest-proven committed records, check
snapshot account ownership and current state, and apply one event atomically.
Neither a mock query nor checkout_confirmed alone grants Pro. No real provider
query response is authenticated by these tests.

Evidence: 12 focused tests; duplicate-key guard mutation produced the expected
failure and was restored. Full regression: 107 backend tests, zero failed/ignored,
and 39 pgTAP assertions. Verification remains local; review was in-session.

## Trusted Period Cases (Task 7A.3)

`ecpay_billing_normalizer_test.ts` uses the real notification verifier with the
original synthetic first/renewal fixtures below. No unverified object is cast
to VerifiedCandidate. TrustedOrderFacts must come from a private server-side
order loader, not callback custom fields or a client-selected account.

Explicit Jan 31 -> Feb 29 (2024), Feb 29 -> Mar 31 (2024), and Jan 31 -> Feb 28
(2025) schedules test preservation of supplied boundaries. They are not a claim
about ECPay's real billing anchors. Callback receipt time, authorization time and
counters do not establish a paid period. Missing/throwing/invalid resolvers yield
bounded needs_review results. The later transactional writer must still check
current ownership, period continuity and terminal subscription state.

Replay key: SHA-256 of JSON tuple `["aio-auth-v1", merchantID, orderID,
authorizationID]`, prefixed `aio-v1:`. First/renewal routes share this identity.
Facts digest: SHA-256 of JSON tuple `["aio-payment-facts-v1", provider, orderID,
eventKey, kind, occurredAt, currency, amountMinor, paidFrom, paidThrough]`.
All timestamps are canonical UTC ISO strings. Changed financial facts change
the digest without changing the authorization key. Future Task 5 must compare
and persist this digest atomically; generating a digest alone does not prevent
database replay. No raw/card/custom fields are hashed or retained.

Simulation and unsuccessful callbacks never produce a payment event here.
Whole-TWD conversion uses integer arithmetic and checks the safe-integer bound
before converting to numeric minor units. Expected order amount must match.
Evidence: ten focused tests; amount-guard mutation failed as expected and was
restored. Full backend regression passed 95 tests, with 39 pgTAP assertions.

## Notification Profile (Task 7A.2)

Verified against official documentation on 2026-09-28:
[first payment](https://developers.ecpay.com.tw/2878/),
[additional credit-card fields](https://developers.ecpay.com.tw/5675/),
[renewal](https://developers.ecpay.com.tw/16549/).
Some direct pages returned 404; their indexed official text was available.
This is a candidate local profile, not sandbox interoperability evidence.

| Fact | First payment | Renewal |
| --- | --- | --- |
| Merchant/order | MerchantID / MerchantTradeNo | MerchantID / MerchantTradeNo |
| Authorization | gwsr | Gwsr |
| Amount | amount, equal to TradeAmt | Amount |
| Authorization time | process_date | ProcessDate |
| Outcome | RtnCode | RtnCode |
| Simulation | SimulatePaid required, 0 or 1 | absent for real notifications, otherwise 0 or 1 |

First payments require `NeedExtraPaidInfo=Y` at checkout and credit-card
PaymentType. We do not substitute TradeNo or PaymentDate for missing authorization
facts. The renewal page's generic YAML is not an alternative accepted schema.
The UTC+08 timestamp interpretation remains a candidate assumption to confirm in
7B. Local fixtures are original synthetic data, signed at runtime using dummy
credentials. Checksum correctness is independently covered by Task 1 vectors.

Parser limits are local policy: POST form only, UTF-8, 65,536 wire bytes,
128 fields, 64 decoded name bytes, 8,192 decoded value bytes. Names are ASCII
identifiers and unique ignoring case; values are decoded once, never trimmed.
Unknown fields participate in MAC verification but are not retained. Numeric
facts must be canonical nonnegative safe integers; amount/reference must be
positive. Incomplete failures reject for later query/review, not invented facts.

The frozen, privately branded candidate carries `simulated`; it is not a paid
event. Task 3 must reject simulation and bind the candidate to trusted order and
period facts before any grant. No HTTP endpoint or database write is introduced.
Errors expose only bounded reason codes, never raw notification/card data.

Task 2 evidence: 9 RED failures against the initial rejecting stub, then 9 GREEN
tests. Removing merchant equality caused the wrong-merchant test to fail; the
guard was restored. Full local regression: 85 Deno tests with zero ignored or
failed, plus 39 pgTAP assertions. Local fixture row counts returned to zero.
Lint passed. Review was in-session. External deployment remains unperformed.

Task 7A.1, verified 2026-09-27. No payment API is contacted by these tests.

## Independent Reference

The pinned source is ECPay's official public repository:
[checksum vectors](https://github.com/ECPay/ECPay-API-Skill/blob/ae964f75b69ec90e1c205b136364ab6587fc328c/test-vectors/checkmacvalue.json).
Revision and raw-file SHA-256 are recorded in `checksum-vectors.json`.
Select only the five SHA256 vectors without a separate formula field; logistics
MD5, invoice MD5 and ECTicket are deliberately excluded. Expected digests are
read from the pinned independent source, not generated by our implementation.

The source LICENSE restricts redistribution. We retain only source metadata in
Git, not its vectors or verification scripts. Public test credentials in the
external file are not the owner's merchant credentials. Do not replace this
file with real merchant material. The official script was read, not executed.
The official developer checksum page returned 404; the pinned reference is
the basis for local candidate compatibility, not proof of live interoperability.

For local evaluation download the raw source to a location outside Git, then
from `supabase/` run:

```sh
curl -sSfL https://raw.githubusercontent.com/ECPay/ECPay-API-Skill/ae964f75b69ec90e1c205b136364ab6587fc328c/test-vectors/checkmacvalue.json -o /tmp/ytdp-ecpay-vectors.json
YTDP_AIO_VECTOR_FILE=/tmp/ytdp-ecpay-vectors.json deno test --allow-env=YTDP_AIO_VECTOR_FILE --allow-read=/tmp/ytdp-ecpay-vectors.json functions/entitlement/ecpay_aio_checksum_test.ts
```

The test verifies raw-file SHA-256 before reading expected answers. Wrong or
missing files fail. Without environment permission the independent-source test
is explicitly ignored; that run alone does not satisfy Task 1 acceptance.
Granting environment permission but omitting the variable fails immediately.
Keep the restricted source out of release archives and repository uploads.

## Original Local Cases

The small local vectors use original inputs and dummy `local-key`/`local-iv`.
Expected digests were calculated independently with Python standard-library
`urllib.parse.quote_plus(..., safe="!*()")`, explicit tilde percent-encoding,
lowercase canonicalization and `hashlib.sha256`, before production code existed.
They cover ordering, Chinese text, apostrophe, tilde, spaces, literal plus,
percent, ampersand, equals, punctuation and empty values.

The verifier accepts only the documented uppercase 64-hex SHA-256 representation.
It scans all digest bytes without early exit, but makes no JavaScript constant-
time guarantee. This is a low-level checksum primitive, not authentication of
a complete payment: Task 2 must reject malformed/duplicate/case-colliding form
fields and validate merchant identity before any financial action. Because AIO
canonicalization lowercases data, the MAC must not be described as detecting
every case-only change. Never use checksum success alone to grant Pro.

## Execution Evidence

- RED: empty compute/false verify stubs produced four failing positive tests.
- GREEN: all six focused tests passed, including five external official vectors.
- Mutation: returning true for every well-formed MAC caused the tampering test
  to fail; the correct comparison was restored before final verification.
- Scope ruling: complete only Task 1 in this user turn; leave Tasks 2-7 pending.
- Final regression: 76 Deno tests passed, zero failures/ignored (including
  PostgreSQL and the external vector); 39 pgTAP assertions passed. Formatting,
  lint and diff checks passed. Review was in-session, not independent review.
- License ruling: source manifest plus opt-in local external fixture replaces
  copied official vectors. This prevents restricted material entering Git.
- Verification is local/offline after obtaining the public reference; no live
  checkout, merchant account access or external deployment.
