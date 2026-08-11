# QuickJS Build Information

- Version: `2026-06-04`
- Source URL: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
- Source archive SHA-256: `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`
- Build date: `2026-08-12`
- Build host: Apple Silicon macOS
- Build command: `MACOSX_DEPLOYMENT_TARGET=11.0 make -j 10 qjs`
- Bundled binary: `tools/qjs`
- Bundled binary SHA-256 before ad-hoc signing: `4aa2bb4684e0038d66af835d39890d7c38351c2e493da15454ae96be0017810c`
- Bundled binary SHA-256 after ad-hoc signing: `5851ca28fd6aec806474c233ea74865cac492d1f305c73d44e45a05b45d3f82f`
- Architecture: `arm64`
- Deployment target: `macOS 11.0`
- Dynamic dependencies: `/usr/lib/libSystem.B.dylib` only
- License: MIT
- Upstream project and license: https://bellard.org/quickjs/

The binary is built directly from the official QuickJS source archive. It is bundled so yt-dlp can solve supported YouTube JavaScript challenges without relying on a user-installed Deno, Node.js, Bun, or Homebrew package.
