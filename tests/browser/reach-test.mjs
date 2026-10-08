// tests/browser/reach-test.mjs — a person's ways to be reached, and the card
// that carries some of them (browser/app/reach.js, from ui/app/reach.ts).
//
// What is pinned: the list is kept on the device and reads back; a point of
// an unknown kind, an empty one and one past a line are refused; a point
// held twice is held once; a value opens as a link only through its kind's
// own prefix, and a web address only when it is http(s); a card's text reads
// back as the card, and a card's fields — its giver's words — are cut to
// size and read as text whatever they hold.
//
// Run: node tests/browser/reach-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();
const store = { get: k => localStorage.getItem(k), set: (k, v) => localStorage.setItem(k, v) };
store.set("pn.reach", JSON.stringify([{ kind: "email", value: "kept@example.org" }, { kind: "carrier-pigeon", value: "loft" }, "junk"]));

const R = await import("../../browser/app/reach.js");

const { check, done } = harness();
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

check("the list kept on the device reads back, without what is no point", same(R.reach(), [{ kind: "email", value: "kept@example.org" }]));
check("a point is added, trimmed, and kept", R.addReach("phone", "  +49 30 1234567 ") === null
      && same(JSON.parse(store.get("pn.reach"))[1], { kind: "phone", value: "+49 30 1234567" }));
check("a point held twice is held once", R.addReach("phone", "+49 30 1234567") === null && R.reach().length === 2);
check("an unknown kind is refused", typeof R.addReach("carrier-pigeon", "loft") === "string" && R.reach().length === 2);
check("an empty value is refused", typeof R.addReach("email", "   ") === "string");
check("a value past a line is refused", typeof R.addReach("note", "x".repeat(201)) === "string" && typeof R.addReach("note", "a\nb") === "string");
check("removing takes it off the list and the device", (R.removeReach({ kind: "phone", value: "+49 30 1234567" }), R.reach().length === 1)
      && JSON.parse(store.get("pn.reach")).length === 1);

check("an email opens as mail", R.linkOf({ kind: "email", value: "a@b.org" }) === "mailto:a@b.org");
check("a phone opens as a call", R.linkOf({ kind: "phone", value: "+49 30 1" }) === "tel:+49%2030%201");
check("a Telegram handle opens without its @", R.linkOf({ kind: "telegram", value: "@ana" }) === "https://t.me/ana");
check("a Matrix id keeps its @", R.linkOf({ kind: "matrix", value: "@ana:example.org" }) === "https://matrix.to/#/@ana:example.org");
check("a web address opens only when it is http(s)", R.linkOf({ kind: "web", value: "https://example.org/x" }) === "https://example.org/x"
      && R.linkOf({ kind: "web", value: "javascript:alert(1)" }) === "" && R.linkOf({ kind: "web", value: "example.org" }) === "");
check("a value cannot change its kind's scheme", R.linkOf({ kind: "email", value: "javascript:alert(1)" }).startsWith("mailto:"));
check("a note and a kind the catalogue does not name open nothing", R.linkOf({ kind: "note", value: "ring twice" }) === "" && R.linkOf({ kind: "fax", value: "1" }) === "");

const card = { name: "Ana", points: [{ kind: "email", value: "ana@example.org" }, { kind: "note", value: "ring twice" }] };
check("a card's text reads back as the card", same(R.readCard(R.cardText(card)), card));
check("what is no card reads as none", R.readCard("") === null && R.readCard("not json") === null && R.readCard(undefined) === null);
const odd = R.readCard(JSON.stringify({ name: 7, points: [{ kind: "email", value: 3 }, null, { kind: "x".repeat(99), value: "y".repeat(999) }, ...Array(40).fill({ kind: "note", value: "n" })] }));
check("a card's fields are read as text and cut to size", odd.name === "" && odd.points.length === 24
      && odd.points[0].kind.length === 24 && odd.points[0].value.length === 200);
check("a card with no points is a card with none", same(R.readCard('{"name":"Ana"}'), { name: "Ana", points: [] }));

done();
