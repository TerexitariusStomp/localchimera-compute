#!/usr/bin/env python3
"""fold-world-decl.py — fold a fixture's hand-written world setup into declare-world!.

    tools/fold-world-decl.py [--write] FILE...

The engine's tests declared their worlds by writing to engine globals directly:

    (reset!) (set! *places* '("a" "b")) (set! *periods* '(0)) (mkcells!)
    (hash-set! *latlon* "a" (cons 40.0 -74.0)) (set! *templates* (list (tpl)))

which is one door said in six forms.  This folds each such run into

    (declare-world! #:places '(("a" 40.0 -74.0) "b") #:templates (list (tpl)))

Rules — every one of them is what keeps a fold from changing what a test means:

  * Only a run ANCHORED at (reset!) folds.  reset! puts every door global at the
    door's own default, so a reset!-anchored run is a TOTAL declaration whatever
    it leaves unsaid; a run without reset! is a layering onto a standing world
    and a door call would silently default the parts it does not name.  Those
    are reported, not folded.
  * Argument expressions are evaluated before the door resets, so a setter whose
    expression READS a door global (*cells*, *periods*, *latlon*, …) stays a raw
    set! after the door.  Reported.
  * A run ends at the next (reset!), at a duplicate setter of the same global, and
    at any in-between form that is not visibly order-independent of the fold: a
    define, anything naming a door global or reset!/mkcells!, anything that looks
    like a solve.  Forms after the cut are left as they are.  Reported.
  * *latlon* entries fold into #:places only when #:places is a literal list of
    string names they can be merged into; otherwise the hash-set! stays (a table
    filling, harmless where it is).
  * Setters at a global's reset default are dropped rather than repeated.

The scanner is comment-, string- and #\\( -aware (see the despaghetti skill: a
depth counter that is not is counting characters).  Without --write it prints
the diff it would make and the leftovers it would not touch.
"""
import re, sys, difflib

DOOR = ['places','periods','workers','movable','storable','templates','ride-modes',
        'riders','resource-suppliers','stationary','spatial-things',
        'commute-km','tau-commute','emp-mode']
DEFAULT = {'places':["'()"], 'periods':["'(0)","(list 0)"], 'workers':["'()"], 'movable':["'()"],
           'storable':["'()"], 'ride-modes':["'()"], 'riders':["'()"], 'resource-suppliers':["'()"],
           'stationary':["'()"], 'spatial-things':["'()"], 'commute-km':["0.0","0"],
           'tau-commute':["0.0","0"], 'emp-mode':["'total"], 'templates':[]}
KW_ORDER = ['places','periods','spans','templates','workers','riders','ride-modes',
            'resource-suppliers','movable','storable','stationary','spatial-things',
            'commute-km','tau-commute','emp-mode']
WORLD_MENTION = re.compile(r'\*(cells|latlon|' + '|'.join(re.escape(g) for g in DOOR) + r')\*'
                           r'|\breset!|\bmkcells!|\bset-period-span!')
SOLVEISH = re.compile(r'build-|located-warm|\bsolve|ingest|\bplan-|report|call-with-values')

# ── scanner: a tree of (start, end, children) with atoms as leaves ───────────
class Node:
    __slots__=('s','e','kids','atom')
    def __init__(s_,s,e,kids,atom): s_.s=s; s_.e=e; s_.kids=kids; s_.atom=atom
def parse(src):
    n=len(src); i=0; stack=[Node(0,n,[],False)]; pending=[None]
    def push(node):
        if pending[0] is not None: node.s=pending[0]; pending[0]=None
        stack[-1].kids.append(node)
    while i<n:
        c=src[i]
        if c in "'`,":                       # quote prefixes attach to the next node
            if pending[0] is None: pending[0]=i
            i+= 2 if (c==',' and i+1<n and src[i+1]=='@') else 1; continue
        if c==';':
            j=src.find('\n',i); i=n if j<0 else j+1; continue
        if c=='#' and i+1<n and src[i+1]=='|':
            j=src.find('|#',i+2); i=n if j<0 else j+2; continue
        if c=='#' and i+1<n and src[i+1]=='\\':
            k=i+3
            while k<n and (src[k].isalnum() or src[k]=='-'): k+=1
            push(Node(i,k,[],True)); i=k; continue
        if c=='"':
            j=i+1
            while j<n and src[j]!='"':
                j+= 2 if src[j]=='\\' else 1
            push(Node(i,j+1,[],True)); i=j+1; continue
        if c in '([':
            nd=Node(i,None,[],False); push(nd); stack.append(nd); i+=1; continue
        if c=='#' and i+1<n and src[i+1]=='(':
            nd=Node(i,None,[],False); push(nd); stack.append(nd); i+=2; continue
        if c in ')]':
            nd=stack.pop(); nd.e=i+1; i+=1
            if not stack: stack.append(Node(0,n,[],False))
            continue
        if c.isspace(): i+=1; continue
        j=i
        while j<n and not src[j].isspace() and src[j] not in '()[]";': j+=1
        push(Node(i,j,[],True)); i=j
    return stack[0]

