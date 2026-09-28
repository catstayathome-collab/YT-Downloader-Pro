# Task 7B: External Integration Readiness

Date: 2026-09-28. Status: preparation only; external integration blocked.

## Scope And Evidence

Task 7A.1 checksum, 7A.2 notification parsing and 7A.3 trusted order/period
normalization, 7A.4 mock query validation/decisions, 7A.5 atomic recovery and
7A.6 bounded mock-only runner are implemented locally.
7A.7 remains: end-to-end regression and maintainer handoff. These are prerequisites,
not features already delivered by the notification parser.

`PAYMENT_PROVIDER_QUESTIONS.md` still records the provider inquiry as not
submitted. No dated written approval for this product was found in the repository.
If approval exists outside the repository, obtain a redacted copy or evidence
reference from the owner; never infer permission from an existing merchant login.
`COMMERCIAL_FEASIBILITY.md` remains the release gate.

No merchant settings, cloud deployment, real checkout, cancellation or charge
was performed for this preparation. Do not store keys, cards, ID documents or
raw callback bodies in this document, Git, chat, logs or test fixtures.

## Ordered Work And Acceptance Gates

1. Finish 7A.7 and review the local evidence. Simulation, mismatched merchant,
   wrong account, conflicting replay and incomplete history must never grant Pro.
2. Obtain dated written product eligibility and recurring-payment approval;
   confirm contracted API/product, merchant identity, fees, cancellation/refund
   rules and owner authorization for a specifically scoped staging exercise.
3. Confirm first-payment extra-field availability with NeedExtraPaidInfo=Y;
   exact first/renewal/query identities, UTC+08 semantics, failure payloads,
   recurring period boundaries and cancellation effective-time evidence.
   Missing authorization or ambiguous period data must stay needs_review.
4. Add a staging-only transport behind the provider protocol, disabled by
   default. Use separate project/merchant secrets, HTTPS allowlists, request
   deadlines, body limits and redacted diagnostics. Reject production hosts in
   staging. Tests must prove secrets and raw payment/card fields cannot escape.
5. Deploy only after fresh approval naming the destination and intended changes.
   Verify signed callbacks through the parser, trusted normalizer and atomic
   ledger. A browser return URL or simulated notification cannot activate Pro.
   Replay tests must show one grant; altered facts must require review.
6. Exercise approved sandbox first payment, renewal, missed-notification query,
   duplicate, cancellation uncertainty, confirmed cancellation and rollback.
   Do not infer recurring success from one checkout. Record redacted evidence,
   exact app/backend revision and timestamps, not sensitive responses.
7. Verify the existing signed-entitlement boundary end-to-end: account isolation,
   expiry, cancellation paid-through plus 72 hours, revoked/refunded behavior,
   offline restrictions and Free fallback. No client-side switch grants paid Pro.
8. Review incident handling, reconciliation ownership, privacy, accounting and
   release evidence. Production credentials/charging require a separate approval;
   passing sandbox tests is not paid-launch authorization.

## Owner Input Needed

- Written ECPay product/recurring eligibility response, if received (redacted).
- Confirmation of the contracted recurring API and sandbox availability.
- After local prerequisites pass, explicit staging deployment/test approval.

Until then, continue local TDD. Do not activate billing or schedule unattended
financial operations. This checklist is not a claim that 7B is implemented.
