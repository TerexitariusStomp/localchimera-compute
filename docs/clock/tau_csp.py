#!/usr/bin/env python3
"""
tau-CSP: a generic constraint solver that is literally the rolling machine.

Every variable is an ANGLE on the tau-circle (theta_i, read mod tau).
Every constraint is a coupling between two angles:
    "diff"  -> the two angles want to sit tau/2 apart   (J = +1)
    "same"  -> the two angles want to coincide          (J = -1)

The machine rolls downhill on the phase energy
    E(theta) = sum_(i,j)  J_ij cos(theta_i - theta_j)      # constraints
             - Ks * sum_i cos(2 theta_i)                   # binarizer (SHIL)
via gradient flow  theta_i' = -dE/dtheta_i , i.e. the Kelvin/Bush integrator:

    theta_i'  =  sum_j  J_ij sin(theta_i - theta_j)  -  2 Ks sin(2 theta_i)

The -cos(2 theta) term has its two minima at theta = 0 and theta = tau/2, so as
Ks is annealed up every angle is pinned to one of two slots -> a binary answer
s_i = +1 (theta~0) or -1 (theta~tau/2).  Read out s_i = sign(cos theta_i).

This is an oscillator-Ising machine; Ising is a universal CSP substrate, so the
same 40 lines solve MAX-CUT, graph 2-colouring, and (via reduction) any CSP.
"""

import math, random

TAU = 2 * math.pi


def roll(n, constraints, steps=6000, dt=0.02, ks_max=1.8, seed=0):
    """Relax the phase machine; return the binary assignment s and final angles."""
    random.seed(seed)
    theta = [random.uniform(0, TAU) for _ in range(n)]
    for t in range(steps):
        frac = t / steps
        ks = ks_max * frac                 # anneal the binarizer up
        noise = 0.30 * (1 - frac)          # cooling noise to shake out of traps
        grad = [0.0] * n
        for (i, j, rel) in constraints:
            jval = 1.0 if rel == "diff" else -1.0
            c = jval * math.sin(theta[i] - theta[j])
            grad[i] += c                    # theta_i' gets +J sin(theta_i-theta_j)
            grad[j] -= c                    # theta_j' gets the opposite
        for i in range(n):
            grad[i] -= 2 * ks * math.sin(2 * theta[i])
            theta[i] += dt * grad[i] + math.sqrt(dt) * noise * random.gauss(0, 1)
            theta[i] %= TAU
    s = [1 if math.cos(th) >= 0 else -1 for th in theta]
    return s, theta


def check(s, constraints):
    """How many constraints does assignment s satisfy?"""
    ok = 0
    for (i, j, rel) in constraints:
        if rel == "diff" and s[i] != s[j]:
            ok += 1
        elif rel == "same" and s[i] == s[j]:
            ok += 1
    return ok


def brute_force(n, constraints):
    """Best possible (max satisfied) by exhaustive search -- ground truth."""
    best = -1
    for bits in range(2 ** n):
        s = [1 if (bits >> k) & 1 else -1 for k in range(n)]
        best = max(best, check(s, constraints))
    return best


def run(name, n, constraints, tries=12):
    # multi-start: the phase energy is NON-convex (Ising is NP-hard), so we
    # roll a few times from different angles and keep the best -- honest about
    # the trap problem from Part VI of the doc.
    best_s, best_ok = None, -1
    for seed in range(tries):
        s, _ = roll(n, constraints, seed=seed)
        ok = check(s, constraints)
        if ok > best_ok:
            best_ok, best_s = ok, s
    opt = brute_force(n, constraints)
    total = len(constraints)
    colours = "".join("AB"[(x + 1) // 2] for x in best_s)
    status = "ALL SATISFIED" if best_ok == total else f"best possible ({best_ok}/{total}) -- frustrated"
    print(f"{name}")
    print(f"   vars={n}  constraints={total}")
    print(f"   machine: {best_ok}/{total} satisfied   assignment={colours}")
    print(f"   optimum: {opt}/{total} (brute force)   -> {'MATCH' if best_ok == opt else 'MISS'}")
    print(f"   {status}\n")


if __name__ == "__main__":
    # A) an even ring: 6 nodes, every neighbour must DIFFER (2-colouring).
    #    Even cycle -> fully satisfiable.  Machine should get 6/6.
    ring6 = [(i, (i + 1) % 6, "diff") for i in range(6)]
    run("A) even ring C6 (all-diff, 2-colourable)", 6, ring6)

    # B) a PENTAGON: 5 nodes, every neighbour must DIFFER.
    #    Odd cycle -> UNSAT for 2 colours; best is 4/5.  Frustration, and a nod
    #    to the golden pentagon the whole document started from.
    ring5 = [(i, (i + 1) % 5, "diff") for i in range(5)]
    run("B) pentagon C5 (all-diff, frustrated odd cycle)", 5, ring5)

    # C) a mixed generic CSP: some pairs must match, some must differ.
    #    0,1,2 should agree; 3,4 should agree; the two groups must differ;
    #    plus one extra 'diff' inside -- still satisfiable.
    mixed = [(0, 1, "same"), (1, 2, "same"),
             (3, 4, "same"),
             (2, 3, "diff"), (0, 4, "diff"), (2, 4, "diff")]
    run("C) mixed same/diff CSP (generic binary constraints)", 5, mixed)
