#!/usr/bin/env python3
"""build-dependency-graph.py — regenerate docs/dependency-graph-data.js.

Walks module/**/*.scm for (define-module ...) / #:use-module / (use-modules ...)
forms and browser/app/**/*.js (+ browser/lib/keri-crypto.js) for ES `import`
statements, classifies each file into a system component (by top-level
module path) and a "kind" (actor/store/bridge/ui/... — by filename pattern
and content heuristics), and writes the combined graph as the GRAPH_DATA
literal docs/dependency-graph.html reads at load time.

Usage:
    python3 docs/_scripts/build-dependency-graph.py            # dry run, prints counts
    python3 docs/_scripts/build-dependency-graph.py --write     # writes dependency-graph-data.js

Re-run this whenever module/** or browser/app/** changes materially — nothing
regenerates it automatically. The CATEGORY_INFO descriptions below are hand-written;
update them if a component's purpose changes, they won't be re-derived.
"""
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
MODULE_DIR = os.path.join(ROOT, "module")
OUT_PATH = os.path.join(ROOT, "docs", "dependency-graph-data.js")

# ---------- Scheme module + dependency extraction ----------

define_module_re = re.compile(r'\(define-module\s+\(([^)]+)\)', re.MULTILINE)
use_module_re = re.compile(r'#:use-module\s+\(([^)]+)\)')
use_modules_block_re = re.compile(r'\(use-modules\b(.*?)\)\s*(?=\n\n|\(define|\(load|\Z)', re.DOTALL)
paren_group_re = re.compile(r'\(([^()]+)\)')


def norm(name):
    return re.sub(r'\s+', ' ', name.strip())


def extract_scheme_graph():
    nodes = {}
    edges = set()
    scm_files = []
    for dirpath, _dirnames, filenames in os.walk(MODULE_DIR):
        for f in filenames:
            if f.endswith(".scm"):
                scm_files.append(os.path.join(dirpath, f))

    for path in scm_files:
        rel = os.path.relpath(path, ROOT)
        try:
            with open(path, 'r', errors='ignore') as fh:
                text = fh.read()
        except OSError:
            continue
        loc = text.count('\n')

        m = define_module_re.search(text)
        if not m:
            continue
        modname = norm(m.group(1))
        nodes[modname] = {"file": rel, "loc": loc, "text": text}

        for um in use_module_re.finditer(text):
            edges.add((modname, norm(um.group(1))))
        for block in use_modules_block_re.finditer(text):
            for pg in paren_group_re.finditer(block.group(1)):
                dep = norm(pg.group(1))
                if dep:
                    edges.add((modname, dep))

    return nodes, edges


# ---------- browser/app JS extraction ----------

js_import_re = re.compile(r"^import\s+(?:[^'\"]*?from\s+)?['\"](\.[^'\"]+)['\"]", re.MULTILINE)


def extract_js_graph():
    nodes = {}
    edges = set()
    js_files = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, "browser", "app")):
        for f in filenames:
            if f.endswith(".js"):
                js_files.append(os.path.join(dirpath, f))
    js_files.append(os.path.join(ROOT, "browser", "keri-crypto.js"))

    for path in js_files:
        rel = os.path.relpath(path, ROOT)
        try:
            with open(path, 'r', errors='ignore') as fh:
                text = fh.read()
        except OSError:
            continue
        loc = text.count('\n')
        nodes[rel] = {"file": rel, "loc": loc}
        for im in js_import_re.finditer(text):
            target_path = os.path.normpath(os.path.join(os.path.dirname(path), im.group(1)))
            edges.add((rel, os.path.relpath(target_path, ROOT)))

    return nodes, edges


# ---------- kind classification ----------

def classify_scheme_kind(rel_path, text):
    fname = os.path.basename(rel_path).lower()
    dirname = os.path.basename(os.path.dirname(rel_path)).lower()
    parent_dir = os.path.dirname(rel_path)
    grandparent = os.path.dirname(parent_dir)
    stem = fname[:-4]

    if os.path.isdir(os.path.join(ROOT, grandparent, stem)):
        return "umbrella"
    if 'test' in fname or dirname in ('test', 'tests'):
        return "test"
    if 'bench' in fname or dirname == 'bench':
        return "test"
    if 'store' in fname:
        return "store"
    if 'bridge' in fname:
        return "bridge"
    if 'schema' in fname or 'types' in fname:
        return "schema"
    if 'util' in fname or dirname == 'utils':
        return "utility"
    if 'config' in fname:
        return "config"
    if fname in ('gateway.scm', 'lobby.scm', 'server.scm') or 'gateway' in fname or 'lobby' in fname:
        return "service"
    if 'adapter' in fname or 'transport' in fname or 'protocol' in fname:
        return "adapter"
    if dirname == 'data':
        return "data"
    if dirname == 'ui':
        return "ui"
    if 'define-actor' in text or re.search(r'\(define \^', text):
        return "actor"
    return "module"


