// SPDX-License-Identifier: AGPL-3.0-or-later
// lib/nostr.js — the small slice of nostr a DVM needs: sign, verify,
// and speak REQ/EVENT/CLOSE/EOSE/OK to a relay over WebSocket.
//
// Nothing here is a nostr implementation of record — it's the honest
// minimum, over the vendored noble-secp256k1 (schnorr/BIP-340), so the
// DVM runner can take NIP-90 work without a dependency tree.

import * as secp from "../vendor/noble/secp256k1.js";

const enc = new TextEncoder();
const toHex = (u8) =>
  [...u8].map((b) => b.toString(16).padStart(2, "0")).join("");
const fromHex = (h) => {
  const u8 = new Uint8Array(h.length / 2);
  for (let i = 0; i < u8.length; i++) u8[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return u8;
};
const sha256hex = async (u8) => toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", u8)));

// bech32 (BIP-173) — nsec/npub decode only; operators paste these, the
// wire stays hex internally
const B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
export const bech32decode = (s) => {
  const lower = s.toLowerCase();
  const pos = lower.lastIndexOf("1");
  if (pos < 1 || pos + 7 > lower.length) throw new Error("nostr: bad bech32");
  const hrp = lower.slice(0, pos);
  const data = [...lower.slice(pos + 1)].map((c) => {
    const v = B32.indexOf(c);
    if (v < 0) throw new Error("nostr: bad bech32 char");
    return v;
  }).slice(0, -6); // strip checksum
  // 5→8 bit regroup
  let acc = 0, bits = 0;
  const out = [];
  for (const v of data) {
    acc = (acc << 5) | v; bits += 5;
    if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 0xff); }
  }
  if (bits > 4 || ((acc << (8 - bits)) & 0xff)) throw new Error("nostr: bad bech32 padding");
  return { hrp, bytes: new Uint8Array(out) };
};

export const secretKeyBytes = (s) =>
  s.startsWith("nsec") ? bech32decode(s).bytes : fromHex(s);
export const publicKeyHex = (sec) => toHex(secp.schnorr.getPublicKey(secretKeyBytes(sec)));

// event id = sha256 of the canonical serialization — the rule every
// relay enforces, so a wrong field signs a different id and verifies
// nowhere
const serialize = (ev) =>
  JSON.stringify([0, ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content]);

export const finalizeEvent = async (seckey, partial) => {
  const priv = secretKeyBytes(seckey);
  const ev = {
    pubkey: toHex(secp.schnorr.getPublicKey(priv)),
    created_at: partial.created_at ?? Math.floor(Date.now() / 1000),
    kind: partial.kind,
    tags: partial.tags ?? [],
    content: partial.content ?? "",
  };
  const id = await sha256hex(enc.encode(serialize(ev)));
  const sig = toHex(await secp.schnorr.sign(fromHex(id), priv));
  return { ...ev, id, sig };
};

export const verifyEvent = async (ev) => {
  const id = await sha256hex(enc.encode(serialize(ev)));
  if (id !== ev.id) return false;
  return secp.schnorr.verify(fromHex(ev.sig), fromHex(id), fromHex(ev.pubkey));
};

// ── the relay — one WebSocket, many subscriptions ───────────────────────
// onEvent(subId, event) for live events, onEose(subId) when stored history
// ends. Reconnects with backoff; subscriptions re-arm on reconnect.
export class NostrRelay {
  constructor(url, opts = {}) {
    this.url = url;
    this.opts = opts;
    this.ws = null;
    this.subs = new Map(); // subId → {filters, onEvent, onEose}
    this.okWaiters = new Map(); // eventId → resolve
    this.closed = false;
    this.backoff = 1000;
    this._open = null;
  }

  connect() {
    if (this._open) return this._open;
    this._open = new Promise((resolve, reject) => {
      const WS = this.opts.WebSocketImpl ?? WebSocket;
      const ws = new WS(this.url);
      this.ws = ws;
      ws.onopen = () => {
        this.backoff = 1000;
        for (const [id, s] of this.subs)
          ws.send(JSON.stringify(["REQ", id, ...s.filters]));
        resolve();
      };
      ws.onmessage = (m) => this._message(m.data);
      ws.onerror = (e) => { if (this._open) { this._open = null; reject(e); } };
      ws.onclose = () => {
        this._open = null;
        this.ws = null;
        if (!this.closed) {
          this.backoff = Math.min(this.backoff * 2, 30000);
          this._timer = setTimeout(() => this.connect(), this.backoff);
        }
      };
    });
    return this._open;
  }

  _message(data) {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (!Array.isArray(msg)) return;
    const [type, a, b] = msg;
    if (type === "EVENT") {
      const sub = this.subs.get(a);
      if (sub) sub.onEvent(b);
    } else if (type === "EOSE") {
      const sub = this.subs.get(a);
      if (sub?.onEose) sub.onEose();
    } else if (type === "OK") {
      const w = this.okWaiters.get(a);
      if (w) { this.okWaiters.delete(a); w({ accepted: b, message: msg[3] ?? "" }); }
    }
  }

  async subscribe(subId, filters, onEvent, onEose) {
    this.subs.set(subId, { filters, onEvent, onEose });
    await this.connect();
    this.ws?.send(JSON.stringify(["REQ", subId, ...filters]));
  }

  async unsubscribe(subId) {
    this.subs.delete(subId);
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(["CLOSE", subId]));
  }

  async publish(ev) {
    // the waiter lands before the send — an OK that arrives while the
    // socket was still opening still resolves
    const ack = new Promise((res) => this.okWaiters.set(ev.id, res));
    await this.connect();
    this.ws.send(JSON.stringify(["EVENT", ev]));
    // a relay that never OKs still shouldn't hang the runner
    return Promise.race([
      ack,
      new Promise((res) =>
        setTimeout(() => {
          this.okWaiters.delete(ev.id);
          res({ accepted: false, message: "timeout" });
        }, this.opts.publishTimeoutMs ?? 15000)),
    ]);
  }

  close() {
    this.closed = true;
    clearTimeout(this._timer);
    this.ws?.close();
    this.ws = null;
  }
}
