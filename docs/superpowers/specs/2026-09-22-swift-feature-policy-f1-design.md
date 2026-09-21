# Swift Feature Policy F1 Design

## Document Control

| Field | Value |
| --- | --- |
| Status | Approved in-chat design; awaiting written-spec review |
| Product | YT Downloader Pro macOS Swift 2.x |
| Phase | F1 local feature policy and synthetic entitlement fixtures |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-22 |
| Production enforcement | Explicitly out of scope |

## 1. Decision Summary

YT Downloader Pro will add a pure Swift `FeaturePolicy` subsystem that turns a
trusted local entitlement value into deterministic feature decisions. F1 is a
local preparation phase: it defines the Free and Pro product rules, synthetic
entitlement fixtures, development-only policy modes, entry-point checks, tests,
and maintenance documentation without contacting an account, entitlement, or
payment service.

The normal public 2.0.1 build remains behavior-compatible with the current app.
It does not suddenly restrict existing users, show upgrade prompts, or require
an account. Free and Pro enforcement is available only through an explicit
development gate until real authentication, entitlement verification, payment,
consumer disclosures, and launch approvals are complete.

This design implements the approved product split:

- Free: one URL at a time, MP4 video up to and including 720p, MP3 audio, one
  basic subtitle language, local history, manual retry, and the existing local
  output controls.
- Pro: 1080p and 4K/source quality, multiple URLs, playlist expansion, advanced
  subtitles, reusable format presets, automatic retry, history synchronization,
  and priority support.

## 2. Goals

- Give every commercial capability one stable identifier and one central rule.
- Represent Free and Pro access with immutable, testable Swift values.
- Keep the normal public build accountless and behavior-compatible.
- Let engineers locally exercise Free and Pro decisions without real people,
  accounts, secrets, tokens, network calls, or payments.
- Check quality, multi-URL input, and playlist expansion at their Store command
  boundaries during development-mode testing.
- Return structured denial reasons suitable for English, Japanese, and
  Traditional Chinese presentation.
- Preserve a clean path to a future cryptographically verified entitlement
  without making F1 pretend that local fixtures are secure.

## 3. Non-Goals And Hard Boundaries

F1 must not:

- Contact Google, Apple, ECPay, a YT Downloader Pro backend, analytics, email,
  support, or any other external service.
- Parse, verify, refresh, or persist a production entitlement token.
- Include signing keys, OAuth identifiers, ECPay secrets, production endpoints,
  real account fixtures, or personally identifying data.
- Activate Free limits in a normal public launch of 2.0.1.
- Show pricing, checkout, subscription, cancellation, or purchase restoration UI.
- Associate entitlement state with media URLs, titles, cookies, output paths,
  thumbnails, diagnostics, or local history.
- Change the Windows Python product line.
- Claim that UI or Store checks alone are sufficient production enforcement.

Real token verification, offline grace, command/helper-boundary enforcement,
account binding, and production activation each require a separate reviewed
specification and implementation plan. Real provider or payment work remains
blocked by `COMMERCIAL_FEASIBILITY.md` and the gates in
`ENTITLEMENT_ARCHITECTURE.md`.

## 4. Selected Approach

Use a pure value-based policy rather than hiding SwiftUI controls or introducing
a networked policy service.

- A pure policy is deterministic, Sendable, easy to test, and independent of
  SwiftUI, downloads, and provider SDKs.
- Views may use policy decisions for presentation, but the Store owns command
  admission in F1.
- A future verified-entitlement adapter can construct the same policy value
  without changing feature consumers.
- An actor or network service is unnecessary because F1 has no mutable remote
  state and no I/O.

Rejected alternatives:

- UI-only gating is insufficient because keyboard commands, restored jobs, and
  programmatic Store calls could bypass hidden controls.
- Immediate backend enforcement violates the current external-approval boundary
  and would couple product rules to unfinished provider infrastructure.

## 5. Product Capability Matrix