def classify_js_kind(rel_path):
    fname = os.path.basename(rel_path).lower()
    if 'tabs/' in rel_path:
        return "ui"
    if fname == 'main.js':
        return "umbrella"
    if fname in ('state.js', 'reactive.js'):
        return "state"
    if fname == 'seam.js':
        return "bridge"
    if fname in ('geom.js', 'timefmt.js', 'nutrition.js', 'audio.js', 'palette.js'):
        return "utility"
    return "module"


# ---------- component (category) classification + hand-written descriptions ----------

CATEGORY_INFO = {
    "playnet ai": {"label": "AI", "desc": "LLM integration — bridges the browser evaluator's (ai ...) forms to real models via key-pool; prompt templates; TEE attestation for private inference.", "color": "#8b5cf6"},
    "playnet crypto": {"label": "Crypto", "desc": "Low-level cryptographic primitives (Shamir's Secret Sharing k-of-n threshold splitting), used e.g. to split governance root key material among founders.", "color": "#6d28d9"},
    "playnet deprecated": {"label": "Deprecated", "desc": "Superseded/parallel-experiment code kept for reference (old federation substrates, kanren planning experiments, an older planner). New work should not depend on it.", "color": "#6b7280"},
    "playnet fleet": {"label": "Fleet", "desc": "Automated VPS provisioning — a reconciler actor driving a declarative desired-state fleet through payment→launch→provisioning, dispatching to pluggable hosting providers.", "color": "#0891b2"},
    "playnet gateway": {"label": "Gateway", "desc": "The server's public OCapN entry point — ^lobby actor (KERI challenge-response auth, mailbox/terminal access), signup agent, gateway-exposed services.", "color": "#0ea5e9"},
    "playnet governance": {"label": "Governance", "desc": "The core organizational/commune layer — unified ^scope actor (communes/federations, merge/split/recompose), KERI-backed credentialing, ballots, delegation, sybil detection, founding ceremony.", "color": "#dc2626"},
    "playnet interface": {"label": "Interface", "desc": "Generic transport-agnostic conversational front-end — ^channel binds one chat surface to a backend, command dispatch, multi-turn flows, Matrix/Telegram adapters.", "color": "#ea580c"},
    "playnet keri": {"label": "KERI", "desc": "KERI decentralized identity primitives — CESR encoding, DID:keri, witness/toad selection, credentials, recovery, KERIA/signify bridge. The identity substrate under governance and gateway auth.", "color": "#b91c1c"},
    "playnet key-pool": {"label": "Key Pool", "desc": "Goblins actor for round-robin, capability-secure pooling of API keys; vf-bridge emits ValueFlows records so key usage is planned/accounted like any other resource flow.", "color": "#7c3aed"},
    "playnet lang": {"label": "Lang", "desc": "Language-layer building blocks that must run in-browser (Hoot/WASM): the metacircular evaluator, miniKanren, relational knowledge queries, wisp transpiler, markdown, autocomplete.", "color": "#059669"},
    "playnet monero": {"label": "Monero", "desc": "Sealed wallet actor and spend-policy governance for Monero payments — wraps monero-wallet-rpc, persists budget/allowlist policy; used by fleet to pay for servers privately.", "color": "#f97316"},
    "playnet mqtt": {"label": "MQTT", "desc": "Shared MQTT subscription-loop helper (wraps mosquitto_sub, handles reconnects/JSON parsing) used by various bridges to listen for planner/fleet signals.", "color": "#64748b"},
    "playnet notify": {"label": "Notify", "desc": "The unified notification system — a single registry authors each event's presentation once; a router resolves recipient channels, dedups, renders per-channel style, and dispatches.", "color": "#d97706"},
    "playnet org": {"label": "Org (kernel)", "desc": "The kernel of the governance pattern — ^org/^logger/proxy-pair actors (Heart of Spritely accountability/revocation), gplay.scm (Hoot-compatible evaluator), factories for open/governed orgs.", "color": "#991b1b"},
    "playnet planner": {"label": "Planner", "desc": "The ValueFlows economic planning engine — convex optimization (interior-point/OSQP) over located, time-scoped economic activity, plus recipes, agents, matching, federation (ADMM), legal/compliance, chat/query.", "color": "#15803d"},
    "playnet push": {"label": "Push", "desc": "Web Push (RFC 8030/8291/8292) delivery adapter and VAPID key management for browser push — one of notify's channel adapters.", "color": "#ca8a04"},
    "playnet sms": {"label": "SMS", "desc": "Client for an SMS-number rental/verification API used for phone-based verification flows.", "color": "#64748b"},
    "playnet social": {"label": "Social", "desc": "A \"lens\" abstraction defining named neighborhoods of AIDs over the social graph (friends/family/commons), used to weight collaborative signals by whose assertions count.", "color": "#c026d3"},
    "playnet test": {"label": "Test infra", "desc": "Shared test infrastructure — assertion helpers, mock server spawning, KERIA integration-test bring-up contract reused across suites.", "color": "#71717a"},
    "playnet ui": {"label": "UI (server SXML)", "desc": "Server-side SXML component library for the dashboard (zone badges, buffer bars, calendar, network/treemap diagrams) — pure functions producing virtual-DOM trees rendered in-browser.", "color": "#2563eb"},
    "playnet utils": {"label": "Utils", "desc": "Cross-cutting small utilities — safe-call/error helpers, GNU Units integration, hex/hashmap/alist helpers, constant-time comparisons, secure memory, the SAID content-addressed disk store.", "color": "#475569"},
    "goblins": {"label": "Goblins (vendored)", "desc": "The vendored Spritely Goblins actor-model library — distributed object-capability actors, vats, OCapN/CapTP. The dependency playnet's governance patterns are built on.", "color": "#1e293b"},
    "agronomy": {"label": "Agronomy data", "desc": "Crop yield-response constants and the FAO Ky water-stress model, feeding planner multiplier/derived-data computation.", "color": "#166534"},
    "bioclim": {"label": "Bioclim data", "desc": "Derives a bioregion's rainfall scenarios (drought/normal/flood) from precipitation records for the planner's ecological modeling.", "color": "#166534"},
    "js-dial": {"label": "Browser: dial (day view)", "desc": "The Hoot-free vanilla-JS day/calendar UI — signals-based reactive rendering, tabs for governance/inventory/law/contacts/matter/chat/fragility/containers/calendar/id.", "color": "#2dd4bf"},
}


