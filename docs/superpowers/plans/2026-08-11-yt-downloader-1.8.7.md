# YT Downloader Pro 1.8.7 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a locally verified YT Downloader Pro 1.8.7 Apple Silicon release candidate that cannot delete pre-existing downloads, never reuses stale analysis data, verifies HTTPS certificates, uses main-thread-only Tkinter access, and has reproducible packaging metadata.

**Architecture:** Keep the Python/Tkinter and in-process yt-dlp architecture for this patch release. Add two small value objects inside the versioned entrypoint: `DownloadRequest` carries immutable values captured on the UI thread, and `DownloadArtifactTracker` owns only paths created by one job. All worker results return to Tk through `root.after`, while build and bundle checks enforce version, architecture, signing, helper count, and FFmpeg redistribution gates.

**Tech Stack:** Python 3.13, Tkinter 8.6, yt-dlp, PyInstaller, FFmpeg/FFprobe, unittest, macOS codesign/plutil/lipo.

## Global Constraints

- Create `YT_downloader_187.py`; do not modify `YT_downloader_186.py`.
- Keep the release Apple Silicon-only with minimum macOS 11.0 and ad-hoc signing.
- Preserve the user's uncommitted `AppIcon.icns` change and never revert it.
- Never delete a path that existed before a download job began.
- Do not publish a public GitHub Release when FFmpeg provenance or redistribution checks fail.
- Do not update remote `main/version.txt` until a downloadable v1.8.7 release asset exists.
- Use test-first red/green cycles for every behavior change.

---

### Task 1: Establish the versioned 1.8.7 entrypoint

**Files:**
- Create: `YT_downloader_187.py`
- Modify: `tests/test_settings.py`
- Modify: `scripts/build_1_8_1.sh`

**Interfaces:**
- Produces: `YT_downloader_187.VERSION == "1.8.7"`
- Produces: tests and the existing build script import/build the 1.8.7 entrypoint.

- [ ] **Step 1: Add a failing release version test while the suite still imports 1.8.6**

```python
class ReleaseMetadataTests(unittest.TestCase):
    def test_current_source_is_version_1_8_7(self):
        self.assertEqual(app_module.VERSION, "1.8.7")
```

- [ ] **Step 2: Run the test and verify the expected red result**

Run: `python3 -m unittest tests.test_settings.ReleaseMetadataTests -v`

Expected: FAIL because the imported module reports `1.8.6`.

- [ ] **Step 3: Create the versioned source mechanically and switch the test import**

Run: `cp YT_downloader_186.py YT_downloader_187.py`

Change only these initial values:

```python
VERSION = "1.8.7"
DEFAULT_UPDATE_DOWNLOAD_URL = "https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest"
```

Change the test import to:

```python
import YT_downloader_187 as app_module
```

Change the PyInstaller source argument to `YT_downloader_187.py`.

- [ ] **Step 4: Run the release test and complete suite**

Run: `python3 -m unittest tests.test_settings.ReleaseMetadataTests -v`

Expected: PASS.

Run: `python3 -m unittest discover -s tests -v`

Expected: 9 tests pass.

- [ ] **Step 5: Commit the versioned entrypoint**

```bash
git add YT_downloader_187.py tests/test_settings.py scripts/build_1_8_1.sh
git commit -m "Start versioned 1.8.7 entrypoint"
```

### Task 2: Replace title-glob cleanup with job-owned artifact tracking

**Files:**
- Modify: `YT_downloader_187.py`
- Modify: `tests/test_settings.py`

**Interfaces:**
- Produces: `DownloadArtifactTracker(directory: str, output_filename: str)`
- Produces: `track(path: str | None) -> None`
- Produces: `cleanup() -> list[str]`
- Consumes: paths from yt-dlp progress and postprocessor hooks.

- [ ] **Step 1: Write failing safety tests**

Add tests that create real files in `TemporaryDirectory`:

```python
class ArtifactCleanupTests(unittest.TestCase):
    def test_cleanup_preserves_preexisting_same_title_files(self):
        existing = Path(self.tmpdir) / "Same Title.mp4"
        existing.write_text("keep", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title (1).mp4")
        partial = Path(self.tmpdir) / "Same Title (1).mp4.part"
        partial.write_text("partial", encoding="utf-8")
        tracker.track(str(partial))

        removed = tracker.cleanup()

        self.assertTrue(existing.exists())
        self.assertFalse(partial.exists())
        self.assertEqual(removed, [str(partial)])

    def test_cleanup_preserves_preexisting_tracked_path(self):
        partial = Path(self.tmpdir) / "Same Title.mp4.part"
        partial.write_text("old", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title.mp4")
        tracker.track(str(partial))
        tracker.cleanup()
        self.assertTrue(partial.exists())

    def test_cleanup_rejects_path_outside_output_directory(self):
        outside = Path(self.otherdir) / "outside.part"
        outside.write_text("keep", encoding="utf-8")
        tracker = app_module.DownloadArtifactTracker(self.tmpdir, "Same Title.mp4")
        tracker.track(str(outside))
        tracker.cleanup()
        self.assertTrue(outside.exists())
```

Also add a symlink test when `os.symlink` is available: a new link inside the output directory that resolves outside must be preserved.

- [ ] **Step 2: Run the cleanup tests and verify red**

Run: `python3 -m unittest tests.test_settings.ArtifactCleanupTests -v`

Expected: ERROR because `DownloadArtifactTracker` does not exist.

- [ ] **Step 3: Implement the minimal tracker**

Use `pathlib.Path` and store lexical absolute paths that existed at construction time. `track()` accepts only paths whose `resolve(strict=False)` remains inside the resolved output directory. `cleanup()` unlinks only tracked, non-preexisting files/symlinks and returns the removed lexical paths.

```python
class DownloadArtifactTracker:
    def __init__(self, directory, output_filename):
        self.directory = Path(directory).resolve()
        self.output_path = (self.directory / output_filename).absolute()
        self.preexisting = {path.absolute() for path in self.directory.iterdir()}
        self.tracked = set()
        self.track(str(self.output_path))

    def track(self, path):
        if not path:
            return
        candidate = Path(path)
        if not candidate.is_absolute():
            candidate = self.directory / candidate
        candidate = candidate.absolute()
        resolved = candidate.resolve(strict=False)
        if resolved != self.directory and self.directory not in resolved.parents:
            return
        if candidate not in self.preexisting:
            self.tracked.add(candidate)

    def cleanup(self):
        removed = []
        for path in sorted(self.tracked, key=lambda item: len(str(item)), reverse=True):
            if path in self.preexisting:
                continue
            resolved = path.resolve(strict=False)
            if resolved != self.directory and self.directory not in resolved.parents:
                continue
            if path.is_file() or path.is_symlink():
                path.unlink()
                removed.append(str(path))
        return sorted(removed)
```

- [ ] **Step 4: Connect the tracker to one download job**

Create the tracker immediately after choosing the unique filename. Record `filename`, `tmpfilename`, and `info_dict.filepath` from progress hooks, and add a postprocessor hook that records `filepath`/`filename`. Replace `cleanup_incomplete_files()` with `self.current_artifacts.cleanup()` only for explicit user cancellation. Do not clean partial files for ordinary errors.

- [ ] **Step 5: Verify cleanup red becomes green**

Run: `python3 -m unittest tests.test_settings.ArtifactCleanupTests -v`

Expected: all artifact tests pass and no pre-existing file is removed.

Run: `python3 -m unittest discover -s tests -v`

Expected: complete suite passes.

- [ ] **Step 6: Commit the safety fix**

```bash
git add YT_downloader_187.py tests/test_settings.py
git commit -m "Prevent cancel cleanup from deleting existing files"
```

### Task 3: Bind analysis data to its URL and snapshot UI inputs

**Files:**
- Modify: `YT_downloader_187.py`
- Modify: `tests/test_settings.py`