def text(src,nd): return src[nd.s:nd.e]
def head(src,nd):
    return None if nd.atom or not nd.kids else text(src,nd.kids[0])
def prefixed(src,nd):
    """quoted/quasiquoted data, not code"""
    return src[nd.s] in "'`,"

def classify(src,nd):
    """('reset',) | ('set',G,exprnode) | ('cells',) | ('latlon',Pnode,LATnode,LONnode) | ('span',[T,A,B]) | None"""
    if nd.atom or prefixed(src,nd): return None
    h=head(src,nd); k=nd.kids
    if h=='reset!' and len(k)==1: return ('reset',)
    if h=='mkcells!' and len(k)==1: return ('cells',)
    if h=='set!' and len(k)==3 and text(src,k[1]).startswith('*'):
        g=text(src,k[1])[1:-1]
        if g in DOOR: return ('set',g,k[2])
    if h=='hash-set!' and len(k)==4 and text(src,k[1])=='*latlon*':
        v=k[3]
        if not v.atom and head(src,v)=='cons' and len(v.kids)==3:
            return ('latlon',k[2],v.kids[1],v.kids[2])
    if h=='set-period-span!' and len(k)==4: return ('span',k[1:])
    return None

def literal_string_list(src,nd):
    """'("a" "b") → (True, ['"a"','"b"']); (list a "b") → (False, ['a','"b"']); else None.
       Atoms only — a place list with structure in it is left alone."""
    if nd.atom: return None
    kids=nd.kids; quoted=text(src,nd).startswith("'(")
    if not quoted:
        if prefixed(src,nd) or head(src,nd)!='list': return None
        kids=kids[1:]
    out=[]
    for x in kids:
        if not x.atom: return None
        out.append(text(src,x))
    return (quoted,out)

def reindent(expr, from_col, to_col, block=False):
    lines=expr.split('\n')
    if len(lines)==1: return expr
    d=to_col-from_col
    if block:   # continuation lines never sit left of the expression's new column
        mn=min(len(l)-len(l.lstrip(' ')) for l in lines[1:] if l.strip())
        d=max(d, to_col+2-mn)
    out=[lines[0]]
    for l in lines[1:]:
        if d>=0: out.append(' '*d+l)
        else:
            strip=min(-d, len(l)-len(l.lstrip(' ')))
            out.append(l[strip:])
    return '\n'.join(out)
def col_of(src,pos): return pos-(src.rfind('\n',0,pos)+1)
def trailing_comment(src,nd):
    """a `; …` comment that ends the line a form ends on, with nothing but blanks between"""
    le=src.find('\n',nd.e); le=len(src) if le<0 else le
    rest=src[nd.e:le]
    m=re.fullmatch(r'\s*(;.*)',rest)
    return m.group(1).strip() if m else None

class Report:
    def __init__(s): s.lines=[]
    def add(s,src,path,nd,why): s.lines.append(f"{path}:{src.count(chr(10),0,nd.s)+1}: {why}: {text(src,nd)[:70]}")

