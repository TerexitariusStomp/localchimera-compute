#!/usr/bin/env python3
"""fetch-fr-gpu.py — one French commune's land regime as a CONTEXT PACK.

A context pack (knowledge/context-pack.scm) is where a place is and what the law
asks there, in one file. This is the FRANCE adapter that produces one: it reads
the open national services and writes the pack's two halves.

    tools/law/fetch-fr-gpu.py <insee> > docs/legal/contexts/fr-<insee>.sexp

Sources, all open, no key:
  geo.api.gouv.fr          the administrative chain (commune → EPCI → dept → region)
  apicarto.ign.fr/api/gpu  the urbanism document, its zones and its prescriptions
  georisques.gouv.fr       the risks the state records for the commune

What is COUNTRY-SPECIFIC lives in the two tables below — ZONE_RULES maps a French
PLU zone type to demands, PRESCRIPTION_RULES maps a CNIG prescription code. The
shape either produces (a guard form + demands + provenance) is not French at all,
so a second country is a second adapter beside this one, not a change anywhere
else.

REPRODUCIBILITY: the pack records, per rule, the document id (`idurba`) and the
date the state validated that zone (`datvalid`). Re-running against an unchanged
document yields a byte-identical pack; a modification changes only the rules whose
zones moved.
"""
import json, sys, urllib.request, urllib.parse, datetime

UA = {"User-Agent": "playnet-law-ingest/1.0"}

def get(url, **params):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        return json.load(r)

# ── the French vocabulary: PLU zone type → what the state asks there ──────────
# `act-is` matches an UNSPECIFIED act, so a `negate (act-is …)` clause stays
# silent until a recipe names its act — the permissive-when-unknown default the
# guard language already has. A zone that only permits its own use is written
# that way: forbid the crossing UNLESS the act is the permitted one.
#
# CONFIDENCE is about this RULE's fidelity to the law, not about how
# authoritative the dataset is. The zone geometry is the state's own and beyond
# doubt either way; what varies is whether the demand written here is what the
# statute says for that category, or something the adapter inferred.
#
#   reported  — the demand IS the statutory meaning of the dataset's category
#               (code de l'urbanisme L151-11: in zone A only constructions
#               necessary to farming; L113-1: an Espace Boisé Classé forbids
#               défrichement). The pack restates law, it does not guess it.
#   uncertain — the adapter inferred a demand the source does not name. Folds as
#               a strong soft cost, never a hard prune (legal/gate.scm).
#
# KNOWN INCOMPLETENESS: a French zone A also permits extensions and annexes of
# existing dwellings, services publics, reconstruction after a disaster — all
# under conditions stated only in the règlement's prose, which no adapter reading
# a vector layer can see. So these rules OVER-PROHIBIT at the margin. That is the
# diagnosable direction — a plan that cannot build says so — where
# under-prohibition is silent, which is why they stay `reported` rather than
# being softened to cover for detail this adapter does not have.
#
# The remedy is a companion pack that reads the document and SUPERSEDES these by
# demand name (`cancels`): for a given commune that is fr-<insee>-reglement.sexp,
# from its own PLU règlement PDF. A category rule is the best a
# dataset can do and the worst a règlement can say; where someone has read the
# prose, the prose governs.
ZONE_RULES = {
    # An A zone IS agricultural land — so the adapter classifies it and stops
    # there. Every national rule about agricultural land (SAFER's pre-emption
    # over a sale, code rural L143-1 et s.) reaches it through `place-has`,
    # written once by the nation rather than repeated per commune.
    "A": dict(kind="agricole", confidence="reported", classify=["agricultural"],
              rules=[("forbid", "construction non nécessaire à l'exploitation agricole",
                      ["built-structure"], "agriculture")]),
    "N": dict(kind="naturelle", confidence="reported",
              rules=[("forbid", "construction en zone naturelle",
                      ["built-structure"], None)]),
    "U": dict(kind="urbaine", confidence="reported",
              rules=[("obtain", "Permis de construire", ["built-structure"], None)]),
    "AU": dict(kind="a-urbaniser", confidence="reported",
               rules=[("obtain", "Permis de construire", ["built-structure"], None)]),
    "AUc": dict(kind="a-urbaniser", confidence="reported",
                rules=[("obtain", "Permis de construire", ["built-structure"], None)]),
    "AUs": dict(kind="a-urbaniser", confidence="reported",
                rules=[("forbid", "zone à urbaniser fermée (ouverture par modification du PLU)",
                        ["built-structure"], None)]),
}