**Interfaces:**
- Produces: immutable `DownloadRequest` dataclass with `url`, `video_format_id`, `audio_format_id`, `audio_only`, `output_directory`, and `title`.
- Produces: `invalidate_analysis() -> None`
- Produces: `download_selection_is_valid(url: str, audio_only: bool) -> bool`
- Produces: `apply_analysis_result(request_id, url, title, video_data, audio_data) -> None`

- [ ] **Step 1: Write failing pure state tests**

Construct the app with `object.__new__` and plain attributes. Verify:

```python
def test_changed_url_invalidates_download_selection(self):
    app.analyzed_url = "https://youtu.be/first"
    app.video_format_list = ["137"]
    app.audio_format_list = ["140"]
    self.assertFalse(app.download_selection_is_valid("https://youtu.be/second", False))

def test_video_download_requires_video_and_audio_formats(self):
    app.analyzed_url = "https://youtu.be/first"
    app.video_format_list = []
    app.audio_format_list = ["140"]
    self.assertFalse(app.download_selection_is_valid("https://youtu.be/first", False))

def test_audio_only_requires_an_audio_format(self):
    app.analyzed_url = "https://youtu.be/first"
    app.audio_format_list = []
    self.assertFalse(app.download_selection_is_valid("https://youtu.be/first", True))
```

- [ ] **Step 2: Run and verify red**

Run: `python3 -m unittest tests.test_settings.AnalysisStateTests -v`

Expected: ERROR because the validation method is absent.

- [ ] **Step 3: Implement analysis identity and stale-result protection**

Initialize `analyzed_url = ""` and `analysis_request_id = 0`. `start_analyze()` increments the request ID, invalidates existing data before launching, and passes the ID to `analyze_video`. `apply_analysis_result` ignores callbacks whose request ID no longer matches. Bind URL key changes and paste actions to `invalidate_analysis`.

- [ ] **Step 4: Capture a request before starting the worker**

In `start_download()`, read every Tk value on the main thread and construct:

```python
@dataclass(frozen=True)
class DownloadRequest:
    url: str
    video_format_id: str | None
    audio_format_id: str | None
    audio_only: bool
    output_directory: str
    title: str
```

Change the worker signature to `download_video(self, request: DownloadRequest)`. The worker must not call `.get()` on Tk variables or read editable widgets.

- [ ] **Step 5: Run state tests and full suite**

Run: `python3 -m unittest tests.test_settings.AnalysisStateTests -v`

Expected: PASS.

Run: `python3 -m unittest discover -s tests -v`

Expected: complete suite passes.

- [ ] **Step 6: Commit state isolation**

```bash
git add YT_downloader_187.py tests/test_settings.py
git commit -m "Bind downloads to current analysis results"
```

### Task 4: Restore certificate verification and main-thread dialogs

**Files:**
- Modify: `YT_downloader_187.py`
- Modify: `tests/test_settings.py`

**Interfaces:**
- Produces: `make_analysis_options() -> dict`
- Produces: `make_download_options(request, ffmpeg_dir) -> dict`
- Extends: `clean_download_error(error) -> str` for certificate, network, and permission failures.

- [ ] **Step 1: Add failing option and error tests**

```python
def test_analysis_options_keep_certificate_checks_enabled(self):
    self.assertNotIn("nocheckcertificate", app.make_analysis_options())

def test_certificate_error_is_localized(self):
    message = app.clean_download_error(Exception("CERTIFICATE_VERIFY_FAILED"))
    self.assertIn("安全憑證", message)

def test_permission_error_is_localized(self):
    message = app.clean_download_error(PermissionError("denied"))
    self.assertIn("權限", message)
```

- [ ] **Step 2: Run and verify red**

Run: `python3 -m unittest tests.test_settings.NetworkSafetyTests -v`

Expected: ERROR for missing option builder and FAIL for untranslated errors.

- [ ] **Step 3: Remove insecure overrides and add option builders**