def fold_body(src,body,path,edits,rep):
    """edits: list of (start,end,replacement). Walks siblings, groups, emits."""
    kids=[k for k in body.kids if not k.atom]
    # first recurse into every child so nested bodies fold too
    for k in kids:
        if not prefixed(src,k): fold_body(src,k,path,edits,rep)
    # now this body's own sibling runs
    i=0; n=len(body.kids)
    while i<n:
        c=classify(src,body.kids[i])
        if c is None or c[0]!='reset':
            if c is not None and c[0]=='set' and c[1]=='templates':
                k=body.kids[i]; edits.append((k.s,k.kids[2].s,'(set-templates! '))
            elif c is not None and c[0]!='reset': rep.add(src,path,body.kids[i],'no reset! anchor')
            i+=1; continue
        # anchored group
        anchor=body.kids[i]; group=[]; seen=set(); j=i+1; cut=None
        while j<n:
            k=body.kids[j]; ck=classify(src,k)
            if ck is None:
                if k.atom: j+=1; continue
                t=text(src,k); h=head(src,k)
                if h=='define' or h=='define*' or WORLD_MENTION.search(t) or SOLVEISH.search(t):
                    cut=k; break
                j+=1; continue
            if ck[0]=='reset': break
            key = ck[1] if ck[0]=='set' else ck[0] if ck[0] in ('cells',) else None
            if key and key in seen: cut=k; break
            if key: seen.add(key)
            group.append((k,ck)); j+=1
        # eligibility of each setter's expression
        sets={}; spans=[]; latlon=[]; cells=False; raw=[]
        for k,ck in group:
            if ck[0]=='cells': cells=True; continue
            if ck[0]=='set':
                if WORLD_MENTION.search(text(src,ck[2])):
                    rep.add(src,path,k,'expression reads the world it declares'); raw.append(k); continue
                sets[ck[1]]=(k,ck[2])
            elif ck[0]=='latlon':
                if any(WORLD_MENTION.search(text(src,x)) for x in ck[1:]):
                    rep.add(src,path,k,'latlon reads the world'); raw.append(k); continue
                latlon.append((k,ck))
            elif ck[0]=='span':
                spans.append((k,ck))
        # an ineligible raw setter that reads global G whose setter is folded but came AFTER it in source: refuse
        for k in raw:
            for g,(kn,ex) in sets.items():
                if kn.s>k.s and ('*'+g+'*') in text(src,k):
                    rep.add(src,path,anchor,'REFUSED: raw setter reads a global folded from after it'); group=None; break
            if group is None: break
        if group is None: i=j; continue
        if not sets and not spans and not latlon and not cells:
            i=j; continue     # a bare reset! — leave it
        if not cells and 'places' not in sets and 'periods' not in sets:
            # reset! + only e.g. templates: still fine — door lays default cells; but keep honest: fold anyway
            pass
        # merge latlon into places
        kw=[]
        door_col=col_of(src,anchor.s)+len('(declare-world! ')
        places_txt=None
        if 'places' in sets:
            pk,pe=sets['places']; lit=literal_string_list(src,pe)
            names=lit[1] if lit else None
            if latlon and names is not None and all(text(src,ck[1]) in names for _,ck in latlon):
                d={text(src,ck[1]):(text(src,ck[2]),text(src,ck[3])) for _,ck in latlon}
                allit=lit[0] and all(re.fullmatch(r'-?[\d.]+',a) and re.fullmatch(r'-?[\d.]+',b) for a,b in d.values())
                if allit:
                    items=[ (f'({nm} {d[nm][0]} {d[nm][1]})' if nm in d else nm) for nm in names]
                    places_txt="'("+' '.join(items)+")"
                else:
                    items=[ (f'(list {nm} {d[nm][0]} {d[nm][1]})' if nm in d else nm) for nm in names]
                    places_txt="(list "+' '.join(items)+")"
                latlon_folded=True
            else:
                latlon_folded=False
                if latlon: 
                    for k,_ in latlon: rep.add(src,path,k,'latlon left (places not a literal name list)')
                pt=text(src,pe)
                places_txt=(reindent(pt,col_of(src,pe.s),door_col+len('#:places ')) if '\n' not in pt
                            else '\n'+' '*(door_col+2)+reindent(pt,col_of(src,pe.s),door_col+2,True))
        else:
            latlon_folded=False
            for k,_ in latlon: rep.add(src,path,k,'latlon left (no #:places in run)')
        vals={}; notes={}
        def note(g,k):
            c=trailing_comment(src,k)
            if c:
                notes[g]=(notes.get(g,'')+' '+c).strip()
                le=src.find('\n',k.e); edits.append((k.e, len(src) if le<0 else le, None))
        if places_txt is not None:
            vals['places']=places_txt; note('places',sets['places'][0])
            if latlon_folded:
                for k,_ in latlon: note('places',k)
        for g,(kn,ex) in sets.items():
            if g=='places': continue
            et=text(src,ex)
            if et in DEFAULT[g] and not trailing_comment(src,kn): continue
            note(g,kn)
            vals[g]=(reindent(et,col_of(src,ex.s),door_col+len('#:'+g+' ')) if '\n' not in et
                     else '\n'+' '*(door_col+2)+reindent(et,col_of(src,ex.s),door_col+2,True))
        if spans:
            parts=[]; lit=True
            for k,ck in spans:
                note('spans',k)
                ts=[text(src,x) for x in ck[1]]
                if not all(re.fullmatch(r'-?\d+|"[^"]*"',x) for x in ts): lit=False
                parts.append(ts)
            vals['spans']=("'("+' '.join('('+' '.join(p)+')' for p in parts)+")") if lit \
                          else "(list "+' '.join('(list '+' '.join(p)+')' for p in parts)+")"
        # emit
        pieces=[((f'#:{g}{vals[g]}' if vals[g].startswith('\n') else f'#:{g} {vals[g]}'), notes.get(g)) for g in KW_ORDER if g in vals]
        if not pieces: door='(declare-world!)'
        else:
            # short keywords share a line while they fit; a commented one ends its line
            door='(declare-world! '+pieces[0][0]; open_note=pieces[0][1]
            for p,c in pieces[1:]:
                if open_note is None and '\n' not in door and '\n' not in p and len(door)+len(p)<80: door+=' '+p
                else:
                    if open_note: door+='   '+open_note
                    door+='\n'+' '*door_col+p
                open_note=c
            door+=')'
            if open_note: door+='   '+open_note
        moved=[]
        anchor_indent=' '*col_of(src,anchor.s)
        for k,_ in group:
            if k in raw: continue
            if _[0]=='latlon' and not latlon_folded: continue
            edits.append((k.s,k.e,None))
            # full-line ;; comments right above a deleted form move above the door
            ls=src.rfind('\n',0,k.s)+1
            if src[ls:k.s].strip()=='' and ls>anchor.e:
                cs=ls; cl=[]
                while True:
                    pls=src.rfind('\n',0,cs-1)+1 if cs>0 else 0
                    line=src[pls:cs-1] if cs>0 else ''
                    if cs>anchor.e and re.fullmatch(r'\s*;.*',line) and pls>anchor.e:
                        cl.insert(0,line.strip()); cs=pls
                    else: break
                if cl:
                    edits.append((cs,ls,None)); moved.extend(cl)
        if moved: door='\n'.join(anchor_indent+c if i else c for i,c in enumerate(moved))+'\n'+anchor_indent+door
        edits.append((anchor.s,anchor.e,door))
        i=j

