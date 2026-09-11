# Third-Party Notices

This project bundles command-line tools used by YT Downloader Pro.

## yt-dlp

- Source: https://github.com/yt-dlp/yt-dlp
- Bundled helper: `tools/yt-dlp_macos`
- Bundled macOS helper version reported by `--version`: `2026.07.04`
- Bundled helper SHA-256 before release re-signing: `498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b`
- Matching source archive: https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp.tar.gz
- Source archive SHA-256: `31c32457d1a573a341bb0929386c624fe47339a5338829e6e9c9454bdfa7397a`
- Bundled Python package: `yt-dlp==2026.6.9`
- The yt-dlp project source is dedicated under the Unlicense. The official
  PyInstaller standalone executable includes GPL-licensed components; upstream
  identifies that distributed combined work as GPL version 3 or later.
- macOS bundle license texts: `tools/licenses/GPL-3.0-or-later.txt`,
  `tools/licenses/yt-dlp-Unlicense.txt`, and
  `tools/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt`

## yt-dlp-ejs

- Source: https://github.com/yt-dlp/ejs
- Bundled Python package: `yt-dlp-ejs==0.8.0`
- License expression reported by the package: Unlicense AND MIT AND ISC
- Purpose: provides the JavaScript challenge solver files used by yt-dlp.

## QuickJS

- Source: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
- Bundled helper: `tools/qjs`
- Version: 2026-06-04
- License: MIT
- Purpose: executes the bundled yt-dlp EJS challenge solver without requiring Homebrew or Deno.
- Build and checksum details: `tools/QUICKJS_BUILD_INFO.md`
- License text: `tools/licenses/QuickJS-MIT.txt`

## FFmpeg and FFprobe

- Source: https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz
- Bundled helpers: `tools/ffmpeg`, `tools/ffprobe`
- Version: 9.0
- License: GNU Lesser General Public License, version 2.1 or later
- Build: Apple Silicon arm64, statically linked FFmpeg libraries, macOS 11.0 deployment target
- Build and checksum details: `tools/FFMPEG_BUILD_INFO.md`
- License text: `tools/licenses/FFmpeg-LGPL-2.1.txt`

## BtbN FFmpeg and FFprobe (Windows x64 test build)

- Source distribution: BtbN FFmpeg-Builds
- Upstream: https://github.com/BtbN/FFmpeg-Builds
- Exact archive: https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-08-12-13-15/ffmpeg-N-126086-ge5ecfe8970-win64-lgpl.zip
- Version: `N-126086-ge5ecfe8970`
- SHA-256: `3fe180f31a12a1de60568cdcf72210a1d3f475f5f88719afdd6c7012e13f6d3e`
- License: `LGPL-2.1-or-later`
- License text: `tools/licenses/FFmpeg-LGPL-2.1.txt`
- Bundled Windows helpers: `Helpers/ffmpeg.exe`, `Helpers/ffprobe.exe`
- Archive member: `ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffmpeg.exe` -> `Helpers/ffmpeg.exe`
- Archive member: `ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffprobe.exe` -> `Helpers/ffprobe.exe`
- The Windows test build uses this pinned LGPL archive rather than the macOS arm64 helpers above.

## Deno (Windows x64 test build)

- Upstream: https://github.com/denoland/deno
- Exact archive: https://github.com/denoland/deno/releases/download/v2.8.1/deno-x86_64-pc-windows-msvc.zip
- Version: `2.8.1`
- SHA-256: `5fb5bac71f609fb91ec8960fb290885aadc27eeb22f07a8eca0c3db6be38b11a`
- License: `MIT`
- License text: `tools/licenses/Deno-MIT.txt`
- Bundled Windows helper: `Helpers/deno.exe`
- Archive member: `deno.exe` -> `Helpers/deno.exe`
- Purpose: executes the yt-dlp JavaScript challenge solver in the Windows x64 test build.

## LAME

- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- Version: 3.100
- License: GNU Lesser General Public License, version 2
- Purpose: statically linked into FFmpeg to provide the `libmp3lame` MP3 encoder.
- Both bundled `ffmpeg` and `ffprobe` contain LAME symbols and are represented by
  `STATIC_LINK` relationships in the macOS SPDX document.
- License text: `tools/licenses/LAME-LGPL-2.0.txt`

## Swift 2.0 macOS Bundle

The Swift 2.0 packaging script copies exactly one of each macOS helper to:

- `YT Downloader Pro 2.app/Contents/Helpers/yt-dlp_macos`
- `YT Downloader Pro 2.app/Contents/Helpers/ffmpeg`
- `YT Downloader Pro 2.app/Contents/Helpers/ffprobe`
- `YT Downloader Pro 2.app/Contents/Helpers/qjs`

It also copies this notice, a source-availability index, an SPDX 2.3 SBOM, and
the exact yt-dlp, FFmpeg, LAME, and QuickJS license texts under
`Contents/Resources/`. Repository helper files are not modified during assembly;
only copied bundle files are re-signed. The SBOM records both the canonical
pre-signing helper hashes and the final hashes after the copied helpers are
signed.

The canonical inventory is `tools/macos-helper-inventory.json`. Its helper and
license hashes are enforced by `scripts/generate_swift_sbom.py`; the packaged
SBOM is independently enforced by `scripts/check_swift_bundle.py`. See
`docs/swift-2.0/SBOM_AND_LICENSES.md` for the maintenance contract and limits.

The current provenance-aligned FFmpeg 9.0, FFprobe 9.0, and QuickJS 2026-06-04
binaries are arm64-only. `yt-dlp_macos` is universal, but that does not make the
four-helper toolchain universal. Swift 2.0 internal packaging therefore supports
arm64 only and fails closed for Intel/universal requests until matching reviewed
slices are supplied for all four helpers.
