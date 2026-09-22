# Swift Free And Test Pro Product Experience Design

## Document Control

| Field | Value |
| --- | --- |
| Status | Approved in-chat design; awaiting written-spec review |
| Product | YT Downloader Pro macOS Swift 2.x |
| Phase | Local Free and internal Test Pro product experience after Feature Policy F1 |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-22 |
| Public launch default | Free, with video capped at 720p |
| Real login, billing, and paid entitlement | Explicitly out of scope |

## 1. Decision Summary

YT Downloader Pro will turn the existing local Feature Policy F1 decisions into
one coherent product experience. A normal public build starts as Free, displays
the current plan, allows supported video formats up to and including 720p, and
shows higher supported formats as locked Pro choices. An internal-test build
starts as Free but exposes a clearly labeled, local-only Free/Test Pro switch so
engineers can exercise both product states without an account, payment, backend,
or production entitlement.

The build channel and current plan are separate concepts. The build channel
controls whether internal controls are compiled into the application. The plan
controller supplies the current capability policy to every consumer. Public
builds do not compile the internal plan-switching UI and ignore any stale local
test-plan preference. Internal builds may persist only the selected synthetic
test plan.

This phase supersedes the transitional public-compatibility launch behavior in
[`2026-09-22-swift-feature-policy-f1-design.md`](2026-09-22-swift-feature-policy-f1-design.md)
for the new product-experience candidate. It does not retroactively change the
already built 2.0.1 candidate and does not authorize publication. The exact
candidate still requires its normal release, legal, licensing, privacy, Apple,
and owner approval gates.

## 2. Approved Product Behavior

The implemented experience must satisfy all six owner-approved requirements:

1. A normal public launch displays Free as the current plan.
2. Free video download is capped at 720p in presentation, Store admission, and
   immediately before helper execution.
3. Supported 1080p, 1440p, 2160p/4K, and source-quality choices remain visible
   with a Pro lock instead of disappearing.
4. Settings always displays the current plan and a local plan explanation.
5. Only an internal-test build displays a persistent Free/Test Pro switch.
6. Upgrade entry points open one local plan-comparison view and perform no
   login, checkout, payment, external navigation, or submission.

The previously approved F1 capability matrix remains binding. Free supports one
URL, supported MP4 video through 720p, MP3 audio, basic subtitles, manual retry,
local history, and standard support. Pro additionally permits higher/source
quality, batch URLs, playlist expansion, advanced subtitle capabilities,
format presets, full recovery policy, optional future history sync, and
priority support. Features that do not yet exist remain descriptions of the
future matrix, not newly implemented workflows.

## 3. Goals

- Give the public candidate an honest, visible Free identity without requiring
  an account.
- Make the 720p rule impossible to bypass through a hidden control, keyboard
  command, restored job, direct Store call, retry, or direct Runner call.
- Keep higher qualities discoverable and explain why they are locked.
- Let engineers test both product states in one internal application while
  making that switch unavailable in a public binary.
- Preserve one authoritative plan-to-policy data flow across settings, media
  options, cards, scheduling, persistence recovery, and helper execution.
- Keep this phase local, deterministic, private, and testable without network
  services or external accounts.
- Leave a narrow replacement point for a future verified entitlement provider.

## 4. Non-Goals And Hard Boundaries

This phase must not:

- implement real Google or Apple login;
- contact ECPay, create an order, collect payment, restore a purchase, cancel a
  subscription, or display an actionable checkout control;
- call a YT Downloader Pro account or entitlement backend;
- parse, verify, refresh, or persist a production entitlement token;
- claim that Test Pro is a purchase, subscription, or valid paid entitlement;
- show an unapproved price, recurring term, refund claim, availability date, or
  external upgrade URL;
- add analytics, telemetry, email, support submission, or cloud sync;
- associate plan state with media URLs, titles, cookies, paths, thumbnails,
  diagnostics, or downloaded files;
- change the Windows Python product line;
- publish, tag, release, notarize, or alter repository visibility;
- weaken safety, privacy, local export, local deletion, or ordinary Free
  recovery behavior.

