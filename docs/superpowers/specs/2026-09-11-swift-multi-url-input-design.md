# YT Downloader Pro Swift Multi-URL Input Design

## 1. Summary

YT Downloader Pro 2 currently treats the permanent URL field as one metadata
request. Pasting multiple links can therefore send one combined string to
`MetadataProbe`, while `DownloadStore.analyzeURL(_:)` intentionally allows only
the latest single analysis to publish. The app must instead recognize a batch
of URLs and analyze every valid, unique item without silently discarding later
links.

This feature preserves the existing single-video and single-playlist flows. A
single URL still opens the current options or playlist-selection sheet. Two or
more URLs use a dedicated batch path that creates one visible analyzing card
per input, analyzes inputs in first-seen order, applies the saved default
options, and automatically starts each successful result as capacity permits.

## 2. Goals

- Accept HTTP and HTTPS media URLs separated by line breaks, spaces, or tabs.
- Preserve first-seen order and discard exact normalized duplicates.
- Keep the single-URL options and playlist-selection experience unchanged.
- Represent every batch input immediately as an independent download card.
- Analyze batch inputs sequentially to reduce unnecessary upstream request
  bursts while allowing completed analyses to enter the existing download
  coordinator immediately.
- Let one failed analysis become one failed card without stopping later inputs.
- Use the saved default output, quality, audio, subtitle, metadata, cookie, and
  destination options for batch inputs.
- Allow queued batch jobs to be edited individually before they start.
- Persist batch cards and recover them safely after app termination.

## 3. Non-Goals

- Increasing the configured download concurrency beyond the existing 1 through
  10 range.
- Running multiple metadata probes concurrently.
- Adding an account, cloud queue, analytics event, or remote submission.
- Guessing URLs from prose that are not recognized as links by Foundation.
- Removing YouTube tracking query items or deduplicating different URLs that
  happen to identify the same video.
- Changing how a single playlist asks the user to select entries.
- Adding a second extraction engine or changing the controlled yt-dlp recovery
  ladder.

## 4. User Contract

### 4.1 Single URL

When the input contains exactly one supported URL, Enter and the Analyze button
retain the current behavior:

1. Validate the bundled toolchain.
2. Analyze the URL.
3. Show `MediaOptionsSheet` for a video or `PlaylistSelectionSheet` for a
   playlist.
4. Add and automatically start the user-confirmed jobs.

### 4.2 Multiple URLs

When the input contains two or more supported URLs:

1. Create an analyzing placeholder card for each URL in first-seen order.
2. Clear the input field after the cards have been accepted.
3. Analyze placeholders one at a time in FIFO order.
4. Convert a successful video placeholder into a normal job using the saved
   default options.
5. Expand a successful playlist into every available entry using the same saved
   default options, then remove its temporary playlist placeholder.
6. Send successful jobs to the existing automatic-start path immediately.
7. Convert only the affected placeholder to `failed` if its analysis fails.
8. Continue analyzing every remaining placeholder.

The batch flow does not open a stack of modal option sheets. A queued card keeps
the existing edit action so the user can change its options before it starts.

### 4.3 Invalid And Duplicate Input

- Unsupported text is ignored only when at least one valid URL is also present.
- If no supported URL is found, the existing localized invalid-URL presentation
  is shown and no card is created.
- URLs with credentials are rejected by `MediaURLValidator` and never reach a
  metadata process or persistent record.
- Duplicate detection uses a credential-free normalized URL string with a
  lowercased scheme and host and no fragment. Query items remain intact.
- The UI reports how many invalid and duplicate items were skipped without
  displaying their full contents.

## 5. Architecture

### 5.1 MediaURLInputParser

Create `Services/MediaURLInputParser.swift` as a pure parser. It uses
Foundation link detection to extract candidate links and validates every
candidate with `MediaURLValidator`.

```swift
struct MediaURLInputParseResult: Equatable, Sendable {
    var urls: [String]
    var rejectedCount: Int
    var duplicateCount: Int
}

enum MediaURLInputParser {
    static func parse(_ input: String) -> MediaURLInputParseResult
}
```

The parser has no access to the pasteboard, store, filesystem, network, or
helper processes. This makes line, whitespace, duplicate, credential, and
invalid-input behavior independently testable.

### 5.2 URL Input Presentation

`DownloadCenterView` submits the complete field value to one command instead of
calling `analyzeURL(_:)` directly:

```swift
func submitURLInput(_ input: String) async -> URLInputSubmissionResult
```

The view clears its text only when the store reports that one or more inputs
were accepted. The standard one-line appearance remains. Paste handling must
retain all clipboard text, replacing embedded line breaks with spaces for
display rather than truncating at the first line.

`URLInputSubmissionResult` contains accepted, rejected, and duplicate counts so
presentation code can provide bounded localized feedback without echoing URLs.

### 5.3 Batch Placeholder Jobs

`DownloadJob` receives an explicit marker that distinguishes a batch metadata
placeholder from an ordinary queued or recovered download:

```swift
var awaitsBatchAnalysis: Bool
```

New batch placeholders use `.analyzing`, the source URL, default options, and a
localized generic title. They do not enter `DownloadCoordinator` until metadata
analysis succeeds. The marker is encoded with a default of `false` for backward
compatibility with existing `downloads.json` snapshots.

