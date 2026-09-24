# Entitlement Signing-Key Rotation

## Boundary

The entitlement service signs short-lived compact ES256 tokens. Private keys
stay in managed server-side secret storage; apps contain only reviewed P-256
public keys indexed by `kid`. The normal token lifetime is 24 hours and the app
may use a previously verified token for at most another 72 hours of offline
grace. Rotation therefore retains the old public key for at least 96 hours
after the signing switch.

This runbook is for owner-approved staging exercises until production legal,
security, operations, and release gates are complete.

## Planned Rotation

1. Generate a fresh P-256 signing key offline on a trusted operator machine.
   Give it a new non-secret `kid`; never reuse a retired ID.
2. Add only the new uncompressed public key and `kid` to the app's reviewed
   key ring. Keep the old public key present.
3. Build, test, sign, and distribute the updated app. Confirm it accepts both
   old- and new-key fixtures, rejects unknown keys, and still enforces issuer,
   audience, subject, schema, time, feature, height, state, and revision claims.
4. Add the new private key to the approved staging secret store. Never place it
   in Git, app resources, CI output, support material, or operator chat.
5. Change `ENTITLEMENT_ES256_KID` so the service signs new tokens with the new
   key. Verify one synthetic staging account end to end.
6. Retain the old public key in shipped apps for at least 96 hours after the
   switch: 24-hour token life plus 72-hour offline grace.
7. Stop signing with the old `kid` and confirm current responses use only the
   new ID. Keep the old private key disabled and access-restricted during the
   observation period.
8. Remove the old public key only after telemetry-free operational evidence,
   support evidence, and staged tests show no accepted token still requires it.
   Removing it requires another reviewed app release.

Record the UTC timestamps, old/new `kid`, app versions, function version,
verification results, owner approval, and rollback decision. Record identifiers
and outcomes only, never private-key material or complete tokens.

## Compromise Response

If a private key may be exposed:

1. Treat the event as active compromise; stop signing with the affected `kid`.
2. Restrict service access, preserve audit evidence, and notify the product
   owner/security contact through the incident process.
3. Generate a clean offline key and deploy the new public key/app path as fast
   as the reviewed release process allows.
4. Rotate the server secret and signing `kid`; do not extend the normal 96-hour
   overlap for a compromised key.
5. Remove trust in the compromised public key through an emergency app update.
   Until that update reaches users, consider returning canonical Free and
   disabling entitlement issuance rather than trusting suspect Pro grants.
6. Review issued token IDs, grant revisions, account changes, logs, backups,
   access roles, and secret-store audit history without collecting media data.
7. Document scope, user impact, notification/legal decisions, recovery tests,
   and the conditions for restoring service.

Never solve a suspected compromise by embedding a private key in the app,
accepting an unsigned response, weakening claim checks, or granting Pro from
account identity or local preferences.