Client-side enforcement can be patched by a determined user. This phase builds
correct product behavior and defense in depth, not an assertion of unbreakable
DRM. A later paid launch still requires verified signed entitlement material
and all external approval gates.

## 5. Selected Architecture

### 5.1 Build Channel

Add an immutable `AppBuildChannel` with exactly two values:

- `publicRelease`
- `internalTest`

`scripts/build_swift_2.sh` must require an explicit `--app-channel public` or
`--app-channel internal-test`. Omission or an unknown value fails before tests,
compilation, bundle replacement, or signing. Signing mode and application
channel are independent: an unsigned/ad-hoc candidate may exercise public
behavior, and a signed build is not automatically public.

An internal build compiles with `YTDP_INTERNAL_TEST`. Internal settings and
mutation APIs that are presentation-only are guarded by this flag. A public
binary does not compile the test switching section. `Info.plist` also records a
non-secret `YTDPBuildChannel` string for diagnostics and bundle verification,
but runtime metadata alone is not the UI security boundary.

Public and internal artifacts use separate output directories and reports so
one cannot silently overwrite the other. Artifact names include the channel.

### 5.2 Plan Controller And Providers

Add one main-actor `PlanController` and inject it at the application root. It is
the sole mutable source of the current plan. Its public interface exposes the
current `AppPlan`, immutable build channel, derived `FeaturePolicyContext`, and
whether internal switching is available.

The approved local states are:

- `free`
- `testPro`, available only to an internal-test build

Future verified Free or Pro state will come from a different provider; it does
not belong in this phase. Plan sources conform to a narrow `PlanProviding`
boundary:

- `PublicFreePlanProvider` always supplies Free;
- `InternalTestPlanProvider` supplies Free or Test Pro from the local internal
  preference;
- a future `VerifiedEntitlementPlanProvider` may supply a validated production
  snapshot without changing feature consumers.

Authentication and plan state remain independent. The existing authentication
mock never grants Test Pro, and a Test Pro selection never manufactures an
account session.

### 5.3 Internal Preference

`InternalTestPlanStore` uses a dedicated key such as
`internal-test-selected-plan`. It accepts only `free` and `test-pro`. Missing,
corrupt, padded, differently cased, or unknown values fail closed to Free.

The key is not part of `AppSettings`, `downloads.json`, local support reports,
or local data exports. Public builds do not read it. Resetting ordinary user
settings does not manufacture Test Pro; the internal settings section owns an
explicit `Reset to Free` action.

## 6. Authoritative Data Flow

The application uses one direction of data flow:

```text
AppBuildChannel
    -> PlanProviding
    -> PlanController
    -> FeaturePolicyContext
    -> Settings / media options / cards / DownloadStore
    -> immutable execution-time policy snapshot
    -> DownloadRunner
```

Views never infer a plan from button visibility or account labels. Store and
Runner code never infer a plan from user-facing text. The policy remains a pure,
Sendable value after derivation.

`AppLifecycle` constructs the channel, provider, plan controller, account
session store, and download store. SwiftUI receives `PlanController` as an
environment object. `DownloadStore` reads the controller at every commercial
command boundary instead of caching an independent plan.

Immediately before a job starts, the Store passes an immutable policy snapshot
to `DownloadRunner`. The Runner validates before output security-scope access,
name reservation, partial-file creation, or helper launch. Once a helper has
started under an allowed snapshot, a later downgrade does not terminate that
active process.

## 7. Free Quality Semantics

Metadata analysis may discover all supported formats. Free presentation keeps
higher choices visible but selects only an eligible default.

- A known video height from 1 through 720 inclusive is Free-safe.
- A height above 720 requires Pro.
- A format explicitly described as 2160p, 4K, UHD, or source quality requires
  Pro.
- An unknown video height is not Free-safe.
- Audio-only MP3 is not subject to the video-height cap.
- Existing QuickTime-compatible MP4 rules remain mandatory. A locked format is
  not displayed merely because yt-dlp reported it if the application cannot
  produce the currently supported QuickTime-compatible output.

