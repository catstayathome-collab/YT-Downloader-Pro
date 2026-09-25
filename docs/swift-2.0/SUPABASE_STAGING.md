# Supabase Staging Handoff

## Current Boundary

The repository contains a staging-capable Google sign-in adapter, entitlement
schema, migration, Edge Function, verifier, and app bridge. On 2026-09-25, the
owner-configured Supabase staging project `kjevrhjcrlvgncxaacaz` and Google
OAuth client completed a live sign-in smoke test. Supabase showed the test user;
the ad-hoc internal app displayed the account and remained Free using the
explicit process-memory session mode. The app reported that entitlement status
could not yet be confirmed. Developer ID Keychain persistence, a live Pro
entitlement, billing, and public service remain unverified or unavailable.

The normal public app remains accountless Free. Staging authentication requires
all three conditions:

1. an `internal-test` compilation;
2. exact process mode `YTDP_AUTH_MODE=staging`; and
3. a valid bundled `SupabaseConfiguration.json`.

Missing or malformed configuration fails closed to disabled authentication.
Never use this staging path for production users, payment, or billing.

## Public Configuration Contract

Only these non-secret fields may appear in the JSON object:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `projectURL` | Exact `https://<project-ref>.supabase.co` origin |
| `publishableKey` | Supabase `sb_publishable_...` key only |
| `redirectURL` | `com.tachouweng.ytdownloaderpro2://auth/callback` |
| `entitlementURL` | Same origin plus `/functions/v1/entitlement` |
| `entitlementIssuer` | Reviewed HTTPS issuer string |
| `entitlementAudience` | `com.tachouweng.ytdownloaderpro2` |
| `publicKeys` | Map of reviewed key IDs to uncompressed P-256 public keys encoded as base64url |

The file must be a regular, non-symlink file, no larger than 128 KiB, and not
group- or world-writable. It must never contain a service-role key, JWT secret,
Google client secret, entitlement private key, ECPay HashKey/HashIV, or any
other private credential.

Validate a candidate before packaging:

```bash
python3 scripts/check_supabase_configuration.py /absolute/path/SupabaseConfiguration.json
```

## Owner-Controlled Setup Checklist

The owner approved and completed the staging project and Google provider setup
for the smoke test. Recheck the remaining access, branding, and entitlement-key
items before a wider test; this checklist grants no production authorization:

1. Create a disposable Supabase staging project in a reviewed region.
2. Enable Google as an identity provider in Supabase.
3. Create a Google OAuth client under the owner's organization/account.
4. Register Supabase's provider callback shown by the dashboard, normally
   `https://<project-ref>.supabase.co/auth/v1/callback`, with Google.
5. Add the app deep link
   `com.tachouweng.ytdownloaderpro2://auth/callback` to the Supabase redirect
   allowlist. This is different from Google's Supabase callback.
6. Request only `openid email profile`; do not request YouTube, Drive, contacts,
   or other Google scopes.
7. Restrict test access to named staging accounts and review OAuth branding.
8. Generate the entitlement P-256 signing key offline and follow
   `ENTITLEMENT_KEY_ROTATION.md`.

Supabase injects these reserved runtime values automatically. Confirm they are
present, but do not attempt to create or replace them with `supabase secrets
set`:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

The owner-managed Edge Function secret names are:

- `ENTITLEMENT_ISSUER`
- `ENTITLEMENT_AUDIENCE`
- `ENTITLEMENT_ES256_KID`
- `ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8`

Values belong only in Supabase staging secret storage. Do not put values in
Git, app resources, build logs, screenshots, support reports, or this document.
Google provider credentials are configured through Supabase's protected
provider settings and must not be bundled with the app.

## Future Manual Migration And Deployment

Do not run these commands until the owner approves the exact staging project,
region, configuration, and secret handling. They are a handoff, not an
authorization:

```bash
supabase login
supabase link --project-ref '<staging-project-ref>'
supabase db push --linked
supabase functions deploy entitlement --project-ref '<staging-project-ref>'
supabase secrets set \
  ENTITLEMENT_ISSUER='<reviewed-staging-issuer>' \
  ENTITLEMENT_AUDIENCE='com.tachouweng.ytdownloaderpro2' \
  ENTITLEMENT_ES256_KID='<reviewed-kid>' \
  ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8='<base64-pkcs8-private-key-value>'
```

After provisioning, create the public-material JSON outside Git and package it
only into an internal test app:

```bash
./scripts/build_swift_2.sh \
  --app-channel internal-test \
  --version 2.0.1 \
  --architectures arm64 \
  --unsigned-test \
  --auth-config /absolute/path/SupabaseConfiguration.json \
  --sbom-created '<UTC-RFC3339-candidate-timestamp>'
```

## Staging Test Procedure

1. Use a dedicated test Google account with no production data.
2. Confirm the public app has no configuration and displays no account UI.
3. Launch the configured internal app with exact `YTDP_AUTH_MODE=staging`.
   An ad-hoc app cannot access the data-protection Keychain. For an OAuth UI
   smoke test only, also set `YTDP_STAGING_EPHEMERAL_SESSION=1`; the session
   then exists in process memory and disappears when the app closes.
4. Confirm the system-browser consent page requests only the three approved
   scopes and returns through the exact app deep link.
5. Confirm the app shows only display name and optional masked email.
6. Confirm signed-out Free works without an account.
7. Confirm a verified entitlement alone changes the effective plan and that
   account identity alone never grants Pro.
8. Exercise refresh, expiry, 72-hour offline grace, account replacement,
   logout, app relaunch, and stale-response rejection.
9. Inspect Keychain and local files: refresh credential and signed entitlement
   are device-only Keychain records; access tokens remain memory-only.
10. Verify no media URL, title, path, cookie, thumbnail, job, history, or helper
    output reaches Supabase or Google.

An ad-hoc build does not prove the production data-protection Keychain contract.
Repeat persistence tests in a correctly provisioned Developer ID test host.

## Cleanup And Pause

At the end of a staging session, sign out, delete disposable test users and
their entitlement rows, revoke test sessions, rotate any exposed staging
credential, and record what was removed. Pause the Supabase project when it is
not being tested if the provider supports that state. Before resuming, verify
region, redirect allowlists, RLS policies, secrets, key IDs, test-user access,
logs, retention, and spending limits again.

Deleting an app-local session does not prove server-side account deletion.
Server deletion, backup expiry, audit retention, and vendor deletion behavior
must be verified separately before production use.
