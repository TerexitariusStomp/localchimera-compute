// browser/lib/legal-operator.js — fills the operator identity into terms.html /
// privacy.html / accessibility.html from /operator.json.
//
// WHY this indirection. playnet is federated: the software is not the data
// controller, the person or collective running THIS gateway is (see
// docs/planning/gdpr-analysis.md, "Who is the controller"). So the legal pages
// ship as a template with the controller's identity left as a slot, and each
// operator fills it once — in the environment, not in a tracked file, so it is
// never committed and a change is a restart away.
//
// The server (server/serve-static.scm, `operator-config`) builds /operator.json
// from PLAYNET_OPERATOR_{NAME,CONTACT,ABUSE,PRIVACY,SECURITY,JURISDICTION,
// ADDRESS,SUPERVISORY,REPRESENTATIVE}. On a deployed box they come from the
// provider config's `operator` alist (deploy/os.scm); locally, export them
// before `make serve`. docs/legal/README.md §2 lists each field.
//
// `abuse` is where a report of unlawful or harmful content, and any child-safety
// concern, goes; `privacy` is where a data-subject request goes. Each is
// optional and, left out, falls back to `contact`: one inbox serves all three
// until the operator separates them (FALLBACK below).
//
// `source` and `docs` are links, not slots: the markup keeps the upstream
// project's own addresses (right for an unmodified deployment) until the
// operator names theirs — the AGPL asks each deployment to offer ITS source.
//
// Every field is optional. A field left out (or the whole block left out)
// leaves the page's inline placeholder text standing, styled as visibly UNSET
// (.op.unset) — an unfilled template must LOOK unfilled, never like a finished
// document that happens to name nobody.
//
// No-JS readers see the placeholders too, which is the correct fallback: the
// obligations in the text do not depend on the operator's name being rendered.

(function () {
  "use strict";
  var slots = document.querySelectorAll("[data-op]");
  // links the operator may point elsewhere: <a data-op-href="source" href="…the upstream…">
  // keeps the upstream href until /operator.json names this deployment's own;
  // <span data-op-label="source"> then shows it without its scheme
  var links = document.querySelectorAll("[data-op-href]");
  var labels = document.querySelectorAll("[data-op-label]");
  if (!slots.length && !links.length) return;
  var FALLBACK = { abuse: "contact", privacy: "contact" };
  var say = function (op, key) {
    var v = op[key];
    if ((typeof v !== "string" || !v.trim()) && FALLBACK[key]) v = op[FALLBACK[key]];
    return typeof v === "string" && v.trim() ? v.trim() : null;
  };

  fetch("operator.json")
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (op) {
      op = op || {};
      links.forEach(function (a) {
        var v = op[a.getAttribute("data-op-href")];
        if (typeof v === "string" && /^https?:\/\//.test(v.trim())) a.setAttribute("href", v.trim());
      });
      labels.forEach(function (el) {
        var v = op[el.getAttribute("data-op-label")];
        if (typeof v === "string" && /^https?:\/\//.test(v.trim()))
          el.textContent = v.trim().replace(/^https?:\/\//, "").replace(/\/$/, "");
      });
      slots.forEach(function (el) {
        var v = say(op, el.getAttribute("data-op"));
        if (v) {
          el.textContent = v;
          el.classList.remove("unset");
        }
      });
    })
    .catch(function () { /* placeholders stand — the intended fallback */ });
})();
