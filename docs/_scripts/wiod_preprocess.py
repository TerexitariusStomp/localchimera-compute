#!/usr/bin/env python3
"""wiod_preprocess.py — turn the WIOD 2016 release (year 2014) into a planner-ready
input-output table.

Inputs  (download into docs/data/wiod/):
  WIOT_excel.zip   dataverse datafile 199104  — World Input-Output Tables, all years
  SEA.xlsx         dataverse datafile 199095  — Socio-Economic Accounts (hours)
  (optional CO2 accounts — JRC; left out unless docs/data/wiod/CO2.xlsx present)

Outputs (docs/data/wiod/):
  wiod2014.sexp    for module/localchimera/bench/bench-real.scm
  wiod2014.npz     for docs/_scripts/validate_leontief.py

The WIOT is a CLOSED world model (44 regions × 56 ISIC sectors = 2464 sectors,
incl. a Rest-of-World region), values in millions of USD. We extract the 2464×2464
intermediate block Z, the gross-output row x, and the final-demand columns f, then
form the direct-requirements matrix A = Z / x_col. Hours come from SEA H_EMPE
(physical hours ⇒ currency-safe) matched on (country, sector-code); the labour
coefficient used downstream is H_EMPE_j / x_j(WIOT-USD).

Run under the Guix python stack:
  guix shell python python-numpy python-scipy python-openpyxl -- \
    python3 docs/_scripts/wiod_preprocess.py
"""
import os, sys, zipfile, io, re, csv, subprocess
import numpy as np
import openpyxl
# No solving here: preprocessing only extracts data. The planner seeds its own
# strictly-feasible starting plan in Scheme (demand backtrace), so there is no
# numpy/scipy crutch on the critical path. (validate_leontief.py uses scipy, but
# that's the independent ground-truth checker, deliberately a separate engine.)

HERE  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # docs/
DDIR  = os.path.join(HERE, "data", "wiod")
YEAR  = 2014
PRUNE = 1e-6          # drop |a_ij| below this (economically negligible, keeps cond honest)

# ── SEA: hours worked by employees (H_EMPE), year 2014, per (country, code) ──
def load_hours():
    wb = openpyxl.load_workbook(os.path.join(DDIR, "SEA.xlsx"), read_only=True, data_only=True)
    ws = wb["DATA"]; hdr = None; ycol = None; H = {}
    for r in ws.iter_rows(values_only=True):
        if hdr is None:
            hdr = list(r); ycol = hdr.index(YEAR); continue
        country, var, desc, code = r[0], r[1], r[2], r[3]
        if var == "H_EMPE":
            v = r[ycol]
            H[(country, code)] = float(v) if isinstance(v, (int, float)) else 0.0
    return H

# ── WIOT: extract Z (2464²), gross output x, final demand f, labels ──────────
# The WIOT ships as .xlsb (binary); openpyxl can't read it, so we convert it to
# CSV with headless LibreOffice (once) and parse that. Layout (confirmed by
# inspection):
#   6 header rows; row idx4 = country-per-column, row idx5 = c1..c56 per column.
#   data rows: col0=sector code, col1=description, col2=country(ISO3), col3=RNr
#   ("r1"…), then 2464 intermediate-use values (same order as rows, industry-by-
#   industry ⇒ already symmetric), then 5 final-demand categories × 44 regions,
#   then a trailing TOT column. 8 summary rows follow (col2=="TOT"), incl. "GO"
#   (Output at basic prices) = gross output per COLUMN sector.
#   Numbers may carry thousands-separator commas but are QUOTED, so csv parses
#   them as single fields; we strip commas before float().
WIOT_XLSB_RE = re.compile(r"WIOT%d.*\.xlsb$" % YEAR, re.I)

def ensure_wiot_csv():
    csvp = os.path.join(DDIR, "WIOT%d_Nov16_ROW.csv" % YEAR)
    if os.path.exists(csvp):
        return csvp
    # extract the year member from the all-years zip, then soffice → csv
    zp = os.path.join(DDIR, "WIOT_excel.zip")
    member = None
    with zipfile.ZipFile(zp) as z:
        for nm in z.namelist():
            if WIOT_XLSB_RE.search(nm):
                member = nm; z.extract(nm, DDIR); break
    if member is None:
        raise FileNotFoundError("WIOT%d xlsb not found in zip" % YEAR)
    xlsb = os.path.join(DDIR, member)
    subprocess.run(["soffice", "--headless",
                    "-env:UserInstallation=file:///tmp/sofficeprof_pp",
                    "--convert-to", "csv:Text - txt - csv (StarCalc):44,34,76,1,,,false",
                    "--outdir", DDIR, xlsb], check=True)
    return csvp

