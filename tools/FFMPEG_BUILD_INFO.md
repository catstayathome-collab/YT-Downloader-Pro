# FFmpeg 9.0 Build Information

The `ffmpeg` and `ffprobe` helpers in this directory were built from official
upstream source on 2026-08-12 for YT Downloader Pro 1.8.7.

## Sources

- FFmpeg: https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz
- FFmpeg source SHA-256: `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52`
- LAME: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- LAME source SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`

## Build

- Architecture: `arm64`
- Deployment target: `macOS 11.0`
- SDK: `macOS 15.5`
- Compiler: Apple clang 17.0.0
- FFmpeg license reported by configure: LGPL 2.1 or later
- External codec library: statically built LAME 3.100 (`libmp3lame`)
- Symbol inspection: both repository `ffmpeg` and `ffprobe` contain LAME symbols,
  so the source inventory records LAME as statically linked into both helpers.
- Dynamic dependencies: macOS system frameworks and `/usr/lib` libraries only

FFmpeg configure options:

```text
--prefix=/private/tmp/ytdp-ffmpeg-official-1.8.7/prefix-macos11
--arch=arm64
--cc=clang
--disable-shared
--enable-static
--disable-debug
--disable-doc
--disable-ffplay
--enable-libmp3lame
--pkg-config-flags=--static
--extra-cflags=-mmacosx-version-min=11.0 -I/private/tmp/ytdp-ffmpeg-official-1.8.7/prefix-macos11/include
--extra-ldflags=-mmacosx-version-min=11.0 -L/private/tmp/ytdp-ffmpeg-official-1.8.7/prefix-macos11/lib
```

`MACOSX_DEPLOYMENT_TARGET=11.0` was set while compiling both LAME and FFmpeg.
The build does not enable `--enable-gpl` or `--enable-nonfree`.

## Binary Checksums

Unsigned build outputs:

- `ffmpeg`: `5bad10ebbd86cfb20211087c4aaf1788c9293835ce3a47d7e07556e3230bcd69`
- `ffprobe`: `8f8ec8c6b916cc65f48d52855d798b806edda65a3ed761feb0ab97e22dc28bfa`

Repository copies after ad-hoc signing:

- `ffmpeg`: `6460942f5665043fb23aab1964940afd7e1a707751b38142066e97381b00982d`
- `ffprobe`: `791a41a9821e4a3804f70050f67c2f4449a091ebf0b06dea178c54fe6d32a8e8`
