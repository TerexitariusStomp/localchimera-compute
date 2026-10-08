// tests/browser/symbols-test.mjs — what a symbol the camera read means
// (browser/app/symbols.js, browser/app/barcodes.js, from ui/app/symbols.ts and barcodes.ts).
//
// What is pinned: a label's QR (the playnet: scheme, a link carrying label=) reads
// as a label with its code; the same text in a barcode format, or a QR that
// carries something else, is not a label; linear and data-matrix formats read as
// products; every other symbol reads as text; formats print as the standards
// spell them; the formats asked of the detector lead with the label's QR; and a
// barcode pairs with a stock and lets it go.
//
// Run: node tests/browser/symbols-test.mjs

const store = new Map();
globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => { store.set(k, String(v)); }, removeItem: k => { store.delete(k); } };

const S = await import("../../browser/app/symbols.js");
const B = await import("../../browser/app/barcodes.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const r = (format, value) => S.classify({ format, value });

check("a label's QR reads as a label with its code", JSON.stringify(r("qr_code", "playnet:A1B2C3")) === JSON.stringify({ kind: "label", code: "A1B2C3" }));
check("…a link carrying label= too", r("qr_code", "https://playnet.example/app.html?label=a1b2c3").kind === "label");
check("…read in whatever case", r("qr_code", "playnet:a1b2c3").code === "A1B2C3");
check("a QR carrying something else is text", r("qr_code", "https://example.org/menu").kind === "text");

// a person's link (browser/app/connect-link.js): one grammar for a QR, a pasted link, an address, a bare identifier
const L = await import("../../browser/app/connect-link.js");
const AID = "E" + "a1B2-c3D4_".repeat(5).slice(0, 43);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
check("a link carrying connect= names the person, where the link came from, and their name",
      same(L.connectIn(`https://playnet.example/app.html?connect=${AID}&name=Ana%20B`), { aid: AID, origin: "https://playnet.example", name: "Ana B" }));
check("…a key-log address names them too", same(L.connectIn(`http://c.example:8089/oobi/${AID}`), { aid: AID, origin: "http://c.example:8089", name: "" }));
check("…and so does the bare identifier, with spaces around it", same(L.connectIn(`  ${AID}\n`), { aid: AID, origin: "", name: "" }));
check("an identifier of the wrong length names no one", L.connectIn(AID.slice(1)) === null && L.connectIn(`https://x.example/?connect=${AID}x`) === null);
check("a web address that carries no person names no one", L.connectIn("https://example.org/menu") === null && L.connectIn("friend") === null);
check("a link that is not http names no one", L.connectIn(`javascript:alert(1)//?connect=${AID}`) === null);
check("a name longer than a name is cut", L.connectIn(`https://p.example/?connect=${AID}&name=${"x".repeat(200)}`).name.length === 60);
check("the link built for a person reads back as that person",
      same(L.connectIn(L.connectLink("https://p.example/app.html", AID, "Ana & co")), { aid: AID, origin: "https://p.example", name: "Ana & co" }));
check("a person's QR reads as a person", same(r("qr_code", `https://p.example/app.html?connect=${AID}`), { kind: "person", link: { aid: AID, origin: "https://p.example", name: "" } }));
check("…and a label's link stays a label", r("qr_code", "https://playnet.example/app.html?label=a1b2c3").kind === "label");
check("the same link in a barcode format is not a person", r("code_128", `https://p.example/app.html?connect=${AID}`).kind === "product");
check("a barcode never reads as a label, though its digits might", r("code_128", "A1B2C3").kind === "product");
check("an EAN-13 is a product", JSON.stringify(r("ean_13", " 4006381333931 ")) === JSON.stringify({ kind: "product", format: "ean_13", value: "4006381333931" }));
check("so are UPC, Code 39, ITF and Data Matrix", ["upc_a", "upc_e", "ean_8", "code_39", "itf", "data_matrix"].every(f => r(f, "12345").kind === "product"));
check("an empty barcode is nothing a product", r("ean_13", "  ").kind === "text");
check("Aztec and PDF417 are text", r("aztec", "x").kind === "text" && r("pdf417", "x").kind === "text");

check("formats print as the standards spell them", S.formatName("ean_13") === "EAN-13" && S.formatName("qr_code") === "QR" && S.formatName("data_matrix") === "Data Matrix");
check("an unknown format prints as it is", S.formatName("maxicode") === "maxicode");
check("the detector is asked for the label's QR first", S.READ_FORMATS[0] === "qr_code" && S.PRODUCT_FORMATS.every(f => S.READ_FORMATS.includes(f)));

check("an unpaired barcode names no stock", B.boundTo("4006381333931") === "");
B.bind("4006381333931", "bin/1/jam");
B.bind("0012345678905", "bin/2/rice");
check("a paired barcode names its stock", B.boundTo("4006381333931") === "bin/1/jam" && B.boundTo("0012345678905") === "bin/2/rice");
B.bind("4006381333931", "bin/3/milk");
check("pairing again moves it", B.boundTo("4006381333931") === "bin/3/milk" && B.boundTo("0012345678905") === "bin/2/rice");
B.unbind("4006381333931");
check("letting one go leaves the others", B.boundTo("4006381333931") === "" && B.boundTo("0012345678905") === "bin/2/rice");

done();
