# QuickJS Build Information

- Version: `2026-06-04`
- Source URL: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
- Source archive SHA-256: `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`
- Build date: `2026-08-12`
- Build host: Apple Silicon macOS
- Build command: `make -j 10 qjs`
- Bundled binary: `tools/qjs`
- Bundled binary SHA-256 before ad-hoc signing: `61cdcaa2f2ca66bdd86dbe114aad8e9dde0132f92338adda6b46191aedb31982`
- Bundled binary SHA-256 after ad-hoc signing: `233fba492335cff4e33ac9ac667f28afb9f9388f76773e1839c0bf6f90c7b000`
- Architecture: `arm64`
- Dynamic dependencies: `/usr/lib/libSystem.B.dylib` only
- License: MIT
- Upstream project and license: https://bellard.org/quickjs/

The binary is built directly from the official QuickJS source archive. It is bundled so yt-dlp can solve supported YouTube JavaScript challenges without relying on a user-installed Deno, Node.js, Bun, or Homebrew package.