def categorize(name):
    parts = name.split()
    if parts[0] == "playnet" and len(parts) > 1:
        cat = "playnet " + parts[1]
        if cat in CATEGORY_INFO:
            return cat
    if parts[0] in CATEGORY_INFO:
        return parts[0]
    return "playnet utils" if parts[0] == "playnet" else parts[0]


# ---------- assemble ----------

def build():
    scheme_nodes, scheme_edges = extract_scheme_graph()
    js_nodes, js_edges = extract_js_graph()

    nodes = []
    node_index = {}
    for name, info in scheme_nodes.items():
        node_index[name] = len(nodes)
        nodes.append({
            "id": name,
            "file": info["file"],
            "loc": info["loc"],
            "category": categorize(name),
            "kind": "scheme",
            "type": classify_scheme_kind(info["file"], info["text"]),
        })
    for name, info in js_nodes.items():
        node_index[name] = len(nodes)
        nodes.append({
            "id": name,
            "file": info["file"],
            "loc": info["loc"],
            "category": "js-dial",
            "kind": "js",
            "type": classify_js_kind(info["file"]),
        })

    links = []
    seen = set()
    for src, dep in scheme_edges:
        if dep not in node_index or src == dep:
            continue
        key = (src, dep)
        if key in seen:
            continue
        seen.add(key)
        links.append({"source": node_index[src], "target": node_index[dep]})
    for src, dep in js_edges:
        if dep not in node_index or src == dep:
            continue
        key = (src, dep)
        if key in seen:
            continue
        seen.add(key)
        links.append({"source": node_index[src], "target": node_index[dep]})

    return {"nodes": nodes, "links": links, "categories": CATEGORY_INFO}


def main():
    graph = build()
    scheme_count = sum(1 for n in graph["nodes"] if n["kind"] == "scheme")
    js_count = sum(1 for n in graph["nodes"] if n["kind"] == "js")
    print(f"{scheme_count} Scheme modules, {js_count} JS modules, {len(graph['links'])} internal edges")

    if "--write" in sys.argv:
        with open(OUT_PATH, 'w') as f:
            f.write("const GRAPH_DATA = ")
            json.dump(graph, f, separators=(',', ':'))
            f.write(";\n")
        print(f"wrote {OUT_PATH}")
    else:
        print("dry run — pass --write to regenerate docs/dependency-graph-data.js")


if __name__ == "__main__":
    main()
