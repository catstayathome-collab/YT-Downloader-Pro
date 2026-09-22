# Swift 2.0 Plan And Entitlement Architecture

## Current Boundary

The current product has two local plans: `Free` and `Test Pro`. `Test Pro`
exists only to exercise planned Pro behavior in an internal build. It is not a
paid entitlement and cannot be produced by login, payment, a token, or a
server. Production Google and Apple authentication, account APIs, ECPay,
subscriptions, cancellation, and verified Pro delivery are not implemented.

## Build Channels

| App channel | Compile flag | Startup plan | Plan switch |
| --- | --- | --- | --- |
| `public` | none | Free | not compiled |
| `internal-test` | `YTDP_INTERNAL_TEST` | Free, or a valid saved internal choice | Settings-only Free/Test Pro control |

`AppBuildChannel.current` is compile-time derived. `PlanController.live()` uses
`PublicFreePlanProvider` in public compilation and `InternalTestPlanProvider`
only in internal compilation. Public startup ignores any stale internal
preference. Missing, malformed, or unknown internal values resolve to Free.

The bundle repeats the channel as `YTDPBuildChannel` in `Info.plist`. This is
verification metadata, not the runtime source of authority. The executable's
compile flag and the verifier's expected channel must agree with it.

## Policy Flow

`PlanController.currentPlan` produces one enforced `FeaturePolicyContext`.
Views, `DownloadStore`, and `DownloadRunner` consume that same context:

1. Views present selectable Free formats and locked Pro formats.
2. Store command boundaries reject batch, playlist, advanced subtitle, or
   selected-quality work not allowed by the current plan.
3. Persisted and queued work is reconciled when the internal plan changes.
4. Runner checks again before helper launch or filesystem side effects.

Free allows MP3 and supported video formats no higher than 720p. Unknown,
source, or higher video quality fails closed. Test Pro enables the currently
implemented synthetic Pro matrix. A downgrade lets active work finish but
restricts non-active Pro-only jobs. An upgrade clears the restriction without
automatically starting those jobs.

## Internal Preference

The internal choice uses `UserDefaults` key `internal-test-selected-plan` and
accepts only exact `free` or `test-pro` values. It must never appear in local
support reports, exported app data, analytics, or public UI. Reset to Free is
always available in the internal Settings section.

## Packaging Contract

`scripts/build_swift_2.sh` requires `--app-channel public` or
`--app-channel internal-test`. It passes `-DYTDP_INTERNAL_TEST` only to the
internal Swift test and release-build commands. Each channel owns a separate
`dist/swift-2.0/<channel>/` directory, app, report, and ZIP.

`scripts/check_swift_bundle.py` requires `--expected-app-channel`. It rejects:

- missing or unknown expected channels;
- missing, unknown, or mismatched `YTDPBuildChannel` metadata;
- report or archive destinations outside the expected channel directory;
- every existing signature, architecture, helper, SBOM, license, symlink,
  inode, writable-state, resource, and archive violation.

Signing and app channel are independent. `public` means the Free product
surface was compiled; it does not mean signed, notarized, approved, or released.
`internal-test` means local plan controls were compiled; it does not authorize
distribution to customers.

## Future Verified Pro

A future, separately approved phase may add a provider that converts a
cryptographically verified server entitlement into the existing policy
snapshot. That phase must define issuer, audience, signature keys, expiry,
revocation, replay handling, offline grace, account deletion, cancellation,
privacy, and failure-to-Free behavior. It must not reuse the internal
`UserDefaults` preference as production authority.

Until those requirements and the external legal, accounting, payment-provider,
licensing, privacy, and owner gates are approved, all public builds remain Free
and all Test Pro behavior remains an explicitly local engineering fixture.
