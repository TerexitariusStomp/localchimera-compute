// app/demo/contacts.ts — the demo contact book: the people the page shows
// while no seat is taken at a gateway.
//
// One person per state a row can be in, so the demo day shows every reading
// the Contacts view has:
//   Ana     — you vouch for each other, both recognised
//   Sam     — you vouch for him
//   Priya   — she vouches for you
//   mama    — asking to be recognised, one signature of two
//   dad     — a tag and nothing signed
//   the two commons — a recognised group, and one that is a tag alone
// Ana and you hold each other's cards; Priya gave you hers.
import type { Contact } from '../seam.js';

export const DEMO_CONTACTS: Contact[] = [
  { alias: "Ana",                    aid: "EKp3qD…9fL2", rel: "friend",    online: true,  recognised: true, mine: "friend", theirs: "friend", verified: true,
    card: JSON.stringify({ name: "Ana", points: [{ kind: "email", value: "ana@example.org" }, { kind: "phone", value: "+359 88 123 4567" },
                                                  { kind: "note", value: "ring twice, the bell sticks" }] }),
    given: "2026-09-28T09:00:00Z" },
  { alias: "Sam",                    aid: "DBq7nW…1xR4", rel: "friend",    online: false, recognised: true, mine: "friend", verified: true },
  { alias: "mama",                   aid: "EHt2kZ…77Kz", rel: "family",    online: true,  ask: { said: "demo-ask-mama", count: 1, quorum: 2 } },
  { alias: "dad",                    aid: "DLm9pQ…4pQs", rel: "family",    online: false },
  { alias: "Priya",                  aid: "EXj8oM…3kMo", rel: "colleague", online: true,  recognised: true, theirs: "colleague", verified: true,
    card: JSON.stringify({ name: "Priya", points: [{ kind: "matrix", value: "@priya:example.org" }] }) },
  { alias: "neighbourhood assembly", aid: "EUc1aW…0aWn", rel: "commons",   online: true,  recognised: true },
  { alias: "repair café crew",       aid: "Dn4f8b…Vt2r", rel: "commons",   online: false },
];
