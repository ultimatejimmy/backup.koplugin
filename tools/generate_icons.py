#!/usr/bin/env python3
"""
generate_icons.py
Generates 64x64 and 256x256 icons (PNG, SVG, ICO) from the Feather 'zap' SVG icon.
Uses resvg-py for pixel-perfect Rust-based SVG rendering and Pillow for icon formatting.
"""

import io
import os
import sys
from pathlib import Path

try:
    import resvg_py
    from PIL import Image
except ImportError as e:
    print(f"Missing required dependency: {e}")
    print("Install via: pip install resvg-py pillow")
    sys.exit(1)

# Feather Zap polygon: (13,2) -> (3,14) -> (12,14) -> (11,22) -> (21,10) -> (12,10) -> (13,2)
FEATHER_ZAP_PATH = "13 2 3 14 12 14 11 22 21 10 12 10 13 2"

def make_svg(width=24, height=24, stroke="black", fill="none", stroke_width=2):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 24 24" fill="{fill}" stroke="{stroke}" stroke-width="{stroke_width}" '
        f'stroke-linecap="round" stroke-linejoin="round">\n'
        f'  <polygon points="{FEATHER_ZAP_PATH}"/>\n'
        f'</svg>\n'
    )

def main():
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    assets_dir = repo_root / "backup.koplugin" / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)

    print(f"Target assets directory: {assets_dir}")

    # 1. Base SVGs
    svg_24 = make_svg(24, 24, stroke="black")
    svg_64 = make_svg(64, 64, stroke="black")
    svg_256 = make_svg(256, 256, stroke="black")

    (assets_dir / "zap.svg").write_text(svg_24, encoding="utf-8")
    (assets_dir / "zap-64.svg").write_text(svg_64, encoding="utf-8")
    (assets_dir / "zap-256.svg").write_text(svg_256, encoding="utf-8")
    print("Saved zap.svg, zap-64.svg, zap-256.svg")

    # 2. Render standard Feather outlined PNGs (black stroke, transparent bg)
    for size in (64, 256):
        svg_code = make_svg(size, size, stroke="#000000", fill="none", stroke_width=2)
        png_bytes = resvg_py.svg_to_bytes(svg_string=svg_code, width=size, height=size)
        out_path = assets_dir / f"zap-{size}.png"
        out_path.write_bytes(png_bytes)
        img = Image.open(io.BytesIO(png_bytes))
        print(f"Saved {out_path.name}: {img.size} ({img.mode}, {len(png_bytes)} bytes)")

    # 3. Render filled variant PNGs (black fill, transparent bg)
    for size in (64, 256):
        svg_code = make_svg(size, size, stroke="#000000", fill="#000000", stroke_width=2)
        png_bytes = resvg_py.svg_to_bytes(svg_string=svg_code, width=size, height=size)
        out_path = assets_dir / f"zap-filled-{size}.png"
        out_path.write_bytes(png_bytes)
        print(f"Saved {out_path.name}")

    # 4. Render dark mode / white stroke PNGs (white stroke, transparent bg)
    for size in (64, 256):
        svg_code = make_svg(size, size, stroke="#ffffff", fill="none", stroke_width=2)
        png_bytes = resvg_py.svg_to_bytes(svg_string=svg_code, width=size, height=size)
        out_path = assets_dir / f"zap-white-{size}.png"
        out_path.write_bytes(png_bytes)
        print(f"Saved {out_path.name}")

    # 5. Multi-size ICO file for desktop / web icon use
    ico_path = assets_dir / "zap.ico"
    img_256 = Image.open(assets_dir / "zap-256.png")
    img_256.save(ico_path, format="ICO", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print(f"Saved {ico_path.name} (multi-size: 16, 32, 48, 64, 128, 256)")

    print("\nIcon generation complete!")

if __name__ == "__main__":
    main()