In Free, the highest-quality label means `Highest available up to 720p`. The
presentation resolves that choice to a concrete eligible format so helper
arguments cannot interpret an unbounded `best` request. It prefers the
highest supported QuickTime-compatible format at or below 720p and falls back
through lower known heights. If no eligible format exists, it returns a clear
localized denial instead of selecting an unknown or higher format.

Restored defaults or jobs that request a Pro format do not receive grandfathered
access. Defaults normalize to the highest eligible Free choice. Jobs remain
intact but cannot start or retry until the user edits them to a Free choice or
the current policy permits Pro.

## 8. Three Enforcement Boundaries

### 8.1 Presentation

The media options presentation classifies each supported video choice as
allowed or locked. It chooses an eligible default and refuses to mutate the
selection when a locked row is activated.

### 8.2 Store Admission And Recovery

`DownloadStore` checks policy when it accepts URLs, expands a playlist, creates
a job, applies queued or failed-job edits, restores persisted jobs, resumes a
paused job, or retries a failed job. A direct Store caller cannot bypass the
view.

### 8.3 Runner Boundary

`DownloadRunner` checks the current immutable snapshot before any download side
effect. A denial returns a typed policy result. It launches no helper and owns
no new output, reservation, partial, or temporary artifact.

Policy denial is not classified as a network, YouTube, FFmpeg, or filesystem
failure. Raw helper output is not involved.

## 9. Restricted Job State And Plan Transitions

Add a sanitized `DownloadAccessRequirement` to distinguish a policy-blocked
job from an ordinary user pause or operational failure. It contains only a
stable required feature and denial reason. Backward-compatible decoding treats
its absence as no cached requirement, then recomputes against the current
policy. A stored requirement never grants access and is always revalidated.

A restricted waiting or paused job remains in the paused navigation category
and displays `Requires Pro` on its card. The media URL, title, and output path
are not copied into the access requirement.

When an internal tester changes Test Pro to Free:

- downloading and merging jobs continue to their terminal result;
- analysis may finish, but any resulting options use the latest Free policy;
- queued Pro-only jobs are removed from runnable scheduling and become
  policy-blocked;
- paused jobs keep partial files but cannot resume when Pro is required;
- failed jobs revalidate before retry;
- completed media and history remain untouched;
- an open media options view normalizes a now-illegal selection to the highest
  eligible Free choice and shows one local notice.

When the tester changes Free to Test Pro, eligible blocked jobs become manually
resumable. They do not auto-start. This prevents a plan switch from launching a
large restored queue without a fresh user command.

Store reconciliation and Runner validation close the scheduling race. If a job
passes scheduler selection while a downgrade occurs, the Runner's latest
pre-side-effect check is authoritative.

## 10. Locked Format Interaction

Replace the video-format `Picker` with a focused native `VideoFormatMenu`. The
current selection appears as the menu label. Rows use stable dimensions so a
checkmark, format label, lock icon, and Pro indicator do not shift the sheet.

In Free:

- eligible rows are ordinary selectable actions;
- supported 1080p, 1440p, 2160p/4K, source-quality, and unknown-height rows show
  `lock.fill` plus a localized `Pro` label;
- activating a locked row preserves the current selection, creates an upgrade
  route, and opens the local comparison view;
- VoiceOver reads the quality and `Requires Pro` state;
- keyboard navigation can reach and activate the explanatory locked row.

In Test Pro, the same rows are unlocked and selectable. Audio choices keep the
existing native control because MP3 remains Free and this phase introduces no
audio-tier split.

If a source has no higher supported format, no artificial locked row is added.
The menu represents actual analyzed choices only.

## 11. Upgrade Routing And Local Plan Comparison

Every local upgrade entry uses one non-sensitive `UpgradePresentationRoute`.
Its entry-point cases cover locked quality, batch input, playlist expansion,
advanced subtitles, a restricted job, and Settings. It may retain a generic
capability reason but never a media URL, title, path, cookie mode, format ID,
thumbnail, diagnostic excerpt, or account identifier.

