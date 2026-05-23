#!/bin/bash
# =============================================================================
# Raketa v0.9.2 — SVG icon (reliable, no binary assets)
# Run from repo root: bash patch_raketa_092.sh
# =============================================================================
set -e
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.9.2 — SVG Icon               ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

[ ! -f "ViewController.m" ] && echo -e "${R}✗ Run from repo root${N}" && exit 1

cp .github/workflows/build.yml .github/workflows/build.yml.bak092
cp Info.plist Info.plist.bak092
echo -e "${G}✓ Backups created${N}\n"

# =============================================================================
# 1. AppIcon.svg  — committed to repo, single source of truth
#    White "R", Helvetica Neue Bold, on blue radial-gradient rounded rect.
#    viewBox 100×100 so percentages are clean.
# =============================================================================
echo -e "${Y}→ AppIcon.svg${N}"
cat > AppIcon.svg << 'EOF_SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <radialGradient id="bg" cx="40%" cy="35%" r="65%">
      <stop offset="0%"   stop-color="#7BBFE8"/>
      <stop offset="100%" stop-color="#3A7FC1"/>
    </radialGradient>
  </defs>
  <!-- Background: rounded rect with gradient, corner radius = 22.5% (macOS standard) -->
  <rect width="100" height="100" rx="22.5" fill="url(#bg)"/>
  <!-- Letter R: Helvetica Neue Bold, white, optically centred -->
  <text x="50" y="76"
        font-family="'Helvetica Neue', Helvetica, Arial, sans-serif"
        font-size="72"
        font-weight="700"
        fill="white"
        text-anchor="middle"
        letter-spacing="-1">R</text>
</svg>
EOF_SVG
echo -e "${G}✓ AppIcon.svg${N}"

# =============================================================================
# 2. generate_icon.py  — SVG → PNG sizes → AppIcon.icns
#    Uses cairosvg (pip) for reliable headless SVG rasterization.
#    cairosvg is pure-Python + libcairo; pre-installed or installs in ~5s.
#    Falls back to rsvg-convert (librsvg) if cairosvg unavailable.
#    iconutil (macOS built-in) assembles the final .icns.
# =============================================================================
echo -e "${Y}→ generate_icon.py${N}"
cat > generate_icon.py << 'EOF_PY'
#!/usr/bin/env python3
"""
Raketa icon builder.
Reads AppIcon.svg → rasterises to required PNG sizes → assembles AppIcon.icns.
"""
import os, subprocess, sys, shutil, tempfile

SVG_SRC  = "AppIcon.svg"
ICNS_OUT = "AppIcon.icns"

# iconutil requires this exact set of filenames
# Format: (logical_size, scale, filename)
ICONSET = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (64,  1, "icon_64x64.png"),         # optional but nice
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

def rasterise_cairosvg(svg_path: str, png_path: str, size: int):
    import cairosvg
    cairosvg.svg2png(url=svg_path,
                     write_to=png_path,
                     output_width=size,
                     output_height=size)

def rasterise_rsvg(svg_path: str, png_path: str, size: int):
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size),
         "-o", png_path, svg_path],
        check=True
    )

def rasterise_qlmanage(svg_path: str, png_path: str, size: int):
    """Last resort: macOS qlmanage (may produce slightly different sizes)."""
    tmp = tempfile.mkdtemp()
    subprocess.run(
        ["qlmanage", "-t", "-s", str(size), "-o", tmp, svg_path],
        check=True, capture_output=True
    )
    # qlmanage appends .png to the filename
    produced = os.path.join(tmp, os.path.basename(svg_path) + ".png")
    if os.path.exists(produced):
        shutil.copy(produced, png_path)
    else:
        raise RuntimeError(f"qlmanage did not produce {produced}")

def get_rasteriser():
    # Try cairosvg first (most reliable, pip-installable)
    try:
        import cairosvg  # noqa
        return rasterise_cairosvg
    except ImportError:
        pass
    # Try rsvg-convert (part of librsvg, installable via brew)
    if shutil.which("rsvg-convert"):
        return rasterise_rsvg
    # Last resort
    if shutil.which("qlmanage"):
        return rasterise_qlmanage
    raise RuntimeError(
        "No SVG rasteriser found.\n"
        "Install one of:\n"
        "  pip3 install cairosvg\n"
        "  brew install librsvg"
    )

def main():
    if not os.path.exists(SVG_SRC):
        print(f"ERROR: {SVG_SRC} not found", file=sys.stderr); sys.exit(1)

    rasterise = get_rasteriser()
    print(f"Using rasteriser: {rasterise.__name__}")

    iconset_dir = "AppIcon.iconset"
    os.makedirs(iconset_dir, exist_ok=True)

    svg_abs = os.path.abspath(SVG_SRC)
    for logical, scale, fname in ICONSET:
        pixel_size = logical * scale
        out_path   = os.path.join(iconset_dir, fname)
        rasterise(svg_abs, out_path, pixel_size)
        print(f"  {pixel_size}×{pixel_size}  →  {fname}")

    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", ICNS_OUT],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"iconutil error:\n{result.stderr}", file=sys.stderr); sys.exit(1)

    size_kb = os.path.getsize(ICNS_OUT) // 1024
    print(f"\n✓ {ICNS_OUT}  ({size_kb} KB)")

