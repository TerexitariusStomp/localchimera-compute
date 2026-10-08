#!/usr/bin/env python3
"""
The discrete wrapper, certified past the enumerate-budget.

The planner's discrete layer chooses WHICH RECIPE makes each good.  Small config
spaces it ENUMERATES (certified global); large ones it anneals and reports
"uncertified" (relaxation.scm solve-discrete).  This closes that gap the way the
companion says: LIFT the discrete choice into its convex hull (the recipe
simplex), BOUND, then BRANCH — mixed-integer convex programming, reusing the
same log-barrier convex engine.

Model (each good made by recipe A or B; both compete for two shared caps):
  activities  xA_g, xB_g >= 0 ;  output q_g = xA_g + xB_g
  desire      max  -sum_g w_g (t_g - q_g)^2
  limits      sum_g (aA_g xA_g + aB_g xB_g) <= Lcap        (labour)
              sum_g (rA_g xA_g + rB_g xB_g) <= Rcap        (a scarce resource)
  INTEGER     for each g, only ONE of {xA_g, xB_g} may run   <- the non-convexity

  relaxation  drop the integer rule: let both run (a recipe MIXTURE).  Still
              convex (linear caps, concave desire) -> its optimum UPPER-BOUNDS
              every integer config.  That bound is the certificate annealing lacks.
"""

import numpy as np, itertools, random

# ── instance ────────────────────────────────────────────────────────────────
def make_instance(K, seed=0):
    rng = np.random.default_rng(seed)
    t = rng.uniform(4, 10, K)
    w = np.ones(K)
    aA, aB = rng.uniform(0.3, 1.0, K), rng.uniform(0.3, 1.0, K)   # labour / recipe
    rA, rB = rng.uniform(0.3, 1.0, K), rng.uniform(0.3, 1.0, K)   # resource / recipe
    lab = np.column_stack([aA, aB]).ravel()     # [aA0,aB0,aA1,aB1,...] , index 2g/2g+1
    res = np.column_stack([rA, rB]).ravel()
    Lcap = 0.55 * np.sum(np.minimum(aA, aB) * t)     # binding: can't cheaply meet all
    Rcap = 0.55 * np.sum(np.minimum(rA, rB) * t)
    return dict(K=K, t=t, w=w, lab=lab, res=res, Lcap=Lcap, Rcap=Rcap)