def num(s):
    s = (s or "").strip().replace(",", "")
    if not s:
        return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0

def load_wiot():
    csvp = ensure_wiot_csv()
    with open(csvp, newline="") as fh:
        rows = list(csv.reader(fh))
    # data rows: a real ISO country in col2 (summary rows have "TOT")
    col_country = rows[4]                      # country per column (from header row idx4)
    iso = set(c for c in col_country[4:] if c and c != "TOT")
    data_idx = [i for i, r in enumerate(rows)
                if len(r) > 3 and r[2] in iso and r[0]]
    n = len(data_idx)
    labels    = [f"{rows[i][2]}|{rows[i][0]}" for i in data_idx]
    countries = [rows[i][2] for i in data_idx]
    codes     = [rows[i][0] for i in data_idx]
    C0 = 4
    ncols = len(rows[data_idx[0]])             # uniform under proper csv parsing
    # intermediate block
    Z = np.array([[num(rows[src][C0 + cj]) for cj in range(n)] for src in data_idx])
    # final demand: columns C0+n .. last-1 (drop trailing TOT), summed per row
    fd = np.array([sum(num(rows[src][cj]) for cj in range(C0 + n, ncols - 1))
                   for src in data_idx])
    # gross output from the GO row (col0 == "GO"), per column sector
    go_idx = next(i for i, r in enumerate(rows) if (r[0] or "").strip().upper() == "GO")
    go = np.array([num(rows[go_idx][C0 + cj]) for cj in range(n)])
    return n, np.array(labels), countries, codes, Z, fd, go

# ── assemble + emit ─────────────────────────────────────────────────────────
def main():
    H = load_hours()
    n, labels, countries, codes, Z, fd, go = load_wiot()
    print(f"WIOT {YEAR}: n={n}  Σgo={go.sum():.4g}  Σfd={fd.sum():.4g}")

    # A = Z / x_col  (column-normalise by gross output)
    x = go.copy(); x[x <= 0] = np.nan
    A = Z / x[np.newaxis, :]
    A = np.nan_to_num(A, nan=0.0)
    A[np.abs(A) < PRUNE] = 0.0
    rows_i, cols_j = np.nonzero(A)
    a_val = A[rows_i, cols_j]
    print(f"A=Z/x: nnz={len(a_val)}  max col-sum={np.nan_to_num(A.sum(axis=0)).max():.3f}  "
          f"mean col-sum={np.nan_to_num(A.sum(axis=0)).mean():.3f}")

    # hours aligned to WIOT order (RoW etc. → 0)
    hours = np.array([H.get((countries[j], codes[j]), 0.0) for j in range(n)])
    co2   = np.zeros(n)   # filled if a CO2 accounts file is wired in later
    va    = go - Z.sum(axis=0)   # value added ≈ output − intermediate inputs
    fd_clamped = np.maximum(fd, 0.0)
    dropped = float(fd.sum() - fd_clamped.sum())
    print(f"hours matched: {(hours>0).sum()}/{n}  Σhours={hours.sum():.4g}  "
          f"net-final-demand negatives (inventory drawdown) sum={-dropped:.4g}")

    # .npz for the numpy validator (fd_raw lets it prove exact extraction before
    # clamping; fd is the clamped vector the planner actually uses)
    np.savez(os.path.join(DDIR, "wiod2014.npz"),
             n=n, labels=labels, go=go, fd=fd_clamped, fd_raw=fd, va=va,
             hours=hours, co2=co2,
             a_row=rows_i.astype(np.int32), a_col=cols_j.astype(np.int32), a_val=a_val)

    # .sexp for bench-real.scm
    def vec(name, arr):
        return f"  ({name} #(" + " ".join(repr(float(v)) for v in arr) + "))\n"
    with open(os.path.join(DDIR, "wiod2014.sexp"), "w") as p:
        p.write("(wiod-io\n")
        p.write(f"  (year {YEAR})\n  (n {n})\n")
        p.write("  (labels #(" + " ".join('"%s"' % l for l in labels) + "))\n")
        p.write(vec("gross-output", go))
        # raw net final demand WITH its negatives: the planner splits each into a
        # demand (positive part) and an on-hand inventory cushion (negative part =
        # stock the economy drew down that year), so the warehouse sectors balance.
        p.write(vec("final-demand-raw", fd))
        p.write(vec("value-added", va))
        p.write(vec("hours", hours))
        p.write(vec("co2", co2))
        p.write("  (a-triples\n")
        for i, j, a in zip(rows_i, cols_j, a_val):
            p.write(f"    ({int(i)} {int(j)} {float(a)!r})\n")
        p.write("  ))\n")
    print(f"wrote {DDIR}/wiod2014.sexp and wiod2014.npz")

if __name__ == "__main__":
    main()