| Capability | Free | Pro | Stable feature identifier |
| --- | --- | --- | --- |
| Single URL download | Allowed | Allowed | `download.single` |
| MP4 video up to 720p | Allowed | Allowed | `video.standard` |
| Video above 720p | Denied | Allowed | `video.hd` |
| 2160p/source-class video | Denied | Allowed | `video.uhd` |
| MP3 audio | Allowed | Allowed | `audio.mp3` |
| One explicitly selected subtitle language | Allowed | Allowed | `subtitle.basic` |
| Multiple/all-language or future advanced subtitle workflow | Denied | Allowed | `subtitle.advanced` |
| More than one submitted URL | Denied | Allowed | `queue.batch` |
| Playlist expansion | Denied | Allowed | `playlist.expand` |
| Save or apply reusable format presets | Denied | Allowed | `format.presets` |
| Manual retry initiated by the user | Allowed | Allowed | `recovery.manual` |
| Automatic retry/recovery policy | Denied | Allowed | `recovery.full` |
| Local on-device history | Allowed | Allowed | `history.local` |
| Cross-device or server history synchronization | Denied | Allowed | `history.sync` |
| Standard self-service support | Allowed | Allowed | `support.standard` |
| Priority support routing | Denied | Allowed | `support.priority` |

Feature identifiers are additive and stable. Unknown identifiers are ignored
when constructing a policy; they never grant access. Removing or changing the
meaning of an identifier requires a schema migration rather than silently
reusing its string.

### 5.1 Quality Rules

- Audio-only MP3 is not subject to a video-height limit.
- Free video selection accepts a known height from 1 through 720 inclusive.
- A video format above 720p requires `video.hd`; 2160p or a format explicitly
  described as source/4K also requires `video.uhd`.
- A video format whose height cannot be established is not considered Free-safe.
  Development enforcement returns a structured denial instead of guessing.
- Analysis may continue to display every source format. In an enforced Free
  session, the default selection is the best eligible format at or below 720p.
- Existing explicit Pro selections are not silently rewritten. They receive a
  denial that lets the caller ask the user to choose a Free format.

### 5.2 URL And Playlist Rules

- A submission containing exactly one non-playlist URL needs only
  `download.single`.
- A submission containing two or more accepted URLs requires `queue.batch`
  before analyzing placeholder cards are created.
- A URL discovered to be a playlist requires `playlist.expand` before playlist
  entries become jobs, even when it was the only submitted URL.
- Denial never partially accepts the first item from a batch. The command is
  rejected as one user action so the result is predictable.

### 5.3 Subtitle, Retry, And History Rules

- Free may select no subtitles or one language through the existing basic
  subtitle workflow.
- Multiple languages, all-language selection, or future subtitle automation is
  Pro. F1 does not add those workflows; it only reserves the capability.
- Free users keep manual retry and the minimum reliability fixes required for
  ordinary downloads.
- Only automatic retry orchestration beyond the ordinary one-shot command is
  Pro. Safety recovery needed to avoid corrupting or deleting files is never a
  paid feature.
- Local history and local data export remain Free. `history.sync` refers only to
  a future opt-in server synchronization feature.

## 6. Domain Model

Create the subsystem under `Sources/YTDownloaderPro2/Entitlements/`.

### 6.1 `FeatureID`

`FeatureID` is a String-backed, Codable, Hashable, Sendable value containing the
identifiers from the capability matrix. Its serialized strings match the future
entitlement contract. Unknown strings can be preserved by entitlement decoding
but do not become known granted features.

### 6.2 `EntitlementSnapshot`

`EntitlementSnapshot` is an already-trusted input to policy derivation. It
contains:

- schema version;
- plan (`free` or `pro`);
- a set of recognized granted features;
- a video-height policy (`limited(720)` or `unlimited`);
- a sanitized subscription presentation state;
- optional validity dates for future adapters.

