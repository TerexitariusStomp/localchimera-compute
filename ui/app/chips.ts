// app/chips.ts — the one toggle-chip button every screen's own options row
// uses. Not in rest.ts: rest.ts is pure enough that node runs it standalone
// (tests/browser/rest-test.mjs imports it with no DOM), and template.js
// needs a browser (`matchMedia`) at load time — a chip belongs with the
// other DOM-facing components, not the pure catalogue port.

import { html } from './template.js';
import type { Fragment } from './template.js';

export const chip = (on: boolean, label: string, onclick: () => void, title = ""): Fragment =>
  html`<button class="ob-chip ${on ? "on" : ""}" title="${title}" onclick=${onclick}>${label}</button>`;
