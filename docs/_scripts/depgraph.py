import os, re, json, glob, sys, tempfile

ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),"..",".."))
MODROOT=os.path.join(ROOT,"module")

# map module-name-tuple -> file
mod2file={}
file2mod={}
files=glob.glob(os.path.join(MODROOT,"**","*.scm"),recursive=True)

def parse_modname(text):
    m=re.search(r"\(define-module\s+\(([^)]*)\)",text)
    if not m: return None
    parts=tuple(m.group(1).split())
    return parts

def parse_imports(text):
    imps=set()
    # use-modules forms: (use-modules (a b) (c d) ...)
    for m in re.finditer(r"\(use-modules\b(.*?)\)\s*(?:;|\n|$)", text, re.S):
        pass
    # simpler: find all (localchimera ...) and (planner ...) style module refs within use contexts
    # capture both #:use-module (x y) and (use-modules (x y))
    for m in re.finditer(r"#:use-module\s+\(([^)]*)\)", text):
        imps.add(tuple(m.group(1).split()))
    # use-modules blocks
    for m in re.finditer(r"\(use-modules\s+((?:\([^()]*\)\s*)+)\)", text):
        block=m.group(1)
        for mm in re.finditer(r"\(([^()]*)\)", block):
            imps.add(tuple(mm.group(1).split()))
    return imps

data={}
for f in files:
    with open(f,encoding="utf-8",errors="replace") as fh:
        t=fh.read()
    mod=parse_modname(t)
    rel=os.path.relpath(f,ROOT)
    file2mod[rel]=mod
    if mod: mod2file[mod]=rel
    data[rel]={"mod":mod,"imports":parse_imports(t)}

# build edges only for localchimera-internal modules
def is_internal(mod):
    return mod in mod2file

rev={}  # mod -> set of importer rel files
fwd={}  # rel -> set of internal mod imported
for rel,info in data.items():
    fwd[rel]=set()
    for imp in info["imports"]:
        # normalize: strip selectors after #: not captured anyway
        if imp in mod2file:
            fwd[rel].add(imp)
            rev.setdefault(imp,set()).add(rel)

# save
out={
 "mod2file":{ " ".join(k):v for k,v in mod2file.items()},
 "file2mod":{k:(" ".join(v) if v else None) for k,v in file2mod.items()},
 "fwd":{k:sorted(" ".join(x) for x in v) for k,v in fwd.items()},
 "rev":{ " ".join(k):sorted(v) for k,v in rev.items()},
}
out_path=sys.argv[1] if len(sys.argv)>1 else os.path.join(tempfile.gettempdir(),"depgraph.json")
with open(out_path,"w") as fh:
    json.dump(out,fh,indent=1)
print("wrote",out_path)

# orphans: internal modules nobody imports
orphans=[]
for mod,rel in mod2file.items():
    if mod not in rev:
        orphans.append(rel)
print("TOTAL files:",len(files))
print("with define-module:",sum(1 for v in file2mod.values() if v))
print("no define-module:",sum(1 for v in file2mod.values() if not v))
print("\n=== ORPHAN modules (defined but never imported by another module) ===")
for o in sorted(orphans):
    print(o)
