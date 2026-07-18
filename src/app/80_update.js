/* 80_update.js -- "check for updates" for the copies that can't update themselves: the downloaded file://
   standalone and the bridge-served page. (The GitHub Pages copy IS the latest build -- no check there.)
   The build's git commit is stamped in at build time (window.WM_BUILD, see build.py); once a day we ask
   api.github.com (CORS: *) for the repo's current HEAD. A strictly newer commit shows a dismissible bar
   linking the rolling release download. "Skip this one" remembers that sha and stays quiet until the NEXT
   update after it. Offline / rate-limited / fetch-less -> silently do nothing. */
(function () {
  "use strict";
  var B = window.WM_BUILD || {};
  var API = "https://api.github.com/repos/loganw234/mercs2-webmap/commits/master";
  var KEY = "m2map.update.v1", CHECK_EVERY = 20 * 3600e3;   // ~daily, survives frequent reopens
  var $ = function (id) { return document.getElementById(id); };

  var isLocalCopy = location.protocol === "file:" || location.host === "127.0.0.1:27050";
  if (!isLocalCopy || !window.fetch || !B.sha || B.sha === "dev") return;

  var st = {};
  try { st = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) {}
  function save() { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} }

  try { document.querySelector("#panel h1").title = "build " + B.sha + (B.date ? " · " + B.date.slice(0, 10) : ""); } catch (e) {}

  function maybeShow(remote) {
    if (!remote || !remote.sha || remote.sha === B.sha || st.skip === remote.sha) return;
    // only a strictly NEWER commit counts -- a locally rebuilt page ahead of origin stays quiet
    if (remote.date && B.date && !(new Date(remote.date) > new Date(B.date))) return;
    $("updbar").hidden = false;
  }

  $("updClose").onclick = function () { $("updbar").hidden = true; };
  $("updSkip").onclick = function () {
    if (st.remote) { st.skip = st.remote.sha; save(); }
    $("updbar").hidden = true;
  };

  var now = Date.now();
  if (st.last && now - st.last < CHECK_EVERY) { maybeShow(st.remote); return; }
  fetch(API, { headers: { Accept: "application/vnd.github+json" } })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (j) {
      if (!j || !j.sha) return;
      var remote = { sha: j.sha.slice(0, 7), date: (j.commit && j.commit.committer && j.commit.committer.date) || "" };
      st.last = now; st.remote = remote; save();
      maybeShow(remote);
    })
    .catch(function () {});
})();