Cards use the existing analyzing visual state and cancel action. Cancelling a
placeholder removes it from the pending analysis order and prevents a helper
process from starting for that item.

### 5.4 Batch Analysis Ownership

`DownloadStore` owns one `batchAnalysisTask`, one optional
`batchAnalysisRequestTask`, and a FIFO list of placeholder IDs. The outer task
advances the FIFO; the child task owns only the current metadata request. This
separation lets cancellation stop one active request without terminating the
remaining batch. The child calls the existing metadata analyzer and toolchain
validator, but it does not publish through the global single-analysis
`analysisState`.

For each placeholder ID, the store verifies that the job still exists, is
`.analyzing`, and has `awaitsBatchAnalysis == true` before and after suspension
points. Stale or cancelled results cannot mutate a removed or repurposed card.

The existing `analysisTask` and generation mechanism remain dedicated to the
single-URL modal flow. Starting a single analysis does not cancel a batch, and a
batch does not replace the current single-analysis result.

### 5.5 Successful Video Adoption

On video success, the store sanitizes analyzer output through the existing
credential-removal boundary, then updates the placeholder in place:

- source URL and source metadata,
- title and title source,
- duration and thumbnail,
- normalized default options,
- `awaitsBatchAnalysis = false`,
- status `.queued`.

The store flushes persistence, starts thumbnail caching, and calls the existing
automatic-start path for that job. Updating in place preserves card identity,
ordering, selection, and accessibility focus.

### 5.6 Successful Playlist Adoption

On playlist success, every available entry becomes a new queued job using the
same sanitized adoption rules and default options. The new entries occupy the
placeholder's list position in playlist order. The temporary placeholder is
removed only after replacement jobs are ready. Unavailable entries are skipped;
if no entries are available, the placeholder becomes failed.

### 5.7 Failure And Cancellation

Analysis failures use the existing typed `DownloadFailure` conversion and
sanitized diagnostic logger. The failed placeholder keeps its stable ID and
source URL, clears `awaitsBatchAnalysis`, records the failure, and appears in
the Failed sidebar section. Retry uses the existing failed-job reanalysis flow.

Cancelling the currently analyzed placeholder cancels only its metadata task.
The batch loop then advances to the next ID. Cancelling a waiting placeholder
removes it without disturbing the current request. App termination cancels and
joins both single and batch analysis tasks before persistence is finalized.

## 6. Persistence And Recovery

- Batch placeholders are persisted immediately after creation.
- On launch, persisted `.analyzing` jobs with `awaitsBatchAnalysis == true` are
  returned to the batch FIFO in their existing chronological order.
- A recovered placeholder is never sent directly to `DownloadCoordinator`.
- Credential scrubbing remains mandatory before restored URLs are published or
  passed to the analyzer.
- Existing snapshots that do not contain `awaitsBatchAnalysis` decode it as
  `false` and retain current recovery behavior.
- Successfully adopted jobs follow the existing queue and interrupted-job
  recovery rules.

## 7. Localization And Accessibility

Add English, Traditional Chinese, and Japanese strings for:

- generic batch analyzing title,
- accepted-input summary,
- skipped invalid-input count,
- skipped duplicate count,
- no-valid-URL error,
- batch playlist with no available entries.

The Analyze button keeps its current label and accessibility name. Cards expose
their normal status and actions. Feedback uses counts only and never reads a
full URL aloud unless the user is editing the URL field itself.

## 8. Testing Strategy

### 8.1 Parser Tests

- Extract two newline-separated YouTube URLs.
- Extract URLs separated by spaces and tabs.
- Preserve order across mixed separators.
- Deduplicate normalized exact matches.
- Retain distinct query strings.
- Reject non-HTTP schemes and credential-bearing URLs.
- Return no accepted URLs for prose without links.

### 8.2 Store Tests

- One URL continues to use the existing single-analysis state.
- Two URLs create two analyzing placeholders immediately.
- Batch metadata requests execute FIFO and never overlap.
- First success queues and starts while the second is still analyzing.
- First failure does not prevent the second request.
- Cancelling a waiting placeholder prevents its metadata request.
- Cancelling the active placeholder advances to the next item.
- Video success updates the existing placeholder identity.
- Playlist success replaces its placeholder with available entries in order.
- Recovered batch placeholders resume in chronological order.
- Stale results cannot mutate cancelled or replaced placeholders.
- URLs are scrubbed before persistence and runner execution.

### 8.3 Presentation Tests

- Enter and Analyze route through the same submission command.
- Multi-line paste preserves every link in the submitted text.
- The input clears only after at least one URL is accepted.
- Localized skipped-count feedback contains counts but no input URLs.
- Single-URL sheets retain their current behavior.
- Batch submissions do not open stacked sheets.

### 8.4 Regression Verification

- Run focused parser, store, presentation, persistence, and localization tests.
- Run the complete strict Swift suite with warnings as errors.
- Run the complete Python suite because release scripts share repository gates.
- Build and verify an arm64 internal App with the canonical helper inventory,
  SBOM, licenses, ad-hoc signatures, and deterministic ZIP checks.

## 9. Delivery Boundaries

This feature remains macOS Swift 2.x only. It does not change Windows Python
behavior, payment entitlements, repository visibility, support submission, or
public release status. The resulting App remains an internal test build until
Developer ID signing, notarization, source-delivery obligations, clean-device
testing, and the separate legal and commercial launch gates are complete.
