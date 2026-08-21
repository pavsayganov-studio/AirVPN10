#!/usr/bin/env python3
# =============================================================================
# Raketa v0.10.2 — validate outbound (server/server_port) before config write
#
# Root cause: the only gate on `outbound` before it's written into
# config.json and handed to sing-box is "does a tag exist that matches the
# dropdown selection". There is no check that the outbound actually has a
# usable server (non-empty string) or server_port (integer in the valid
# 1-65535 TCP range).
#
# Two paths feed proxyOutbounds and both can produce a bad outbound:
#   - parseVless: falls back to server=@"" when a vless:// URL has no host
#     (e.g. malformed link with an empty authority section).
#   - parsedJSON: (raw JSON subscription / sing-box-format outbounds) only
#     checks that `type` and `tag` are non-nil — server/server_port aren't
#     checked at all. A corrupted or adversarial subscription can hand back
#     an outbound missing server_port entirely, or with a non-numeric type.
#
# Cost of not catching this: identical pattern to roadmap #2.6 (the
# sing-box binary check already shipped in v0.10.1). Right now a bad
# outbound still gets written to config.json, the user is prompted for
# their admin password, sing-box then crashes immediately on the bad
# config, and only 1.5s later does the existing coreAlive check report
# "Ядро не запустилось". This wastes a password prompt and an admin
# grant on a failure that was detectable before either happened.
#
# Fix (roadmap.md #2.2): validate server (non-empty after trimming
# whitespace) and server_port (numeric, in range 1-65535) right after
# `outbound` is resolved, before anything else in startVPN runs. Both
# fields are checked defensively with isKindOfClass: rather than assuming
# a type, since a malformed subscription could hand back any JSON type
# in that slot (e.g. server_port as an array) — sending intValue to an
# unexpected type would crash rather than fail gracefully.
#
# This patch is written against the v0.10.1 codebase (must already have
# roadmap #2.1, #2.6, and the GUI spacing pass applied). It will refuse
# to run — cleanly, with no partial writes — against a plain v0.10.0
# checkout or an already-v0.10.2 one.
#
# Scope: only the head of startVPN is touched, right after `if (!outbound)
# return;`. Nothing else in ViewController.m changes.
#
# Usage (from repo root, inside GitHub Codespaces):
#   python3 patch_raketa_0102.py
# =============================================================================
import os
import sys

REPO_MARKER = "ViewController.m"
OLD_VERSION = "0.10.1"
NEW_VERSION = "0.10.2"


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
# 2.2: validate outbound server / server_port before config write + launch
# =============================================================================
OLD_OUTBOUND_CHECK = '''    NSDictionary *outbound = nil;
    for (NSDictionary *o in self.proxyOutbounds)
        if ([o[@"tag"] isEqualToString:tag]) { outbound = o; break; }
    if (!outbound) return;

    // FIX (roadmap.md #2.6): see note above OLD_STARTVPN_HEAD in the patch
    // script for why this check exists and what it prevents.
    NSString *singBoxBin = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];'''

NEW_OUTBOUND_CHECK = '''    NSDictionary *outbound = nil;
    for (NSDictionary *o in self.proxyOutbounds)
        if ([o[@"tag"] isEqualToString:tag]) { outbound = o; break; }
    if (!outbound) return;

    // FIX (roadmap.md #2.2): neither parseVless: nor parsedJSON: guarantee
    // a usable server/server_port — a malformed vless:// link can leave
    // server as an empty string, and a raw JSON subscription isn't
    // validated beyond having a type/tag at all. Without this check, a bad
    // outbound still reaches config.json and the privileged sing-box
    // launch, wasting an admin password prompt on a config that was
    // always going to fail. isKindOfClass: checks guard against a
    // malformed subscription putting an unexpected JSON type (e.g. an
    // array) in server_port's slot, which would crash on intValue.
    NSString *server = [outbound[@"server"] isKindOfClass:[NSString class]]
        ? [outbound[@"server"] stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : nil;
    id portRaw = outbound[@"server_port"];
    BOOL portTypeOK = [portRaw isKindOfClass:[NSNumber class]]
                    || [portRaw isKindOfClass:[NSString class]];
    NSInteger port = portTypeOK ? [portRaw integerValue] : 0;

    if (!server.length || port < 1 || port > 65535) {
        [self setStatus:@"Некорректные данные сервера" color:rkRed];
        return;
    }

    // FIX (roadmap.md #2.6): see note above OLD_STARTVPN_HEAD in the patch
    // script for why this check exists and what it prevents.
    NSString *singBoxBin = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];'''

if OLD_OUTBOUND_CHECK not in vc:
    die("startVPN: outbound-check block doesn't match expected v0.10.1 text — "
        "aborting before touching the file. (Repo may not have roadmap #2.1/"
        "#2.6 applied yet, or may already have #2.2 applied, or has diverged "
        "from what this script expects.)")

# ── Backup (only now that we know the source matches what we expect) ───────
for fname in ["ViewController.m", "Info.plist"]:
    bak = fname + ".bak0102"
    with open(fname, "rb") as src, open(bak, "wb") as dst:
        dst.write(src.read())
    ok(f"Backed up {fname} -> {bak}")

vc = vc.replace(OLD_OUTBOUND_CHECK, NEW_OUTBOUND_CHECK, 1)
ok("Patched startVPN: with server/server_port validation before config write (roadmap #2.2)")

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
        f"File was already written — restore from ViewController.m.bak0102 "
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
ok("Patch 0102 applied successfully.")
print()
print("\033[1;36m" + "=" * 70 + "\033[0m")
print("\033[1;36mNext steps:\033[0m")
print("\033[1;36m" + "=" * 70 + "\033[0m")
print(f'''
git add -A
git commit -m "v{NEW_VERSION}: validate outbound server/server_port before launch (roadmap #2.2)"
git push origin main

Then trigger the build manually:
  GitHub repo -> Actions -> "Build Raketa" -> Run workflow
  -> version field: {NEW_VERSION}
''')
