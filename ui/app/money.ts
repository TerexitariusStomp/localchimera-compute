// app/money.ts — what an hour of credit reads as in a currency, and which
// currency this reader wants it read in.
//
// Credit is denominated in labour-hours and never leaves the commons
// (playnet.typ §The credit identity). A currency is an EXTERNAL ASSET the
// commons acquired, priced like any other good at what it cost society: the
// hours spent obtaining a unit, its crystallized SNLT (§Credits and external
// liquidity — "if acquiring $1 000 requires 20 hours, the SNLT of $1 000 is
// 20 hours"). So the rate between an hour and a currency is not a market
// quote: it is read off the inventory's money spec, `spec-<code>`, whose unit
// names the amount ("€100", "0.1 XMR") and whose snlt says the hours. A
// currency the commons holds none of has no rate, and this module says so
// rather than inventing one.
//
// The reader's default currency is a preference. Unset, it follows where the
// device says it is — the time zone first, the locale's region second — and
// falls back to the dollar.

import { EXT } from './core.js';
import { DEMO_SPECS } from './desire-projection.js';
import { currency, setCurrency } from './prefs.js';
import type { InventorySpec } from './seam.js';

export { currency, setCurrency };

/** The currencies the reader can pick — the money units the slots know, plus the common ones a device may sit in. */
export const CURRENCIES: { code: string; symbol: string; name: string }[] = [
  { code: "USD", symbol: "$",  name: "US dollar" },
  { code: "EUR", symbol: "€",  name: "euro" },
  { code: "GBP", symbol: "£",  name: "pound sterling" },
  { code: "CHF", symbol: "CHF", name: "Swiss franc" },
  { code: "CAD", symbol: "C$", name: "Canadian dollar" },
  { code: "AUD", symbol: "A$", name: "Australian dollar" },
  { code: "JPY", symbol: "¥",  name: "yen" },
  { code: "INR", symbol: "₹",  name: "rupee" },
  { code: "BRL", symbol: "R$", name: "real" },
  { code: "MXN", symbol: "MX$", name: "peso" },
  { code: "XMR", symbol: "ɱ",  name: "monero" },
];
export const symbolOf = (code: string): string => (CURRENCIES.find(c => c.code === code) || { symbol: code }).symbol;

/**
 * The currency a time zone implies. Prefixes are tried longest first, so
 * "Europe/London" finds the pound before "Europe/" finds the euro. The
 * table is the zones a device commonly reports, not the world.
 */
const TZ_CURRENCY: [string, string][] = [
  ["Europe/London", "GBP"], ["Europe/Dublin", "EUR"], ["Europe/Zurich", "CHF"],
  ["Europe/Warsaw", "PLN"], ["Europe/Prague", "CZK"], ["Europe/Budapest", "HUF"],
  ["Europe/Stockholm", "SEK"], ["Europe/Oslo", "NOK"], ["Europe/Copenhagen", "DKK"],
  ["Europe/Istanbul", "TRY"], ["Europe/Moscow", "RUB"], ["Europe/Kyiv", "UAH"],
  ["Europe/", "EUR"],
  ["America/Toronto", "CAD"], ["America/Vancouver", "CAD"], ["America/Edmonton", "CAD"], ["America/Winnipeg", "CAD"], ["America/Halifax", "CAD"],
  ["America/Mexico_City", "MXN"], ["America/Sao_Paulo", "BRL"], ["America/Argentina/", "ARS"],
  ["America/Bogota", "COP"], ["America/Lima", "PEN"], ["America/Santiago", "CLP"],
  ["America/", "USD"],
  ["Asia/Kolkata", "INR"], ["Asia/Tokyo", "JPY"], ["Asia/Shanghai", "CNY"], ["Asia/Hong_Kong", "HKD"],
  ["Asia/Singapore", "SGD"], ["Asia/Seoul", "KRW"], ["Asia/Bangkok", "THB"], ["Asia/Jakarta", "IDR"],
  ["Asia/Manila", "PHP"], ["Asia/Karachi", "PKR"], ["Asia/Dhaka", "BDT"], ["Asia/Dubai", "AED"],
  ["Asia/Tel_Aviv", "ILS"], ["Asia/Jerusalem", "ILS"],
  ["Australia/", "AUD"], ["Pacific/Auckland", "NZD"],
  ["Africa/Johannesburg", "ZAR"], ["Africa/Lagos", "NGN"], ["Africa/Nairobi", "KES"], ["Africa/Cairo", "EGP"],
];
/** The currency a locale's region implies, for the regions the zone table does not settle. */
const REGION_CURRENCY: Record<string, string> = {
  US: "USD", GB: "GBP", IE: "EUR", DE: "EUR", FR: "EUR", ES: "EUR", IT: "EUR", NL: "EUR", BE: "EUR", AT: "EUR", PT: "EUR", FI: "EUR", GR: "EUR",
  CH: "CHF", CA: "CAD", AU: "AUD", NZ: "NZD", JP: "JPY", IN: "INR", BR: "BRL", MX: "MXN", CN: "CNY", KR: "KRW", ZA: "ZAR",
};