# CNIG prescription code → a demand over the whole commune's crossing, with the
# same confidence rule: 01 restates L113-1, 02 is an inference (the prescription
# records that a collapse perimeter EXISTS; it does not name a study).
PRESCRIPTION_RULES = {
    "01": ("forbid", "Espace Boisé Classé — défrichement interdit, coupes soumises à déclaration",
           ["clear-woodland"], "reported"),
    "02": ("obtain", "Étude de sol — périmètre d'effondrement (carrières souterraines)",
           ["built-structure"], "uncertain"),
    # R.421-17 d): work on an element protected under L.151-19 needs a déclaration
    # préalable. Which formality it is, is this adapter's reading — hence uncertain.
    "07": ("tell", "Déclaration préalable — élément protégé au titre du L.151-19",
           ["built-structure"], "uncertain"),
}

# Codes this adapter SEES and deliberately does not encode. Recorded in the pack
# header rather than dropped in silence: an omission nobody can see is the same
# failure as a rule that never fires, one layer earlier.
PRESCRIPTION_UNENCODED = {
    "05": "emplacements réservés — a pre-emption over the parcel, not a demand on an activity",
    "15": "limitations d'implantation — the code lumps setbacks, alignments and zones "
          "non aedificandi together; too coarse to read as one demand",
    "18": "périmètres d'OAP — development must be COMPATIBLE with an orientation whose "
          "content is prose, not a demand the vector layer states",
}

PERMIT_SPEC = {
    "Permis de construire": ["implantation", "emprise", "hauteur", "aspect-exterieur"],
    "Étude de sol — périmètre d'effondrement (carrières souterraines)": ["cavite", "fondations"],
}

def simplify(g, keep=120):
    """The commune outline, thinned enough to travel in a query string."""
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    best = max((r for p in polys for r in p), key=len)
    step = max(1, len(best) // keep)
    ring = [best[i] for i in range(0, len(best), step)]
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    return {"type": "Polygon", "coordinates": [[[round(x, 5), round(y, 5)] for x, y in ring]]}

def scm(v):
    """Python value → Scheme datum."""
    if v is None or v is False:
        return "#f"
    if v is True:
        return "#t"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, Sym):
        return v.s
    if isinstance(v, (list, tuple)):
        return "(" + " ".join(scm(x) for x in v) + ")"
    if isinstance(v, dict):
        return "(" + " ".join("(%s . %s)" % (k, scm(x)) for k, x in v.items()) + ")"
    raise TypeError(type(v))

class Sym:
    def __init__(self, s): self.s = s

def demand(kind, name, rides=None, spec=None, detail=None):
    """The five-slot demand sexp legal/registry.scm's `sexp->demand` reads."""
    return [Sym(kind), name, Sym(rides) if rides else False, spec, detail or {}]

