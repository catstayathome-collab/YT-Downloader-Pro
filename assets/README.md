# App Icon Sources

`AppIcon-1024.png` is the reviewed master for YT Downloader Pro 1.8.7.
`AppIcon.iconset/` contains all ten standard macOS 1x and 2x PNG representations.

The master was produced with the built-in ImageGen edit workflow from the prior
1.8.7 icon. The accepted edit preserves the hand-drawn cat, headphones, music
note, white background, and exact `catstayathome` text while increasing the
visible artwork from about 57% width to 64.8% width and 84.7% height.

The iconset was generated from the 1024 master with `sips`. On the build host,
macOS 26 `/usr/bin/iconutil` rejected even iconsets round-tripped from an existing
ICNS, so the final `AppIcon.icns` was composed with `icnsutil==1.1.0`. It was then
validated by both `icnsutil test` and a successful Apple `iconutil` extraction.

Final ICNS records:

- `icp4`: 16x16
- `ic11`: 16x16@2x
- `icp5`: 32x32
- `ic12`: 32x32@2x
- `ic07`: 128x128
- `ic13`: 128x128@2x
- `ic08`: 256x256
- `ic14`: 256x256@2x
- `ic09`: 512x512
- `ic10`: 512x512@2x