F1 snapshots are synthetic values built in memory. Calling the type a snapshot,
not a token, makes clear that F1 performs no signature or issuer verification.
Future token verification must produce a validated snapshot before policy code
can consume it.

### 6.3 `FeaturePolicy`

`FeaturePolicy` is an immutable Sendable value derived from one snapshot. It
provides narrowly typed queries rather than exposing ad hoc set checks:

- `decision(for feature: FeatureID) -> FeatureDecision`
- `videoDecision(height: Int?, isAudioOnly: Bool, isSourceQuality: Bool) -> FeatureDecision`
- `urlSubmissionDecision(count: Int) -> FeatureDecision`
- `playlistExpansionDecision() -> FeatureDecision`
- `subtitleDecision(languageCount: Int, usesAdvancedMode: Bool) -> FeatureDecision`

Invalid request values such as a zero URL count or negative height return a
programming-error denial and never grant a commercial capability.

### 6.4 `FeatureDecision`

`FeatureDecision` is either allowed or denied. A denial contains:

- the required feature identifier when one applies;
- a stable reason code;
- a localization key and non-sensitive formatting arguments;
- whether choosing a Free-compatible option can resolve the denial.

It contains no price, checkout URL, provider name, raw token content, media URL,
or account identity. UI presentation maps the reason to localized copy.

## 7. Runtime Modes And Public Compatibility

`FeaturePolicyEnvironment` resolves once at process launch.

| Environment | Behavior |
| --- | --- |
| No `YTDP_FEATURE_POLICY_MODE` | Public compatibility; current 2.0.1 behavior remains available |
| `YTDP_FEATURE_POLICY_MODE=mock-free` | Enforced synthetic Free policy for development and tests |
| `YTDP_FEATURE_POLICY_MODE=mock-pro` | Enforced synthetic Pro policy for development and tests |
| Empty or any other value | Public compatibility with a sanitized local diagnostic |

Only the exact two mock values enable commercial decision enforcement in F1.
The mode is not stored in user settings and no public UI exposes it. Mock mode
must be visibly labeled as development-only if account or policy diagnostics are
shown.

Public compatibility is an explicit transitional state, not a Free entitlement
and not evidence of payment. It preserves current behavior until a separately
approved production entitlement phase changes the launch default. Code must not
describe public compatibility users as Pro subscribers.

## 8. Data Flow And Enforcement Points

1. `AppLifecycle` resolves `FeaturePolicyEnvironment` at launch and constructs
   one immutable policy context for the Store.
2. `DownloadStore` asks the policy context before accepting multiple URLs.
3. Metadata analysis remains local and unchanged for an accepted command.
4. When analysis identifies a playlist, the Store asks before expanding it.
5. The options presentation uses the policy to select the best eligible Free
   default in `mock-free` and to explain denied quality choices.
6. Before a selected job is created, the Store checks its video, subtitle, and
   batch-related decisions again so a direct Store call cannot bypass the view.
7. Public compatibility bypasses commercial denials and produces no upgrade UI.

F1 does not yet add the second enforcement boundary inside helper-argument
construction or sensitive retry. Therefore F1 is suitable for development and
contract testing only, not paid launch. The production enforcement phase must
re-check policy after persistence restoration and immediately before command
execution without terminating a download already in progress.

No policy decision performs network or file I/O. No URL, title, path, cookie,
thumbnail, diagnostic event, or history item is passed into entitlement policy.

## 9. Presentation And Error Handling

F1 adds localized messages only for development-mode policy decisions:

- quality above the Free 720p limit;
- multiple URLs requiring Pro;
- playlist expansion requiring Pro;
- advanced subtitle capability requiring Pro;
- an unknown or invalid local policy request.

The normal public build shows none of these messages. Denials must not expose
raw enum names or English-only fallback text. Cancellation and existing download
errors remain separate from commercial denials.

If a synthetic snapshot has an unsupported schema or contradictory claims, the
fixture adapter fails closed to the defined Free policy and emits a sanitized
local diagnostic. It never upgrades to Pro and never crashes the app.

