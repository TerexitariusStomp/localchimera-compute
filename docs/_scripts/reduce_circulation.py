#!/usr/bin/env python3
"""reduce_circulation.py — "pure deletion" of faux-frais / circulation sectors.

Drops the chosen ISIC codes (finance, real-estate imputations, advertising, …) as
both rows AND columns of the WIOD technology matrix: the remaining technical
coefficients are unchanged, but every kept sector loses its circulation INPUT, so
the Leontief multiplier (I−A)⁻¹ shrinks. This is the counterfactual "labour
requirement of the same material technology minus its circulation overhead" — a
economic claim, not a measurement of a planned economy (the data is market-based).

Reads docs/data/wiod/wiod2014.npz; writes wiod2014-lean.sexp + wiod2014-lean.npz.
Env DROP_CODES=K64,K65,K66,L68,M73 (default = pure circulation).

Run: guix shell python python-numpy python-scipy -- python3 docs/_scripts/reduce_circulation.py
"""
import os, numpy as np
import scipy.sparse as sp, scipy.sparse.linalg as spla

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DDIR = os.path.join(HERE, "data", "wiod")
DROP = set((os.environ.get("DROP_CODES") or "K64,K65,K66,L68,M73").split(","))

d = np.load(os.path.join(DDIR, "wiod2014.npz"), allow_pickle=True)
n = int(d["n"]); labels = d["labels"]
code = np.array([str(l).split("|")[1] for l in labels])
keep = np.array([c not in DROP for c in code])
old2new = -np.ones(n, dtype=np.int64); old2new[keep] = np.arange(keep.sum())
nk = int(keep.sum())

# subset vectors
go = d["go"][keep]; fd = d["fd"][keep]; fd_raw = d["fd_raw"][keep]
hours = d["hours"][keep]; co2 = d["co2"][keep]; lab2 = labels[keep]
# subset + reindex A triples (keep only edges between kept goods)
ar, ac, av = d["a_row"], d["a_col"], d["a_val"]
m = keep[ar] & keep[ac]
ar2 = old2new[ar[m]].astype(np.int32); ac2 = old2new[ac[m]].astype(np.int32); av2 = av[m]

# diagnostics: density + conditioning before/after
def stats(n_, ar_, ac_, av_, tag):
    A = sp.coo_matrix((av_, (ar_, ac_)), shape=(n_, n_)).tocsc()
    # row nnz of balance form = 1 + in-degree; count "dense" rows (>24) and Σm²
    deg = np.bincount(ar_, minlength=n_) + 1
    kd = int((deg > 24).sum()); sm2 = float((deg.astype(float)**2).sum())
    x = np.ones(n_)
    for _ in range(300):
        y = A @ x; nrm = np.linalg.norm(y)
        if nrm == 0: break
        x = y / nrm
    rho = float((A @ x) @ x / (x @ x))
    ImA = (sp.eye(n_, format="csc") - A).tocsc()
    try:
        smax = spla.svds(ImA, k=1, which="LM", return_singular_vectors=False)[0]
        smin = spla.svds(ImA, k=1, which="SM", return_singular_vectors=False)[0]
        cond = smax / smin
    except Exception:
        cond = float("nan")
    print(f"  {tag:6s}: n={n_:5d}  nnz={len(av_):7d}  dense-rows(k)={kd:5d}  Σm²={sm2:.3e}  ρ(A)={rho:.4f}  cond(I−A)={cond:.2f}")
    return A

print(f"dropping codes {sorted(DROP)} → removing {n-nk} of {n} sectors ({100*(n-nk)/n:.1f}%)")
stats(n, ar, ac, av, "full")
A2 = stats(nk, ar2, ac2, av2, "lean")
# labour saved at published output (informational): hours on dropped sectors
dropped_hours = float(d["hours"][~keep].sum()); tot_hours = float(d["hours"].sum())
print(f"  labour on dropped sectors: {dropped_hours:.4g} of {tot_hours:.4g} Mhours ({100*dropped_hours/tot_hours:.1f}%)")

# emit lean sexp + npz
np.savez(os.path.join(DDIR, "wiod2014-lean.npz"),
         n=nk, labels=lab2, go=go, fd=fd, fd_raw=fd_raw, hours=hours, co2=co2,
         a_row=ar2, a_col=ac2, a_val=av2)
def vec(name, a): return f"  ({name} #(" + " ".join(repr(float(v)) for v in a) + "))\n"
with open(os.path.join(DDIR, "wiod2014-lean.sexp"), "w") as p:
    p.write("(wiod-io\n  (year 2014)\n")
    p.write(f"  (n {nk})\n")
    p.write("  (labels #(" + " ".join('"%s"' % l for l in lab2) + "))\n")
    p.write(vec("gross-output", go))
    p.write(vec("final-demand-raw", fd_raw))
    p.write(vec("hours", hours)); p.write(vec("co2", co2))
    p.write("  (a-triples\n")
    for i, j, a in zip(ar2, ac2, av2): p.write(f"    ({int(i)} {int(j)} {float(a)!r})\n")
    p.write("  ))\n")
print(f"wrote wiod2014-lean.sexp / .npz")
