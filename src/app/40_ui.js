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
  };
})();
