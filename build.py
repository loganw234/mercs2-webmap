#!/usr/bin/env python3
"""build.py -- merge src/ into ONE standalone dist/index.html.

Inlines everything (Leaflet's JS+CSS, our CSS, the embedded map image, the collectibles data, the vendored
ess-bridge.js, and every app/*.js) so the output is a single self-contained file with zero external
requests. That one file works three ways:
  * hosted on GitHub Pages (open the URL),
  * downloaded and opened straight off disk (file://),
  * served by the lua-bridge itself at http://127.0.0.1:27050/ (the all-browsers path for the live overlay).

Edit files under src/ (regenerate the map with tools/gen_map_image.py or the data with the JSON), then
re-run:  python build.py
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src"


def guard(s):
    # never let inlined content close the <script>/<style> early
    return s.replace("</script", "<\\/script").replace("</style", "<\\/style")


def read(*parts):
    return (SRC.joinpath(*parts)).read_text(encoding="utf-8")


def main():
    html = read("index.html")

    leaflet_css = read("lib", "leaflet.css")
    css = read("styles.css")

    leaflet_js = read("lib", "leaflet.js")
    bridge = read("lib", "ess-bridge.js")

    # data blobs (map image + datasets). map-image.js is optional-but-expected; fail loud if it's missing.
    map_js = SRC / "data" / "map-image.js"
    if not map_js.exists():
        raise SystemExit("missing src/data/map-image.js -- run: python tools/gen_map_image.py")
    data = (map_js.read_text(encoding="utf-8") + "\n"
            + read("data", "collectibles.js") + "\n"
            + read("data", "teleports.js"))

    app_files = sorted((SRC / "app").glob("*.js"))
    app = "\n".join("/* ==== %s ==== */\n%s" % (p.name, p.read_text(encoding="utf-8")) for p in app_files)

    html = (html
            .replace("/*__LEAFLET_CSS__*/", guard(leaflet_css))
            .replace("/*__CSS__*/", guard(css))
            .replace("/*__LEAFLET_JS__*/", guard(leaflet_js))
            .replace("/*__BRIDGE__*/", guard(bridge))
            .replace("/*__DATA__*/", guard(data))
            .replace("/*__APP__*/", guard(app)))

    out = ROOT / "dist" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print("[build] wrote %s (%d KB, %d app modules + leaflet + bridge)" % (out, out.stat().st_size // 1024, len(app_files)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
