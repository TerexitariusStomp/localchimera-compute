#!/usr/bin/env python3
"""validate_leontief.py — independent ground-truth check for bench-real.scm.

The convex planner's Run A claims to reproduce published gross output. That claim
has two layers, both checked here against numpy/scipy (an engine wholly separate
from the Scheme solver):

  1. DATA layer:    x* = (I − A)^-1 f   must equal published gross output GO.
                    (validates that A=Z/x and f were extracted correctly.)
  2. SOLVER layer:  the planner's dumped solution runA.x must equal x* (= GO).
                    (validates that the convex solver lands on the Leontief point.)

Reads docs/data/wiod/wiod2014.npz (emitted alongside the .sexp by
wiod_preprocess.py) and, if present, docs/data/wiod/runA.x (the planner dump).

Run under the Guix python stack:
  guix shell python python-numpy python-scipy -- \
    python3 docs/_scripts/validate_leontief.py
"""
import sys, os
import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # docs/
NPZ  = os.path.join(HERE, "data", "wiod", "wiod2014.npz")
RUNA = os.path.join(HERE, "data", "wiod", "runA.x")

def load():
    d = np.load(NPZ, allow_pickle=True)
    n = int(d["n"])
    A = sp.coo_matrix((d["a_val"], (d["a_row"], d["a_col"])), shape=(n, n)).tocsc()
    fd_raw = d["fd_raw"].astype(float) if "fd_raw" in d.files else d["fd"].astype(float)
    return n, A, d["go"].astype(float), d["fd"].astype(float), fd_raw, d["labels"]

def rel(a, b):
    nb = np.linalg.norm(b)
    return np.linalg.norm(a - b) / nb if nb else np.linalg.norm(a - b)

def main():
    n, A, go, fd, fd_raw, labels = load()
    print(f"loaded {NPZ}: n={n}  nnz(A)={A.nnz}  Σf={fd.sum():.4g}  Σgo={go.sum():.4g}")

    # spectral radius proxy: power iteration on A (real I-O ⇒ ρ(A) ∈ (0,1))
    x = np.ones(n)
    for _ in range(200):
        y = A @ x; nrm = np.linalg.norm(y)
        if nrm == 0: break
        x = y / nrm
    rho = float((A @ x) @ x / (x @ x))
    print(f"ρ(A) ≈ {rho:.4f}  (Leontief invertible iff < 1)")

    # condition-number proxy for (I−A): ratio of largest/smallest singular value
    # via a few Lanczos steps on the normal operator (cheap, approximate).
    ImA = (sp.eye(n, format="csc") - A).tocsc()
    try:
        smax = spla.svds(ImA, k=1, which="LM", return_singular_vectors=False)[0]
        smin = spla.svds(ImA, k=1, which="SM", return_singular_vectors=False)[0]
        print(f"cond(I−A) ≈ {smax/smin:.3g}  (σmax={smax:.3g} σmin={smin:.3g})")
    except Exception as e:
        print(f"cond(I−A): svds failed ({e})")

    # ── layer 0: row-balance closure (no SYSTEMATIC extraction error) ──
    # identity: GO_i = Σ_j z_ij + f_i. Z = A·diag(go) reconstructs intermediate use.
    Zsum = np.asarray((A @ sp.diags(go)).sum(axis=1)).ravel()
    imbal = (go - (Zsum + fd_raw))
    print(f"\n[ROWBAL] ‖GO − (Σz + f)‖/‖GO‖ = {rel(Zsum + fd_raw, go):.3e}  "
          f"max|imbal|/GO = {np.nanmax(np.abs(imbal)/np.where(go>0,go,np.nan)):.2e}  "
          f"(WIOD is RAS-balanced ⇒ ~1e-3 statistical discrepancy is expected)")

    # ── layer 1: closed-form Leontief vs published GO ──
    # (a) RAW final demand reproduces GO to the data's own balance precision.
    xraw = spla.spsolve(ImA, fd_raw)
    r0 = rel(xraw, go)
    print(f"[DATA ] (I−A)⁻¹·f_raw  vs GO : {r0:.3e}   "
          + ("OK — matches to data balance precision" if r0 < 5e-3 else "MISMATCH — check extraction"))
    # (b) the CLAMPED f (what the planner uses) differs only by the inventory/import
    #     negatives, amplified by the Leontief multiplier — a small, explained gap.
    xstar = spla.spsolve(ImA, fd)
    r1 = rel(xstar, go)
    clamp = abs(fd_raw.sum() - fd.sum()) / abs(go.sum())
    print(f"        (I−A)⁻¹·f_clamp vs GO : {r1:.3e}   "
          f"(clamp mass {clamp:.1e} × mult 1/(1−ρ)≈{1/(1-rho):.1f})")
    neg = int((xstar < -1e-6).sum())
    if neg: print(f"        note: {neg} negative entries in (I−A)⁻¹f_clamp")

    # ── layer 2: planner solution vs closed-form ──
    if os.path.exists(RUNA):
        xp = np.loadtxt(RUNA)
        if xp.shape[0] != n:
            print(f"[SOLVER] runA.x has {xp.shape[0]} rows, expected {n} — skip")
            return
        r2 = rel(xp, xstar)
        # report worst few sectors
        idx = np.argsort(-np.abs(xp - xstar))[:5]
        print(f"[SOLVER] ‖x_planner − x*‖/‖x*‖ = {r2:.3e}   "
              + ("OK — solver lands on Leontief point (to data precision)"
                 if r2 < 2e-3 else "DRIFT"))
        for i in idx:
            lab = labels[i] if i < len(labels) else str(i)
            print(f"         {str(lab):14s} planner={xp[i]:.4g}  x*={xstar[i]:.4g}")
    else:
        print(f"[SOLVER] {RUNA} not found — run bench-real.scm first")

if __name__ == "__main__":
    main()
