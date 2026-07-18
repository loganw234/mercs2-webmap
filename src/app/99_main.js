/* 99_main.js -- boot. Build the map, drop in the built-in datasets (the collectibles), wire the panel. */
(function () {
  "use strict";
  var WM = window.WM;

  function boot() {
    WM.initMap();
    if (WM.initCollected) WM.initCollected();   // load saved ticks + wire popup buttons before markers are placed
    if (WM.initTeleport) WM.initTeleport();     // wire "Teleport here" popup buttons
    var built = window.MERCS_DATASETS || [];
    built.forEach(function (ds) { try { WM.addDataset(ds); } catch (e) { /* one bad dataset shouldn't kill the map */ } });
    if (WM.teleports) { try { WM.teleports.init(); } catch (e) {} }   // built-in + localStorage spots -> the teleport layer
    if (WM.initHeightmap) { try { WM.initHeightmap(); } catch (e) {} }   // ground-height grid: query + elevation overlay
    WM.renderLayerPanel();
    WM.renderLegend();
    if (WM.updateProgress) WM.updateProgress();
    WM.wireUI();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
