# Swift Multi-URL Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept multiple pasted media URLs, show one durable analysis card per URL, and process the batch sequentially without changing the existing single-URL sheets.

**Architecture:** A pure `MediaURLInputParser` owns extraction, validation, normalization, and deduplication. `DownloadStore.submitURLInput(_:)` routes one accepted URL to the existing modal analysis and routes multiple URLs into persistent placeholder jobs managed by one FIFO analysis loop and one cancellable child request. `DownloadCenterView` submits the complete field value and presents count-only feedback.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation, Swift Concurrency, XCTest, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-11-swift-multi-url-input-design.md`

## Global Constraints

- macOS Swift 2.x only; Windows Python behavior remains unchanged.
- Accept only credential-free HTTP and HTTPS URLs validated by `MediaURLValidator`.
- Metadata probes execute sequentially; download concurrency remains the existing 1 through 10 setting.
- Single-URL submissions retain the existing video and playlist sheets.
- Multi-URL submissions use saved default options, auto-start successful jobs, and never open stacked sheets.
- Persisted legacy jobs decode with `awaitsBatchAnalysis == false`.
- Feedback exposes counts only and never echoes rejected URL contents.
- No account, payment, cloud, analytics, upload, external submission, public release, or second extraction engine work.

---

### Task 1: Pure Multi-URL Parser

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/MediaURLInputParser.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/MediaURLInputParserTests.swift`

**Interfaces:**
- Consumes: `MediaURLValidator.isSupported(_:)`.
- Produces: `MediaURLInputParseResult` and `MediaURLInputParser.parse(_:)`.

- [ ] **Step 1: Write failing parser tests**

```swift
func testParsesMixedWhitespaceInFirstSeenOrder() {
    let result = MediaURLInputParser.parse("https://youtu.be/one\nhttps://youtu.be/two\thttps://youtu.be/three")
    XCTAssertEqual(result.urls, ["https://youtu.be/one", "https://youtu.be/two", "https://youtu.be/three"])
}

func testDeduplicatesNormalizedURLsButRetainsDistinctQueries() {
    let result = MediaURLInputParser.parse("HTTPS://YOUTU.BE/one#top https://youtu.be/one https://youtu.be/one?t=5")
    XCTAssertEqual(result.urls, ["https://youtu.be/one", "https://youtu.be/one?t=5"])
    XCTAssertEqual(result.duplicateCount, 1)
}

func testRejectsCredentialsAndNonHTTPLinks() {
    let result = MediaURLInputParser.parse("https://user:pass@example.com/a ftp://example.com/file")
    XCTAssertTrue(result.urls.isEmpty)
    XCTAssertEqual(result.rejectedCount, 2)
}
```

- [ ] **Step 2: Run the focused test and confirm missing parser symbols fail compilation**

Run: `swift test --package-path swift-2.0 --disable-sandbox --filter MediaURLInputParserTests`

- [ ] **Step 3: Implement the pure parser**

```swift
struct MediaURLInputParseResult: Equatable, Sendable {
    let urls: [String]
    let rejectedCount: Int
    let duplicateCount: Int
}

enum MediaURLInputParser {
    static func parse(_ input: String) -> MediaURLInputParseResult
}
```

Use Foundation link detection, normalize scheme and host to lowercase, remove fragments, preserve query strings, validate before acceptance, and deduplicate by normalized string.

- [ ] **Step 4: Run focused parser tests until green**
- [ ] **Step 5: Commit parser and tests**

---

### Task 2: Durable Batch Placeholder Model

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadJob.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/ModelsTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/PersistenceControllerTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/Fixtures.swift`

**Interfaces:**
- Consumes: existing `DownloadJob` persistence and recovery.
- Produces: `DownloadJob.awaitsBatchAnalysis: Bool` with legacy default `false`.

- [ ] **Step 1: Write failing Codable tests**

```swift
func testBatchAnalysisMarkerRoundTrips() throws {
    let job = DownloadJob.fixture(status: .analyzing, awaitsBatchAnalysis: true)
    let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
    XCTAssertTrue(decoded.awaitsBatchAnalysis)
}

func testLegacyJobWithoutBatchMarkerDefaultsToFalse() throws {
    let decoded = try JSONDecoder().decode(DownloadJob.self, from: legacyJobJSONWithoutBatchMarker)
    XCTAssertFalse(decoded.awaitsBatchAnalysis)
}
```

- [ ] **Step 2: Run focused model and persistence tests and confirm the marker is missing**
- [ ] **Step 3: Add the marker, initializer parameter, and explicit backward-compatible decoding**
- [ ] **Step 4: Run focused model and persistence tests until green**
- [ ] **Step 5: Commit the model migration**

---

### Task 3: Submission Routing And Sequential Batch Analysis

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`

