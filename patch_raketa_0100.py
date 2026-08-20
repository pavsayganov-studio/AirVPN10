#!/usr/bin/env python3
# =============================================================================
# Raketa v0.10.0 — manual version input for releases (removes auto-bump)
#
# What happened: the previous workflow auto-computed the next version by
# scanning existing git tags with `sort -V` and bumping the highest one.
# Some tag in the repo's history sorted higher than expected (root cause
# not fully visible from here — likely a stray/malformed tag created at
# some point), producing an unexpected jump to v9.1.3 instead of v0.9.9.
#
# Fix: remove tag-scanning entirely. The person now types the exact
# version number into a text field when running the workflow manually —
# full control, zero guessing, this entire bug class becomes impossible.
#
# Usage (from repo root, inside GitHub Codespaces):
#   python3 patch_raketa_0100.py
# =============================================================================
import os
import re
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
      version:
        description: "Версия релиза, например 0.10.0 (без буквы v)"
        required: true
        type: string
permissions:
  contents: write

jobs:
  build:
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v3
      with:
        fetch-depth: 0

    # ── Validate and create the tag from manual input ──────────────────────
    # No tag-scanning, no auto-bump — the person types the exact version.
    # This permanently eliminates the class of bug where `sort -V` picked
    # an unexpected "latest" tag from repo history (root cause of the
    # v9.1.3 incident).
    - name: Validate version and create tag
      id: version
      run: |
        RAW="${{ github.event.inputs.version }}"

        # Strip a leading 'v' if the person typed one anyway — forgiving input
        RAW="${RAW#v}"

        if ! [[ "$RAW" =~ ^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$ ]]; then
          echo "::error::Неверный формат версии: '$RAW'. Нужно X.Y.Z, например 0.10.0"
          exit 1
        fi

        NEW_TAG="v${RAW}"
        echo "Requested version: $NEW_TAG"

        if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
          echo "::error::Тег $NEW_TAG уже существует. Выберите другую версию."
          exit 1
        fi

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

          Собрано из ветки `main` при ручном запуске workflow.
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
'''


def main():
    if not os.path.exists(REPO_MARKER):
        die(f"Run this from the repo root (where {REPO_MARKER} lives).")

    print("\033[0;36m╔══════════════════════════════════════════════╗")
    print("║   Raketa v0.10.0 — manual version input      ║")
    print("╚══════════════════════════════════════════════╝\033[0m\n")

    # ── Step 1: rewrite build.yml ──────────────────────────────────────────
    info("Rewriting .github/workflows/build.yml (manual version input)...")
    os.makedirs(".github/workflows", exist_ok=True)
    build_yml_path = ".github/workflows/build.yml"
    if os.path.exists(build_yml_path):
        backup = build_yml_path + ".bak0100"
        with open(build_yml_path, "r") as f:
            old_content = f.read()
        with open(backup, "w") as f:
            f.write(old_content)
        ok(f"Backed up existing build.yml → {backup}")
    with open(build_yml_path, "w") as f:
        f.write(NEW_BUILD_YML)
    ok("build.yml rewritten — you now type the exact version at release time")

    # ── Step 2: bump in-app version strings to 0.10.0 ──────────────────────
    info("Bumping version strings to 0.10.0...")

    vc_path = "ViewController.m"
    if os.path.exists(vc_path):
        with open(vc_path, "r") as f:
            vc = f.read()
        new_vc, n = re.subn(r'@"v0\.\d+\.\d+"', '@"v0.10.0"', vc)
        if n:
            with open(vc_path, "w") as f:
                f.write(new_vc)
            ok(f"ViewController.m version label → v0.10.0 ({n} occurrence(s))")
        else:
            print("  (version label pattern not found — check manually)")

    plist_path = "Info.plist"
    if os.path.exists(plist_path):
        with open(plist_path, "r") as f:
            plist = f.read()
        new_plist = re.sub(r"0\.\d+\.\d+", "0.10.0", plist)
        with open(plist_path, "w") as f:
            f.write(new_plist)
        ok("Info.plist → 0.10.0")

    # ── Step 3: clean up the backup this patch just made, keep tree tidy ──
    # (Per project convention the .bak0100 stays — cleanup patches remove
    #  old .bak files in bulk periodically, not every single patch run.)

    # ── Final instructions ──────────────────────────────────────────────────
    print("\n\033[0;36m╔══════════════════════════════════════════════════════╗")
    print("║  Next steps — run these commands:                    ║")
    print("╠══════════════════════════════════════════════════════╣")
    print("║  git add -A                                          ║")
    print('║  git commit -m "v0.10.0: manual version input"       ║')
    print("║  git push origin main                                ║")
    print("╚══════════════════════════════════════════════════════╝\033[0m")

    print("\n\033[1;33mЧтобы выпустить релиз 0.10.0:\033[0m")
    print("  1. Откройте вкладку Actions в репозитории на GitHub")
    print("  2. Слева выберите workflow «Build Raketa»")
    print("  3. Нажмите «Run workflow» (справа)")
    print("  4. В поле «Версия релиза» введите:  0.10.0")
    print("  5. Нажмите зелёную кнопку «Run workflow»")
    print()
    print("  Тег v0.10.0 будет создан и запушен автоматически. Если тег")
    print("  с таким именем уже существует — сборка остановится с чёткой")
    print("  ошибкой вместо того, чтобы угадывать следующую версию.")


if __name__ == "__main__":
    main()
