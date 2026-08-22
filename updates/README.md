# Update manifest contracts

`macos.json` is consumed only by the Swift 2.x app. `windows.json` is consumed
only by future Python Windows builds. Both are fetched through the GitHub
Contents API, whose base64 `content` field is decoded before schema validation.

The checked-in manifests use `0.0.0`, `example.invalid` URLs, zero checksums,
and explicit placeholder notes. They document the schema and are not a release
or update claim. A release process must replace every placeholder with values
verified against the matching package and platform-specific release.

Generate the macOS file deterministically with:

```bash
python3 scripts/create_macos_manifest.py \
  --version 2.0.0 \
  --minimum-macos 13.0.0 \
  --release-url https://example.invalid/releases/macos-example \
  --download-url https://example.invalid/macos-example.zip \
  --sha256 0000000000000000000000000000000000000000000000000000000000000000 \
  --published-at 2026-08-18T00:00:00Z \
  --release-notes "Placeholder example only; not a release."
```

Windows selection is fail-closed: the top-level platform must be `windows`,
and the chosen asset must separately declare `platform: windows` and
`architecture: x64`, with HTTPS URLs and a lowercase SHA-256. Do not remove or
repurpose the root `version.txt`; already-released clients still read it.

Split manifests use strict ASCII SemVer 2.0 precedence: prereleases sort below
their matching release and build metadata does not affect precedence. Legacy
plain-text and legacy JSON version sources intentionally retain the older
numeric-component comparison used by already-released Python clients.

The macOS checker accepts at most a 192 KiB GitHub Contents envelope and a 96
KiB decoded manifest. It also requires the final response after redirects to
remain HTTPS on the requested API origin and path. These limits are application
contracts; release notes must stay comfortably below them.
