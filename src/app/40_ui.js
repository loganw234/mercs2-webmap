/* 40_ui.js -- wire the panel chrome: collapse toggle, "Load JSON layer…", the follow checkbox, and the
 * live connect/disconnect button. Pure DOM glue over the WM.* functions the other modules expose. */
(function () {
  "use strict";
  var WM = window.WM;

  function $(id) { return document.getElementById(id); }

  WM.wireUI = function () {
    var toggle = $("panelToggle"), panel = $("panel");
    if (toggle && panel) toggle.addEventListener("click", function () {
      panel.classList.toggle("collapsed");
      toggle.textContent = panel.classList.contains("collapsed") ? "›" : "‹";
    });

    var live = $("liveBtn");
    if (live) live.addEventListener("click", function () { WM.connectLive(); });

    var follow = $("followChk");
    if (follow) follow.addEventListener("change", function (e) { WM.follow = e.target.checked; });

    var hide = $("hideCollected");
    if (hide) hide.addEventListener("change", function (e) { WM.setHideCollected(e.target.checked); });

    var reset = $("resetCollected");
    if (reset) reset.addEventListener("click", function () {
      if (window.confirm("Clear all collected ticks?")) {
        if (hide) hide.checked = false;
        WM.hideCollected = false;
        WM.resetCollected();
      }
    });

    var file = $("loadJson");
    if (file) file.addEventListener("change", function (e) {
      var f = e.target.files && e.target.files[0]; if (!f) return;
      var name = f.name.replace(/\.json$/i, "");
      var reader = new FileReader();
      reader.onload = function () {
        var data; try { data = JSON.parse(reader.result); }
        catch (err) { alert("Couldn't parse " + f.name + " as JSON:\n" + err.message); return; }
        try {
          var entry = WM.addDataset(data, name);
          var n = 0; for (var k in entry.groups) n += entry.groups[k].count;
          if (n) WM.fitToLayers(); else alert("Loaded " + f.name + " but found no {position:{x,y,z}} points in it.");
        } catch (err2) { alert("Couldn't load " + f.name + ":\n" + err2.message); }
      };
      reader.readAsText(f);
      e.target.value = "";  // allow re-loading the same file
    });

    // ---- teleport-spot tools: save current position, paste-import, export ----
    var importPane = $("importPane"), exportPane = $("exportPane"), importText = $("importText"), exportText = $("exportText");

    var saveSpot = $("saveSpotBtn");
    if (saveSpot) saveSpot.addEventListener("click", function () {
      if (!(WM.bridge && WM.bridge.state === "open")) { alert("Connect to the game first — then Save current spot reads your live position."); return; }
      var name = window.prompt("Name this spot:", "Spot " + (WM.teleports.user.length + 1));
      if (name === null) return;
      saveSpot.disabled = true; saveSpot.textContent = "Saving…";
      WM.captureSpot(name, function (ok) {
        saveSpot.textContent = ok ? "✓ Saved" : "Save failed";
        setTimeout(function () { saveSpot.textContent = "＋ Save current spot"; saveSpot.disabled = !(WM.bridge && WM.bridge.state === "open"); }, 1300);
      });
    });

    var importBtn = $("importSpotsBtn");
    if (importBtn) importBtn.addEventListener("click", function () {
      if (exportPane) exportPane.hidden = true;
      if (importPane) { importPane.hidden = !importPane.hidden; if (!importPane.hidden && importText) importText.focus(); }
    });
    var importAdd = $("importAdd");
    if (importAdd) importAdd.addEventListener("click", function () {
      var n = WM.teleports.importText(importText ? importText.value : "");
      if (n) { if (importText) importText.value = ""; if (importPane) importPane.hidden = true; }
      else alert("No spots found. Paste [Ess][LOCATION] log lines, or JSON spots.");
    });
    var importCancel = $("importCancel");
    if (importCancel) importCancel.addEventListener("click", function () { if (importPane) importPane.hidden = true; if (importText) importText.value = ""; });

    var exportBtn = $("exportSpotsBtn");
    if (exportBtn) exportBtn.addEventListener("click", function () {
      if (importPane) importPane.hidden = true;
      if (exportText) exportText.value = WM.teleports.exportJSON();
      if (exportPane) { exportPane.hidden = !exportPane.hidden; if (!exportPane.hidden && exportText) { exportText.focus(); exportText.select(); } }
    });
    var exportCopy = $("exportCopy");
    if (exportCopy) exportCopy.addEventListener("click", function () {
      if (!exportText) return;
      exportText.select();
      var done = function () { exportCopy.textContent = "Copied ✓"; setTimeout(function () { exportCopy.textContent = "Copy"; }, 1200); };
      try { if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(exportText.value).then(done, function () { try { document.execCommand("copy"); done(); } catch (e) {} }); return; } } catch (e) {}
      try { document.execCommand("copy"); done(); } catch (e) {}
    });

    // ---- "Teleport to all" toggle (with the obligatory ceremony) ----
    var tpAll = $("tpAllToggle");
    if (tpAll) {
      tpAll.checked = WM.tpAllEnabled ? WM.tpAllEnabled() : false;
      tpAll.addEventListener("change", function () {
        if (!tpAll.checked) { WM.setTpAll(false); return; }   // turning it OFF needs no ceremony
        WM.confirmModal(
          "<h3>Enable not <em>too</em> cheaty mode?</h3>"
          + "<p>This lets you teleport to <b>any</b> point on <b>any</b> layer — every collectible, every marker — not just the teleport spots.</p>"
          + "<p class='modal-fine'>Strictly for efficient traversal, obviously.</p>",
          { okText: "Enable it 😏", cancelText: "Nah, keep it fair",
            onOk: function () { WM.setTpAll(true); },
            onCancel: function () { tpAll.checked = false; } });
      });
    }
  };
})();
