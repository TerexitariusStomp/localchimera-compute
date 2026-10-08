#!/usr/bin/env python3
"""
The playnet harmony planner, built from the golden-angle.typ primitives.

Nothing new here — this is the planner of playnet.typ (§ The program, exactly)
assembled from bricks the companion already set up:

  primitive (golden-angle.typ)          brick used here
  ------------------------------------  ------------------------------------
  rolling machine  x' = -grad F         gradient descent on the potential
  convex bowl (Parts VI-VII)            quadratic desire-tensions  w_d (q*-q)^2
  log-barrier (Parts IX-X)              hard limits -> -t log(slack)
  second order = curve the metric (X)   Newton step  H dx = -grad
  Hessian = sum of rank-1 outer prods   H = 2w_b a a^T + ... (coupling = off-diag)
  central path (Part IX, the safety axis) sweep the barrier weight t -> 0
  pulls = KKT duals                     lambda_i = t / slack_i
  duality-gap certificate               gap = m * t
  warm / online metabolism (Part VIII)  re-solve from the standing plan x*

Toy economy (the mill->flour->bake->bread chain of playnet.typ Fig 3):
  x1 = mill level (grain -> flour),  x2 = bake level (flour -> bread).
  desire : want q* bread                       -> w_d (q* - x2)^2
  balance: flour made = flour used (soft)       -> w_b (x1 - x2)^2   (couples x1,x2)
  limits : labour l1 x1 + l2 x2 <= A ; grain x1 <= G ; x1,x2 >= 0   -> log-barriers
"""

import math

# --- economy parameters ------------------------------------------------------
w_d, w_b = 1.0, 50.0          # desire weight ; flour-balance (soft conservation) weight
l1, l2 = 0.5, 0.5             # labour per unit mill / bake
A, G = 8.0, 15.0             # labour available ; grain available
qstar = 10.0                 # bread desired


def slacks(x, A, G):
    x1, x2 = x
    return [A - l1 * x1 - l2 * x2, G - x1, x1, x2]   # labour, grain, x1>=0, x2>=0


def grad_hess(x, t, A, G, qstar):
    """Analytic gradient and Hessian of F = desire + balance + t*barrier."""
    x1, x2 = x
    s = slacks(x, A, G)
    s1, s2, s3, s4 = s
    # gradient
    g1 = 2 * w_b * (x1 - x2) + t * (l1 / s1 + 1 / s2 - 1 / s3)
    g2 = -2 * w_d * (qstar - x2) + 2 * w_b * (x2 - x1) + t * (l2 / s1 - 1 / s4)
    # Hessian (each barrier contributes rank-1 outer products of its row)
    h11 = 2 * w_b + t * (l1 * l1 / s1**2 + 1 / s2**2 + 1 / s3**2)
    h22 = 2 * w_d + 2 * w_b + t * (l2 * l2 / s1**2 + 1 / s4**2)
    h12 = -2 * w_b + t * (l1 * l2 / s1**2)          # coupling lives in the off-diagonal
    return (g1, g2), (h11, h12, h22)


def newton_center(x, t, A, G, qstar, iters=12, tol=1e-8):
    """Newton, roll in the Hessian metric; backtrack to keep every slack > 0."""
    steps = 0
    for _ in range(iters):
        (g1, g2), (h11, h12, h22) = grad_hess(x, t, A, G, qstar)
        det = h11 * h22 - h12 * h12
        dx1 = -(h22 * g1 - h12 * g2) / det           # H dx = -grad, 2x2 solve
        dx2 = -(-h12 * g1 + h11 * g2) / det
        # line search: stay strictly interior (barrier keeps us feasible)
        a = 1.0
        while True:
            xn = (x[0] + a * dx1, x[1] + a * dx2)
            if all(si > 1e-12 for si in slacks(xn, A, G)):
                break
            a *= 0.5
        x = (x[0] + a * dx1, x[1] + a * dx2)
        steps += 1
        if math.hypot(dx1, dx2) * a < tol:
            break
    return x, steps