Delete the global `_create_unverified_context` assignment and all `nocheckcertificate` options. Keep update checks on the default verified `urllib` context. Add localized keys for certificate, network, permission, missing formats, changed URL, and merging state in Chinese, English, and Japanese.

- [ ] **Step 4: Route every worker dialog and UI mutation through `root.after`**

The worker schedules small main-thread methods such as `show_download_success()`, `show_download_error(message)`, `show_cancelled(removed_paths)`, and `reset_ui()`. Capture exception text before creating lambdas:

```python
message = self.clean_download_error(error)
self.root.after(0, lambda value=message: messagebox.showerror("Error", value))
```

- [ ] **Step 5: Verify network tests and suite**

Run: `python3 -m unittest tests.test_settings.NetworkSafetyTests -v`

Expected: PASS.

Run: `python3 -m unittest discover -s tests -v`

Expected: complete suite passes.

- [ ] **Step 6: Commit secure networking and UI dispatch**

```bash
git add YT_downloader_187.py tests/test_settings.py
git commit -m "Restore TLS verification and safe UI dispatch"
```

### Task 5: Make merging controls honest

**Files:**
- Modify: `YT_downloader_187.py`
- Modify: `tests/test_settings.py`

**Interfaces:**
- Produces: `download_phase` values `idle`, `downloading`, `paused`, `merging`.
- Produces: `set_download_phase(phase: str) -> None` on the main thread.

- [ ] **Step 1: Write failing phase tests with fake buttons**

Verify that `merging` disables pause and cancel, `downloading` enables both, and `idle` disables both.

- [ ] **Step 2: Run and verify red**

Run: `python3 -m unittest tests.test_settings.DownloadPhaseTests -v`

Expected: ERROR because `set_download_phase` does not exist.

- [ ] **Step 3: Implement phase transitions**

`progress_hook(status="downloading")` schedules the downloading phase. `status="finished"` schedules merging and a localized `Merging...` label. `toggle_pause` updates paused/downloading only. `cancel_download` ignores merging. `reset_ui` returns to idle.

- [ ] **Step 4: Verify phase and full tests**

Run: `python3 -m unittest tests.test_settings.DownloadPhaseTests -v`

Expected: PASS.

Run: `python3 -m unittest discover -s tests -v`

Expected: complete suite passes.

- [ ] **Step 5: Commit phase behavior**

```bash
git add YT_downloader_187.py tests/test_settings.py
git commit -m "Disable unavailable controls while merging"
```

### Task 6: Pin dependencies and enforce bundle metadata

**Files:**
- Modify: `requirements.txt`
- Create: `scripts/build_1_8_7.sh`
- Modify: `scripts/check_bundle_tools.py`
- Modify: `tests/test_settings.py`

**Interfaces:**
- Produces: exact dependency versions `yt-dlp==2026.6.9` and `pyinstaller==6.21.0` after they pass the integration gate.
- Produces: bundle metadata version `1.8.7`, build `187`, minimum macOS `11.0`.

- [ ] **Step 1: Add failing release configuration tests**

Read text files and assert exact dependencies, the 1.8.7 source argument, and the three plist values in the new build script. These tests initially fail because the new script does not exist and requirements use `>=`.

- [ ] **Step 2: Run and verify red**

Run: `python3 -m unittest tests.test_settings.ReleaseConfigurationTests -v`

Expected: FAIL/ERROR for missing 1.8.7 build metadata and unpinned dependencies.

- [ ] **Step 3: Create the 1.8.7 build script**

Copy the existing script mechanically, then use `YT_downloader_187.py`. After PyInstaller creates the app, use `/usr/libexec/PlistBuddy` to set:

```text
CFBundleShortVersionString = 1.8.7
CFBundleVersion = 187
LSMinimumSystemVersion = 11.0
```

Perform plist changes before helper and app signing. Keep the old build script for historical releases.

- [ ] **Step 4: Expand bundle checks**

