# Raketa — Technical Handoff

**Current version:** v0.14.0
**Platform:** macOS 10.13 (High Sierra) through macOS 12.x (Monterey), Intel x86_64
**Status:** Production. Fully working, actively used by the owner (Pablo).

---

## 1. What this is

Raketa is a minimalist menu-bar VPN client for macOS, purpose-built for users in
Russia who need to bypass DPI-based blocking. It wraps **sing-box v1.14.3** as
the core proxy engine, using **VLESS + Reality + uTLS** to disguise traffic as
legitimate TLS connections to real sites (Chrome fingerprint impersonation).

It was previously named **PauloVPN / AirVPN**, then renamed to **Raketa**.
Repo, bundle ID, and all UI strings now say "Raketa" — do not reintroduce the
old names unless explicitly asked.

The person is not a professional iOS/macOS developer. They work via
**GitHub Codespaces + GitHub Actions**, applying changes as **complete bash
patch scripts** that rewrite whole files, then commit/tag/push to trigger the
Actions build. There is no local Xcode workflow. **Always deliver a single
self-contained bash script**, never a diff or partial snippet.

---

## 2. Architecture (do not change without explicit request)

### Why System Proxy, not a TUN VPN
Early versions tried a `utun` interface — this requires root, causes double
password prompts, and produces frozen/broken states when the core process
crashes without cleanup. **This was abandoned deliberately.** Current
architecture uses:

- **System HTTP/HTTPS/SOCKS proxy** via `networksetup`, pointed at
  `127.0.0.1`
- **sing-box** running as a plain background process (not a LaunchDaemon,
  not a TUN device)
- One **AppleScript `do shell script ... with administrator privileges`**
  call per operation (start / stop / force-off), never split into multiple
  privileged calls — this is what prevents the "double password" bug.

### Process lifecycle
- `startVPN`: kills any stray `sing-box`, sets system proxy via
  `networksetup`, launches `sing-box run -c config.json > log 2>&1 & echo $!`
  — **no `nohup`** (see §4, macOS 12 fix).
- PID is captured from the AppleScript result and stored in `self.corePID`.
- A **watchdog timer** (12s interval) checks liveness via `kill(pid, 0)` —
  essentially free, no process fork. Falls back to `pgrep -x sing-box` only
  if the PID was never captured.
- `stopVPN` / `forceProxyOff`: single AppleScript call, kills the process,
  resets all three proxy states off.
- On termination (`quit` or `onTerminate:`), a `self.stopping` guard
  prevents the shutdown sequence firing twice.

