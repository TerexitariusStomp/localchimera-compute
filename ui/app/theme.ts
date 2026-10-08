// app/theme.ts — the site's theme: ONE mapping over every colour it draws.
//
// The whole sheet in app.html is written in tokens (`var(--t-2c4a6e)`), and the
// token NAME carries its own base value — so a theme doesn't have to re-author
// 260 colours by hand. A theme is a FUNCTION in perceptual space: take each base
// colour's (lightness, chroma, hue), move it, write the result back as one
// `<style>` override on :root. Night is "invert the lightness, keep the hue".
// That's the whole trick, and it's why adding a theme is ~4 lines below rather
// than a second stylesheet.
//
// Reactive: the pick is a signal (app/reactive.js). An effect re-renders the
// override block, stamps `data-theme` on <html>, saves the choice, re-tints the
// identity palette (app/palette.js) and fires `playnet:theme` for the faces
// that paint in JS.

import { signal, effect } from "./reactive.js";
import { retint } from "./palette.js";
import { clamp01 } from "./geom.js";
import { readStr, writeStr } from './store.js';
import { K } from "./keys.js";

/**
 * A colour in Ottosson's OKLab cylindrical form: perceived lightness, chroma,
 * hue in degrees. Every theme is a function in this space.
 */
export interface Oklch {
  L: number;
  C: number;
  h: number;
}

/** A theme IS this function: where each base colour should land. */
export type ThemeMap = (c: Oklch) => Oklch;

/** A theme you can actually paint with. */
export interface PaintTheme {
  id: string;
  label: string;
  hint: string;
  dark?: boolean;
  map: ThemeMap;
  follows?: undefined;
}

/**
 * A theme that defers to the system instead of painting. "auto" is not a theme
 * you can map a colour through — it is a pointer at one — so it carries no
 * `map`, and the split is what lets activeTheme() promise a PaintTheme.
 */
export interface FollowTheme {
  id: string;
  label: string;
  hint: string;
  follows: true;
  map?: undefined;
  dark?: undefined;
}

export type Theme = PaintTheme | FollowTheme;

/* ---- perceptual colour space (Ottosson's OKLab) ---------------------------
   sRGB is not perceptual: halving #ffff00's channels reads as a different
   colour, not a darker yellow. OKLab's L IS perceived lightness, so "invert the
   lightness, keep the hue" is a one-liner that looks right on every hue. */


const lin = (c: number): number => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const gam = (c: number): number => (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);

function hexToOklch(hex: string): Oklch {
  const n = parseInt(hex, 16);
  const r = lin(((n >> 16) & 255) / 255), g = lin(((n >> 8) & 255) / 255), b = lin((n & 255) / 255);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
  const A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  return { L, C: Math.hypot(A, B), h: (Math.atan2(B, A) * 180) / Math.PI };
}