## 10. Persistence And Privacy

- F1 policy mode and synthetic snapshots are not persisted.
- No entitlement file, account identifier, installation fingerprint, or plan
  selection is added to `downloads.json` or `UserDefaults`.
- Download jobs continue to persist only the local media state already defined
  by the Swift architecture.
- Diagnostics may record only the policy mode, stable reason code, and feature
  identifier. They must not include media or account data.
- History cleanup continues to remove records only and never deletes completed
  media.

## 11. Test Strategy

### 11.1 Pure Policy Tests

- Free allows a known 720p format and denies 721p, 1080p, and 2160p.
- Pro allows 1080p, 2160p, and source quality.
- MP3 remains allowed under both plans.
- Free allows exactly one URL and rejects zero or more than one.
- Pro allows valid multi-URL counts.
- Free denies playlist expansion; Pro allows it.
- Free allows zero or one basic subtitle language and denies advanced/multiple
  language requests.
- Manual retry and local history are allowed for both plans.
- Unknown feature identifiers do not grant access.
- Invalid heights and unsupported snapshot schemas fail closed without crashing.

### 11.2 Environment Tests

- Missing mode resolves to public compatibility.
- Exact `mock-free` and `mock-pro` values resolve to their synthetic policies.
- Empty, differently cased, whitespace-padded, and unknown values do not enable
  enforcement and emit only a sanitized diagnostic.
- No fixture contains a real email address, provider subject, payment reference,
  secret, media URL, or output path.

### 11.3 Store And Presentation Regression Tests

- Public compatibility preserves existing single, batch, playlist, and format
  behavior.
- `mock-free` rejects a batch before placeholder jobs or analysis processes are
  created.
- `mock-free` rejects playlist expansion before child jobs are created.
- `mock-free` chooses the best known format at or below 720p and rejects a direct
  attempt to create a higher-quality job.
- `mock-pro` preserves all currently supported quality, batch, and playlist
  flows.
- Denial presentation resolves in English, Japanese, and Traditional Chinese.
- Existing authentication mock mode does not implicitly grant Pro; authentication
  and entitlement test modes remain independent.

The focused entitlement tests and the complete strict Swift suite must pass.
No test may require a network connection, provider account, Keychain credential,
or bundled production helper.

## 12. Documentation And Maintenance

- Add the entitlement subsystem and transitional compatibility mode to
  `docs/swift-2.0/ARCHITECTURE.md`.
- Cross-link this design from `ENTITLEMENT_ARCHITECTURE.md` without changing its
  external approval gates.
- Document exact mock launch values for engineers and state that they are not a
  purchase simulator or production entitlement.
- Keep feature strings centralized; views and Store code must not duplicate
  string literals.
- Any future feature added to Free or Pro requires a capability-matrix update,
  policy test, localized denial decision where applicable, and review of both
  command admission and helper execution boundaries.

## 13. Acceptance Criteria

F1 is complete only when:

- The pure policy models and synthetic fixtures are implemented without external
  dependencies or I/O.
- The approved Free and Pro matrix is covered by focused tests.
- Public compatibility remains the default and all existing strict Swift tests
  pass.
- Development-only Free mode blocks quality above 720p, multi-URL submission,
  and playlist expansion at Store boundaries without creating partial jobs.
- Development-only Pro mode preserves the corresponding existing flows.
- Localized denial presentation is complete for all three supported languages.
- Authentication mock state cannot accidentally grant Pro.
- Architecture documentation clearly states that F1 is not production paid
  enforcement and does not authorize provider or payment work.

## 14. Future Approval Gates

After F1, the next technical phases may design and test a signed-entitlement
verifier, expiry/offline-grace state, and execution-boundary enforcement using
local fixtures. Real Google, Apple, backend, ECPay, billing, email, deployment,
or public paid-feature activation still requires fresh owner approval and every
applicable legal, accounting, provider, privacy, security, and release gate.