# ── the convex core: log-barrier Newton on the allowed activities ────────────
def solve(inst, active, x0=None):
    """Central-path Newton over the allowed activities (a boolean mask, length 2K).
    Returns (harmony, full-x, newton_steps). This is the SAME engine as tau_planner."""
    K, t, w, lab_all, res_all = inst['K'], inst['t'], inst['w'], inst['lab'], inst['res']
    Lcap, Rcap = inst['Lcap'], inst['Rcap']
    idx = np.where(active)[0]
    n = len(idx)
    lab, res = lab_all[idx], res_all[idx]
    M = np.zeros((K, n))                          # x -> outputs q = M x
    for j, i in enumerate(idx):
        M[i // 2, j] = 1.0
    x = np.full(n, 0.05) if x0 is None else x0[idx].clip(1e-3)
    steps = 0
    tt = 1.0
    while True:
        for _ in range(40):
            q = M @ x
            sL, sR = Lcap - lab @ x, Rcap - res @ x
            gradD = -2 * (M.T @ (w * (t - q)))
            gradB = lab / sL + res / sR - 1.0 / x
            grad = gradD + tt * gradB
            HD = 2 * (M.T * w) @ M
            HB = np.outer(lab, lab) / sL**2 + np.outer(res, res) / sR**2 + np.diag(1.0 / x**2)
            H = HD + tt * HB
            reg = 1e-7 * (np.trace(H) / n + 1.0)      # gradient-regularized Newton (Doikov–Nesterov):
            H = H + reg * np.eye(n)                    # lifts the flat xA-xB direction of a free good
            try:
                dx = np.linalg.solve(H, -grad)
            except np.linalg.LinAlgError:
                dx = np.linalg.lstsq(H, -grad, rcond=None)[0]
            a = 1.0
            while True:
                xn = x + a * dx
                if (xn > 1e-12).all() and Lcap - lab @ xn > 1e-12 and Rcap - res @ xn > 1e-12:
                    break
                a *= 0.5
            x = x + a * dx
            steps += 1
            if np.linalg.norm(a * dx) < 1e-9:
                break
        if tt <= 1e-6:
            break
        tt = max(1e-6, tt * 0.2)
    full = np.zeros(2 * K)
    full[idx] = x
    q = M @ x
    harmony = float(-np.sum(w * (t - q) ** 2))
    return harmony, full, steps


def config_mask(inst, c):                          # c[g] in {0,1}: recipe A or B
    a = np.zeros(2 * inst['K'], dtype=bool)
    for g, cg in enumerate(c):
        a[2 * g + cg] = True
    return a


# ── the three strategies ────────────────────────────────────────────────────
def enumerate_exact(inst):
    K = inst['K']
    best_h, best_c = -np.inf, None
    for c in itertools.product((0, 1), repeat=K):
        h, _, _ = solve(inst, config_mask(inst, c))
        if h > best_h:
            best_h, best_c = h, c
    return best_h, best_c, 2 ** K


def anneal(inst, iters=400, restarts=3, seed=1):
    rng = random.Random(seed)
    K = inst['K']
    best_h = -np.inf
    for _ in range(restarts):
        c = [rng.randint(0, 1) for _ in range(K)]
        h, _, _ = solve(inst, config_mask(inst, c))
        temp = 1.0
        for _ in range(iters):
            g = rng.randrange(K)
            c2 = c[:]; c2[g] ^= 1
            h2, _, _ = solve(inst, config_mask(inst, c2))
            if h2 >= h or rng.random() < np.exp((h2 - h) / max(1e-6, temp)):
                c, h = c2, h2
            best_h = max(best_h, h)
            temp *= 0.99
    return best_h


def relaxation_bound(inst):
    """Both recipes may run -> convex -> UPPER bound. Report the split goods."""
    h, x, _ = solve(inst, np.ones(2 * inst['K'], dtype=bool))
    splits = [g for g in range(inst['K'])
              if x[2 * g] > 1e-4 and x[2 * g + 1] > 1e-4]      # fractional -> branch here
    return h, splits, x


# ── branch and bound: certified, past the enumerate budget ──────────────────
def branch_and_bound(inst):
    K = inst['K']
    incumbent = {'h': -np.inf, 'c': None}
    nodes = {'n': 0}

    def node(fixed):                                # fixed: dict good -> 0/1 (or absent = free)
        nodes['n'] += 1
        active = np.zeros(2 * K, dtype=bool)        # free goods: both recipes allowed (relaxation)
        for g in range(K):
            if g in fixed:
                active[2 * g + fixed[g]] = True
            else:
                active[2 * g] = active[2 * g + 1] = True
        h, x, _ = solve(inst, active)               # convex relaxation of this node
        if h <= incumbent['h'] + 1e-9:              # bound <= incumbent -> prune
            return
        frac = [g for g in range(K) if g not in fixed
                and x[2 * g] > 1e-4 and x[2 * g + 1] > 1e-4]
        if not frac:                                # integral -> a real config, a candidate
            if h > incumbent['h']:
                incumbent['h'] = h
                incumbent['c'] = tuple(fixed.get(g, int(x[2 * g + 1] > x[2 * g])) for g in range(K))
            return
        g = max(frac, key=lambda g: min(x[2 * g], x[2 * g + 1]))   # most-split good
        for choice in (0, 1):                        # branch
            node({**fixed, g: choice})

    node({})
    return incumbent['h'], incumbent['c'], nodes['n']


# ── explore ─────────────────────────────────────────────────────────────────
def report(K, seed):
    inst = make_instance(K, seed)
    hb, splits, _ = relaxation_bound(inst)
    ha = anneal(inst)
    hbb, cbb, nodes = branch_and_bound(inst)
    line = (f"K={K:2d} seed={seed}  "
            f"relax-bound={hb:8.3f}  anneal={ha:8.3f}  B&B*={hbb:8.3f}  "
            f"| anneal gap ≤ {100*(hb-ha)/max(1e-9,abs(hb)):5.2f}%  "
            f"| B&B nodes={nodes:5d} vs 2^K={2**K:>6d}"
            f"  ({100*nodes/2**K:4.1f}%)")
    if K <= 12:
        he, ce, _ = enumerate_exact(inst)
        line += f"  | enum*={he:8.3f} {'✓' if abs(he-hbb) < 1e-3 else '✗ MISMATCH'}"
    print(line)
    return inst


if __name__ == "__main__":
    print("=== certifying the discrete wrapper past the enumerate budget ===\n")
    print("small (enumerable) — relaxation bounds it, B&B matches enumeration:")
    for seed in range(4):
        report(8, seed)
    print("\nlarge (2^K past the 4096 budget) — enumeration is out; B&B still certifies:")
    for K in (14, 16, 18):
        report(K, 0)
    print("\n→ the relaxation bound turns annealing's 'uncertified' into 'within X%',")
    print("  and branch-and-bound closes it exactly, visiting a tiny fraction of 2^K.")