if __name__ == "__main__":
    main()
EOF_PY
chmod +x generate_icon.py
echo -e "${G}✓ generate_icon.py${N}"

# =============================================================================
# 3. Info.plist — v0.9.2 (CFBundleIconFile unchanged: "AppIcon")
# =============================================================================
echo -e "${Y}→ Info.plist (v0.9.2)${N}"
cat > Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>Raketa</string>
    <key>CFBundleIdentifier</key>          <string>com.samurai.raketa</string>
    <key>CFBundleName</key>                <string>Raketa</string>
    <key>CFBundleDisplayName</key>         <string>Raketa</string>
    <key>CFBundleVersion</key>             <string>0.9.2</string>
    <key>CFBundleShortVersionString</key>  <string>0.9.2</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>LSMinimumSystemVersion</key>      <string>10.13.0</string>
    <key>LSUIElement</key>                 <true/>
    <!-- AppIcon → looks for AppIcon.icns in Contents/Resources/ -->
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>    <string>Raketa — Ради вас старался Пашенька</string>
</dict>
</plist>
EOF
echo -e "${G}✓ Info.plist${N}"

# =============================================================================
# 4. build.yml — install cairosvg, run generator, copy icns
# =============================================================================
echo -e "${Y}→ build.yml (v0.9.2)${N}"
cat > .github/workflows/build.yml << 'EOF'
name: Build Raketa
on:
  workflow_dispatch:
  push:
    tags:
      - 'v*'
permissions:
  contents: write

jobs:
  build:
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v3

    - name: Set up Go 1.20
      uses: actions/setup-go@v4
      with:
        go-version: '1.20'

    - name: Build sing-box core
      run: |
        git clone --depth=1 -b v1.8.11 \
          https://github.com/SagerNet/sing-box.git core-build
        cd core-build
        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 \
          go build -tags "with_utls,with_grpc,with_reality" \
          -trimpath -ldflags="-s -w" \
          -o ../sing-box ./cmd/sing-box

    # ── Icon generation ───────────────────────────────────────────────────────
    # cairosvg: pure-Python SVG rasterizer, no system font dependency.
    # Reads AppIcon.svg → produces PNG for every required icns size.
    # iconutil (macOS built-in) assembles AppIcon.icns.
    - name: Generate AppIcon.icns from SVG
      run: |
        pip3 install cairosvg --quiet
        python3 generate_icon.py

    # ── Compile ───────────────────────────────────────────────────────────────
    - name: Compile app
      run: |
        mkdir -p Raketa.app/Contents/MacOS \
                 Raketa.app/Contents/Resources

        echo "APPL????" > Raketa.app/Contents/PkgInfo
        cp Info.plist   Raketa.app/Contents/Info.plist
        # Icon — generated in previous step
        cp AppIcon.icns Raketa.app/Contents/Resources/AppIcon.icns
        # Core binary
        cp sing-box     Raketa.app/Contents/Resources/sing-box
        chmod +x        Raketa.app/Contents/Resources/sing-box

        clang -fobjc-arc \
          -framework Cocoa \
          -framework SystemConfiguration \
          -arch x86_64 -mmacosx-version-min=10.13 \
          -o Raketa.app/Contents/MacOS/Raketa \
          main.m AppDelegate.m ViewController.m

        codesign --force --deep -s - Raketa.app
        zip -r "Raketa-macOS-10.13-${{ github.ref_name }}.zip" Raketa.app

    - name: Release
      uses: softprops/action-gh-release@v1
      with:
        tag_name: ${{ github.ref_name }}
        name: "🚀 Raketa ${{ github.ref_name }}"
        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### v0.9.2 — SVG icon
          - AppIcon.svg добавлен в репозиторий (белая «R» на голубом градиенте)
          - При сборке: SVG → PNG (cairosvg) → AppIcon.icns (iconutil)
          - Нет бинарных файлов в репо, нет зависимости от шрифтов системы
          - Все исправления v0.9.x включены
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF
echo -e "${G}✓ build.yml${N}"

# =============================================================================
echo ""
echo -e "${C}╔══════════════════════════════════════════════════════╗"
echo -e "║  Patch applied. Files added to repo:                 ║"
echo -e "║    AppIcon.svg       — icon source (SVG)             ║"
echo -e "║    generate_icon.py  — SVG → icns at build time      ║"
echo -e "╠══════════════════════════════════════════════════════╣"
echo -e "║  git add -A                                          ║"
echo -e "║  git commit -m 'v0.9.2: SVG icon'                   ║"
echo -e "║  git tag v0.9.2                                      ║"
echo -e "║  git push origin main --tags                         ║"
echo -e "╚══════════════════════════════════════════════════════╝${N}"
