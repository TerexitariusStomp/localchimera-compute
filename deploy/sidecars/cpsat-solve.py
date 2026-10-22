#!/usr/bin/env python3
# deploy/sidecars/cpsat-solve.py — the CP-SAT sidecar the solve↔OR-Tools
# seam expects (spec/oss-inventory.md: "OR-Tools is a LIBRARY, not a
# service — the seam presumes the CP-SAT sidecar the deployment runs").
#
# POST /solve {"model": {...}, "params": {...}} → {"status", "values"}.
#
# The model is the wire shape module/playnet/delegates.scm's cpsat-wire
# emits:
#   {"variables":   {name: {"domain": [lo, hi]}},
#    "constraints": [{"linear": {"vars": [...], "coeffs": [...],
#                               "domain": [lo, hi]}}],
#    "objective":   {"maximize"|"minimize": {"vars": [...], "coeffs": [...]}}}
# "domain" endpoints may be the string "-inf"/"inf" (JSON can't carry
# infinities).
#
# Run:  pip install ortools flask
#       python3 cpsat-solve.py            # :5000, override with PORT
#
# Deliberately stateless and single-file — the commune's fleet manager
# keeps it next to the planner; it is not a datastore.

import os
from flask import Flask, request, jsonify
from ortools.sat.python import cp_model

app = Flask(__name__)

INF = cp_model.INT32_MAX  # wire "inf"/-inf map to the solver's bound


def _bound(x):
    if x in ("inf", "+inf", "infinity"):
        return INF
    if x in ("-inf", "-infinity"):
        return -INF
    return int(x)


@app.route("/solve", methods=["POST"])
def solve():
    spec = request.get_json(force=True) or {}
    model = spec.get("model", {})
    m = cp_model.CpModel()

    vs = {}
    for name, v in model.get("variables", {}).items():
        lo, hi = v["domain"]
        vs[name] = m.NewIntVar(_bound(lo), _bound(hi), name)

    for c in model.get("constraints", []):
        lin = c.get("linear")
        if not lin:
            continue
        terms = sum(coef * vs[name]
                    for name, coef in zip(lin["vars"], lin["coeffs"]))
        lo, hi = lin["domain"]
        lo, hi = _bound(lo), _bound(hi)
        if lo > -INF:
            m.Add(terms >= lo)
        if hi < INF:
            m.Add(terms <= hi)

    obj = model.get("objective", {})
    for direction, o in obj.items():
        expr = sum(coef * vs[name]
                   for name, coef in zip(o["vars"], o["coeffs"]))
        m.Maximize(expr) if direction == "maximize" else m.Minimize(expr)

    solver = cp_model.CpSolver()
    params = spec.get("params", {})
    if "maxTimeInSeconds" in params:
        solver.parameters.max_time_in_seconds = float(params["maxTimeInSeconds"])
    status = solver.Solve(m)

    return jsonify({
        "status": solver.StatusName(status),
        "objective": (solver.ObjectiveValue()
                      if status in (cp_model.OPTIMAL, cp_model.FEASIBLE) else None),
        "values": {name: solver.Value(v) for name, v in vs.items()},
    })


@app.route("/healthz")
def healthz():
    return "ok"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
