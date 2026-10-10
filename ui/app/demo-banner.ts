// app/demo-banner.ts — the deployment's own operational status, said once.
//
// A member and a regulator both need the same fact in front of them before
// anything else loads: what has this gateway's software actually organized
// so far? `legal-product.ts`'s DEPLOYMENT_STATUS is product.scm's own
// sentence, the same one the terms (§9) and the privacy notice quote in their
// marked figures — one source, three places. This is the fourth: a ribbon
// pinned above every face, dismissible for as long as the sentence stays the
// same (K.demoBannerSeen), reappearing the moment an operator edits it,
// exactly as a superseded legal-notice acceptance reappears (app/tabs/social/id.ts).
//
// What this is not: a consent gate. Nothing here blocks an action or records
// anything about the member — it is the operator speaking about itself, not
// asking the member to agree to something. main.ts imports this for its
// effect, the way it imports storage-notice.js.

import { K } from "./keys.js";
import { readStr, writeStr } from "./store.js";
import { DEPLOYMENT_STATUS } from "./legal-product.js";

function dismiss(): void {
  writeStr(K.demoBannerSeen, DEPLOYMENT_STATUS);
  document.getElementById("demo-banner")?.remove();
}

if (DEPLOYMENT_STATUS && readStr(K.demoBannerSeen) !== DEPLOYMENT_STATUS) {
  const bar = document.createElement("div");
  bar.id = "demo-banner";
  bar.className = "demo-banner";
  bar.setAttribute("role", "status");
  const text = document.createElement("span");
  text.textContent = DEPLOYMENT_STATUS;
  const close = document.createElement("button");
  close.className = "demo-banner-x";
  close.setAttribute("aria-label", "dismiss");
  close.textContent = "✕";
  close.addEventListener("click", dismiss);
  bar.append(text, close);
  document.body.prepend(bar);
}
