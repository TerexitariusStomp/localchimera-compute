"""Authoritative OOBI-body check, driven by tests/identity/test-oobi-endpoint-replies.scm.

Feeds a localchimera-built OOBI body (KEL + framed OKEA endpoint replies) to
keripy's parser — the same machinery KERIA's OOBI resolution runs — and
exits 0 iff:

  1. the KEL is accepted (AID lands in kevers), and
  2. the /loc/scheme reply VERIFIES and registers the http endpoint in
     db.locs — the exact table hab.fetchUrls (and therefore KERIA's
     witness receiptor) consults.

Usage: python verify-oobi-replies.py <body-file> <aid> <expected-url>
"""
import sys
from keri.app import habbing
from keri.core import parsing, eventing

path, aid, expected_url = sys.argv[1], sys.argv[2], sys.argv[3]
ims = bytearray(open(path, "rb").read())

with habbing.openHby(name="oobi-reply-verify", temp=True) as hby:
    # Mirror an OOBI resolver: non-local Kevery sharing the habery's
    # Revery (reply routes are registered by Habery on its router).
    kvy = eventing.Kevery(db=hby.db, lax=True, local=False, rvy=hby.rvy)
    parsing.Parser(framed=True, kvy=kvy, rvy=hby.rvy).parse(ims=ims)
    # A bt>0 inception is escrowed (partially-witnessed) on first parse;
    # the rct streams that follow it in the body provide the wigs, and
    # escrow processing — which every real resolver runs on its cycle —
    # promotes the event into kevers. Witnessless KELs are unaffected.
    kvy.processEscrows()
    hby.rvy.processEscrowReply()

    ok_kel = aid in hby.db.kevers
    locs = {k[1]: loc.url for k, loc in hby.db.locs.getItemIter(keys=(aid,))}
    ends = [(k, e.allowed) for k, e in hby.db.ends.getItemIter(keys=(aid,))]

    print(f"kel-accepted: {ok_kel}")
    print(f"locs: {locs}")
    print(f"ends: {ends}")

    ok_loc = locs.get("http") == expected_url or locs.get("https") == expected_url
    ok_end = any(allowed for _k, allowed in ends)
    sys.exit(0 if (ok_kel and ok_loc and ok_end) else 1)
