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
