#!/usr/bin/env python3
# =============================================================================
# Raketa v0.9.8 — auto-tagging release workflow + repo cleanup
#
# What this does:
#   1. Rewrites .github/workflows/build.yml so releases are triggered by
#      clicking "Run workflow" in the GitHub Actions tab — no more manual
#      `git tag vX.Y.Z` + `git push origin vX.Y.Z` locally. The workflow
#      itself finds the latest existing tag, bumps it, creates the new tag,
#      and pushes it before building. This also permanently avoids the
#      "tag already exists" collision that just happened with v0.9.7.
#   2. Deletes accumulated cruft: every *.bak* backup file and every old
#      patch_raketa_*.sh / patch_raketa_*.py script sitting in the repo
#      root. Git history keeps all of this permanently — nothing is lost,
#      it's just no longer cluttering the working tree.
#   3. Bumps the in-app version string (UI label + Info.plist) to 0.9.8.
#
# Usage (from repo root, inside GitHub Codespaces):
#   python3 patch_raketa_098.py
# =============================================================================
import glob
import os
import re
import subprocess
import sys

REPO_MARKER = "ViewController.m"


def die(msg):
    print(f"\n\033[0;31m✗ {msg}\033[0m")
    sys.exit(1)


def ok(msg):
    print(f"\033[0;32m✓ {msg}\033[0m")


def info(msg):
    print(f"\033[1;33m→ {msg}\033[0m")


NEW_BUILD_YML = '''name: Build Raketa
on:
  workflow_dispatch:
    inputs:
      bump:
        description: "Version bump type"
        required: true
        default: "patch"
        type: choice
        options:
          - patch
          - minor
          - major
permissions:
  contents: write

jobs:
  build:
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v3
      with:
        fetch-depth: 0   # need full tag history to compute the next version

    # ── Compute and publish the next version tag ──────────────────────────
    # Finds the highest existing vX.Y.Z tag, bumps it according to the
    # chosen input (default: patch), creates the tag, and pushes it.
    # Every later step references $NEW_TAG instead of ${{ github.ref_name }},
    # since this workflow is no longer triggered by a tag push.
    - name: Determine next version
      id: version
      run: |
        git fetch --tags --force
        LATEST=$(git tag -l 'v*.*.*' | sort -V | tail -1)
        if [ -z "$LATEST" ]; then
          LATEST="v0.0.0"
        fi
        echo "Latest tag: $LATEST"

        VERSION="${LATEST#v}"
        MAJOR=$(echo "$VERSION" | cut -d. -f1)
        MINOR=$(echo "$VERSION" | cut -d. -f2)
        PATCH=$(echo "$VERSION" | cut -d. -f3)

        case "${{ github.event.inputs.bump }}" in
          major)
            MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
          minor)
            MINOR=$((MINOR + 1)); PATCH=0 ;;
          *)
            PATCH=$((PATCH + 1)) ;;
        esac

        NEW_TAG="v${MAJOR}.${MINOR}.${PATCH}"
        echo "New tag: $NEW_TAG"

        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git tag "$NEW_TAG"
        git push origin "$NEW_TAG"

        echo "tag=$NEW_TAG" >> "$GITHUB_OUTPUT"

    - name: Set up Go 1.20
      uses: actions/setup-go@v4
      with:
        go-version: '1.20'

    - name: Build sing-box core
      run: |
        git clone --depth=1 -b v1.8.11 \\
          https://github.com/SagerNet/sing-box.git core-build
        cd core-build
        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 \\
          go build -tags "with_utls,with_grpc,with_reality" \\
          -trimpath -ldflags="-s -w" \\
          -o ../sing-box ./cmd/sing-box

    - name: Generate AppIcon.icns from SVG
      run: |
        pip3 install cairosvg --quiet --break-system-packages
        python3 generate_icon.py

    - name: Compile app
      run: |
        mkdir -p Raketa.app/Contents/MacOS \\
                 Raketa.app/Contents/Resources
        echo "APPL????" > Raketa.app/Contents/PkgInfo
        cp Info.plist   Raketa.app/Contents/Info.plist
        cp AppIcon.icns Raketa.app/Contents/Resources/AppIcon.icns
        cp sing-box     Raketa.app/Contents/Resources/sing-box
        chmod +x        Raketa.app/Contents/Resources/sing-box
        clang -fobjc-arc \\
          -framework Cocoa \\
          -framework SystemConfiguration \\
          -arch x86_64 -mmacosx-version-min=10.13 \\
          -o Raketa.app/Contents/MacOS/Raketa \\
          main.m AppDelegate.m ViewController.m
        codesign --force --deep -s - Raketa.app
        zip -r "Raketa-macOS-10.13-${{ steps.version.outputs.tag }}.zip" Raketa.app

    - name: Release
      uses: softprops/action-gh-release@v1
      with:
        tag_name: ${{ steps.version.outputs.tag }}
        name: "🚀 Raketa ${{ steps.version.outputs.tag }}"
        body: |
          ## 🚀 Raketa ${{ steps.version.outputs.tag }}

          Собрано автоматически из ветки `main` при запуске workflow
          вручную (bump: `${{ github.event.inputs.bump }}`).
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
'''


