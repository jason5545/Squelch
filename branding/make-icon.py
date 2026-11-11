#!/usr/bin/env python3
"""產生 Resources/AppIcon.icon（Icon Composer 格式）和 branding/preview.png。

圖案是靜噪：兩條虛線是門檻，門檻內的小條是被壓掉的雜訊（暗），超過門檻的高條是人聲（琥珀色）。
三個圖層分開，讓 macOS 26 的 Liquid Glass 有層次。顏色在 icon.json 的 fill，SVG 一律畫白色。
"""
import json, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Resources", "AppIcon.icon")
ASSETS = os.path.join(ICON, "Assets")

BG = ("#1B2433", "#080B12")       # 夜間駕駛艙
AMBER = "#FFB21E"                 # 無線電面板的琥珀色
NOISE = "#4A5468"
HEIGHTS = [52, 78, 46, 330, 450, 270, 170]   # 半高，1024 畫布
W, GAP, THRESHOLD, SCALE = 70, 34, 104, 0.80

def layout():
    n = len(HEIGHTS)
    total = n * W + (n - 1) * GAP
    return 512 - total / 2, total

def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<g transform="translate(512 512) scale({SCALE}) translate(-512 -512)">{body}</g></svg>')

def bars(loud, color="#FFFFFF"):
    x0, _ = layout()
    out = []
    for i, h in enumerate(HEIGHTS):
        if (h > THRESHOLD) != loud:
            continue
        x = x0 + i * (W + GAP)
        out.append(f'<rect x="{x}" y="{512 - h}" width="{W}" height="{2 * h}" rx="{W / 2}" fill="{color}"/>')
    return "".join(out)

def threshold(color="#FFFFFF"):
    x0, total = layout()
    return "".join(
        f'<line x1="{x0 - 30}" y1="{y}" x2="{x0 + total + 30}" y2="{y}" stroke="{color}" '
        'stroke-width="12" stroke-dasharray="30 22" stroke-linecap="round"/>'
        for y in (512 - THRESHOLD, 512 + THRESHOLD))

def p3(hex_color, alpha=1.0):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"

def group(name, image, color, translucency, glass=True, opacity=1.0):
    return {
        "blur-material": None,
        "layers": [{"fill": {"solid": color}, "glass": glass, "image-name": image, "name": name}],
        "name": name,
        "opacity": opacity,
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "specular": True,
        "translucency": {"enabled": translucency is not None, "value": translucency or 0.5},
    }

def main():
    os.makedirs(ASSETS, exist_ok=True)
    files = {"voice.svg": bars(True), "noise.svg": bars(False), "threshold.svg": threshold()}
    for name, body in files.items():
        with open(os.path.join(ASSETS, name), "w") as f:
            f.write(svg(body))
    icon = {
        "fill": {"linear-gradient": [p3(BG[0]), p3(BG[1])]},
        "groups": [   # 第一個在最上層
            group("Voice", "voice.svg", p3(AMBER), None),
            group("Threshold", "threshold.svg", p3(AMBER, 0.45), 0.2, glass=False),
            group("Noise", "noise.svg", p3(NOISE), 0.15),
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2)
        f.write("\n")

    # 平面預覽（沒有玻璃效果），給 README 和挑色用。
    preview = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
               f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="{BG[0]}"/>'
               f'<stop offset="1" stop-color="{BG[1]}"/></linearGradient></defs>'
               '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>'
               f'<g transform="translate(512 512) scale({SCALE}) translate(-512 -512)">'
               f'{threshold(AMBER + "66")}{bars(False, NOISE)}{bars(True, AMBER)}</g></svg>')
    path = os.path.join(ROOT, "branding", "preview.svg")
    with open(path, "w") as f:
        f.write(preview)
    subprocess.run(["rsvg-convert", "-w", "512", "-h", "512", path, "-o", path.replace(".svg", ".png")], check=True)
    print("wrote", ICON)

if __name__ == "__main__":
    main()
