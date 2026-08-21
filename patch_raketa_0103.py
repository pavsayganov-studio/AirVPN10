#!/usr/bin/env python3
# =============================================================================
# Raketa v0.10.3 — chmod 600 on config.json (contains UUID + Reality keys)
#
# Root cause: config.json is written via [cfgData writeToFile:self.configPath
# atomically:YES]. Foundation's atomic write creates a fresh temp file and
# rename()s it into place — the temp file's permissions come from a new
# file creation, subject to the process's umask (typically resulting in
# 644: world-readable). This file contains the VLESS UUID and, when
# Reality is in use, the Reality short_id/public_key material for every
# saved server. On a shared Mac (multiple local user accounts), any other
# local user can read this file with standard `cat`, no privilege needed.
#
# Because startVPN rewrites config.json on every single connect (not just
# once at first run), permissions reset to the umask default on every
# connect — a one-time fix at first-launch wouldn't hold.
#
# Fix (roadmap.md #2.3): immediately after the write, set POSIX permissions
# to 0600 (owner read/write only) via NSFileManager — no shell-out, no
# NSTask spawn, just a single Foundation API call in the app's own
# unprivileged process (config.json is written by the app itself, before
# the privileged AppleScript call, so no elevated privileges are needed
# for this — the app process already owns the file it just wrote).
#
# Verified this doesn't break sing-box's ability to read the file: sing-box
# is launched via `do shell script ... with administrator privileges`,
# which runs the shell command as root. Root bypasses POSIX owner/group/
# other permission checks entirely, so 0600 has zero effect on sing-box's
# own read access — it only blocks *other non-root local users* from
# reading the file, which is exactly the threat model this addresses.
#
# This patch is written against the v0.10.2 codebase (must already have
# roadmap #2.1, #2.2, #2.6, and the GUI spacing pass applied). It will
# refuse to run — cleanly, with no partial writes — against an earlier or
# already-patched version.
#
# Scope: only the single writeToFile: line in startVPN is touched (one line
# becomes two). Nothing else in ViewController.m changes.
#
# Usage (from repo root, inside GitHub Codespaces):
#   python3 patch_raketa_0103.py
# =============================================================================
import os
import sys

REPO_MARKER = "ViewController.m"
OLD_VERSION = "0.10.2"
NEW_VERSION = "0.10.3"


def die(msg):
    print(f"\n\033[0;31m✗ {msg}\033[0m")
    sys.exit(1)


def ok(msg):
    print(f"\033[0;32m✓ {msg}\033[0m")


def info(msg):
    print(f"\033[1;33m→ {msg}\033[0m")


if not os.path.isfile(REPO_MARKER):
    die(f"{REPO_MARKER} not found — run this from the repo root.")

for fname in ["ViewController.m", "Info.plist"]:
    if not os.path.isfile(fname):
        die(f"{fname} not found — repo layout doesn't match what this patch expects.")

with open("ViewController.m", "r", encoding="utf-8") as f:
    vc = f.read()

# =============================================================================
# 2.3: chmod 600 on config.json right after every write
# =============================================================================
OLD_WRITE = '''    NSData *cfgData = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!cfgData) { [self setStatus:@"Ошибка конфига" color:rkRed]; return; }
    [cfgData writeToFile:self.configPath atomically:YES];

    NSString *bin   = singBoxBin;  // already resolved & validated above'''

NEW_WRITE = '''    NSData *cfgData = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!cfgData) { [self setStatus:@"Ошибка конфига" color:rkRed]; return; }
    [cfgData writeToFile:self.configPath atomically:YES];

    // FIX (roadmap.md #2.3): config.json holds the VLESS UUID and Reality
    // key material for every saved server. writeToFile:atomically: creates
    // a fresh temp file under the hood and rename()s it into place — its
    // permissions come from the process umask (typically 644, world-
    // readable), not from any prior version of this file. Since this write
    // happens on every connect, not just once, the permissions would
    // reset to the umask default every time without this. sing-box itself
    // reads this file as root (via the privileged shell call below), and
    // root bypasses POSIX permission checks entirely — 0600 only blocks
    // *other local user accounts* on a shared Mac from reading it.
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                      ofItemAtPath:self.configPath
                                             error:nil];

    NSString *bin   = singBoxBin;  // already resolved & validated above'''

if OLD_WRITE not in vc:
    die("startVPN: config write block doesn't match expected v0.10.2 text — "
        "aborting before touching the file. (Repo may not have roadmap #2.1/"
        "#2.2/#2.6 applied yet, or may already have #2.3 applied, or has "
        "diverged from what this script expects.)")

# ── Backup (only now that we know the source matches what we expect) ───────
for fname in ["ViewController.m", "Info.plist"]:
    bak = fname + ".bak0103"
    with open(fname, "rb") as src, open(bak, "wb") as dst:
        dst.write(src.read())
    ok(f"Backed up {fname} -> {bak}")

vc = vc.replace(OLD_WRITE, NEW_WRITE, 1)
ok("Patched startVPN: config.json now chmod'd to 0600 immediately after write (roadmap #2.3)")

# ── Version bump in the UI label ────────────────────────────────────────────
OLD_VER_LINE = f'NSTextField *ver = [self lbl:@"v{OLD_VERSION}"'
NEW_VER_LINE = f'NSTextField *ver = [self lbl:@"v{NEW_VERSION}"'
if OLD_VER_LINE not in vc:
    die("Version label string not found — aborting.")
vc = vc.replace(OLD_VER_LINE, NEW_VER_LINE, 1)
ok(f"Bumped UI version label to v{NEW_VERSION}")

with open("ViewController.m", "w", encoding="utf-8") as f:
    f.write(vc)

# Brace balance sanity check
if vc.count("{") != vc.count("}"):
    die(f"Brace mismatch after patch: {{ = {vc.count('{')}, }} = {vc.count('}')}. "
        f"File was already written — restore from ViewController.m.bak0103 "
        f"and report this.")
ok("Brace balance OK")

# =============================================================================
# Info.plist — version bump
# =============================================================================
with open("Info.plist", "r", encoding="utf-8") as f:
    plist = f.read()

plist_new = plist.replace(
    f"<string>{OLD_VERSION}</string>",
    f"<string>{NEW_VERSION}</string>",
)
if plist_new == plist:
    die("Info.plist version string not found/replaced — aborting.")
with open("Info.plist", "w", encoding="utf-8") as f:
    f.write(plist_new)
ok(f"Bumped Info.plist CFBundleVersion / CFBundleShortVersionString to {NEW_VERSION}")

print()
ok("Patch 0103 applied successfully.")
print()
print("\033[1;36m" + "=" * 70 + "\033[0m")
print("\033[1;36mNext steps:\033[0m")
print("\033[1;36m" + "=" * 70 + "\033[0m")
print(f'''
git add -A
git commit -m "v{NEW_VERSION}: chmod 600 on config.json — protects UUID/Reality keys (roadmap #2.3)"
git push origin main

Then trigger the build manually:
  GitHub repo -> Actions -> "Build Raketa" -> Run workflow
  -> version field: {NEW_VERSION}
''')