def apply(src,edits):
    edits.sort(key=lambda e:e[0])
    out=[]; pos=0
    for s,e,r in edits:
        out.append(src[pos:s]); out.append(r if r is not None else '\x00'); pos=e
    out.append(src[pos:])
    s=''.join(out)
    # a line emptied by a deletion vanishes, and so does a trailing `;` comment
    # left with nothing to trail (reported by the caller for review)
    res=[]
    for l in s.split('\n'):
        if '\x00' in l:
            rest=l.replace('\x00','')
            if rest.strip()=='' : continue
            if re.fullmatch(r'\s*;[^;].*',rest): dropped_comments.append(rest.strip()); continue
            mc=re.fullmatch(r'\s*(\)+)\s*(;.*)?',rest)
            if mc and res:
                # a closer orphaned by a deletion rejoins the line before it — ahead of any
                # note — and brings its own trailing comment along
                m=re.fullmatch(r'(.*\))(\s+;.*)',res[-1])
                res[-1]=(m.group(1)+mc.group(1)+m.group(2)) if m else res[-1]+mc.group(1)
                if mc.group(2): res[-1]+='   '+mc.group(2)
                continue
            l=rest
        res.append(l.rstrip())
    return '\n'.join(res)
dropped_comments=[]

def main():
    write='--write' in sys.argv
    paths=[a for a in sys.argv[1:] if a!='--write']
    total=0
    for p in paths:
        src=open(p).read(); tree=parse(src); edits=[]; rep=Report()
        fold_body(src,tree,p,edits,rep)
        if not edits and not rep.lines: continue
        new=apply(src,edits) if edits else src
        # blank-line cleanup: a line emptied by a deletion vanishes
        if edits:
            old_lines=src.split('\n'); new_lines=new.split('\n')
        n=sum(1 for e in edits if e[2] is not None)
        total+=n
        if write and edits: open(p,'w').write(new)
        else:
            sys.stdout.writelines(difflib.unified_diff(src.splitlines(1),new.splitlines(1),p,p+' (folded)'))
        for l in rep.lines: print('  LEFT ',l)
        for c in dropped_comments: print('  COMMENT DROPPED',p,c)
        dropped_comments.clear()
        print(f'  {p}: {n} door(s)')
    print(f'{total} doors')
main()
