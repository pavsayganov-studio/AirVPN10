## What this project is

Raketa — a menu-bar VPN client for macOS (Objective-C + AppKit, no Xcode project file,
compiled via raw `clang` in GitHub Actions). Wraps sing-box v1.14.3 with VLESS+Reality+uTLS.
A second mode, "Смотреть YouTube", sends only YouTube domains through a user-level `ciadpi`
(DPI bypass) instead of the VPN. Repo: https://github.com/pavsayganov-studio/AirVPN10 (public).
Full history, architecture and design system live in `handoff.md`; everything learned about DPI
bypass lives in `dpi-research.md`. Current state: v0.14.0 — the DPI search works and logs where
the filter acts, but no strategy that a macOS `ciadpi` can run beats the current Russian filter;
the UI got a vector rocket in the menu bar (template image), the same rocket as the app icon (on the
macOS icon grid) and a drawn paper plane on the Telegram button (handoff §17, design.md §6).

## First actions in every new conversation (token economy)

1. **Code source of truth = the repo, not an attachment.** In the sandbox run
   `git clone --depth 50 https://github.com/pavsayganov-studio/AirVPN10` (github.com is reachable).
   If a repomix/zip is attached, first check it is Raketa (contains `DPIEngine.m`, `Info.plist`
   with `com.samurai.raketa`); a repomix of a different project was once uploaded by mistake —
   if it is not Raketa, say so in one line and use the clone. If the clone fails, ask for a
   repomix of THIS repo.
2. Compare `Info.plist` version with `handoff.md`; if they differ, the repo wins.
3. Read `dpi-research.md` before any DPI work and `handoff.md` §4 (platform gotchas) before any
   code change; read other sections only when needed, with grep/ranges, not whole files.
   Do not re-research what `dpi-research.md` already holds — research only what is newer.
4. Dev tools in the repo (do not recreate them): `tools/test_patch.sh PATCH.py [SOURCE]` runs a
   patch script end-to-end in a scratch clone with a local bare origin; `tools/objc_diffcheck.sh
   [BASE_REF] [FILE]` is an off-device clang syntax check (FILE = DPIEngine.m by default, also
   AppDelegate.m / ViewController.m) on the legacy GNUstep runtime: a baseline of platform errors
   always remains, pass = no NEW error class. macOS-only API names GNUstep lacks (e.g.
   `NSCompositingOperationClear`, `NSButton.imageScaling`) show up as NEW CLASS — check them against
   Apple docs before calling them bugs. Neither tool proves the code compiles on macOS — say
   "verified off-device: X; not verified on a Mac".

## Non-negotiable constraints

Established deliberately across many iterations. Do not revisit unless asked:

- **macOS 10.13 (High Sierra) is the primary target.** macOS 12.x is confirmed working. A
  command run via `do shell script ... with administrator privileges` has no controlling
  terminal — verify against both OS versions in reasoning (anything `nohup`/TTY-like).
- **CPU/resource load is the top priority — above visual polish.** Before adding any timer,
  polling loop, animation or background `NSTask`, check it is necessary. Model: the watchdog
  (`kill(pid, 0)`, cached interface name, one-shot detection).
- **System Proxy architecture, not TUN.** Tried and abandoned (double password prompts,
  unrecoverable hangs on crash). Do not suggest it unasked.
- **Delivery: one complete, self-contained `.py` patch script per change** (see below). The
  person works only through GitHub Codespaces — no local Xcode, no diffs, no "edit line N".
- Never touch the VLESS/Reality/routing logic, the credit line in the UI or the overall visual
  style unasked — finished and approved. Changing routing (e.g. YouTube through the VLESS
  outbound) needs the person's explicit OK.

## Known, by design (not regressions)

- Telegram needs its in-app proxy (`127.0.0.1:10808` SOCKS5 or `:10810`) — it never read the system
  proxy (handoff §5 item 4, §17). The VPN proxy path is textually unchanged since v0.11.3.

## Working style that has earned trust

- **Diagnose before patching:** state the root cause in one or two plain sentences before code.
- **Surgical over broad:** fix the thing asked; say what was left untouched.
- **Comments in generated Objective-C explain *why*** (especially the platform gotchas).
- **Verify before delivering:** `python3 -m py_compile` / `bash -n`; brace balance; run the
  patch end-to-end with `tools/test_patch.sh`, not just a syntax check; it must report 0 leftover
  `.bak*` files. If a reported "error"
  is a false positive of the patch script's own check, say so plainly instead of re-patching.
- **Be honest about evidence:** label what was measured in the person's log, what was read in
  source, what is a secondary summary, what is inference. Do not present a hypothesis as a
  finding (v0.13.3's DNS hypothesis was wrong; the log disproved it).
- Answers are short and lead with the result; long material goes to a file. If you must stop
  for a decision, give a recommendation and ask once.

## Patch-script conventions

`patch_raketa_<ver>.py`, run from the repo root: backs up touched files (`cp X X.bak<ver>`;
`*.bak*` is gitignored), applies anchored edits (each anchor must match exactly once), runs its
own checks (bracket balance, forbidden/required strings, version bump consistent in
`Info.plist`), restores the backups and stops if a check fails, then `git add` of exact paths,
`git commit` (Russian message, one line), `git push origin main`, and after a successful push
deletes its own backups (every `X.bak<ver>` it made) and itself, so no `.bak*` file stays in the
repo (after a failed check or push the backups stay for recovery). No tags — releases are cut by hand: Actions → Build Raketa → Run workflow.
Version bump consistently: `Info.plist` (`CFBundleVersion` + `CFBundleShortVersionString`).

## Language

Reply in Russian (the person writes Russian). Code, comments, identifiers, log lines, docs in
the repo: English. UI strings, status messages, commit messages: Russian. Reasoning, searching
and analysis: English.

## DPI work — current decision

Path A, experiment first: fake packets on macOS by raw injection as root (SpoofDPI's way), proven
by a standalone lab tool before anything touches ciadpi or the app. Gate on the `wire verdict:`
line of the v0.13.4 search log (`dpi_search.log`); fallback path B (YouTube through the VLESS
outbound) only with the person's OK. Details, specs and what not to do: `dpi-research.md` §5–6.
