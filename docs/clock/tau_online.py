#!/usr/bin/env python3
"""
Warm online convex rolling on the tau-circle = a phase-locked loop.

A reference angle r(t) drifts at rate Omega.  The rolling machine carries its
phase theta forward (WARM: never reset) and rolls downhill on the moving convex
well  f_t(theta) = -K cos(theta - r(t)) :

    theta' = -df/dtheta = -K sin(theta - r(t))        # PLL / online gradient flow

Inside the convex arc |theta - r| < tau/4 the potential is strongly convex
(sin is increasing), so the machine TRACKS the moving optimum with a bounded
lag.  At steady state theta' = r' = Omega, so

    sin(e*) = -Omega/K      ->   |e*| = arcsin(Omega/K) ~ Omega/K   (drift / curvature)

which exists only while Omega <= K -- the LOCK RANGE.  Past it there is no fixed
point: theta can no longer keep up, the error leaves the convex arc, and the
loop CYCLE-SLIPS (winds by tau).  That loss of lock is the same winding-number
/ frustration boundary the pentagon hit in Part VII.
"""

import math

TAU = 2 * math.pi


def track(K, Omega, steps=60000, dt=0.005):
    """Warm online tracker. Returns (mean |lag|, winding rate = slips*tau / time)."""
    theta = 0.0            # machine phase (persists -- warm start every step)
    r = 0.0               # reference phase (drifts)
    D0 = theta - r        # unwrapped phase difference at start of the measured window
    half = steps // 2
    D_start = None
    err_acc, err_n = 0.0, 0
    for t in range(steps):
        r += Omega * dt                       # reference drifts
        theta -= K * math.sin(theta - r) * dt  # roll on the moving convex well
        if t == half:
            D_start = theta - r
        if t >= half:
            e = math.atan2(math.sin(theta - r), math.cos(theta - r))  # wrapped lag
            err_acc += abs(e)
            err_n += 1
    D_end = theta - r
    T = (steps - half) * dt
    winding_rate = (D_end - D_start) / T       # ~0 if locked, nonzero if slipping
    return err_acc / err_n, winding_rate


def main():
    K = 1.0
    print(f"gain K = {K}   (lock range: Omega <= K)\n")
    print(f"  Omega/K   measured |lag|   arcsin(O/K)   winding/tau/s   state")
    for ratio in (0.2, 0.5, 0.9, 0.99, 1.10, 1.50):
        Omega = ratio * K
        lag, wind = track(K, Omega)
        predicted = math.asin(min(ratio, 1.0))
        wind_per_turn = wind / TAU
        locked = abs(wind_per_turn) < 0.05
        state = "LOCKED  (tracking)" if locked else "SLIPPING (lost lock)"
        pred_str = f"{predicted:6.3f} rad" if ratio <= 1.0 else "   —  (none)"
        print(f"  {ratio:5.2f}     {lag:7.3f} rad     {pred_str}    {wind_per_turn:+7.3f}     {state}")

    print("\n  warm vs cold, slow drift (Omega/K = 0.2): steps to re-settle each round")
    # a moving target that jumps a little each 'round'; warm keeps theta, cold resets to 0.
    K, jump, rounds = 1.0, 0.15, 40
    for mode in ("cold", "warm"):
        theta, r, total = 0.0, 0.0, 0
        for _ in range(rounds):
            r += jump                                  # the optimum moves a little
            if mode == "cold":
                theta = 0.0                            # cold: throw away the state
            s = 0
            while abs(math.atan2(math.sin(theta - r), math.cos(theta - r))) > 1e-3:
                theta -= K * math.sin(theta - r) * 0.05
                s += 1
                if s > 100000:
                    break
            total += s
        print(f"    {mode:4s}: {total:6d} total gradient steps over {rounds} rounds"
              f"  ({total / rounds:.1f} per round)")


if __name__ == "__main__":
    main()
