# YT Downloader Pro 2.0.1 Release Notes

## Candidate Status

This document describes the macOS Swift 2.0.1 internal release candidate. It is
not a public release until the Developer ID, notarization, Gatekeeper, licensing,
and source-availability gates in `RELEASE.md` and `SBOM_AND_LICENSES.md` pass.

## Changes

- Prevent repeated analysis callbacks from adding the same multi-URL batch
  twice. Equivalent YouTube URLs are deduplicated while completed, failed, and
  cancelled items remain intentionally resubmittable.
- Keep Traditional Chinese interface selections consistent in media settings,
  local support reports, local export, and local data-management screens.
- Prefer QuickTime-compatible H.264/AAC MP4 output and verify the final media
  container before marking a download complete.
- Include the local-only support report, data export, and data-management user
  interfaces. User review remains required and no data is uploaded silently.

## Regression Coverage

- Single-URL analysis still opens the per-item media settings flow.
- Multi-URL analysis uses the shared defaults and creates one job per unique
  YouTube video or playlist identity.
- The five-URL duplicate-download reproduction set creates five jobs, not ten.
- A completed, failed, or cancelled URL can be submitted again intentionally.
- Traditional Chinese and Japanese resources remain independently selectable.
- MP4 downloads are checked for Apple playback compatibility.

## Distribution Gate

The internal arm64 ZIP is for local testing only and is ad-hoc signed. Do not
publish it to end users. The public asset requires a valid Developer ID
Application identity, hardened runtime, Apple notarization and stapling, a
passing Gatekeeper/install test, and completion of the documented third-party
license and source-delivery review.