function oklchToRgb({ L, C, h }: Oklch): [number, number, number] {
  const rad = (h * Math.PI) / 180, A = C * Math.cos(rad), B = C * Math.sin(rad);
  const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
  const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
  const s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3;
  return [
    clamp01(gam(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
    clamp01(gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
    clamp01(gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)),
  ].map(v => Math.round(v * 255)) as [number, number, number];
}

// out-of-gamut colours clip to garbage (a bright clipped blue reads as magenta),
// so walk the chroma down until the round-trip is faithful — the standard
// gamut-map for OKLCh, cheap enough at ~260 tokens.
function toHex(c: Oklch): { hex: string; rgb: [number, number, number] } {
  let { L, C, h } = c;
  L = clamp01(L);
  for (let i = 0; i < 12; i++) {
    const [r, g, b] = oklchToRgb({ L, C, h });
    const back = hexToOklch(((r << 16) | (g << 8) | b).toString(16).padStart(6, "0"));
    if (Math.abs(back.L - L) < 0.012 && Math.abs(back.C - C) < 0.012) break;
    C *= 0.85;
  }
  const [r, g, b] = oklchToRgb({ L, C, h });
  return { hex: ((r << 16) | (g << 8) | b).toString(16).padStart(6, "0"), rgb: [r, g, b] };
}

/* ---- the themes ------------------------------------------------------------
   Each `map` takes the base colour in OKLCh and returns where it should land.
   `day` is the identity (the sheet as authored). Everything else is a move. */

export const THEMES: Theme[] = [
  { id: "day", label: "day", hint: "the sheet as authored — paper white", dark: false,
    map: c => c },

  { id: "night", label: "night", hint: "lightness inverted, hue kept", dark: true,
    // Neutrals INVERT — white becomes the ground (1 → 0.13), ink becomes light.
    // Colours don't: a coral flipped to maroon stops reading as coral, and the
    // faces use hue for identity (a need, a boundary, a rail). So the more chroma
    // a colour carries, the more it just moves to a legible band on dark ground —
    // blended by chroma, so there's no seam between the two rules.
    map: c => {
      const vivid = Math.min(1, c.C / 0.11);
      const inverted = 0.955 - 0.825 * c.L;      // the ground/ink flip
      const kept = 0.44 + 0.40 * c.L;            // hues, held where they stay legible
      return { L: inverted * (1 - vivid) + kept * vivid,
               C: c.C * (1 + 0.18 * (1 - c.L)), h: c.h };
    } },

  { id: "sepia", label: "sepia", hint: "warm paper — old print", dark: false,
    // compress toward parchment and pull every hue a few degrees toward amber
    map: c => ({ L: 0.055 + 0.9 * c.L, C: c.C * 0.72 + 0.012, h: c.h + 0.35 * angDiff(c.h, 75) }) },

  { id: "ink", label: "ink", hint: "high contrast, near-monochrome", dark: false,
    // push lightness away from the middle and drain the hue: maximal legibility
    map: c => ({ L: c.L < 0.5 ? 0.06 + c.L * 0.62 : 1 - (1 - c.L) * 0.62, C: c.C * 0.28, h: c.h }) },

  { id: "auto", label: "auto", hint: "follow the system — day or night", follows: true },
];

// shortest signed turn from hue a to hue b, in degrees
function angDiff(a: number, b: number): number { let d = (b - a) % 360; if (d > 180) d -= 360; if (d < -180) d += 360; return d; }

/* ---- the token registry ----------------------------------------------------
   The names come from the generated :root block in app.html; each name IS its
   own base value (`--t-2c4a6e` ⇒ #2c4a6e), so we never duplicate the palette
   here and can never drift out of sync with the sheet. */

function readTokens(): string[] {
  const seen = new Set<string>();
  for (const sheet of document.styleSheets) {
    let rules; try { rules = sheet.cssRules; } catch { continue; }   // cross-origin sheet
    for (const r of rules || []) {
      // A CSSRuleList holds every kind of rule; the two reads below ARE the test
      // for the one kind we want, so narrow by that rather than by instanceof.
      const rule = r as CSSStyleRule;
      if (rule.selectorText !== ":root" || !rule.style) continue;
      for (const p of rule.style) if (/^--t-[0-9a-f]{6}$/.test(p)) seen.add(p.slice(4));
    }
  }
  return [...seen];
}

let TOKENS: string[] = [];

/* ---- applying a theme ------------------------------------------------------ */

const dark = matchMedia("(prefers-color-scheme: dark)");
const STORE = K.theme;

// ?theme=night wins over the saved pick — a shareable/dev-testable override
const asked = new URLSearchParams(location.search).get("theme");
export const theme = signal(
  (THEMES.some(t => t.id === asked) && asked) || readStr(STORE) || "auto");
export function setTheme(id: string): void { theme.set(id); }

// the theme actually in force (resolves "auto" against the system)
const systemDark = signal(dark.matches);
dark.addEventListener("change", e => systemDark.set(e.matches));
export function activeTheme(): PaintTheme {
  const t = THEMES.find(t => t.id === theme());
  if (t && !t.follows) return t;
  // "day" and "night" are both authored in THEMES above, so this cannot miss.
  return THEMES.find(x => x.id === (systemDark() ? "night" : "day")) as PaintTheme;
}

/* ---- the JS paint seam -----------------------------------------------------
   The CSS half of the site themes itself (every declaration is a token). The
   other half is painted from JS — d3 sets `fill` / `stroke` / `background` on
   thousands of nodes per redraw, from literals and from lookup tables. Rather
   than rewrite ~340 call sites (and freeze their colours at module-load time),
   we theme the values on their way INTO the DOM: paintThrough() below wraps
   d3's attr/style/html, so a colour is mapped at paint time, from the base hue
   the code actually wrote. The code keeps saying `"#2c4a6e"`; the DOM gets
   whatever the theme in force makes of it. */

const CACHE = new Map();                                   // "<theme>|<in>" → out
const HEX = /#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?\b/g;
const RGB = /rgba?\(\s*(\d+)\s*[, ]\s*(\d+)\s*[, ]\s*(\d+)\s*(?:[,/]\s*([\d.]+)\s*)?\)/g;
const URLREF = /url\(\s*#[^)]*\)/g;                        // url(#gradient) is NOT a colour

function mapHex(h: string): string {
  h = h.length === 3 ? h.split("").map(c => c + c).join("") : h;
  return "#" + toHex(activeTheme().map(hexToOklch(h.toLowerCase()))).hex;
}

// map every colour inside a CSS-ish string ("1px solid #ccc", "rgba(0,0,0,.3)",
// a whole `style="…"` body) — anything that isn't a colour passes through.
export function themeColorsIn(str: string): string {
  const t = activeTheme();
  if (!t || t.id === "day" || !str) return str;
  const key = t.id + "|" + str;
  const hit = CACHE.get(key);
  if (hit !== undefined) return hit;
  const refs: string[] = [];
  let out = String(str).replace(URLREF, m => (refs.push(m), "\u0000" + (refs.length - 1) + "\u0000"));
  out = out
    .replace(HEX, m => mapHex(m.slice(1)))
    .replace(RGB, (_m, r, g, b, a) => {
      const c = mapHex(((+r << 16) | (+g << 8) | +b).toString(16).padStart(6, "0")).slice(1);
      const [nr, ng, nb] = [c.slice(0, 2), c.slice(2, 4), c.slice(4)].map(x => parseInt(x, 16));
      // comma syntax on the way out: d3.color() (and older parsers) reject the
      // space-separated CSS Color 4 form, and these strings flow back through it
      return a === undefined ? `rgb(${nr},${ng},${nb})` : `rgba(${nr},${ng},${nb},${a})`;
    })
    .replace(/\u0000(\d+)\u0000/g, (_m, i) => refs[+i]);
  CACHE.set(key, out);
  return out;
}

// map ONE value through the theme in force. Strings are mapped colour-wise;
// FUNCTIONS are wrapped (d3 takes `d => colour` accessors everywhere), so a
// per-datum colour is themed when it is actually computed; anything else passes
// through untouched.
export function themed<T>(v: T): T {
  const t = activeTheme();
  if (!t || t.id === "day" || v == null) return v;
  // A d3 accessor is themed when it is actually computed, not now — so wrap it
  // and map whatever it eventually returns.
  if (typeof v === "function") return function (this: unknown, ...a: unknown[]) { return themed(v.apply(this, a)); } as T;
  return (typeof v === "string" ? themeColorsIn(v) : v) as T;
}

// markup handed to .html(): theme the colours inside style="…" attributes only —
// never touch hrefs, ids or url(#…) references.
const STYLE_ATTR = /style\s*=\s*(["'])([\s\S]*?)\1/g;
export function themedMarkup<T>(html: T): T {
  const t = activeTheme();
  if (!t || t.id === "day" || typeof html !== "string") return html;
  return html.replace(STYLE_ATTR, (_m: string, q: string, body: string) => `style=${q}${themeColorsIn(body)}${q}`) as T;
}

// a colour property is anything whose NAME suggests one — `stroke-width` and
// `border-radius` come along for the ride and simply have no colour to map.
const COLORISH = /color|fill|stroke|background|border|outline|shadow|stop|flood/i;

export function paintThrough(d3: { selection?: d3.Paintable; transition?: d3.Paintable }): void {
  for (const proto of [d3?.selection?.prototype, d3?.transition?.prototype]) {
    if (!proto || proto.__themedPaint) continue;
    proto.__themedPaint = true;
    for (const m of ["attr", "style"] as const) {
      const inner = proto[m];
      // Rest params rather than `arguments`: the length test is the same one
      // (a one-argument call is d3's GETTER and must pass straight through),
      // and an actual array forwards without a cast.
      proto[m] = function (this: unknown, ...args: unknown[]) {
        const [name, value, ...rest] = args;
        if (args.length < 2 || typeof name !== "string" || !COLORISH.test(name))
          return inner.apply(this, args);
        return inner.call(this, name, themed(value), ...rest);
      };
    }
    const inner = proto.html;
    proto.html = function (this: unknown, ...args: unknown[]) {
      if (args.length === 0) return inner.apply(this, args);
      const [v] = args;
      if (typeof v === "function")
        return inner.call(this, function (this: unknown, ...a: unknown[]) { return themedMarkup(v.apply(this, a)); });
      return inner.call(this, themedMarkup(v));
    };
  }
}

function styleEl(): HTMLStyleElement {
  let el = document.getElementById("themevars") as HTMLStyleElement | null;
  if (!el) { el = document.createElement("style"); el.id = "themevars"; document.head.appendChild(el); }
  return el;
}

function render(): void {
  const t = activeTheme();
  if (!TOKENS.length) TOKENS = readTokens();
  const decls = TOKENS.map(h => {
    const { hex, rgb } = t.id === "day"
      ? { hex: h, rgb: [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4), 16)] }
      : toHex(t.map(hexToOklch(h)));
    return `--t-${h}:#${hex};--t-${h}-rgb:${rgb[0]} ${rgb[1]} ${rgb[2]};`;
  });
  const css = ":root{" + decls.join("") + "}";
  styleEl().textContent = css;
  document.getElementById("themeflash")?.remove();   // the pre-paint guard has done its job
  // the whole rendered palette, for the guard to apply before the modules parse:
  // the next load paints in this theme from its first frame
  writeStr(K.themeCss, css);
  document.documentElement.dataset.theme = t.id;
  document.documentElement.style.colorScheme = t.dark ? "dark" : "light";
  // the pre-paint guard in app.html reads this back on the next load, so a night
  // user never gets a white flash before the module graph has even parsed
  writeStr(K.themeBg, themed("#ffffff"));
  document.dispatchEvent(new CustomEvent("playnet:theme", { detail: { theme: t.id, dark: !!t.dark } }));
}

// identity colours (needs, boundaries) live in palette.js as base hexes; they go
// through the same mapping, resolved at draw time.
retint(hex => themed(hex));

// d3 is a classic script (loaded before any module), so it is already here: every
// fill/stroke/background the faces paint now passes through the theme.
if (typeof window !== "undefined" && window.d3) paintThrough(window.d3);

effect(() => { theme(); systemDark(); render(); });          // reactive: re-render on either
effect(() => writeStr(STORE, theme()));

/* ---- the picker ------------------------------------------------------------
   A quiet ◑ in the top bar; the list is generated from THEMES, so a new theme
   above shows up here for free. */

export function mountPicker(host: HTMLElement | null | undefined): void {
  if (!host || host.querySelector("#themebtn")) return;
  const wrap = document.createElement("div");
  wrap.id = "themepick";
  const btn = document.createElement("button");
  // the glyph is a half-filled disc built out of the tokens themselves (no ◑
  // char — the Inter subset doesn't carry it), so the button re-hues too
  btn.id = "themebtn"; btn.type = "button"; btn.title = "theme";
  btn.setAttribute("aria-label", "theme");
  btn.innerHTML = '<span class="themedisc"></span>';
  const menu = document.createElement("div");
  menu.id = "thememenu";

  // Each option keeps the theme it was built from, so the effect below never
  // has to find it again by reading back the id it just wrote.
  const opts = THEMES.map(t => {
    const o = document.createElement("div");
    o.className = "themeopt"; o.dataset.id = t.id; o.title = t.hint;
    o.innerHTML = `<span class="themesw"></span><b>${t.label}</b><span class="themehint">${t.hint}</span>`;
    o.onclick = () => { setTheme(t.id); menu.classList.remove("on"); };
    menu.appendChild(o);
    return { t, o };
  });

  btn.onclick = e => { e.stopPropagation(); menu.classList.toggle("on"); };
  document.addEventListener("click", () => menu.classList.remove("on"));
  document.addEventListener("keydown", e => { if (e.key === "Escape") menu.classList.remove("on"); });

  wrap.append(btn, menu);
  host.appendChild(wrap);

  // the menu is reactive too — the tick follows the signal, and each swatch
  // shows that theme's own ground colour, computed by its own mapping.
  effect(() => {
    const cur = theme();
    for (const { t, o } of opts) {
      o.classList.toggle("on", t.id === cur);
      const sw = o.querySelector<HTMLElement>(".themesw")!;
      const g = t.follows ? (systemDark() ? "#1b1e24" : "#ffffff")
                          : "#" + toHex(t.map(hexToOklch("ffffff"))).hex;
      const ink = t.follows ? (systemDark() ? "#e8e6e2" : "#222222")
                            : "#" + toHex(t.map(hexToOklch("222222"))).hex;
      sw.style.background = g; sw.style.borderColor = ink;
    }
  });
}