def solve(x0, A, G, qstar, t0=1.0, tmin=1e-8, decay=0.15):
    """Central-path follower: sweep the barrier weight t down from t0, warm-started.
    A COLD solve starts high (t0=1, well-centred). The metabolism RESUMES the path
    near its operating level (small t0) from the standing plan — a few Newton steps."""
    x, total = x0, 0
    t = t0
    while True:
        x, s = newton_center(x, t, A, G, qstar)
        total += s
        if t <= tmin:
            break
        t = max(tmin, t * decay)
    return x, t, total


def report(name, x, t, A, G, qstar):
    s1, s2, s3, s4 = slacks(x, A, G)
    pulls = {"labour": t / s1, "grain": t / s2}       # KKT duals = t / slack
    gap = 4 * t                                       # m * t, m = 4 barriers
    print(f"{name}")
    print(f"   plan     x_mill={x[0]:.3f}  x_bake={x[1]:.3f}")
    print(f"   bread    met {x[1]:.2f} / {qstar:.0f} desired")
    print(f"   labour   used {l1*x[0]+l2*x[1]:.2f} / {A:.0f}   (slack {s1:.3f})")
    print(f"   pulls    labour lambda={pulls['labour']:.3f}   grain mu={pulls['grain']:.4f}")
    print(f"   gap      <= {gap:.2e}   (duality-gap certificate)\n")


if __name__ == "__main__":
    x_cold0 = (4.0, 4.0)                              # a feasible interior start
    x_star, t, n = solve(x_cold0, A, G, qstar)
    report(f"COLD solve  ({n} Newton steps)", x_star, t, A, G, qstar)

    print("--- the metabolism: bread desire drifts 10 -> 12, re-solve three ways ---")
    q2 = 12.0
    _, _, n_cold = solve(x_cold0, A, G, q2)                       # from scratch
    _, _, n_naive = solve(x_star, A, G, q2, t0=1.0)              # warm x, but RESET barrier (wrong)
    x_warm, t_w, n_warm = solve(x_star, A, G, q2, t0=1e-3)       # RESUME the path near operating t
    report(f"  metabolism re-solve (resume path from standing plan, {n_warm} steps)", x_warm, t_w, A, G, q2)
    print(f"  cold          (fresh path from scratch):        {n_cold} Newton steps")
    print(f"  naive warm    (warm x, but reset the barrier):  {n_naive} Newton steps   <- the Part IX trap")
    print(f"  metabolism    (resume path at operating level): {n_warm} Newton steps   -> {n_warm/n_cold:.2f}x cold")


# --- the Part IX trap, solved by riding the path (predictor + corrector) ------
# The trap: a warm point sits near a wall, ill-centred for a fresh barrier.
# The fix (tau lens): don't RESET the path, RIDE it. Treat demand q as a
# continuation parameter; the optimum moves along the central path by the
# sensitivity  dx*/dq  solving  H (dx*/dq) = -d(grad)/dq.  Predict along that
# tangent, then a couple of Newton correctors at the operating level re-centre.
def predictor_corrector(x_star, dq, A, G, qstar_new, t=1e-3):
    # tangent PREDICTOR: step along the central path in the barrier's own metric
    (_, _), (h11, h12, h22) = grad_hess(x_star, t, A, G, qstar_new)
    det = h11 * h22 - h12 * h12
    rhs1, rhs2 = 0.0, 2 * w_d * dq          # -d(grad)/dq = (0, +2 w_d) per unit dq
    px1 = (h22 * rhs1 - h12 * rhs2) / det
    px2 = (-h12 * rhs1 + h11 * rhs2) / det
    x = (x_star[0] + px1, x_star[1] + px2)
    # keep it interior
    a = 1.0
    while not all(si > 1e-9 for si in slacks(x, A, G)):
        a *= 0.5
        x = (x_star[0] + a * px1, x_star[1] + a * px2)
    # CORRECTOR: finish the sweep from here (few steps, already near the path)
    x, _, n = solve(x, A, G, qstar_new, t0=t)
    return x, n

if __name__ == "__main__":
    print("\n--- solving the Part IX trap: RIDE the path, don't reset it ---")
    xpc, npc = predictor_corrector(x_star, q2 - qstar, A, G, q2)
    print(f"   plan  x_mill={xpc[0]:.3f}  x_bake={xpc[1]:.3f}   (same optimum)")
    print(f"   predictor-corrector: {npc} Newton steps"
          f"   -> {npc/n_cold:.2f}x cold, {npc/n_warm:.2f}x plain-warm")
