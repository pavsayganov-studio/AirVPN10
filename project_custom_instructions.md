## What this project is

Raketa — a menu-bar VPN client for macOS (Objective-C + AppKit, no Xcode
project file, compiled via raw `clang` in GitHub Actions CI). Wraps sing-box
v1.8.11 with VLESS+Reality+uTLS. Full technical history, architecture
rationale, and design system live in `handoff.md` — read it at the start of
any new conversation before proposing changes; it documents nine
platform-specific bugs already fixed that must not be reintroduced.

## Non-negotiable constraints

These were established deliberately across many iterations. Do not revisit
them unless the person explicitly asks to:

- **macOS 10.13 (High Sierra) is the primary target.** macOS 12.x is
  confirmed working. Any shell command run via `do shell script ... with
  administrator privileges` executes with no controlling terminal —
  assume this and verify against both OS versions in reasoning, especially
  for anything involving `nohup`-like terminal/TTY behavior.
- **CPU/resource load is the top-level priority — above visual polish.**
  Before adding any timer, polling loop, animation, or background
  `NSTask` spawn, check whether it's actually necessary. The watchdog
  pattern (`kill(pid, 0)` over `pgrep`, cached interface name, one-shot
  detection) is the model to follow for anything similar.
- **System Proxy architecture, not TUN.** This was tried and abandoned
  early (double password prompts, unrecoverable hangs on crash). Don't
  suggest switching back without being asked.
- **Delivery format: one complete script per change**, bash or Python,
  self-contained, ending in exact `git add / commit / tag / push`
  commands. The person works exclusively through GitHub Codespaces — no
  local Xcode, no diffs, no "edit line N" instructions. Every script backs
  up files it touches before rewriting them (`cp X X.bakVERSION`).
- Never touch the underlying VLESS/Reality/routing logic, the credit line
  in the UI, or the overall visual style without being asked — these are
  finished, approved, and explicitly praised by the person as correct.

## Working style that has earned trust here

- **Diagnose before patching.** For any bug report, work out the root
  cause first and state it plainly — one or two sentences, in plain
  language, before showing code. This has mattered more than speed in
  every prior exchange in this project.
- **Surgical over broad.** When asked to fix something specific, fix that
  thing. Don't refactor adjacent code "while in there" unless asked.
  Several past patches explicitly note what was left untouched — keep
  doing that.
- Comments in generated Objective-C should explain *why* a fix exists,
  not just what it does — especially for the nine platform gotchas in
  `handoff.md`. This is what has prevented regressions across versions.
- **Verify before delivering.** Check brace balance and run `bash -n` /
  `python3 -m py_compile` on any generated script before presenting it.
  A truncated heredoc or quoting collision has broken a delivered patch
  before in this project (the git-ref and nested-heredoc incidents) —
  always test-run patch scripts end-to-end in a scratch directory when
  the change is non-trivial, not just syntax-check them.
- When a person-reported "error" in build output turns out to be a false
  positive in the patch script's own verification logic (this has
  happened — e.g. `grep -c` matching a comment and taking the wrong
  branch), say so plainly and explain why, rather than re-patching
  working code.

## When starting a new conversation in this project

If `handoff.md` isn't already in context, treat the first message as a
signal to read it (via search_past_chats or an uploaded copy) before
proposing any code change — it contains the full list of what's already
fixed, the exact port map, routing rules, and file layout. Don't
re-derive architecture decisions that are already documented there.
