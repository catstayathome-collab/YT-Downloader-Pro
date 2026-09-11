# Third-Party Source Availability

> **Status: incomplete for public or paid distribution.** This file is a
> technical provenance index only. It does not yet provide complete
> corresponding source for every transitive component in the yt-dlp standalone
> aggregate, nor an approved relinking/object-file delivery for the static
> FFmpeg/LAME integration. Do not treat it as satisfying GPL/LGPL distribution
> obligations.

This technical source index identifies the upstream source corresponding to the
helper executables bundled with YT Downloader Pro 2 for macOS. It is intended to
make release provenance reproducible. It is not a substitute for legal review or
for any source-distribution obligation that may apply to a particular release.

## yt-dlp macOS standalone 2026.07.04

- Binary: <https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp_macos>
- Binary SHA-256 before local code signing: `498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b`
- Source archive: <https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp.tar.gz>
- Source SHA-256: `31c32457d1a573a341bb0929386c624fe47339a5338829e6e9c9454bdfa7397a`
- License bundle: `ThirdPartyLicenses/GPL-3.0-or-later.txt`,
  `ThirdPartyLicenses/yt-dlp-Unlicense.txt`, and
  `ThirdPartyLicenses/yt-dlp-THIRD_PARTY_LICENSES.txt`

The standalone executable contains a PyInstaller-distributed combined work.
Upstream identifies that executable as GPL-3.0-or-later even though the yt-dlp
project's own source is dedicated under the Unlicense.

## FFmpeg 9.0

- Source archive: <https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz>
- Source SHA-256: `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52`
- Build record: `tools/FFMPEG_BUILD_INFO.md` in the source repository
- License: `ThirdPartyLicenses/FFmpeg-LGPL-2.1.txt`

## LAME 3.100

- Source archive: <https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz>
- Source SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- Integration: statically linked into the bundled `ffmpeg` and `ffprobe`
- License: `ThirdPartyLicenses/LAME-LGPL-2.0.txt`

## QuickJS 2026-06-04

- Source archive: <https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz>
- Source SHA-256: `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`
- Build record: `tools/QUICKJS_BUILD_INFO.md` in the source repository
- License: `ThirdPartyLicenses/QuickJS-MIT.txt`

The release-specific `SBOM.spdx.json` inside the app records the SHA-256 values
of the final signed helper files. Those values can differ from the canonical
pre-signing hashes above because macOS code signing modifies executable bytes.
