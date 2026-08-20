# Raketa — Technical Handoff

**Current version:** v0.9.7
**Platform:** macOS 10.13 (High Sierra) through macOS 12.x (Monterey), Intel x86_64
**Status:** Production. Fully working, actively used by the owner (Pablo).

---

## 1. What this is

Raketa is a minimalist menu-bar VPN client for macOS, purpose-built for users in
Russia who need to bypass DPI-based blocking. It wraps **sing-box v1.8.11** as
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
├── ViewController.m / .h           — ALL app logic lives here (~800 lines)
├── Info.plist                      — bundle metadata, version string
├── AppIcon.svg                     — icon source (white "R" on blue gradient)
├── generate_icon.py                — SVG → .icns build-time converter (cairosvg + iconutil)
└── .github/workflows/build.yml     — CI: builds sing-box, generates icon,
                                       compiles app, codesigns ad-hoc, releases .zip
```

There is no `.xcodeproj`. The app is compiled with a raw `clang` invocation
in CI:
```
clang -fobjc-arc -framework Cocoa -framework SystemConfiguration \
  -arch x86_64 -mmacosx-version-min=10.13 \
  -o Raketa.app/Contents/MacOS/Raketa \
  main.m AppDelegate.m ViewController.m
```

`sing-box` itself is built from source in CI at tag `v1.8.11` with
`-tags "with_utls,with_grpc,with_reality"`, Go 1.20 (last version that
targets 10.13 successfully).

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

## 5. Design system (current, v0.9.7)

**Theme:** soft blue, light, opaque (explicitly *not* translucent —
`NSVisualEffectView` was removed early on because it caused the popover to
look muddy layered over the desktop; every surface now has a solid
`CALayer.backgroundColor`).

```
rkBG      #E0EEFA   main background
rkSurface #CCE3F5   header / bottom bar
rkCard    #D4E8F8   Telegram panel background
rkBorder  #9EC7EB   separators, button borders
rkText    #1A1A1A   primary text (near-black)
rkSub     #666666   secondary text
rkAccent  #1A66C7   links, MTProxy details
rkGreen   #148C38   connected state
rkOrange  #BF6107   warnings
rkRed     #B71414   errors
rkBtn     #B8D6F0   button fill
```

Typography follows Apple's macOS 10.13 HIG as closely as is practical for a
custom (non-native-chrome) popover UI:
- Base control text: 13pt regular
- Secondary/section labels: 11pt
- Micro text (credit line): 9pt, `HelveticaNeue-Light`, `NSKernAttributeName
  0.8` tracking (prevents glyph crowding — a real bug that occurred with
  the default kerning at 9pt)
- 20pt outer margins, 12pt between groups, 8pt between related controls
  (all per HIG spacing conventions)
- Push buttons: 21pt height where possible (HIG standard); the main
  connect toggle is a custom 36pt-tall capsule (`cornerRadius = height/2`)
  since it's a primary action, not a standard push button

**Window layout (popover, `kW=300`, `kH=278`, top-down):**
```
0–32    header: 🚀 Raketa (left) · version (right)
32–83   ПОДПИСКА section: [＋ Добавить ключи (224pt)] [↻ (28pt square)]
83–141  СЕРВЕР section: dropdown of parsed outbound tags
141–168 status row: colored dot + status text
168–204 connect toggle: full-width capsule button (○ ВЫКЛ / ● ВКЛ)
204–278 bottom bar: [Логи] ··· credit line ··· [✈][Выход]
```

The Telegram settings panel is **not** a big always-visible button anymore
(removed in v0.9.4). It's a small square `✈` icon (U+2708) in the bottom
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

Every change ships as a single bash script the person runs inside GitHub
Codespaces from the repo root:

```bash
bash patch_raketa_XYZ.sh
git add -A
git commit -m "..."
git tag vX.Y.Z
git push origin main --tags
```

The tag push triggers `.github/workflows/build.yml`, which:
1. Builds `sing-box` from source (Go 1.20, targets `darwin/amd64`)
2. Installs `cairosvg` (`pip3 install cairosvg --quiet --break-system-packages`
   — the `--break-system-packages` flag is required on macOS CI runners due
   to PEP 668) and runs `generate_icon.py` to produce `AppIcon.icns` from
   `AppIcon.svg`
3. Compiles the app via raw `clang`
4. Ad-hoc codesigns (`codesign --force --deep -s -`)
5. Zips and publishes a GitHub Release with the `.zip` attached

**Patch script conventions the person expects:**
- One complete, self-contained `.sh` file per iteration, runnable start to
  finish with `bash patch_raketa_XYZ.sh`
- Always backs up touched files first (`cp X X.bakXYZ`)
- Always ends with a clearly formatted block of the exact git commands to
  run next
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
