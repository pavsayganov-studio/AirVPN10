# Third-party notices for dpi/ and the bundled ciadpi

- **ByeDPI (`ciadpi`)** — MIT License, (c) 2024 hufrea — https://github.com/hufrea/byedpi.
  Built from source in CI at a pinned commit and bundled as `Resources/ciadpi`.
- **ByeByeDPI** — GPL-3.0 — https://github.com/romanvht/ByeByeDPI.
  `strategies.list`, `youtube.sites` and `googlevideo.sites` in this folder are a
  snapshot of `app/src/main/assets/proxytest_strategies.list`,
  `proxytest_youtube.sites` and `proxytest_googlevideo.sites` at commit
  `0851f0b` (2026-09-30). They are plain data (command-line option strings and
  hostnames). The app re-downloads the current files from the ByeByeDPI
  repository when the person presses the update button (🔍).

If the licensing of the bundled list matters for how you distribute Raketa,
check it with someone qualified: this note is a record of provenance, not legal advice.

Update 2026-10-04 (v0.13.1): the bundled `strategies.list` was re-compared with
ByeByeDPI's `proxytest_strategies.list` at commit 96a3c1f (2026-10-02) and is identical.
Raketa runs lines that use fake-packet options in an adapted form (those options removed)
because the macOS build of ciadpi does not have them; the bundled file is not modified.