**Interfaces:**
- Consumes: `MediaURLInputParser.parse(_:)`, `DownloadJob.awaitsBatchAnalysis`, `MetadataAnalyzing`, existing `automaticallyStartNewJobs(_:)`.
- Produces: `URLInputSubmissionResult` and `DownloadStore.submitURLInput(_:) async -> URLInputSubmissionResult`.

- [ ] **Step 1: Write failing routing and immediate-placeholder tests**

```swift
let single = await store.submitURLInput("https://youtube.test/one")
XCTAssertEqual(single.acceptedCount, 1)
XCTAssertTrue(store.jobs.isEmpty)

let batch = await store.submitURLInput("https://youtube.test/one https://youtube.test/two")
XCTAssertEqual(batch.acceptedCount, 2)
XCTAssertEqual(store.jobs.map(\.awaitsBatchAnalysis), [true, true])
XCTAssertEqual(store.jobs.map(\.status), [.analyzing, .analyzing])
```

- [ ] **Step 2: Run focused tests and confirm `submitURLInput` is absent**
- [ ] **Step 3: Implement single-versus-batch routing and persist placeholders before starting work**
- [ ] **Step 4: Write failing FIFO, no-overlap, success, and failure-isolation tests with a controlled analyzer**
- [ ] **Step 5: Implement `batchAnalysisTask`, `batchAnalysisRequestTask`, pending IDs, and stale-result guards**
- [ ] **Step 6: Write failing video identity and playlist replacement-order tests**
- [ ] **Step 7: Implement in-place video adoption and playlist placeholder replacement using sanitized metadata and default options**
- [ ] **Step 8: Run focused store tests until green**
- [ ] **Step 9: Commit the batch engine**

---

### Task 4: Cancellation, Recovery, And Shutdown

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/PersistenceControllerTests.swift`

**Interfaces:**
- Consumes: Task 3 batch ownership fields and placeholder marker.
- Produces: cancellation of one placeholder only, FIFO recovery, and joined shutdown.

- [ ] **Step 1: Write failing tests for cancelling waiting and active placeholders**
- [ ] **Step 2: Run focused tests and confirm cancellation reaches the coordinator incorrectly or leaves work pending**
- [ ] **Step 3: Route placeholder cancellation to the batch queue and current child task before coordinator cancellation**
- [ ] **Step 4: Write failing recovered-placeholder FIFO test**
- [ ] **Step 5: Requeue recovered batch placeholders without submitting them to `DownloadCoordinator`**
- [ ] **Step 6: Write failing quit test that requires both batch tasks to be cancelled and joined**
- [ ] **Step 7: Extend `deinit` and `performQuit()` to cancel and await batch work**
- [ ] **Step 8: Run focused recovery, cancellation, and shutdown tests until green**
- [ ] **Step 9: Commit lifecycle handling**

---

### Task 5: SwiftUI Submission, Clipboard Preservation, And Localized Feedback

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `DownloadStore.submitURLInput(_:)` and `URLInputSubmissionResult`.
- Produces: shared Enter/button submission, accepted-only field clearing, complete multi-line clipboard placement, and count-only feedback.

- [ ] **Step 1: Write failing pure presentation tests**

```swift
XCTAssertEqual(URLInputPresentation.displayText(for: "one\ntwo"), "one two")
XCTAssertTrue(URLInputPresentation.shouldClearInput(after: .init(acceptedCount: 2, rejectedCount: 0, duplicateCount: 0)))
XCTAssertFalse(URLInputPresentation.shouldClearInput(after: .init(acceptedCount: 0, rejectedCount: 1, duplicateCount: 0)))
```

- [ ] **Step 2: Run focused view tests and confirm presentation symbols are absent**
- [ ] **Step 3: Implement presentation helpers and route Enter/button through one async submission method**
- [ ] **Step 4: Accept multi-URL clipboard text when at least one supported URL is parsed and preserve all accepted URLs for submission**
- [ ] **Step 5: Add English, Japanese, and Traditional Chinese strings for analyzing title, no-valid-URL error, empty-playlist failure, and skipped counts**
- [ ] **Step 6: Extend localization completeness and secret/non-echo tests**
- [ ] **Step 7: Run focused view and localization tests until green**
- [ ] **Step 8: Commit presentation and localization**

---

### Task 6: Full Regression And Internal Bundle Verification

**Files:**
- Modify only if verification exposes a regression.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified feature branch suitable for review and later local integration.

- [ ] **Step 1: Run `git diff --check`**
- [ ] **Step 2: Run the complete strict Swift suite with project-local Clang module cache and warnings as errors**
- [ ] **Step 3: Run the complete Python suite**
- [ ] **Step 4: Build the arm64 internal app and verify helper inventory, SBOM, licenses, signatures, and deterministic ZIP report**
- [ ] **Step 5: Review the final diff for unrelated changes and privacy boundary regressions**
- [ ] **Step 6: Commit any verification-only fixes, then use the finishing-development-branch workflow**