`check_bundle_tools.py` must assert plist values, arm64 compatibility, successful `-version`, absence of `--enable-nonfree`, valid ad-hoc signature, and one physical ffmpeg plus one physical ffprobe.

- [ ] **Step 5: Install pinned versions in an isolated virtual environment and run tests**

Run:

```bash
python3 -m venv .venv-1.8.7
.venv-1.8.7/bin/python -m pip install --upgrade pip
.venv-1.8.7/bin/python -m pip install "yt-dlp==2026.6.9" "pyinstaller==6.21.0"
.venv-1.8.7/bin/python -m unittest discover -s tests -v
```

Expected: installation succeeds and the complete suite passes. If either exact release is unavailable, keep `requirements.txt` unchanged, record the unavailable package/version, and stop the release configuration task rather than silently selecting a different version.

- [ ] **Step 6: Verify configuration tests and commit**

Run: `.venv-1.8.7/bin/python -m unittest tests.test_settings.ReleaseConfigurationTests -v`

Expected: PASS.

```bash
git add requirements.txt scripts/build_1_8_7.sh scripts/check_bundle_tools.py tests/test_settings.py
git commit -m "Make 1.8.7 builds reproducible"
```

### Task 7: Evaluate and replace FFmpeg/FFprobe safely

**Files:**
- Modify conditionally after all gates pass: `tools/ffmpeg`
- Modify conditionally after all gates pass: `tools/ffprobe`
- Modify: `THIRD_PARTY_NOTICES.md`
- Create: `tools/FFMPEG_BUILD_INFO.md`

**Interfaces:**
- Consumes: OSXExperts FFmpeg 9.0 arm64 zip and ffprobe 9.0 arm64 zip.
- Produces: verified checksums and configure output without `--enable-nonfree`.

- [ ] **Step 1: Download candidates into a temporary directory, never over current tools**

Download:

```text
https://www.osxexperts.net/ffmpeg9arm.zip
https://www.osxexperts.net/ffprobe9arm.zip
```

Expected published SHA-256 values:

```text
ffmpeg: 591260c945d0eef150e3bf82b0ef988bd36a9cecc18ff05d6679617159f0a95e
ffprobe: e11c17e8200b3ee4c4c186d245e2b4053f01d56957336c1817fca0b997469106
```

- [ ] **Step 2: Verify every redistribution gate**

After extraction, run `shasum -a 256`, `file`, `lipo -archs`, `otool -L`, `ffmpeg -version`, `ffprobe -version`, and `ffmpeg -hide_banner -encoders`. Required results:

- checksums exactly match published values;
- architecture contains arm64;
- no non-system dylib dependency;
- configure output does not contain `--enable-nonfree`;
- MP3 encoder `libmp3lame` is present;
- ffmpeg and ffprobe identify the same FFmpeg version.

If any result fails, do not replace `tools/*`; document the failed gate in the implementation report and mark public release blocked.

- [ ] **Step 3: Replace tools only after all gates pass**

Copy the verified binaries to `tools/ffmpeg` and `tools/ffprobe`, set mode 755, remove quarantine, ad-hoc sign, and run `scripts/verify_tools.sh`.

- [ ] **Step 4: Record provenance**

`FFMPEG_BUILD_INFO.md` records URLs, download date, SHA-256, architecture, full configure line, FFmpeg version, upstream source link, and redistribution review result. Update third-party notices to remove the old Descript/nonfree statement only after replacement.

- [ ] **Step 5: Commit verified binaries and notices**

```bash
git add tools/ffmpeg tools/ffprobe tools/FFMPEG_BUILD_INFO.md THIRD_PARTY_NOTICES.md
git commit -m "Replace nonfree FFmpeg helpers"
```

Skip this commit entirely when a gate fails.

### Task 8: Write the user-facing GitHub documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: Chinese-first feature, installation, compatibility, limitations, troubleshooting, issue-report, and license sections.

- [ ] **Step 1: Add a documentation completeness test**

