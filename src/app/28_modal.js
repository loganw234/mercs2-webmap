/* 28_modal.js -- a tiny reusable confirm modal (nicer than window.confirm, and it can render markup -- which
 * the "not too cheaty" toggle needs so it can italicise the *too*). Falls back to window.confirm if the
 * overlay markup isn't present. */
(function () {
  "use strict";
  var WM = window.WM;

  // WM.confirmModal(messageHtml, { okText, cancelText, onOk, onCancel })
  WM.confirmModal = function (messageHtml, opts) {
    opts = opts || {};
    var overlay = document.getElementById("modalOverlay");
    var body = document.getElementById("modalBody");
    var ok = document.getElementById("modalOk");
    var cancel = document.getElementById("modalCancel");
    if (!overlay || !body || !ok || !cancel) {   // no modal markup -> degrade to native confirm
      if (window.confirm(String(messageHtml).replace(/<[^>]+>/g, ""))) { if (opts.onOk) opts.onOk(); }
      else if (opts.onCancel) opts.onCancel();
      return;
    }

    body.innerHTML = messageHtml;
    ok.textContent = opts.okText || "OK";
    cancel.textContent = opts.cancelText || "Cancel";

    function done(confirmed) {
      overlay.hidden = true;
      ok.onclick = cancel.onclick = overlay.onclick = null;
      document.removeEventListener("keydown", onKey);
      if (confirmed) { if (opts.onOk) opts.onOk(); } else if (opts.onCancel) opts.onCancel();
    }
    function onKey(e) { if (e.key === "Escape") done(false); else if (e.key === "Enter") done(true); }

    ok.onclick = function () { done(true); };
    cancel.onclick = function () { done(false); };
    overlay.onclick = function (e) { if (e.target === overlay) done(false); };   // click backdrop = cancel
    document.addEventListener("keydown", onKey);
    overlay.hidden = false;
    ok.focus();
  };
})();