/** Where the device says it is, read as a currency — or null when nothing says. */
export function currencyForHere(tz = Intl.DateTimeFormat().resolvedOptions().timeZone, lang = navigator.language): string | null {
  if (tz) {
    const hit = TZ_CURRENCY.find(([prefix]) => tz.startsWith(prefix));
    if (hit) return hit[1];
  }
  const region = (lang || "").split(/[-_]/)[1];
  return (region && REGION_CURRENCY[region.toUpperCase()]) || null;
}

/** The currency in force: the reader's pick, else the device's, else the dollar. */
export const currencyInForce = (): string => currency() || currencyForHere() || "USD";

/** Whether the reader has chosen, as opposed to being defaulted. */
export const currencyChosen = (): boolean => !!currency();

// ── the rate ────────────────────────────────────────────────────────────────

/** The amount a money spec's unit names: "€100" → 100, "0.1 XMR" → 0.1, "USD" → 1. */
const unitAmount = (unit: string | undefined): number => {
  const m = /(\d+(?:[.,]\d+)?)/.exec(unit || "");
  return m ? parseFloat(m[1].replace(",", ".")) : 1;
};

/** The money specs the commons prices: the live inventory's when it has answered, else the demo shelf. */
function moneySpecs(): InventorySpec[] {
  const live = EXT.inventory && Array.isArray(EXT.inventory.specs) ? EXT.inventory.specs : null;
  if (live && live.length) return live;
  return DEMO_SPECS.filter(s => s.external).map(s => ({ id: s.id, name: s.name, unit: s.unit, snlt: s.snlt }));
}

/**
 * How much of `code` one credit-hour draws, at what the commons spent to
 * acquire it — or null when this commons holds none of it. `unit` is the
 * amount the shelf prices (the shop sells "€100" at its hours), so a reader
 * can say where the number comes from.
 */
export function perHour(code: string): { amount: number; unit: string; hoursPerUnit: number } | null {
  const spec = moneySpecs().find(s => s.id === `spec-${code.toLowerCase()}`);
  if (!spec) return null;
  const h = Number(spec.snlt);
  if (!isFinite(h) || h <= 0) return null;
  const q = unitAmount(spec.unit);
  return { amount: q / h, unit: spec.unit || code, hoursPerUnit: h };
}

/** A sum of money written the short way: "€40", "ɱ0.03". */
export function fmtMoney(code: string, x: number): string {
  const s = symbolOf(code);
  const n = x >= 100 ? Math.round(x).toString() : x >= 10 ? x.toFixed(1) : x >= 1 ? x.toFixed(2) : x.toPrecision(2);
  return `${s}${n}`;
}
