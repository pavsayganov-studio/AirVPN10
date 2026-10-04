#!/usr/bin/env python3
"""Tidy up Raketa's GitHub tags and releases.

Dry-run by default: it only prints what it WOULD do. Nothing is changed until you
pass --apply (and confirm).

  python3 tools/cleanup_releases.py                # show the plan
  python3 tools/cleanup_releases.py --apply        # do it (asks for confirmation)

What it does
  1. Keeps real Raketa/AirVPN versions: tags that match --keep (default: v0.*).
  2. Deletes everything else (tag + its release + assets): the `latest` tag and the
     v1.0 ... v11.0 / v9.1.3 series left by the old auto-bump workflow.
  3. Rewrites the notes of kept releases that only have the old boilerplate
     ("Собрано из ветки main ...") with a real changelog built from commit
     subjects between consecutive tags (same format the workflow now writes).
  4. Marks the newest kept release as "Latest".

Needs: git, and the GitHub CLI (`gh`, already logged in inside Codespaces) for --apply.
Deleting a release removes its downloadable zip. Source code is never touched:
tags only point at commits that stay in the history.
"""
import argparse, json, re, shutil, subprocess, sys, tempfile, os

NOTE_MARK = "### Что изменилось"
OLD_BOILERPLATE = ("Собрано из ветки", "Собрано автоматически")


def run(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit("command failed: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def vkey(tag):
    return [int(x) for x in re.findall(r"\d+", tag)]


def changelog(tag, keep_re, kept_sorted):
    """Commit subjects between the nearest earlier kept tag (by ancestry) and `tag`."""
    prev = run("git", "describe", "--tags", "--abbrev=0", "--match", "v0.*", tag + "^", check=False)
    if prev and not keep_re.match(prev):
        prev = ""
    rng = (prev + ".." + tag) if prev else tag
    out = run("git", "log", "--no-merges", "--pretty=- %s (`%h`)", rng, check=False)
    lines = [l for l in out.splitlines() if not re.match(r"^- (chore|ci)(\(.+\))?:", l)]
    if not prev:
        lines = lines[:15]               # first release: don't dump the whole history
    body = "\n".join(lines) if lines else "- Без изменений в коде."
    parts = ["## 🚀 Raketa %s" % tag, "", NOTE_MARK, body, "", "### Установка",
             "macOS 10.13 и новее, Intel (x86_64). Распакуйте архив и перенесите `Raketa.app` в «Программы».",
             "При первом запуске: правый клик → «Открыть» (приложение подписано ad-hoc)."]
    if prev:
        parts += ["", "**Полный список изменений:** %s...%s" % (prev, tag)]
    return "\n".join(parts) + "\n", prev


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="really delete / edit (default: dry-run)")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    ap.add_argument("--keep", default=r"^v0\.\d+(\.\d+)?$", help="regex of tags to keep (default: v0.*)")
    ap.add_argument("--no-notes", action="store_true", help="do not rewrite release notes")
    a = ap.parse_args()
    keep_re = re.compile(a.keep)

    run("git", "rev-parse", "--show-toplevel")
    have_gh = shutil.which("gh") is not None
    if a.apply and not have_gh:
        raise SystemExit("`gh` (GitHub CLI) is required for --apply.")
    run("git", "fetch", "--tags", "--force", "origin", check=False)
    tags = sorted(run("git", "tag").split(), key=vkey)
    releases = {}
    if have_gh:
        raw = run("gh", "release", "list", "--limit", "300", "--json", "tagName,name,isDraft,publishedAt", check=False)
        try:
            releases = {r["tagName"]: r for r in json.loads(raw or "[]")}
        except ValueError:
            releases = {}
    else:
        print("(gh not found: showing a tags-only plan; releases cannot be listed)\n")

    kept = [t for t in tags if keep_re.match(t)]
    junk = [t for t in tags if not keep_re.match(t)]
    for t in releases:                      # releases whose tag is gone locally
        if t not in tags and not keep_re.match(t):
            junk.append(t)
    print("KEEP   (%d): %s" % (len(kept), " ".join(kept) or "-"))
    print("DELETE (%d): %s" % (len(junk), " ".join(sorted(junk, key=vkey)) or "-"))

    # notes plan
    edits = []
    if not a.no_notes:
        for t in kept:
            r = releases.get(t)
            if not r:
                continue
            body = run("gh", "release", "view", t, "--json", "body", "-q", ".body", check=False) if have_gh else ""
            if NOTE_MARK in body:
                continue                    # already has the new-style changelog
            if body.strip() and not any(m in body for m in OLD_BOILERPLATE) and len(body.strip()) > 200:
                continue                    # a hand-written note: leave it alone
            edits.append(t)
    print("REWRITE NOTES (%d): %s" % (len(edits), " ".join(edits) or "-"))
    newest = max((t for t in kept if t in releases), key=vkey, default=None)
    print("LATEST  -> %s" % (newest or "-"))

    if not a.apply:
        sample = (edits[-1] if edits else (kept[-1] if kept else None))
        if sample:
            print("\n--- sample of the new notes (%s) ---" % sample)
            print(changelog(sample, keep_re, kept)[0])
        print("Dry-run only. Re-run with --apply to perform the plan above.")
        return

    if not a.yes:
        print("\nThis permanently deletes %d tag(s)/release(s) and their downloads." % len(junk))
        if input("Type DELETE to continue: ").strip() != "DELETE":
            raise SystemExit("aborted, nothing changed.")

    for t in sorted(junk, key=vkey):
        if t in releases:
            run("gh", "release", "delete", t, "--cleanup-tag", "--yes")
        else:
            run("git", "push", "origin", "--delete", "refs/tags/" + t, check=False)
        run("git", "tag", "-d", t, check=False)
        print("deleted", t)
    for t in edits:
        notes, _ = changelog(t, keep_re, kept)
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
            f.write(notes)
        try:
            run("gh", "release", "edit", t, "--title", "🚀 Raketa " + t, "--notes-file", f.name)
        finally:
            os.unlink(f.name)
        print("notes rewritten:", t)
    if newest:
        run("gh", "release", "edit", newest, "--latest")
        print("marked latest:", newest)
    print("\nDone.")


if __name__ == "__main__":
    main()
