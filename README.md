# Mercs2 Live Map

An interactive top-down map of the Mercenaries 2 world. Overlay JSON point-groups as toggleable **layers**
(the built-in one is the ~100 collectible toolboxes), and — optionally — connect to the running game to see
your **live player position** move on the map in real time.

Built as a **single standalone HTML file**: no build step to *use* it, no server, no external requests. It
works three ways from the exact same file — hosted on GitHub Pages, downloaded and opened off disk, or served
by the game's own lua-bridge at `http://127.0.0.1:27050/`.

## Using it

- **Layers** — toggle each point-group on/off. Click a marker for its coordinates and metadata.
- **Collect tracking** — each collectible's popup has a **Mark collected** button; ticks persist in
  `localStorage` (keyed by `entity_id`), collected boxes dim out, each layer shows `done/total`, and there's
  **Hide collected** + **Reset ticks**.
- **Teleport spots** — a `kind:"teleport"` layer of named locations (bright labelled dots). With the game
  connected, a spot's popup has a **⇱ Teleport here** button that jumps the player there via
  `Ess.Player.teleport(x,y,z,yaw)`. Collect spots three ways: **Save current spot** (reads your live pose),
  **Paste import** (raw `[Ess][LOCATION]` log lines *or* JSON), or edit `teleports.js`. Saved spots live in
  `localStorage`; **Export** dumps all spots as JSON to paste back into `src/data/teleports.js` for everyone.
- **＋ Load JSON layer…** — drop in any JSON array of `{ "position": { "x", "y", "z" }, ... }` points (or a
  `{ name, kind, groupBy, colors, points:[…] }` wrapper) and it becomes a new toggleable layer. This is the
  whole point of the tool being generic — the collectibles are just the first dataset.
- **Live player** *(optional)* — click **Connect to game**. The page talks straight to the running game over
  the lua-bridge WebSocket (`127.0.0.1:27050`) and draws a heading arrow where player 0 is standing, a few
  times a second. It's entirely opt-in: everything else works with no game and no connection. Chrome shows a
  one-time prompt to allow the local connection; opening the page over `https` or from disk both work.
- **Update check** — the *downloaded* (and bridge-served) copy quietly asks GitHub about once a day whether
  a newer build exists (its git commit is stamped in at build time) and offers the release download in a
  dismissible bar. The hosted Pages copy is always current, so it never checks. Offline? Nothing happens.
  "Skip this one" silences that particular version for good.

## How the map lines up

The backdrop is the retail `map.jpg` (8204×8204, world `(0,0)` at centre). Marker placement uses the exact
edge-driven transform from `mercs2-tools/missionforge.html` (confirmed pixel-perfect), so world coordinates
map to the map to the pixel. Leaflet's `CRS.Simple` treats the image as a plain plane; the coordinate space
is the **logical** 8204-unit span, independent of the embedded picture's real size — so the picture can be
downscaled for file size without touching the calibration.

Calibration (see `src/app/00_state.js`): `leftX +4102 / rightX −4102` (world X runs west-positive → grows
left on screen), `topZ +4102 / botZ −4102` (Z is north-up → grows up), `offX/offZ −50`.

## Building

Only needed if you change the source (`src/`). The output is `dist/index.html`.

```
python build.py                         # merge src/ -> dist/index.html (single file)
python tools/gen_map_image.py           # regenerate the embedded map (downscale map.jpg -> src/data/map-image.js)
```

`build.py` inlines Leaflet, the CSS, the embedded map, the data, `ess-bridge.js`, and every `src/app/*.js`.
The map image and collectibles data are pre-generated into `src/data/` and committed, because CI has no copy
of the source `map.jpg` — they're treated like vendored assets.

## Layout

```
build.py                     merge src/ -> dist/index.html
src/
  index.html                 shell with /*__…__*/ inline markers the build fills
  styles.css                 the map's own styling (Leaflet's CSS is inlined separately)
  lib/leaflet.js|.css        vendored Leaflet 1.9.4 (circleMarkers only -> zero image assets needed)
  lib/ess-bridge.js          the browser<->lua-bridge WebSocket client (copied from mercs2-lua-essentials)
  data/map-image.js          window.MERCS_MAP_IMAGE = downscaled map as a data: URI  (generated, committed)
  data/collectibles.js       window.MERCS_DATASETS  = the built-in toolbox layer     (generated, committed)
  data/teleports.js          the shared teleport-spot layer (curated via Export)
  app/00_state.js            shared WM namespace + the map calibration
  app/10_map.js              Leaflet CRS.Simple init + world<->latLng transform
  app/20_layers.js           the generic dataset -> layers loader + panel/legend
  app/24_collected.js        collect-tracking ticks (localStorage) + hide/reset
  app/26_teleport.js         teleport spots: save current / paste import / export / jump
  app/30_live.js             the optional live-player WS overlay
  app/40_ui.js               panel wiring (collapse, load-json, follow, connect)
  app/80_update.js           the once-a-day update check for downloaded copies
  app/99_main.js             boot
tools/gen_map_image.py       downscale + base64 the source map into src/data/map-image.js
```

## Live overlay: what it needs from the game

- The **lua-bridge** running with WebSocket support on `127.0.0.1:27050` (the same bridge the web IDE uses).
- The **Essentials framework** loaded in-game (the overlay polls `Ess.Player.pose(0)`).

The overlay itself only ever *reads* position. The one thing that writes to the game is the **⇱ Teleport
here** button — and only when you click it.
