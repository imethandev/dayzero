"""Steps 3-6 of the offline pipeline: light/dark styles, glyph PBFs and sprites,
all rewritten so every URL points at a file inside Map.bundle.

The app replaces the token {{BUNDLE}} with the bundle's file:// URL at runtime,
because an app's install path is only known on the device.

Usage: python3 prepare_style_assets.py <work dir> <Map.bundle dir>
"""
import json
import os
import shutil
import sys
import urllib.request
import zipfile

work, out = sys.argv[1], sys.argv[2]
TOKEN = "{{BUNDLE}}"
FONTS = ["Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic"]
# Bundled names avoid spaces, so glyph file:// URLs need no percent-encoding.
RENAME = {"Noto Sans Regular": "NotoSans-Regular", "Noto Sans Bold": "NotoSans-Bold", "Noto Sans Italic": "NotoSans-Italic"}
# Every font stack the styles use is collapsed onto one of the bundled fonts.
FONT_MAP = {
    "Metropolis Regular": "Noto Sans Regular",
    "Metropolis Light": "Noto Sans Regular",
    "Metropolis Medium": "Noto Sans Bold",
    "Metropolis Bold": "Noto Sans Bold",
    "Metropolis Light Italic": "Noto Sans Italic",
    "Metropolis Medium Italic": "Noto Sans Italic",
}
STYLES = {
    "light": ("https://raw.githubusercontent.com/openmaptiles/osm-bright-gl-style/master/style.json",
              "https://openmaptiles.github.io/osm-bright-gl-style/sprite"),
    "dark": ("https://raw.githubusercontent.com/openmaptiles/dark-matter-gl-style/master/style.json",
             "https://openmaptiles.github.io/dark-matter-gl-style/sprite"),
}
ATTRIBUTION = "© OpenStreetMap contributors"
# Glyph ranges kept in full: Latin, Greek, Cyrillic, other alphabetic scripts,
# punctuation, currency, arrows and symbols (U+0000-U+22FF), plus Latin ligatures.
# Other ranges (mostly CJK and Hangul, ~30 MB per font) become empty placeholder
# files: MapLibre then draws nothing for those rare characters instead of failing a
# file lookup. Washington labels are almost entirely Latin.
def keep_range(start):
    return start < 0x2300 or start == 0xFB00


def fetch(url, dest):
    if not os.path.exists(dest) or os.path.getsize(dest) == 0:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        req = urllib.request.Request(url, headers={"User-Agent": "DayZero-pipeline"})
        with urllib.request.urlopen(req) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
    return dest


def remap_fonts(node):
    """Rewrite text-font arrays (plain or inside expressions) to a single bundled font."""
    if isinstance(node, list):
        if node and all(isinstance(x, str) for x in node) and any(
            x in FONTS or x in FONT_MAP for x in node
        ):
            for x in node:
                if x in FONTS:
                    return [RENAME[x]]
            return [RENAME[FONT_MAP.get(node[0], FONTS[0])]]
        return [remap_fonts(x) for x in node]
    if isinstance(node, dict):
        return {k: remap_fonts(v) for k, v in node.items()}
    return node


def used_fonts(style):
    found = set()

    def walk(n):
        if isinstance(n, list):
            if n and all(isinstance(x, str) for x in n) and all(x in RENAME.values() for x in n):
                found.update(n)
            for x in n:
                walk(x)
        elif isinstance(n, dict):
            for v in n.values():
                walk(v)

    for layer in style["layers"]:
        walk(layer.get("layout", {}).get("text-font"))
    return found


# --- Glyphs (step 5) ---
zpath = fetch("https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip",
              os.path.join(work, "noto-sans.zip"))
glyph_out = os.path.join(out, "glyphs")
shutil.rmtree(glyph_out, ignore_errors=True)
with zipfile.ZipFile(zpath) as z:
    for name in z.namelist():
        parts = name.split("/")
        # Entries look like "Noto Sans Regular/0-255.pbf" (possibly under a top folder).
        for i, p in enumerate(parts[:-1]):
            if p in FONTS and parts[-1].endswith(".pbf"):
                dest = os.path.join(glyph_out, RENAME[p], parts[-1])
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                start = int(parts[-1].split("-")[0])
                with z.open(name) as src, open(dest, "wb") as f:
                    if keep_range(start):
                        shutil.copyfileobj(src, f)
for font in FONTS:
    n = len(os.listdir(os.path.join(glyph_out, RENAME[font])))
    assert n > 0, f"no glyphs for {font}"
    print(f"glyphs: {font}: {n} ranges")

# --- Styles and sprites (steps 3, 4, 6) ---
for theme, (style_url, sprite_base) in STYLES.items():
    raw = fetch(style_url, os.path.join(work, "styles", f"{theme}-source.json"))
    style = json.load(open(raw))

    sprite_dir = os.path.join(out, "sprites", theme)
    os.makedirs(sprite_dir, exist_ok=True)
    for suffix in ("", "@2x"):
        for ext in ("json", "png"):
            fetch(f"{sprite_base}{suffix}.{ext}", os.path.join(work, "sprites", theme, f"sprite{suffix}.{ext}"))
            shutil.copy(os.path.join(work, "sprites", theme, f"sprite{suffix}.{ext}"),
                        os.path.join(sprite_dir, f"sprite{suffix}.{ext}"))

    style["name"] = f"DayZero {theme}"
    style["sources"] = {
        "openmaptiles": {
            "type": "vector",
            "url": f"pmtiles://{TOKEN}/washington.pmtiles",
            "attribution": ATTRIBUTION,
        }
    }
    style["glyphs"] = f"{TOKEN}/glyphs/{{fontstack}}/{{range}}.pbf"
    style["sprite"] = f"{TOKEN}/sprites/{theme}/sprite"
    style.pop("metadata", None)
    style["layers"] = [remap_fonts(layer) for layer in style["layers"]]

    missing = used_fonts(style) - set(RENAME.values())
    assert not missing, f"{theme}: unbundled fonts {missing}"
    text = json.dumps(style, ensure_ascii=False, separators=(",", ":"))
    for bad in ("http://", "https://", "mapbox://", "{key}"):
        assert bad not in text, f"{theme}: remote reference left in style: {bad}"
    with open(os.path.join(out, f"style-{theme}.json"), "w", encoding="utf-8") as f:
        f.write(text)
    print(f"style-{theme}.json: {len(style['layers'])} layers, fonts {sorted(used_fonts(style))}")
