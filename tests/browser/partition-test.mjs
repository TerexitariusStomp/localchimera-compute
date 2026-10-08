// tests/browser/partition-test.mjs — a household as a set, its members and
// groups as blocks (browser/app/partition.js)
//
// Every WHO on the family face is a block of the individuals: `all` is the
// whole, a name is a singleton, "a+b" or a named group is the block between.
// The picture and the sort both rest on that reading, so the test states it:
// which members a name resolves to, where each block ranks under each order,
// and that the shape through k vertices is a point, a segment, or a closed
// polygon — never a polygon through two.
//
// Run: node tests/browser/partition-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const P = await import("../../browser/app/partition.js");
const { check, done } = harness();
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ── who is who ─────────────────────────────────────────────────────────────
{
  const whos = ["all", "thierry", "tom", "all", "thierry+jolly", "luc", "parents", "jolly"];
  const groups = { parents: ["thierry", "jolly"] };
  const ind = P.individualsOf(whos, groups);
  check("individuals are the plain names and every group's members, in first appearance, once", eq(ind, ["thierry", "tom", "jolly", "luc"]));
  check("a named group alone still yields its members as individuals", eq(P.individualsOf(["parents", "all", "luc"], groups), ["thierry", "jolly", "luc"]));
  check("all is everyone", eq(P.membersOf("all", ind), ind));
  check("a+b is those two", eq(P.membersOf("thierry+jolly", ind), ["thierry", "jolly"]));
  check("a named group resolves through GROUPS", eq(P.membersOf("parents", ind, groups), ["thierry", "jolly"]));
  check("a name is itself", eq(P.membersOf("Tom", ind), ["tom"]));
  check("a stranger is nobody", eq(P.membersOf("nobody", ind), []));
  check("a group member not in the ledger is dropped, not invented", eq(P.membersOf("a+tom", ind), ["tom"]));
}

// ── the orders ─────────────────────────────────────────────────────────────
{
  const n = 4;
  const rank = (order) => [4, 1, 2, 3].map(s => P.blockRank(s, n, order));
  const sorted = (order) => [4, 1, 2, 3].sort((a, b) => P.blockRank(a, n, order) - P.blockRank(b, n, order));
  check("default: the whole, then singletons, then groups (largest group first)", eq(sorted("all-individuals-groups"), [4, 1, 3, 2]));
  check("individuals · groups · all", eq(sorted("individuals-groups-all"), [1, 2, 3, 4]));
  check("groups · individuals · all", eq(sorted("groups-individuals-all"), [3, 2, 1, 4]));
  check("smallest first is by size", eq(sorted("smallest-first"), [1, 2, 3, 4]));
  check("largest first is by size, reversed", eq(sorted("largest-first"), [4, 3, 2, 1]));
  check("ranks are numbers for every order", P.SORT_ORDERS.every(o => rank(o.id).every(Number.isFinite)));
  check("the default order is listed first", P.SORT_ORDERS[0].id === "all-individuals-groups");
}

// ── the shapes ─────────────────────────────────────────────────────────────
{
  const v = P.vertices(4, 10);
  check("the first vertex is at the top", Math.abs(v[0][0]) < 1e-9 && Math.abs(v[0][1] + 10) < 1e-9);
  check("four vertices are a square on the circle", v.every(([x, y]) => Math.abs(Math.hypot(x, y) - 10) < 1e-9));
  check("one member is a point", /^M[-\d.]+,[-\d.]+l0,0$/.test(P.blockPath([2], 4, 10)));
  check("two members are a segment, not closed", /^M[^Z]+L[^LZ]+$/.test(P.blockPath([0, 2], 4, 10)));
  check("three members close into a polygon", /Z$/.test(P.blockPath([0, 1, 3], 4, 10)));
  check("indices out of range are ignored", P.blockPath([7], 4, 10) === "");
  check("vertex order on the circle is kept whatever the input order", P.blockPath([3, 0, 1], 4, 10) === P.blockPath([0, 1, 3], 4, 10));
}

done();