Assert README contains `1.8.7`, `Apple Silicon`, `MP4`, `MP3`, `已知限制`, `問題回報`, and a `/releases/latest` link.

- [ ] **Step 2: Run and verify red**

Run: `python3 -m unittest tests.test_settings.ReadmeTests -v`

Expected: FAIL because the current README lacks the user sections.

- [ ] **Step 3: Rewrite README for users while retaining developer build commands**

Describe only implemented behavior. State that 1.8.7 handles one video at a time, pause applies during download progress but not merging, private/DRM videos are not guaranteed, and the build is Apple Silicon-only. Include the exact issue report fields and legal-use reminder.

- [ ] **Step 4: Verify and commit README**

Run: `python3 -m unittest tests.test_settings.ReadmeTests -v`

Expected: PASS.

```bash
git add README.md tests/test_settings.py
git commit -m "Document 1.8.7 features and support"
```

### Task 9: Build and verify the local release candidate

**Files:**
- Generated, not committed: `dist/YT Downloader Pro.app`
- Generated, not committed: `dist/YT-Downloader-Pro-v1.8.7-macOS-arm64.zip`

**Interfaces:**
- Produces: locally testable 1.8.7 app and zip.

- [ ] **Step 1: Run the full automated suite in the pinned environment**

Run: `.venv-1.8.7/bin/python -m unittest discover -s tests -v`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Re-run the original 1.8.6 destructive reproduction against 1.8.7**

Create an existing `Same Title.mp4`, track a new `Same Title (1).mp4.part`, cancel cleanup, and assert the existing MP4 remains while the new partial is removed.

- [ ] **Step 3: Run live analysis with verified TLS**

Analyze:

```text
https://youtu.be/-g6MYL5lOZs
https://youtu.be/DWwFK2gjwa8
```

Expected for each: non-empty title, at least one eligible video-only format, and at least one audio-only format.

- [ ] **Step 4: Exercise MP4 and MP3 output in a temporary directory**

Use the same 1.8.7 option builders and bundled FFmpeg path. Verify completed files with `ffprobe`, then repeat the MP4 output to verify `(1)` naming. Keep all downloaded test media outside the repository and remove it after verification.

- [ ] **Step 5: Build and inspect the app**

Run:

```bash
./scripts/build_1_8_7.sh
python3 scripts/check_bundle_tools.py "dist/YT Downloader Pro.app"
```

Expected: bundle version 1.8.7/build 187/minimum macOS 11.0, arm64 executable, valid ad-hoc signature, both helpers executable, no `--enable-nonfree`, and one physical file per helper.

- [ ] **Step 6: Launch the packaged app for a smoke test**

Open the app, analyze one test URL, verify controls and localized errors, start a download, pause/resume during transfer, and confirm pause/cancel are disabled while merging.

- [ ] **Step 7: Create the release candidate zip**

Use `ditto -c -k --sequesterRsrc --keepParent` so bundle symlinks and metadata are preserved. Verify the extracted copy again with `check_bundle_tools.py`.

- [ ] **Step 8: Commit any verification-only script fixes, but not generated artifacts**

Run `git diff --check`, `git status`, and review every changed path. Do not stage `dist/`, `.venv-1.8.7/`, or the user's unrelated icon change unless the user explicitly confirms the icon is final.

### Task 10: Hold publication until user acceptance

**Files:**
- Modify only after acceptance: `version.txt`

**Interfaces:**
- Produces later: tag `v1.8.7` and GitHub Release with the verified zip.

- [ ] **Step 1: Present the local app path, zip path, test evidence, and any FFmpeg release blocker to the user**

Do not push, tag, publish, or update `version.txt` in this step.

- [ ] **Step 2: After explicit user acceptance, prepare publication atomically**

Change `version.txt` to `1.8.7`, commit it, create local tag `v1.8.7`, create a draft GitHub Release, upload the verified zip, push `main` and tag, then publish the release. Confirm the Release asset is downloadable before considering update notification live.