def main():
    if not os.path.exists(REPO_MARKER):
        die(f"Run this from the repo root (where {REPO_MARKER} lives).")

    print("\033[0;36m╔══════════════════════════════════════════╗")
    print("║   Raketa v0.9.8 — auto-tag + cleanup     ║")
    print("╚══════════════════════════════════════════╝\033[0m\n")

    # ── Step 1: rewrite build.yml ──────────────────────────────────────────
    info("Rewriting .github/workflows/build.yml (auto-tagging release)...")
    os.makedirs(".github/workflows", exist_ok=True)
    build_yml_path = ".github/workflows/build.yml"
    if os.path.exists(build_yml_path):
        backup = build_yml_path + ".bak098"
        with open(build_yml_path, "r") as f:
            old_content = f.read()
        with open(backup, "w") as f:
            f.write(old_content)
        ok(f"Backed up existing build.yml → {backup}")
    with open(build_yml_path, "w") as f:
        f.write(NEW_BUILD_YML)
    ok("build.yml rewritten — release now triggers from the Actions tab")

    # ── Step 2: clean up backup and old patch script cruft ────────────────
    info("Cleaning up backup files and old patch scripts...")

    patterns_to_remove = [
        "*.bak",           # bare .bak with no suffix (e.g. ViewController.m.bak)
        "*.bak0*",         # versioned backups: .bak071, .bak095, etc.
        "*.bak1*",
        "*.bak2*",
        "*.bak3*",
        "*.bak4*",
        "*.bak5*",
        "*.bak6*",
        "*.bak7*",
        "*.bak8*",
        "*.bak9*",
        "patch_raketa_*.sh",
        "patch_raketa_*.py",
    ]

    removed = []
    for pattern in patterns_to_remove:
        for path in glob.glob(pattern):
            # Never delete this script while it's mid-run, and never touch
            # anything outside the repo root (glob without recursion is
            # already root-only, this is a belt-and-suspenders guard).
            if os.path.basename(__file__) == os.path.basename(path):
                continue
            os.remove(path)
            removed.append(path)

    if removed:
        ok(f"Removed {len(removed)} stale files:")
        for path in sorted(removed):
            print(f"    - {path}")
    else:
        print("  (nothing to remove — already clean)")

    # ── Step 3: bump in-app version strings to 0.9.8 ───────────────────────
    info("Bumping version strings to 0.9.8...")

    vc_path = "ViewController.m"
    if os.path.exists(vc_path):
        with open(vc_path, "r") as f:
            vc = f.read()
        new_vc, n = re.subn(r'@"v0\.9\.\d+"', '@"v0.9.8"', vc)
        if n:
            with open(vc_path, "w") as f:
                f.write(new_vc)
            ok(f"ViewController.m version label → v0.9.8 ({n} occurrence(s))")
        else:
            print("  (version label pattern not found — check manually)")

    plist_path = "Info.plist"
    if os.path.exists(plist_path):
        with open(plist_path, "r") as f:
            plist = f.read()
        new_plist = re.sub(r"0\.9\.\d+", "0.9.8", plist)
        with open(plist_path, "w") as f:
            f.write(new_plist)
        ok("Info.plist → 0.9.8")

    # ── Final instructions ──────────────────────────────────────────────────
    print("\n\033[0;36m╔══════════════════════════════════════════════════════╗")
    print("║  Next steps — run these commands:                    ║")
    print("╠══════════════════════════════════════════════════════╣")
    print("║  git add -A                                          ║")
    print('║  git commit -m "v0.9.8: auto-tag release + cleanup"  ║')
    print("║  git push origin main                                ║")
    print("╚══════════════════════════════════════════════════════╝\033[0m")

    print("\n\033[1;33mЧтобы выпустить релиз теперь:\033[0m")
    print("  1. Откройте вкладку Actions в репозитории на GitHub")
    print("  2. Слева выберите workflow «Build Raketa»")
    print("  3. Нажмите «Run workflow» (справа)")
    print("  4. Выберите тип версии: patch / minor / major (по умолчанию patch)")
    print("  5. Нажмите зелёную кнопку «Run workflow»")
    print()
    print("  Тег vX.Y.Z будет создан и запушен автоматически — больше не")
    print("  нужно вручную делать git tag / git push origin vX.Y.Z.")


if __name__ == "__main__":
    main()