### Ports
| Port  | Type  | Purpose |
|-------|-------|---------|
| 10809 | mixed | System HTTP/HTTPS proxy (handles both HTTP CONNECT and SOCKS5 — **do not use type `http`**, see §4) |
| 10808 | socks | SOCKS5 — fallback for apps that don't read system proxy (e.g. Telegram) |
| 10810 | socks | Dedicated listener surfaced to the user as "Telegram MTProxy port" in the UI (in practice it's a plain SOCKS5 listener; Telegram connects to it fine as SOCKS5 despite the labeling) |

### YouTube / DPI bypass mode (v0.12.0)
Optional second mode, independent of the VPN. The VPN code path (config
generation, `startVPN`, `stopVPN`, routing rules above) is unchanged.

- **Engine:** `ciadpi` (ByeDPI, MIT) built from source in CI at a pinned commit
  and bundled in `Resources/`. It is spawned by the app as a *user-level* child
  process (no root, no TUN, no pf) listening on `127.0.0.1:10811`. Logic lives in
  `DPIEngine.m` (Foundation only); UI lives in the YOUTUBE section of
  `ViewController.m`.
- **Data path:** system proxy → sing-box (`config-yt.json`: inbounds 10809 mixed
  + 10808 socks; outbound `dpi` = socks → `127.0.0.1:10811`) → YouTube / Google
  video domain suffixes go to `dpi`, `final` = `direct`. Ordinary browsing never
  touches the desync proxy.
- **Exclusive with VPN** at the system-proxy level (one sing-box owns 10808/10809).
  The YouTube button is disabled while the VPN is on; pressing ВКЛ while YouTube
  mode is on first runs `ytStopSync` (reuses `stopVPN`), then starts the VPN.
  Switching strategy while active restarts only `ciadpi` (no password prompt).
- **Strategies (superseded in v0.13.4, section 15: the ByeByeDPI list is no longer bundled or
  tested, only the two host lists remain):** bundled snapshot in `dpi/` (`strategies.list`, `youtube.sites`,
  `googlevideo.sites`, copied from ByeByeDPI `proxytest_*` assets, GPL-3.0 repo —
  see `dpi/NOTICE.md`). The 🔍 button first re-downloads the three files from
  `raw.githubusercontent.com/romanvht/ByeByeDPI/master/...` (validated, then saved
  to `Application Support/Raketa/dpi_*`), then tests every strategy.
- **Search (reworked in v0.13.1; candidate set and DNS policy replaced in v0.13.4, section 15):**
  candidates = the ByeByeDPI lines this `ciadpi` can
  run as they are ("originals") plus an adapted form of every line that needs options it
  lacks (next bullet). Per candidate: start a throw-away `ciadpi` on `127.0.0.1:10820`,
  probe `www.youtube.com` + `i.ytimg.com` through it with `curl --socks5-hostname`
  (since v0.13.3 with DoH addresses: `--resolve` + `--socks4`, see section 14)
  (dead -> skip), else run the full battery (13 YouTube hosts + 6 googlevideo hosts,
  concurrent). A request passes by ByeByeDPI's own rule (`SiteCheckUtils`): an HTTP answer
  arrived and, if `Content-Length` was declared, the whole body arrived; for chunked pages
  the body must finish or pass 32 KB (the classic ~16 KB DPI freeze). Timeouts are
  connect 5 s plus stall detection (`-Y 1 -y 5`), not a hard total: v0.12.x used `-m 4/5`
  and a clean curl exit, which failed every merely slow strategy (TTL-based disorder waits
  for a TCP retransmit). Before the loop a control run tests the same hosts with no bypass.
  Rank = successes desc, mean time asc. Top 10 are shown in the menu; results are cached in
  `dpi_results.json` with a network signature (primary interface + router).
- **Search log:** every search overwrites `Application Support/Raketa/dpi_search.log`: the
  control run, then one line per candidate: `N[~]  ok/total  mean-s  failures  line`.
  Failures are `curl-exit x count` (28 timeout or stall, 35 TLS, 52 empty reply, 56 reset,
  97 SOCKS/DNS via the proxy, 1 = body shorter than declared). Read it first when a network
  gives "no working strategies". It deliberately contains no network signature.
- **macOS limitation and adaptation (v0.13.1):** upstream `ciadpi` enables the "fake
  packet" options (`-f -n -S -T -Y`) only on Linux/Windows (`FAKE_SUPPORT`). On macOS they
  are invalid options and the process exits. 37 of the 60 lines of the 2026-09-30 snapshot
  use them; v0.12.x skipped those lines, leaving 23 candidates. Now `DPIEngine` asks the
  binary (`ciadpi --help`) which of those options exist, cuts the missing ones and the
  fake-only modifiers (`-t -Q -O -l`) out of the line, and keeps the rest (split / disorder /
  OOB / tlsrec) as an *adapted* candidate shown as `N~`. `N` is always the line's position
  in the ByeByeDPI file. Adapted lines that collapse into an existing one are dropped
  (23 originals + 34 adapted = 57 candidates on that snapshot). An adapted line is not
  assumed to work: it goes through the same live test. Real fake packets on macOS stay
  open (roadmap 5.1).
- **Safety:** the strategy list comes from a third-party repo, so every line is
  split into argv tokens (never a shell) and each option is whitelisted; options
  that touch files, daemonize or change the listen address are rejected.
- **CPU:** no timers added. The existing watchdog is reused. Search is started only
  by the 🔍 button.
- **Failure isolation:** the `ciadpi` CI step is `continue-on-error`; without the
  binary only the YouTube row is disabled ("движок не найден").
- **Ports added:** 10811 (ciadpi, runtime), 10820 (ciadpi, search only).
- **State:** `ytActive`, `ytBusy`, `ytStartAfterSearch`; selected strategy in
  `NSUserDefaults` key `RaketaDPIStrategy` (raw strategy line is the identity;
  "№N" is its position in the current list).

### Theme: light / dark follows the system (v0.13.0)
- Two palette tables (`kRKPal` in `ViewController.m`: light RGBA, dark RGBA per colour).
  `rkSetPalette(dark)` fills the `rk*` globals; `+initialize` picks the palette that
  matches the system at launch.
- **Detection:** macOS 10.14+ → `NSApp.effectiveAppearance` (works with Auto);
  10.13 → global `AppleInterfaceStyle` ("dark menu bar and Dock"). Appearance names
  are string literals — `NSAppearanceNameDarkAqua` does not exist on 10.13.
- **Switching is event-driven:** `AppleInterfaceThemeChangedNotification`
  (`NSDistributedNotificationCenter`) → `applyThemeNow` → `rkRecolor:` walks the
  view tree and maps every layer/text/button colour from the old palette to the
  new one. A cheap re-check also runs in `viewWillAppear`. No timers.
- **`root.appearance` is set explicitly** to match the palette, so system controls
  (the server dropdown) never disagree with it. The bug it fixes: a light palette on a
  dark system produced white text on light buttons in the bottom row.
- The bottom-row / Telegram-panel buttons no longer use system bezels: `styleBtn:`
  gives them the same flat recipe as ↻ (gotcha #9), so they read the same on every
  macOS and in both themes. `flashButton:` keeps the button's text attributes.
- **Contrast is asserted, not eyeballed:** the patch script computes WCAG ratios for
  every text colour on every surface of both palettes and refuses to commit below 4.5:1.
  The light palette's grey/blue/green/orange/red were darkened slightly for that
  (e.g. green on the tinted ВКЛ button was 2.4:1).
- `NSPopover.appearance` follows the theme too (`AppDelegate syncPopoverAppearance`).

### Menu-bar quick actions (v0.13.0)
Right-click (or Ctrl-click) on the rocket icon in the menu bar opens a menu: Подключить VPN,
Отключить VPN, Обход YouTube (DPI) ✓, Выйти. Left-click still toggles the window.
- `AppDelegate`: `sendActionOn:` mouse-up of both buttons; on right-click the menu is
  attached to the status item, `performClick:` is called, then it is detached again.
- Items are enabled from live state (`ViewController` readonly getters that never load
  the UI). YouTube is disabled while the VPN is on (mutually exclusive, same as the button).
- Actions call the same entry points as the buttons (`toggle`, `ytToggle`); the VPN code
  is untouched. «Подключить VPN» with no saved keys opens the window instead of failing silently.

### Routing rules (`route.rules` in the generated sing-box config)
Direct (bypass VPN): local subnets, `apple.com`/`icloud.com`, `.ru`/`.рф`
domains. Everything else (including Telegram) routes through the active
VLESS outbound. **Do not route Telegram traffic to `direct`** — this was
tried and reverted; see §5 history for why.

### Subscription parsing
- Accepts a raw `vless://` link, a list of `vless://` links (newline or
  base64-encoded), or a JSON subscription with a sing-box-style `outbounds`
  array.
- Parser filters `outbounds` to real server types only
  (`vless, vmess, trojan, shadowsocks, hysteria2, tuic, trojan-go`) and
  **explicitly excludes** meta-outbounds (`selector, urltest, dns, direct,
  block, dns-out`). This exclusion is critical — a `selector`/`urltest`
  group in the config caused a Telegram reconnect-storm that froze the core
  early in development. Do not remove this filter.
- After every successful parse, `persistOutbounds:` writes the canonical
  outbounds array to `subscription.json` in Application Support. This file
  — not the raw pasted text — is what gets reloaded on next launch. If you
  touch persistence logic, preserve this: the saved URL/text in
  `NSUserDefaults` is only used for **manual refresh**, not for the
  automatic reload path.

---

## 3. File map

```
Raketa.xcodeproj-less repo (compiled directly via clang in CI)
├── main.m                          — trivial NSApplicationMain entry point
├── AppDelegate.m / .h              — NSStatusItem + NSPopover host
├── ViewController.m / .h           — ALL UI + VPN logic lives here (~1300 lines)
├── CoreUpdater.m / .h              — in-app sing-box core updater (v0.14.0, Foundation only)
├── RKSubscription.m / .h           — subscription request headers (UA, HWID), Userinfo, error texts (v0.14.0)
├── DPIEngine.m / .h                — YouTube DPI engine: ciadpi process, strategy list,
│                                     search/ranking, YouTube-only sing-box config (v0.12.0)
├── dpi/                            — bundled ByeByeDPI snapshot (v0.13.4: host lists only; was: strategies.list,
│                                     youtube.sites, googlevideo.sites, NOTICE.md
├── Info.plist                      — bundle metadata, version string
├── AppIcon.svg                     — icon source (rocket on the blue gradient, body on the macOS icon grid)
├── generate_icon.py                — SVG → .icns build-time converter (cairosvg + iconutil)
└── .github/workflows/build.yml     — CI: builds sing-box + ciadpi, generates icon,
                                       compiles app, codesigns ad-hoc, releases .zip
```

There is no `.xcodeproj`. The app is compiled with a raw `clang` invocation
in CI:
```
clang -fobjc-arc -framework Cocoa -framework SystemConfiguration \
  -arch x86_64 -mmacosx-version-min=10.13 \
  -o Raketa.app/Contents/MacOS/Raketa \
  main.m AppDelegate.m ViewController.m DPIEngine.m CoreUpdater.m RKSubscription.m
```

`sing-box` is not built any more (v0.14.0): CI downloads the official release asset
`sing-box-<ver>-darwin-amd64-legacy-macos-10.13.tar.gz` and checks it against the SHA-256 pinned in
`build.yml` (`SING_BOX_SHA256`); section 18 has the details. `ciadpi` is still built from source.

---

## 4. Known platform gotchas already fixed — do not reintroduce

These are hard-won fixes. If a future patch accidentally reverts one of
these, the bug **will** come back.

1. **`nohup` breaks on macOS 12+.** `do shell script ... with administrator
   privileges` provides no controlling terminal on Monterey. `nohup`
   detects this and exits with `ENOTTY` ("Inappropriate ioctl for device"),
   killing the launch before sing-box even starts. Fixed in v0.9.5 by
   dropping `nohup` entirely — plain `&` backgrounding is sufficient; the
   child reparents to `launchd` when the AppleScript shell exits. This
   worked by accident on 10.13 (lenient `nohup`) and was invisible until
   tested on 12.x.

2. **`http` inbound type causes `protocol wrong type for socket`.** sing-box's
   `"type": "http"` inbound cannot handle `CONNECT` tunneling reliably in
   all client scenarios. Fixed by using `"type": "mixed"` for the main
   system-proxy port (10809) — it accepts both HTTP CONNECT and SOCKS5 on
   one port.

3. **`selector`/`urltest` outbound groups in a subscription cause a Telegram
   reconnect storm.** These trigger background URL-test pings that overload
   the connection table on the client and cause the core to hang. The
   subscription parser filters them out unconditionally (see §2).

4. **Routing Telegram to `direct` breaks Telegram** (it's blocked at the ISP
   level in Russia) — but routing it through the VPN via a `selector` group
   caused the reconnect storm above. The fix was doing *both*: remove the
   `selector` group AND let Telegram traffic go through the VPN via the
   plain VLESS outbound (`final: tag`). Telegram now works standalone once
   the user manually sets its in-app proxy to `127.0.0.1:10808` (SOCKS5) or
   `:10810`.

5. **`forceProxyOff` in `loadView` fired unconditionally**, causing an
   unwanted password prompt on every popover open even when no VPN was
   active. Fixed by checking `isSystemProxyEnabled` (via
   `SCDynamicStoreCopyProxies`) first — only calls the privileged AppleScript
   if a proxy is actually set.

6. **`cText`/`cSub`/etc. as color variable names collide with `AERegistry.h`**
   (`CoreServices` framework defines `cText = 'ctxt'` as an `OSType` enum).
   All theme colors are prefixed `rk*` (`rkText`, `rkSub`, `rkAccent`, ...)
   to avoid this. **Never use bare 2–5 letter names for globals** in this
   file — Apple's Carbon-era headers are still linked in via Cocoa and
   define a lot of short 4-char OSType constants.

7. **Properties starting with `copy` violate ARC's method-family
   convention** (ARC assumes anything starting with `copy`/`new`/`alloc`/
   `init`/`mutableCopy` returns an owned object). A property named
   `copySecretBtn` failed to compile. Renamed to `secretCopyBtn`. Avoid
   `copy*`, `new*`, `alloc*`, `init*` as property/method name prefixes
   unless you intend ARC ownership semantics.

8. **`contentTintColor` on `NSButton` is macOS 10.14+ only** but the
   deployment target is 10.13. Any use of it must be removed or guarded.
   Button title coloring on 10.13 is done via `attributedTitle` with an
   explicit `NSForegroundColorAttributeName` — this is the only reliable
   cross-version method.

9. **`NSBezelStyleRounded` clips/hides Unicode glyphs at small button
   sizes on 10.13** (confirmed with ↻ U+21BB). Icon-only buttons use
   `bordered = NO` + explicit `CALayer` background/border + `attributedTitle`
   instead of the system bezel.

---

## 5. Design system (current, v0.13.0)

**Theme:** soft blue, light, opaque (explicitly *not* translucent —
`NSVisualEffectView` was removed early on because it caused the popover to
look muddy layered over the desktop; every surface now has a solid
`CALayer.backgroundColor`).

| Токен | Светлая | Тёмная | Назначение |
|---|---|---|---|
| `rkBG` | `#E0EDFA` | `#1C212B` | фон окна |
| `rkSurface` | `#CCE3F5` | `#141A21` | хедер, нижняя панель |
| `rkCard` | `#D4E8F7` | `#242B38` | панель Telegram |
| `rkBorder` | `#9EC7EB` | `#404F66` | разделители, границы |
| `rkText` | `#1A1A1A` | `#F0F0F0` | основной текст |
| `rkSub` | `#575757` | `#B2B2B2` | вторичный текст |
| `rkAccent` | `#0F54AD` | `#73B2FF` | ссылки, моноширинные данные |
| `rkGreen` | `#08571F` | `#66D180` | «подключено» |
| `rkOrange` | `#8C4205` | `#FAAD47` | предупреждение |
| `rkRed` | `#A80F0F` | `#FF8078` | ошибка |
| `rkBtn` | `#B8D6F0` | `#2E3B4C` | заливка второстепенных кнопок |
| `rkField` | `#FFFFFF` | `#293342` | поля ввода (белое / тёмное) |
| `rkTintGreen` | `#0F732E` α0.15 | `#66D180` α0.10 | подсветка активной кнопки (alpha) |
| `rkTintAccent` | `#1A66C7` α0.15 | `#73B2FF` α0.20 | подсветка основной кнопки (alpha) |

Typography follows Apple's macOS 10.13 HIG as closely as is practical for a
custom (non-native-chrome) popover UI:
- Base control text: 13pt regular
- Secondary/section labels: 11pt
- Micro text (credit line): 9pt, `HelveticaNeue-Light`, `NSKernAttributeName
  0.8` tracking (prevents glyph crowding — a real bug that occurred with
  the default kerning at 9pt)
- 20pt outer margins, 12pt between groups, 8pt between related controls
  (all per HIG spacing conventions)

**Fonts and contrast on old vs new macOS (v0.13.0):** system font only (`systemFontOfSize:weight:`
→ SF on 10.11+); no bundled fonts and no text outlines/strokes — a stroke smears 9–13pt glyphs on
non-Retina screens, contrast does the job instead. Small text on buttons is *Medium* (light-on-dark
text looks thinner, and 10.13 renders layer-backed text with grayscale antialiasing). Colours carry
the legibility: every text colour is ≥ 4.5:1 on every surface in both palettes. Emoji icons (🔍) keep
their own colours; glyph icons (↻ ▾ and the drawn paper plane) take the palette text colour. The 9pt credit line keeps
`HelveticaNeue-Light` (approved, untouched).
- Push buttons: 21pt height where possible (HIG standard); the main
  connect toggle is a custom 36pt-tall capsule (`cornerRadius = height/2`)
  since it's a primary action, not a standard push button

**Window layout (popover, `kW=300`, `kH=373`, top-down; the map at the top of
`ViewController.m` is the source of truth):**
```
0–32     header: 🚀 Raketa (left) · version (right)
46–95    ПОДПИСКА: label, [＋ Добавить ключи (224pt)] [↻ (28pt square)]
113–160  СЕРВЕР: label, dropdown of parsed outbound tags
174–188  status row: colored dot + status text
202–238  connect toggle: full-width capsule (○ ВЫКЛ / ● ВКЛ)
252–301  YOUTUBE (v0.12.0): label + strategy caption, then
         [🔍 28pt] [▶ Смотреть YouTube 188pt] [▾ 28pt]
317–373  bottom bar: [Логи] ··· credit line ··· [paper plane][Выход]
```

The Telegram settings panel is **not** a big always-visible button anymore
(removed in v0.9.4). It's a small square paper-plane icon (drawn, `RKPaperPlaneImage`; was the `✈` character until v0.13.4) in the bottom
bar, `toolTip = "Настройка Telegram"`, which slides open a 170pt panel
below the main view and resizes the popover via
`self.preferredContentSize`. Contains two methods: MTProxy-style details
(port 10810) and SOCKS5 fallback (port 10808), both with a `tg://proxy?...`
/ `tg://socks?...` deep-link button plus a "copy secret" button.

The credit line at the bottom — **"Ради вас старался Пашенька"** — is a
permanent, deliberate personal touch requested by the owner. Keep it in
any future redesign unless explicitly told to remove it.

---

## 6. CPU-load discipline (explicit standing priority)

The person has repeatedly emphasized **minimum CPU/resource load** as a
top-level constraint, above visual polish. Concretely, this means:

- The watchdog uses `kill(pid, 0)` (a syscall, ~free) instead of spawning
  `pgrep` (a process fork) on every tick. `pgrep` is only used as a one-time
  fallback if the PID was never captured.
- The watchdog interval is 12s, not tighter.
- The network interface name (`networksetup -listnetworkserviceorder`
  parsing) is detected **once** at launch and cached in
  `self.cachedIface` — never re-queried per VPN start/stop.
- Colors are allocated once in `+initialize`, not per-view-build.
- Subscription file reads happen on a background `QOS_CLASS_UTILITY` queue,
  never blocking the main thread.
- No polling, no animation timers, no background network activity beyond
  what the user explicitly triggers (manual "add keys" / "refresh keys"
  buttons — deliberately **not** automatic, per explicit request).

Any future change that adds a recurring timer, a per-frame animation, or a
background NSTask spawn should be scrutinized against this constraint
before being added.

---

## 7. Build & release process

Every change ships as a single self-contained Python patch script
(`patch_raketa_<ver>.py`) that the person runs inside GitHub Codespaces from
the repo root: `python3 patch_raketa_<ver>.py`. The script backs up touched
files (`cp X X.bak<ver>`), applies anchored edits (each anchor must match
exactly once), runs its own checks, then `git commit` + `git push origin main`
and, after a successful push, deletes its own backups and itself - no `.bak*` file is ever
left in the repo (after a failed check or push the backups stay for recovery).

Releases are cut by hand: GitHub → Actions → **Build Raketa** → *Run workflow* →
type the version (optionally tick *dry run* to build and verify without publishing).
Pushing a tag does **not** start a build. The workflow (rewritten in v0.13.0):
- **Least privilege:** `permissions: {}` at the top; the `build` job gets `contents: read`,
  only the `release` job gets `contents: write`. Third-party actions are pinned to full
  commit SHAs (comment = version); Dependabot (`.github/dependabot.yml`) proposes bumps weekly.
- **No script injection:** the version input reaches shell only through `env`, never `${{ }}`
  inside `run:`. Format `X.Y.Z` is validated and an existing tag is rejected *before* building.
- **`concurrency`** group serialises releases (no cancel); every job has `timeout-minutes`.
- **Caching:** the built `sing-box` binary (key = version + Go) and `ciadpi` (key = pinned SHA)
  are cached, so a normal release skips the multi-minute core build.
- **Build job:** compiles sing-box (Go 1.20, only on cache miss) and `ciadpi` (optional,
  `continue-on-error`), generates the icon, compiles the app, **stamps the release version
  into `Info.plist`** (the UI label reads it back from the bundle), ad-hoc codesigns, then
  *asserts* x86_64 + min macOS 10.13 + a valid signature, zips and writes a SHA-256 file.
- **Release job:** the tag is created **by `gh release create` only after a successful build**
  (a failed build no longer leaves a stray tag). Notes = commit subjects since the nearest
  tag *in this commit's ancestry* (`git describe`), minus `chore:`/`ci:`; the zip and the
  `.sha256` are attached and the release is marked Latest.
- Release hygiene tool: `python3 tools/cleanup_releases.py` (dry-run) / `--apply` removes the
  stray `latest` and v1.x–v11.x tags/releases left by the old auto-bump workflow and
  rewrites boilerplate release notes into real changelogs.

**Patch script conventions the person expects:**
- One complete, self-contained `.py` file per iteration, runnable start to
  finish with `python3 patch_raketa_<ver>.py`
- Always backs up touched files first (`cp X X.bakXYZ`) and removes those backups after a
  successful push, together with the script itself (nothing is left to clean up by hand)
- Runs its own checks, commits and pushes by itself, then deletes itself;
  the release is cut afterwards in Actions → Build Raketa → Run workflow
- Version number bumped consistently across: UI version label string in
  `ViewController.m`, `Info.plist` (`CFBundleVersion` +
  `CFBundleShortVersionString`), and the release notes body in `build.yml`
- Comments in the generated Objective-C explain *why* a fix exists,
  referencing the platform gotcha it addresses (see §4) — this has proven
  valuable for not re-breaking things across iterations

**Before delivering a patch:** verify brace balance and bash syntax
(`bash -n script.sh`) before presenting it — a truncated heredoc or
mismatched brace has silently broken a delivered patch before (see
project history around v0.9.7 iteration).

---

## 8. Open items / things to watch

- **Apple Silicon**: build is `x86_64` only (`-arch x86_64`). Runs fine
  under Rosetta on M-series Macs but hasn't been asked for a universal
  binary. Don't add `arm64` unless requested — could affect the 10.13
  compatibility story (Apple Silicon Macs never shipped 10.13, so a
  universal binary changes nothing for the primary use case but adds
  build complexity).
- **Codesigning is ad-hoc** (`-s -`), not a Developer ID cert. Users will
  see a Gatekeeper warning on first launch and need to right-click → Open,
  or the person distributes with instructions to that effect. Not
  currently a reported pain point — no action needed unless asked.
- **macOS 12.7.6 (21H1320)** is the newest OS version explicitly confirmed
  working (after the `nohup` fix in v0.9.5). Nothing has been tested on
  13/14/15 — if the person reports issues there, check for further
  AppleScript/`do shell script` sandboxing changes in newer macOS releases
  as the first hypothesis (this has been the pattern twice now).
- The `.icns`/SVG icon pipeline (`generate_icon.py` + `cairosvg`) is new
  as of v0.9.2 — if `cairosvg` ever becomes unavailable on GitHub's
  `macos-latest` image, the script has documented fallbacks to
  `rsvg-convert` (librsvg) and `qlmanage`, in that priority order.

---

## 9. Tone / working style notes for continuing this project

- The person is technically capable but works exclusively through
  Codespaces + generated patch scripts, not local Xcode. Never assume
  Xcode project file editing — always emit `.m`/`.h`/`.plist`/`.yml`
  content as heredocs inside a bash script.
- They ask precise, scoped questions and expect precise, scoped fixes —
  avoid unrelated refactors "while you're in there." Several past patches
  explicitly note "everything else untouched."
- Diagnose before coding: they respond well to a short root-cause
  explanation before the patch, especially for platform-specific bugs
  (nohup, ARC naming, framework symbol collisions). Keep this pattern.
  Explaining *why* something is broken, not just *what* changed, is part
  of what earned trust here.
- They've expressed clear satisfaction with the current v0.9.7 state
  ("работает прекрасно и выглядит красиво", "она идеальна" for 10.13).
  Treat the current architecture and design system as the stable baseline
  — changes should be additive/surgical, not rewrites, unless explicitly
  requested.

---

## 10. Findings from the v0.12.0 source audit

- **Watchdog fast path (not changed, needs a decision):** sing-box is launched
  via `do shell script ... with administrator privileges`, so it runs as root.
  `kill(pid, 0)` from the user-level app then returns -1 with `EPERM` even though
  the process is alive, so by reading the code `coreAlive` never takes its fast
  path and falls through to `pgrep` on every 12 s tick. A one-line fix would be to
  treat `errno == EPERM` as alive. Verify on a Mac before relying on this.
- **Docs drift corrected in v0.12.0:** version (was v0.9.7), window layout
  (was kH=278), release flow (was "push a tag"; it is `workflow_dispatch`),
  patch-script conventions (`.py`, self-deleting, commits and pushes itself).
- **Strategy count:** the ByeByeDPI list had 60 strategies on 2026-09-30 (not 72).
  The update button picks up growth automatically.

---

## 11. Release hygiene and session state (v0.13.0)

- **Why releases looked "old":** the repo carried ~46 stray tags (`latest`, v1.0 … v11.0,
  v9.1.3) from the former auto-bump workflow, and every release body was the same
  boilerplate. The new workflow never auto-bumps; `tools/cleanup_releases.py` removes the
  strays (dry-run first) and rewrites the notes.
- **Version source of truth:** the workflow input. `Info.plist` in the repo is bumped by
  patch scripts and overridden at build time; the UI label reads the bundle value.
  v0.12.1 was released from a tree whose plist said 0.12.0 — that mismatch is now a CI warning.
- **Verified on a real artifact (v0.12.1 zip):** `Raketa`, `sing-box` and `ciadpi` are x86_64
  with minimum macOS 10.13; `ciadpi` and `dpi/` are bundled.
- **Not verified on a Mac (needs a manual pass on 10.13 and 12):** dark palette rendering,
  the right-click menu, the strategy ▾ menu inside the popover, 🔍/▾ glyph rendering,
  and real-world DPI search results.
- **Next candidates:** roadmap §5 (fake-packet strategies on macOS, YouTube alongside the VPN)
  and §6 (build provenance attestation, runner pinning).

---

## 12. DPI search rework (v0.13.1)

- **Finding:** the bundled `dpi/strategies.list` is line-for-line the ByeByeDPI list
  (`proxytest_strategies.list`, 60 lines; re-compared with ByeByeDPI `96a3c1f` of 2026-10-02),
  and `ciadpi` is built from the commit ByeByeDPI itself pins (`ba53229`). "Use the ByeByeDPI
  strategies" was already true; the search failed for other reasons.
- **Causes found** (code reading, plus building `ciadpi` without its Linux branch to get the
  macOS option set): (1) only 23 of the 60 lines can start on macOS; (2) the pass rule was
  stricter than ByeByeDPI's. Which of the two dominates on a given network is unknown without
  `dpi_search.log`.
- **Changes:** adapted candidates for fake-packet lines, ByeByeDPI's pass rule, control run
  without bypass, `dpi_search.log`. `ViewController.m` only gained the `~` marker. No VPN,
  routing, layout or colour code was touched.
- **Search time:** 57 candidates instead of 23; a network where everything is dead takes about
  5-6 minutes (about 5 s per dead candidate).
- **Verified off-device** (Linux/GNUstep rig that compiles the real `DPIEngine.m`): candidate list
  equals an independent reference implementation; curl-output parser unit tests; a full search
  through the real `ciadpi` against a local TLS server that misbehaves on purpose (truncated
  body, freeze after 8 KB, hang-up) ranks the originals and adapted lines as expected.
- **Not verified:** anything on a real Mac or a real DPI network. If a network still yields
  nothing, `dpi_search.log` shows whether the control run was blocked, whether strategies reset
  (56/35), stall (28) or never reach the proxy (97).

---

## 13. Manual choice, macOS-first candidates, diagnosis (v0.13.2)

- **Why:** after v0.13.1 the search still found nothing on the person's Mac, and with no
  result there was no way to try a strategy by hand.
- **Manual choice:** the menu behind the down-arrow button now has "Все стратегии (N)": every
  candidate (macOS-first `M..`, ByeByeDPI `N`, adapted `N~`) with its last ok/total (`—` = not
  tested), selectable whether or not the search confirmed it. A hand-picked strategy shows its own
  `№12~ · 0/19` in the caption. "Журнал поиска…" opens `dpi_search.log`. `DPIResult.label` is
  the text after "№"; `numberForStrategy:` is 1000+k for `M` lines.
- **macOS-first candidates (`M`, tested first):** `DPICuratedLines()`. Derived from upstream's
  README, not measured: on a BSD-style stack the retransmit after a TTL=1 "disorder" starts at the
  lost position (README: "Windows"), so upstream recommends `--split 1+s --disorder 3+s` there;
  OOB inside the SNI (`--oob 3+s`); `--disoob 3 --disorder 7`; plus TLS-record splits at the SNI,
  which do not depend on the OS. A line equal to a ByeByeDPI entry is skipped (its number wins).
- **Two control runs** before the candidates: the 19 hosts directly, and through `ciadpi` with NO
  desync option. `diagnosisNote` (menu) and the log say which case it is: direct fine + proxy broken
  = our proxy chain (not the strategies); both blocked = only a better strategy helps; direct fine
  = nothing visible to bypass.
- **Dedupe key** is now canonical (`--split 1+s` == `-s1+s`, `-aN` ignored), so equal lines are
  not tested twice.
- `dpi_results.json` gained `all` (every tested candidate, failures included), `pass_ok/pass_n`, `curated`.
- **Still not possible on macOS:** real fake packets (upstream gets them from a zero-copy
  `sendfile` trick that only exists for Linux/Windows). Hidden `-Z/-W` (wait between parts) is used
  since v0.13.3 (section 14), and the `M` set described above was replaced there.
- **Not verified:** anything on a real Mac or a real DPI network.


---

## 14. DNS over HTTPS for the YouTube route, paced strategies (v0.13.3)

- **Root cause found in the 2026-10-07 log:** all 67 candidates ended at `probe fail 28x2`, and the
  two control runs ("direct", "proxy, no desync") were identical at 3/19 with `28x16`. A result
  that does not depend on the strategy cannot be about the strategy. Since February 2026 Russian
  networks stop answering (or poison) plain DNS for YouTube names and hijack UDP/53 to public
  resolvers; `getaddrinfo()` hangs, curl reports 28 "Resolving timed out", and `ciadpi` resolves
  SOCKS5 domain names with the same `getaddrinfo()`. So no strategy ever got to send a
  ClientHello. This is a hypothesis built on that evidence, not a measurement: the new log says
  which it is (see below). Roadmap 5.3 had predicted this.
- **Search:** a DNS stage runs first. The system resolver is asked for `www.youtube.com` (4 s cap),
  then literal-IP DoH endpoints (`DPIDoHServers()`: 1.1.1.1, 8.8.4.4, 1.0.0.1, 9.9.9.9, 8.8.8.8,
  RFC 8484 GET through `curl`) until one answers; all 19 hosts + 2 probes are resolved over it.
  Every curl then uses `--resolve name:443:ip` and, through the proxy, `--socks4` (a name the DoH
  did not know counts as failure `6` without a request). No DoH answer = the old behaviour
  (`--socks5-hostname`, system DNS).
- **Runtime:** `-[DPIEngine youtubeOnlyConfigWithInbounds:]` (now an instance method) adds, when a
  validated DoH endpoint is stored (`dpi_results.json` keys `doh`, `dns_bad`): a sing-box `dns`
  section (`doh` server for the YouTube suffixes, `local` = system resolver for everything else,
  `final: local`) and makes the `dpi` outbound SOCKS**4**. sing-box's SOCKS4 client resolves the
  destination itself and sends an IPv4 address, so `ciadpi` never resolves anything. Verified
  off-device with the real sing-box 1.8.11 and the pinned `ciadpi` against a local TLS server
  (`ciadpi -x 2` shows `new conn ... addr=127.0.0.1:...`, the SNI cut fires). Not verified on a
  real Mac or against real DoH.
- **Search log (`dpi_search.log`)** now starts with `dns:` lines: the system answer (an IP or
  `timeout`), each DoH endpoint tried, how many names resolved; then three control runs: `direct,
  system DNS`, `direct, DoH addresses`, `proxy, no desync`. Reading it: system DNS `timeout` and
  `direct, DoH addresses` much better than `direct, system DNS` = DNS was the blocker;
  `direct, DoH addresses` still ~3/19 = the filter is on the wire (then the strategies matter,
  and if every one fails identically the blocker is not the ClientHello).
- **Menu:** `diagnosisNote` leads with the DNS finding when the system resolver was unusable.
- **Strategies:** the old `M` set is replaced (see `DPICuratedLines()` for the rationale per line):
  SpoofDPI's per-byte "sni" split, Xray/v2rayN-style 10-30 B fragments, and paced variants of the
  upstream README recipes. The new element is pacing: on a non-Linux `ciadpi`
  `sock_has_notsent()` is a stub, so nothing waits for a part to leave before the TTL is restored
  or the next part is sent; the hidden `-Z` (wait after each part) with `-W <ms>` does. Both are
  now in the option whitelist (`-Z` takes no value, `-W` takes one; `--wait-send`, `--await-int`).
  Line `-r5+s -s25+s -a1 -At,r,s -s50 -r5+s -s50+s -a1` (ByeByeDPI #24) is excluded: `ciadpi`
  exits at once on it (`REJECTED` in the log). The adapted `~` lines were NOT removed: the
  2026-10-07 result cannot tell strategies apart, so none is proven dead.
- **↻ button:** its attributed title was the only icon-button title without a centered paragraph
  style (`ytSetTitle:` and `styleBtn:` have one); it now has the style and `alignment = center`.
  The visual cause is not confirmed (no Mac was available) - if it is still off, measure the
  glyph's real bounds before touching the frame. The «Добавить ключи» button has the same recipe
  gap and was left alone (not reported).


---

## 15. Evidence-driven cleanup: wire probe, 10 candidates, DoH as fallback (v0.13.4)

- **Log of 2026-10-09 (v0.13.3, 68 candidates):** `dns: system resolver www.youtube.com -> <Google
  address>` (it answers), DoH 1.1.1.1 no answer in 0.3 s, DoH 8.8.4.4 answers, `direct, system DNS`
  3/19 (15 x curl 28, 1 x 6), `direct, DoH addresses` 3/19 (16 x 28), `proxy, no desync` 3/19, and
  every candidate `probe fail 28x2`. **Correction of section 14:** the DNS hypothesis was wrong on
  this network. With the system resolver working, DoH addresses changed nothing; the filter is on
  the wire. The three controls being identical means the log cannot tell strategies apart - and
  the reason is not the harness: the same three hosts pass through ciadpi with no desync, so the
  chain works.
- **Why every candidate is dead (strong evidence, not a measurement on the person's network):**
  (1) all 68 lines are plain cuts of the ClientHello - the macOS ciadpi has no fake packets
  (`FAKE_SUPPORT` is `__linux__ || _WIN32`; Linux sends the fake with `vmsplice`+`splice`, Windows
  with `TransmitFile`, both zero-copy so the retransmit carries the real bytes); (2) the zapret
  community list "zapret-discord-youtube" (Flowseal, 528 commits, last change 2026-10-01) has 21
  TCP/443 rules for the YouTube host list, all with `fake`, `seqovl` (TCP sequence overlap) or
  `hostfakesplit`, none a plain split/disorder (the last `split2` rule went in 2025; every rule
  also sets `--ip-id=zero`; the default `general` uses `multisplit` + `seqovl=681` with a
  google.com ClientHello as the overlap pattern); (3) FOCI 2025 (Niere et al.) found TSPU now
  reassembles TCP: TCP segmentation alone or TLS-record fragmentation alone no longer beat its ECH
  block, both together still did; a net4people report of June 2026 says Iran's DPI reassembles
  too and defeats 10-30 B fragments with 10-20 ms pauses (secondary summaries of both were used;
  re-read the originals before quoting them). The GFW is different: 2026 lab tests still saw it
  beaten by 1-5 B fragments, and not by anything for an IP that is on its blocklist.
- **What SpoofDPI does on macOS (v1.5.4, read in source):** its fake ClientHello is a *raw packet*
  written through pcap/BPF (needs root) with the learned hop-count TTL and a random sequence
  number, sent before the real hello; the per-byte SNI split and the TTL=1 "disorder" are only
  the second half. That is why "SpoofDPI works on macOS" and "plain ciadpi cuts do not" can both be
  true. It is Go 1.2x, so it cannot run on macOS 10.13 - the primary target.
- **DNS (what the sources say):** since 2026-02 YouTube names are gone from Russia's national DNS
  (NSDI) and YouTube is blocked, but foreign public resolvers stayed reachable (Mediazona,
  2026-04); on 2026-07-03 8.8.8.8 stopped answering over TCP (DoH, DoT, TCP/53) while 8.8.4.4 kept
  answering everything; plain UDP/53 to public resolvers is unreliable. No resolver "bypasses"
  an SNI filter: DNS only matters when the system answer is unusable.
- **Changes:** (1) *Wire probe* - after the DNS stage the search asks the same address with SNI
  `www.youtube.com` and `www.google.com` (direct curl, `--resolve`) and logs where each dies:
  `no TCP handshake` / `TCP up, TLS never finished (stall)` / `reset during TLS` / `TLS completed`,
  then `wire verdict:` (SNI filter / address or route blocked / not name-based / no filter). It is
  direct on purpose: through the proxy the SOCKS reply hides TCP-vs-TLS. The verdict is kept in
  `dpi_results.json` (`wire`, `wire_sni`) and leads `diagnosisNote`. (2) *Candidates* - 10
  hand-written stream-cutting lines (`DPICuratedLines()`, rationale per line in the comment);
  the ByeByeDPI lines and the adapted `~` forms are no longer tested, `dpi/strategies.list` is
  deleted, `updateListsSync` refreshes only the two host lists, `DPIResult.adapted` is gone,
  `coverageNote` flags results of the old 68-line format. A search takes about a minute.
  (3) *DNS policy* - DoH is tried only when the system answer is unusable; DoH order is 8.8.4.4,
  1.0.0.1, 9.9.9.9, 1.1.1.1, 8.8.8.8; the runtime config uses DoH + SOCKS4 only when the last
  search recorded `dns_bad` (before, a stored DoH endpoint was used even when system DNS worked).
- **Untouched:** VPN path, VLESS/Reality/routing, credit line, layout, colours, ciadpi build step.
- **Not verified:** anything on a real Mac or a real DPI network. Verified off-device: the patch
  applied to a scratch clone, brace balance, a differential clang syntax check of `DPIEngine.m`
  against the unmodified file (legacy GNUstep runtime, so a baseline of platform errors remains),
  and the curl `-w` timing fields against local servers.
- **Reading the next log:** `wire verdict: SNI filter` + all candidates 0/19 = the filter reads the
  name and reassembles; only fake packets can help (macOS: raw injection as root, roadmap 5.1).
  `wire verdict: address or route blocked` = no desync of any kind helps, route YouTube through
  the VPN instead. `TLS completed` for YouTube = the filter is not on this network right now.


---

## 16. Dev tooling and the next step (after v0.13.4)

- `tools/test_patch.sh PATCH.py [SOURCE]` runs a patch script end-to-end (apply, checks, commit,
  push, self-delete) in a scratch clone with a local bare origin, then runs the syntax check.
  `tools/objc_diffcheck.sh [BASE_REF]` compiles `DPIEngine.m` and the base revision with clang on
  the legacy GNUstep runtime (Linux) and reports only NEW error classes; a baseline of platform
  errors (no ARC, no object subscripting, no NSURLSession/SystemConfiguration) always remains, so
  a pass means "no new class", not "compiles on macOS". Installs its toolchain on first use.
- `dpi-research.md` is the digest of everything learned about DPI bypass (evidence labelled
  measured / source / summary / inferred); `project_custom_instructions.md` is the project's
  instruction text (the repo is the code source of truth: clone it, do not ask for a repomix).
- **Next step (decided):** path A, experiment first - a standalone lab tool (`tools/rkfake-lab.c`,
  root, raw socket) that injects fake ClientHellos before the real one and prints, per variant,
  whether a ServerHello comes back; nothing touches ciadpi or the app until it shows a working
  variant. Gate: the `wire verdict:` line of the v0.13.4 search log. Fallback path B (YouTube
  through the VLESS outbound) only with the owner's explicit OK. Full spec: `dpi-research.md` section 5.


---

## 17. UI polish: menu-bar glyph, app icon, Telegram icon (v0.13.5)

- **Menu bar:** the status item shows only a monochrome rocket, no "Raketa" text. It is a
  *template* image drawn by `RKRocketGlyph()` in `AppDelegate.m` (18 pt canvas, rocket 16 pt,
  black on transparent; macOS tints it for the light/dark menu bar like the other status icons).
  Tooltip "Raketa" is the only remaining label. The popover header keeps «🚀  Raketa».
- **App icon (Dock / Finder / Launchpad):** `AppIcon.svg` redrawn - the same rocket (colour: white
  hull, red nose and fins, blue porthole, orange flame) on the same blue gradient. The body is now
  824/1024 of the canvas (macOS icon grid, corner radius 22.4% of the body); before, the rounded
  square filled the whole canvas, which is why the icon looked bigger than every other one. The CI
  pipeline is unchanged (`generate_icon.py` + cairosvg render the new SVG). To change the size,
  edit `width/height/x/y/rx` of the background `rect` (and the `scale` of the rocket group).
  The rocket is hand-drawn vector art after the 🚀 emoji, not the Apple emoji itself: baking the
  emoji into an icon was neither testable off-device nor clearly licensed. One shape set serves
  both the SVG and `RKRocketGlyph()` (the transform is written out as a matrix in the code).
- **Telegram button:** the `✈` character (read as "airplane mode") is replaced by a drawn paper
  plane, `RKPaperPlaneImage(color)` in `ViewController.m` (16 pt image, colour baked in, fold cut
  with the Clear operator). It is not a template image: the button is layer-backed and
  unbordered, colours come from the palette, so `-rkRecolor:` swaps the image on a theme change.
- **Telegram "only works with an in-app proxy" - investigated, no code change.** `git diff
  v0.11.3..v0.13.3` of `ViewController.m` shows no change in the VPN path: the inbounds (mixed
  10809, socks 10808, tg 10810), the three `networksetup` system-proxy commands and the routing
  rules are textually identical; every proxy-related line added since belongs to the YouTube
  mode (v0.12.0+). By design (section 5, item 4; port table) Telegram never relied on the system
  proxy - it needs `127.0.0.1:10808` (SOCKS5) or `:10810` set in its own settings, which is what
  the Telegram panel's links do. So a change in behaviour comes from the Telegram client (an update,
  or a reset proxy setting). Quick check that Raketa still sets the system proxy while the VPN is on:
  `scutil --proxy | grep -E "SOCKS|HTTP"` shows `SOCKSEnable : 1`, port 10808.
- **Not verified on a Mac:** how the glyphs look at 1x/2x and in both themes (the geometry was
  rendered and inspected off-device with cairosvg, and the ObjC matrix geometry was compared with
  the SVG silhouette: IoU 0.97), the Dock size next to other icons, and the CI icon step. Verified
  off-device: patch applied in a scratch clone, brackets, differential clang check of the three sources.


## 18. Cores and subscription client (v0.14.0)

Why: VPN problems started on the owner's network while INCY (an Xray-core client) kept working, and
sing-box was six minors behind (1.8.11 vs stable 1.14.3 on 2026-10-14). Raketa has two cores only,
sing-box and `ciadpi`; there is no Xray or Happ inside it (INCY and Happ are the Xray-based clients).

- **sing-box 1.8.11 -> 1.14.3, downloaded, not built.** SagerNet publishes
  `sing-box-<ver>-darwin-amd64-legacy-macos-10.13.tar.gz` (patched Go, cgo, deployment target 10.13).
  **[source]** its Mach-O header says `LC_VERSION_MIN_MACOSX 10.13`, x86_64, 78 MB, read in this session;
  CI now asserts both on every build ("Verify bundle"), pins the archive by SHA-256
  (`SING_BOX_SHA256` in `build.yml`; hash of the 1.14.3 archive: 5deb29ed...d112) and no longer needs Go
  or a cache for the core. **Not run on a Mac yet** - first thing to check after the build: connect,
  and `Ядра` shows `sing-box 1.14.3 · встроенное`.
- **Config compatibility, [measured] with the Linux 1.14.3 `sing-box check`:** the VPN config (mixed +
  two socks inbounds, VLESS/Reality/uTLS outbound, direct, route rules) and the plain YouTube config are
  accepted unchanged. The legacy DNS format (`"address": "https://..."`) is a FATAL error since 1.14.0
  (deprecated in 1.12): the DoH branch of `youtubeOnlyConfigWithInbounds:` was rewritten to typed
  servers (`type: https`, `server`, `server_port`, `path`), the strategy moved into the DNS rule and
  `route.default_domain_resolver: local` was added (without it `check` fails). Transports ws, grpc,
  httpupgrade, http check fine. **`xhttp` is rejected** (`unknown transport type: xhttp`), as is
  VLESS Encryption - a server that needs them works in INCY/Happ (Xray) and cannot work in sing-box.
- **In-app updater, `CoreUpdater.m`** (button `Ядра` in the bottom bar, menu: active version, check
  for update, back to the bundled core). Flow, on a background queue, only on a click: latest stable tag
  from the GitHub API -> the same legacy-10.13 asset by a URL built from the tag (strict `vX.Y.Z`) ->
  SHA-256 against the digest GitHub publishes (when there is one) -> `tar` to a staging dir ->
  `sing-box version` must run (a dyld error on 10.13 shows up here) -> `sing-box check -c` on a trivial
  config and on the real `config.json` / `config-yt.json` when they exist (a release that dropped a field
  the app still writes is refused) -> install to `~/Library/Application Support/Raketa/cores/sing-box-<ver>/`
  and flip `cores.json` (atomic). The bundle is never modified (ad-hoc signature); the bundled core is
  always the fallback; one previous version stays on disk. A running core is not touched - the new one
  is used from the next connect. `startVPN` and `ytLaunchCore` ask `self.cores activeCorePath`; only
  files under `cores/` are honoured. Trust model = the app's own: HTTPS from github.com, hash when
  published, must run and accept the app's configs; the installed core is user-writable (like the app
  in /Applications). `ciadpi` has no macOS binary upstream and is built in CI, so it updates with the app.
- **Subscription client, `RKSubscription.m`** (what INCY/Happ do and Raketa did not): the request now
  carries `User-Agent: Raketa/<ver> sing-box/<core> (macOS <ver>)` (the `sing-box` token makes panels
  that pick the format by User-Agent answer with something sing-box can run) and `x-hwid` (random
  per-install id kept in NSUserDefaults, not hardware-derived), `x-device-os`, `x-ver-os`,
  `x-device-model`. **[source]** Remnawave docs (HWID device limit): with the limit on, a client that sends
  no `x-hwid` gets no subscription. The response is read: `Subscription-Userinfo` -> a right-aligned
  caption on the ПОДПИСКА row (used / total · expiry, cached in NSUserDefaults), HTTP 401/403/404/429/5xx
  and `x-hwid-limit: true` -> a specific `⚠` message instead of "Серверы не найдены". vless:// links with
  `type=xhttp|splithttp` or `encryption` other than `none` are counted and shown as "пропущено N (XHTTP)"
  (all skipped: "⚠ XHTTP не поддерживается (N)"). `parseVless:` itself is unchanged. The status label
  now also carries its text as a tooltip (long messages are cut off).
  Side effect to know: the Mac registers as one more device at a provider with a device limit.
- **Verified off-device:** configs with the real 1.14.3 `check`; the three sources with the differential
  clang check; the patch applied end to end in a scratch clone. **Not verified on a Mac:** the downloaded
  core on 10.13, the updater flow, the new User-Agent against the real provider, the layout of the new
  button and caption.
- **Backlog, not done on purpose:** Xray-core as a second engine for XHTTP servers (needs its own config
  writer, ports and a patched-Go build for 10.13; decide after seeing which `type=`/`encryption=` the
  INCY-working link has); trojan/ss/hysteria2/vmess links (only vless:// is parsed from link lists).
