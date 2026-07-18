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
    if (window.MERCS_TELEPORTS) { try { WM.addDataset(window.MERCS_TELEPORTS); } catch (e) {} }
    WM.renderLayerPanel();
    WM.renderLegend();
    if (WM.updateProgress) WM.updateProgress();
    WM.wireUI();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