The route presents `PlanComparisonView`. It shows the current plan, the reason
for presentation, and a concise comparison of the approved capability matrix:
Free through 720p and Pro with all supported qualities, plus the approved
single/batch, playlist, subtitle, history, and support distinctions.

The view is an operational settings sheet, not a marketing landing page. It
uses a full-width comparison layout with no nested cards. Its only actionable
command is Close. It states that upgrading is not yet available. It does not
show a price, open a browser, start login, simulate purchase, change the test
plan, submit data, or contact a service.

Entry points include locked format activation, Settings `View Pro features`,
policy denial actions, and restricted job actions. Closing the view restores
the prior media-options context without changing selections.

## 12. Settings Experience

Settings always begins with a Plan section independent of authentication:

- current plan: Free or, in an internal build, Test Pro;
- current quality access: `Up to 720p` or `All supported qualities`;
- `View Pro features`, which opens the local comparison view.

Only an internal-test build compiles a separate Development Testing section.
It includes a segmented Free/Test Pro picker, an `Internal test mode` label, a
clear statement that the state is not a login, purchase, or subscription, and a
`Reset to Free` command. Test Pro is never labeled simply as a verified Pro
subscription.

Plan changes publish immediately. Settings, an open comparison view, media
format menus, card actions, scheduler admission, and retry/resume decisions
observe the same controller. Plan changes do not close sheets or reset output
folder, subtitle, MP3, thumbnail, metadata, or cookie choices.

## 13. Localization And Accessibility

All new visible text belongs in `Localizable.xcstrings` with English, Japanese,
and Traditional Chinese values. No policy enum or raw fallback text reaches a
user.

Required accessibility coverage includes:

- current plan and quality limit;
- internal-test disclaimer;
- each locked quality and its Pro requirement;
- `View Pro features` and Close actions;
- restricted card status;
- the plan comparison rows and current-plan state.

The design preserves the current light, near-white operational interface,
compact typography, native symbols, keyboard default/cancel behavior, stable
control sizes, and usable sheets at the existing minimum window dimensions.

## 14. Privacy, Diagnostics, And Export

Plan decisions consume only capability identifiers and format properties needed
for the decision. No media activity is sent to any entitlement component.

Diagnostics may record build channel, local plan provenance, stable feature ID,
and denial reason. They must not record raw test preference values, URL, title,
path, selected format ID, cookie information, account identity, or helper
stderr as part of a plan event.

Local export and support-report previews do not include the internal plan
preference. Existing history cleanup and data-management behavior remains
unchanged. Switching plans never deletes downloads, history, thumbnails,
partials, settings, or diagnostics.

## 15. Packaging And Verification Contract

The build script adds channel selection without conflating it with signing:

```text
--app-channel public
--app-channel internal-test
```

It passes `YTDP_INTERNAL_TEST` only for the internal compilation and writes the
matching `YTDPBuildChannel` metadata. The bundle verifier rejects a missing,
unknown, or unexpected channel and checks that the archive/report identifies
the same channel.

Public and internal outputs use separate directories, ZIP names, and reports.
The existing version, architecture, helper execution, SBOM, license, signing,
symlink/inode, writable-state, resource, and archive checks remain mandatory.
Neither channel is public-release evidence by itself.

## 16. TDD Implementation Slices

Implementation proceeds in six independently reviewable commits:

1. Add the build-gated plan controller, providers, fail-closed internal store,
   dependency injection, and focused controller tests.
2. Enforce Free policy through Store recovery/admission and the Runner's
   pre-side-effect boundary, including restricted job state and tests.
3. Add pure video-format access presentation plus the native locked format
   menu and interaction/accessibility tests.
4. Add plan presentation, local comparison view, shared upgrade route,
   Settings section, localization, and side-effect-free routing tests.
5. Add internal switching, persistence, immediate view updates, queue
   reconciliation, downgrade/upgrade races, and restart tests.
6. Add explicit packaging channels, bundle-verifier coverage, documentation,
   full strict verification, and separate public/internal test artifacts.

