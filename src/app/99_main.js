/* 99_main.js -- boot. Build the map, drop in the built-in datasets (the collectibles), wire the panel. */
(function () {
  "use strict";
  var WM = window.WM;

  function boot() {
    WM.initMap();
    var built = window.MERCS_DATASETS || [];
    built.forEach(function (ds) { try { WM.addDataset(ds); } catch (e) { /* one bad dataset shouldn't kill the map */ } });
    WM.renderLayerPanel();
    WM.renderLegend();
    WM.wireUI();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