def main(insee):
    today = datetime.date.today().isoformat()
    com = get("https://geo.api.gouv.fr/communes",
              code=insee, fields="nom,code,codeDepartement,codeRegion,codeEpci,population")[0]
    dep = get("https://geo.api.gouv.fr/departements/%s" % com["codeDepartement"])
    reg = get("https://geo.api.gouv.fr/regions/%s" % com["codeRegion"])
    epci = None
    if com.get("codeEpci"):
        try:
            epci = get("https://geo.api.gouv.fr/epcis/%s" % com["codeEpci"], fields="nom,code")
        except Exception:
            epci = None

    muni_f = get("https://apicarto.ign.fr/api/gpu/municipality", insee=insee)["features"][0]
    muni = muni_f["properties"]

    # ── which document covers this commune ───────────────────────────────────
    # Asking for partition=DU_<insee> finds a COMMUNAL plan and nothing else. For
    # the ~14,900 communes under an intercommunal PLUi the document is filed
    # under the EPCI's SIREN, so that query returns zero features and the adapter
    # used to emit a pack with a correct administrative chain and no zoning at
    # all — for Bordeaux, 0 zones instead of 2,478, reported as success.
    #
    # Querying by the commune's own GEOMETRY finds whatever document covers the
    # ground, communal or intercommunal, and the server does the clipping. The
    # partition then falls out of the data rather than having to be guessed, and
    # is recorded below as provenance.
    geom = json.dumps(simplify(muni_f["geometry"]))
    # …and then KEEP only this commune's own document. A geometry query is a
    # spatial filter, not a jurisdictional one: a commune's outline can touch its
    # neighbours', so the first version of this pulled their zones in as if they
    # were its own — a real test commune showed 27 zones where it has 23. The
    # partition says
    # whose plan a zone belongs to, and only two can be this commune's: its own
    # communal document, or its EPCI's intercommunal one.
    mine = {"DU_%s" % insee} | ({"DU_%s" % epci["code"]} if epci else set())
    def own(fs):
        return [f for f in fs if f["properties"].get("partition") in mine]
    zones = own(get("https://apicarto.ign.fr/api/gpu/zone-urba", geom=geom).get("features", []))
    if not zones and not muni.get("is_rnu"):
        # a commune with a document but no zones is a contradiction worth saying
        sys.stderr.write("fetch-fr-gpu: %s reports a document (is_rnu false) but no zone "
                         "covers it — check apicarto.\n" % insee)
    # all THREE geometries: a protection can be a surface, a line or a point, and
    # reading only surfaces silently missed most of the same test commune's
    # prescriptions (66 of 182).
    presc = []
    for layer in ("prescription-surf", "prescription-lin", "prescription-pct"):
        presc += own(get("https://apicarto.ign.fr/api/gpu/%s" % layer,
                         geom=geom).get("features", []))
    risks = get("https://georisques.gouv.fr/api/v1/gaspar/risques", code_insee=insee)["data"]

    nation, region_id = "france", "fr-reg-%s" % reg["code"]
    dep_id, com_id = "fr-dep-%s" % dep["code"], "fr-%s" % insee
    epci_id = "fr-epci-%s" % epci["code"] if epci else None

    # ── places: the administrative chain, then the zones under the commune ────
    places = [
        # France is IN the European Union, and saying so is not decoration: the
        # EU food-safety rules another pack already carries are guarded on
        # `in-jurisdiction "eu"`, and a chain that stopped at France made every
        # one of them unreachable here. The row is emitted so this pack stands
        # alone; a pack that also places `eu` merges with it.
        ["eu", "European Union", "world", Sym("region"), {}, False, False],
        [nation, "France", "eu", Sym("nation"), {"iso": "250"}, 46.6, 2.3],
        [region_id, reg["nom"], nation, Sym("region"), {"insee": reg["code"]}, False, False],
        [dep_id, dep["nom"], region_id, Sym("region"), {"insee": dep["code"]}, False, False],
    ]
    parent_of_commune = dep_id
    if epci_id:
        places.append([epci_id, epci["nom"], dep_id, Sym("region"),
                       {"siren": epci["code"], "kind": "epci"}, False, False])
        parent_of_commune = epci_id
    com_extra = {"insee": insee, "population": com.get("population") or 0,
                 "rnu": muni.get("is_rnu")}
    if muni.get("is_rnu"):
        # ~6,675 communes have no local plan at all and fall under the RÈGLEMENT
        # NATIONAL D'URBANISME. There are no zones to fetch and the rules are the
        # nation's, so the adapter CLASSIFIES and a national rule does the rest —
        # the same division of labour as agricultural land and the SAFER.
        com_extra["classified-as"] = ["rnu"]
    places.append([com_id, com["nom"], parent_of_commune, Sym("locality"),
                   com_extra, False, False])

    # one place per distinct zone LABEL (a label may have many polygons)
    labels = {}
    for f in zones:
        p = f["properties"]
        labels.setdefault(p["libelle"], p)
    for lb in sorted(labels):
        p = labels[lb]
        extra = {"zone": lb, "typezone": p["typezone"], "idurba": p.get("idurba"),
                 "datvalid": p.get("datvalid")}
        cls = (ZONE_RULES.get(p["typezone"]) or {}).get("classify")
        if cls:
            extra["classified-as"] = cls
        places.append(["%s-%s" % (com_id, lb), "%s zone %s" % (com["nom"], lb), com_id,
                       Sym("locality"), extra, False, False])

    # ── rules ────────────────────────────────────────────────────────────────
    rules = []
    doc = (list(labels.values())[0].get("idurba") if labels else None) or "n/a"
    src = "GPU %s — %s" % (doc, (list(labels.values())[0].get("nomfic") if labels else ""))

    for lb in sorted(labels):
        p = labels[lb]
        spec = ZONE_RULES.get(p["typezone"])
        if not spec:
            continue
        for (dkind, reason, crossings, unless_act) in spec["rules"]:
            guard = [Sym("all-of"), [Sym("in-jurisdiction"), "%s-%s" % (com_id, lb)],
                     ([Sym("on-crossing"), Sym(crossings[0])] if len(crossings) == 1
                      else [Sym("any-of")] + [[Sym("on-crossing"), Sym(c)] for c in crossings])]
            if unless_act:
                guard.append([Sym("negate"), [Sym("act-is"), Sym(unless_act)]])
            if dkind == "forbid":
                ds = [demand("forbid", reason, detail={"reason": reason, "direction": False})]
            elif dkind == "tell":
                ds = [demand("tell", reason, rides="entity",
                             detail={"to": "SAFER Nouvelle-Aquitaine",
                                     "discloses": [Sym("parcelle"), Sym("prix"), Sym("acquereur")],
                                     "direction": False, "retain": False, "renew": False})]
            else:
                ds = [demand("obtain", reason, rides="entity", spec=[Sym(s) for s in PERMIT_SPEC.get(reason, [])],
                             detail={"issuer": "Mairie de %s" % com["nom"], "per": Sym("each-site"),
                                     "direction": False, "retain": False, "renew": False})]
            rules.append([guard, ds,
                          "%s/%s/%s" % (insee, lb, dkind),
                          src, p.get("datvalid"), Sym(spec["confidence"]), com_id])

    seen = set()
    for f in presc:
        code = f["properties"].get("typepsc")
        if code not in PRESCRIPTION_RULES or code in seen:
            continue
        seen.add(code)
        dkind, reason, crossings, conf = PRESCRIPTION_RULES[code]
        guard = [Sym("all-of"), [Sym("in-jurisdiction"), com_id],
                 [Sym("on-crossing"), Sym(crossings[0])]]
        if dkind == "forbid":
            ds = [demand("forbid", reason, detail={"reason": reason, "direction": False})]
        else:
            ds = [demand("obtain", reason, rides="entity",
                         spec=[Sym(s) for s in PERMIT_SPEC.get(reason, [])],
                         detail={"issuer": "Mairie de %s" % com["nom"], "per": Sym("each-site"),
                                 "direction": False, "retain": False, "renew": False})]
        rules.append([guard, ds, "%s/prescription-%s" % (insee, code),
                      src + " (prescription CNIG %s)" % code,
                      f["properties"].get("datappro") or today, Sym(conf), com_id])

    # what was seen and not encoded — per code, with its count
    from collections import Counter
    seen_codes = Counter(f["properties"].get("typepsc") for f in presc)
    skipped = [(c, n, PRESCRIPTION_UNENCODED.get(c, "no mapping in this adapter"))
               for c, n in sorted(seen_codes.items())
               if c not in PRESCRIPTION_RULES]
    # ── the zones' own EXTENTS, on the boundaries convention ─────────────────
    # The pack names zones and says which law each carries; it cannot say WHERE
    # one is, and every `within` a parcel claims was decided against these
    # polygons by a script whose answer nothing else could check. Written beside
    # the pack in the same shape `tools/qgis/ingest-boundaries.scm` uses for
    # DEM-derived sheds — properties.id names the place, `derivation` says where
    # the polygon came from — the geometry becomes a fact the system holds rather
    # than one an ingest step consumed and discarded.
    #
    # One feature per zone LABEL, unioned: a label is one place in the pack even
    # where the plan draws it as several polygons.
    import os
    by_label = {}
    for f in zones:
        lb = f["properties"]["libelle"]
        g = f["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        by_label.setdefault(lb, []).extend(polys)
    zderiv = {"source": "apicarto.ign.fr/api/gpu zone-urba (Géoportail de l'Urbanisme)",
              "document": doc, "partitions": sorted({z["properties"].get("partition") or "?"
                                                     for z in zones}),
              "tool": "tools/law/fetch-fr-gpu.py"}
    zfc = {"type": "FeatureCollection", "features": [
        {"type": "Feature",
         "geometry": {"type": "MultiPolygon", "coordinates": polys},
         "properties": {"id": "%s-%s" % (com_id, lb), "name": "%s zone %s" % (com["nom"], lb),
                        "tier": "zone", "commune": com_id,
                        "typezone": labels[lb]["typezone"], "derivation": zderiv}}
        for lb, polys in sorted(by_label.items())]}
    zpath = "data/law/fr-%s-zones.geojson" % insee
    os.makedirs(os.path.dirname(zpath) or ".", exist_ok=True)
    with open(zpath, "w", encoding="utf-8") as fh:
        json.dump(zfc, fh, ensure_ascii=False)
    sys.stderr.write("wrote %s (%d zone extents)\n" % (zpath, len(zfc["features"])))

    hdr = [";;; fr-%s.sexp — %s (INSEE %s): a CONTEXT PACK, generated." % (insee, com["nom"], insee),
           ";;; tools/law/fetch-fr-gpu.py %s   fetched %s" % (insee, today),
           ";;; document: %s   zones: %d   prescriptions kept: %d" % (doc, len(labels), len(seen)),
           ";;; partition(s) covering this commune: %s%s" % (
               ", ".join(sorted({z["properties"].get("partition") or "?" for z in zones})) or "none",
               "   [RNU — no local plan; the national règlement applies]"
               if muni.get("is_rnu") else ""),
           ";;; state-recorded risks: %s" % ", ".join(
               r.get("libelle_risque_long", "") for r in (risks[0]["risques_detail"] if risks else [])),
           ";;; Confidence per rule: `reported` where the demand is the statutory",
           ";;; meaning of the dataset's own category, `uncertain` where this adapter",
           ";;; inferred it. A steward reads the règlement and re-signs at `verified`.",
           ";;;",
           ";;; COVERAGE, stated rather than left to be discovered:",
           ";;; · %d zone labels carry only %d distinct rules, because the vector layer's"
           % (len(labels), len(set(p["typezone"] for p in labels.values()))),
           ";;;   `typezone` is the coarse handle and the label's meaning (density, height,",
           ";;;   setback, what Uy or Ue is FOR) lives in the règlement's prose. The labels",
           ";;;   are kept as distinct PLACES, so refining a single one is additive: add a",
           ";;;   rule guarded on it, regenerate nothing.",
           ";;; · prescriptions seen and NOT encoded:"] + \
          [";;;     %s ×%-3d %s" % (c, n, why) for (c, n, why) in skipped] + \
          ([] if skipped else [";;;     (none)"]) + \
          [";;; · this adapter reads no prose: %s is untouched. A companion pack" % (
               (list(labels.values())[0].get("nomfic") if labels else "n/a")),
           ";;;   that reads it supersedes these category rules by demand name.",
           ";;;",
           ";;; · the zones' polygons are written beside this as data/law/fr-%s-zones.geojson," % insee,
           ";;;   on the boundaries convention, so where a zone IS is a fact the system holds.",
           ";;;",
           ";;; NOT in this pack (each its own authority, none of them the commune's):",
           ";;;   SUP/servitudes, AOC/INAO delimitation, SAGE, SCoT, risk PPR."]
    out = "\n".join(hdr) + "\n" + scm([[Sym("places")] + places, [Sym("rules")] + rules]) + "\n"
    sys.stdout.write(out)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: fetch-fr-gpu.py <insee>")
    main(sys.argv[1])