Every slice follows red, green, refactor. Each commit contains its production
code, tests, and directly affected maintenance text. A slice does not proceed
while its focused tests or the complete strict Swift suite fails.

## 17. Automated Test Requirements

Tests must prove at minimum:

- public starts Free and has no plan mutation control;
- internal starts Free, can select Test Pro, persists it, and resets safely;
- public ignores a pre-existing internal Test Pro preference;
- invalid plan data fails to Free;
- Free allows 720p and denies 721p, 1080p, 1440p, 2160p, source, and unknown
  video height;
- Test Pro allows all currently supported quality choices;
- Free highest-quality selection resolves to a concrete supported format no
  higher than 720p;
- no eligible Free format produces a localized, typed denial;
- locked activation preserves selection and creates only a sanitized route;
- the comparison view performs no network or external action;
- direct Store and Runner calls cannot bypass policy;
- Runner denial precedes helper launch, scope access, reservation, partial, and
  temporary-file creation;
- downgrading does not stop an active process but blocks queued, paused, and
  retried Pro-only work;
- upgrading does not auto-start blocked work;
- scheduling races fail closed before side effects;
- internal plan state is absent from local export and support drafts;
- all new copy resolves in all three locales;
- the public and internal packaging contracts fail closed when misconfigured.

Focused tests are followed by the complete strict-concurrency and
warnings-as-errors Swift suite, SBOM and bundle unit tests, release compilation,
bundle verification, helper execution, strict codesign validation, ZIP testing,
and Git diff/status checks.

## 18. Manual Acceptance

The owner tests separate freshly assembled public and internal candidates:

1. Public first launch shows Free and no development switch.
2. Settings shows Free, the 720p limit, and a local Pro comparison entry.
3. A video with multiple supported qualities shows 720p as selectable and
   higher/source qualities as locked.
4. Activating a lock opens the local comparison view and preserves selection.
5. Free highest-quality output is at most 720p and plays in QuickTime.
6. MP3 remains downloadable in Free.
7. Free batch, playlist, and other implemented F1-restricted entry points show
   the same comparison flow without creating partial work.
8. Internal first launch shows Free and the clearly labeled test section.
9. Switching to Test Pro immediately unlocks formats and survives restart.
10. Switching to Free during an active Pro download lets that process finish,
    blocks queued Pro-only jobs, preserves partials, and does not delete media.
11. Switching back to Test Pro makes blocked jobs manually resumable without
    auto-starting them.
12. English, Japanese, Traditional Chinese, keyboard navigation, VoiceOver,
    and minimum window/sheet sizes remain coherent.
13. Existing single download, MP3, duplicate naming, pause/resume, retry,
    output-folder persistence, local support/export/deletion, and QuickTime
    compatibility regressions remain healthy.

## 19. Definition Of Done

This phase is complete only when:

- public behavior is visibly Free and cannot expose internal switching;
- no public Free path can start a helper for a video request above 720p or with
  an unknown/source-class height;
- internal Free and Test Pro behavior updates immediately and predictably;
- all upgrade presentation remains local and side-effect-free;
- existing privacy, safety, persistence, and media compatibility contracts
  remain intact;
- all focused, strict, bundle, SBOM, signing, archive, and manual acceptance
  evidence is recorded for both test channels;
- Git contains no unintended source, bundle, credential, media, or diagnostic
  changes.

Completion authorizes only review of the local product-experience candidates.
It does not authorize public release, paid claims, login activation, backend
deployment, ECPay configuration, billing, email, repository visibility changes,
or any other external-account action.

## 20. Future Migration To Verified Pro

A separately approved production-entitlement phase may replace
`PublicFreePlanProvider` with a provider that accepts only a cryptographically
verified snapshot and falls back to Free on missing, expired, malformed, or
untrusted data. The plan controller, capability policy, locked-format
presentation, Store checks, Runner boundary, and comparison routing remain the
consumers.

That later phase must specify issuer/audience/key validation, replay handling,
offline grace, account binding, refresh, logout, cancellation, refund/dispute,
clock behavior, key rotation, backend privacy, and incident recovery. None of
those concerns are simulated or implied by this local design.
