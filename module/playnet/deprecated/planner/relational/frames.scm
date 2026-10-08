;;; frames.scm — Frame semantics, distilled into relational miniKanren
;;;
;;; Charles Fillmore's frame semantics (1968 "Case for Case"; 1976 "Frame
;;; Semantics"; FrameNet at Berkeley from 1997) starts from a single
;;; observation: the meaning of a word is given by the structured situation
;;; it evokes, not by syntax. "Buy" and "sell" describe the same transaction
;;; from opposite sides; the transaction itself — Buyer, Seller, Goods,
;;; Money — is the load-bearing thing. That structured situation is a FRAME.
;;;
;;; A frame has named slots called frame elements (FEs). Some are CORE
;;; (obligatory: a producing event needs an agent and a product) and some
;;; are PERIPHERAL (optional: time, place, instrument, recipient). Each FE
;;; has a TYPE RESTRICTION on what kind of entity can fill it. Frames are
;;; arranged in an INHERITANCE HIERARCHY, so PRODUCING inherits from
;;; INTENTIONALLY-CREATE which inherits from EVENT.
;;;
;;; A LEXICAL UNIT is a word paired with the frame it evokes plus a mapping
;;; from syntactic positions (subject, object, by, in, ...) to frame
;;; elements (agent, product, instrument, ...). Two lexical units can evoke
;;; the same frame from opposite perspectives — "buy" maps subject→buyer,
;;; "sell" maps subject→seller. Same frame, different lens.
;;;
;;; In miniKanren this all collapses into data plus a small set of
;;; relations. Everything runs in either direction:
;;;
;;;   - ground a word, get the frame
;;;   - ground a frame, get the words
;;;   - ground constituents and word, get each FE's filler
;;;   - ground a frame and FE, get the syntactic position
;;;   - ground partial constraints, enumerate the verbs that satisfy them
;;;
;;; There is no parser, no interpreter, no record type. Just relations.
;;; Unification does the work.
;;;
;;; ── A note on representation ─────────────────────────────────────────────
;;;
;;; The data is written in a human-friendly nested form (one entry per
;;; frame, with named fields), but every relation queries a *flat* table —
;;; one row per (frame, fe), (frame, fe, class), (word, syn, fe), etc.
;;; The flat tables are derived from the nested form at module-load time.
;;;
;;; This matters because `in-list-o` from the project's miniKanren walks
;;; its list argument eagerly when the relation is constructed; if the list
;;; is itself a logic variable bound by an outer goal, in-list-o won't see
;;; the binding and the lookup quietly returns nothing. Flattening keeps
;;; the list argument a ground constant in every relation.

(define-module (playnet deprecated planner relational frames)
  #:export (*class-hierarchy* class-direct-parent-o class-isa-o *classifications*
            classified-direct-o classified-as-o *frames* assq-cadr *frame-names*
            *core-fes* *peripheral-fes* *fe-restrictions* *frame-parents* frame-o
            core-fe-o peripheral-fe-o fe-of-o fe-restriction-o parent-frame-o
            frame-isa-o inherits-fe-o *lexical-units* *lu-evokes* *lu-mappings*
            lexical-unit-o evokes-o syn-of-fe-o fe-of-syn-o filled-o absent-from-o
            missing-core-o constituent-typed-o well-typed-fill-o shared-fe-o
            *vf-translations* *vf-event-types* *vf-param-map* vf-event-type-o
            vf-translation-o vf-param-of-o))

(use-modules ((playnet deprecated kanren-constraints)
              #:select (== fresh conde succeed fail
                        run-plan run-plan*
                        in-list-o
                        =/=))
             ((srfi srfi-1) #:select (filter-map append-map)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Class hierarchy
;;;
;;; A tiny ontology of classes for FE type restrictions and entity
;;; classifications. Every class is ultimately a subclass of `entity`.
;;; ══════════════════════════════════════════════════════════════════════════

(define *class-hierarchy*
  ;; (CHILD . PARENT)  — child ISA parent
  '((person          . sentient)
    (organization    . sentient)
    (sentient        . entity)
    (food            . physical-object)
    (ingredient      . physical-object)
    (crop            . food)
    (baked-good      . food)
    (tool            . physical-object)
    (currency        . physical-object)
    (physical-object . entity)
    (recipe          . abstract)
    (measure         . abstract)
    (purpose         . abstract)
    (abstract        . entity)))

(define (class-direct-parent-o sub super)
  "SUB has SUPER as its directly-declared parent class."
  (in-list-o `(,sub . ,super) *class-hierarchy*))

(define (class-isa-o sub super)
  "SUB is a (possibly indirect) subclass of SUPER. Reflexive."
  (conde
    ((== sub super))
    ((fresh (mid)
       (class-direct-parent-o sub mid)
       (class-isa-o mid super)))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Classifications  (entity → class membership)
;;; ══════════════════════════════════════════════════════════════════════════

(define *classifications*
  ;; (ENTITY CLASS) — flat: one row per (entity, class) pair
  '((vincent  person)
    (mia      person)
    (butch    person)
    (commune  organization)
    (bakery   organization)
    (factory  organization)
    (bread    baked-good)
    (flour    ingredient)
    (wheat    crop)
    (wrench   tool)
    (hammer   tool)
    (oven     tool)
    (mill     tool)
    (dollars  currency)
    (recipe-1 recipe)
    (kg       measure)
    (loaves   measure)
    (eating   purpose)
    (baking   purpose)))

(define (classified-direct-o entity class)
  "ENTITY directly belongs to CLASS (no inheritance)."
  (in-list-o `(,entity ,class) *classifications*))

(define (classified-as-o entity class)
  "ENTITY belongs to CLASS, possibly via class-hierarchy inheritance.
   `entity` is the top class — every chain in *class-hierarchy* terminates
   there, so this relation reaches it without needing a special case."
  (fresh (direct)
    (classified-direct-o entity direct)
    (class-isa-o direct class)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Frames — human-friendly nested definitions
;;;
;;; Format:
;;;
;;;   (FRAME-NAME
;;;     (core         (FE ...))
;;;     (peripheral   (FE ...))
;;;     (restrictions ((FE . CLASS) ...))
;;;     (inherits-from PARENT-FRAME-OR-#f))
;;;
;;; Convention: every FE that appears in core or peripheral should also
;;; appear in restrictions (defaulting to `entity` for unconstrained slots).
;;; ══════════════════════════════════════════════════════════════════════════

(define *frames*
  '((event
     (core         ())
     (peripheral   (time place))
     (restrictions ((time . entity) (place . entity)))
     (inherits-from #f))

    (intentionally-create
     (core         (agent product))
     (peripheral   ())
     (restrictions ((agent . sentient) (product . physical-object)))
     (inherits-from event))

    (producing
     (core         (agent product))
     (peripheral   (recipe instrument quantity recipient))
     (restrictions ((agent      . sentient)
                    (product    . physical-object)
                    (recipe     . recipe)
                    (instrument . tool)
                    (quantity   . measure)
                    (recipient  . sentient)))
     (inherits-from intentionally-create))

    (transfer
     (core         (donor recipient theme))
     (peripheral   (quantity time place reason))
     (restrictions ((donor     . sentient)
                    (recipient . sentient)
                    (theme     . physical-object)
                    (quantity  . measure)
                    (time      . entity)
                    (place     . entity)
                    (reason    . purpose)))
     (inherits-from event))

    (commerce-buy
     (core         (buyer goods))
     (peripheral   (seller money quantity))
     (restrictions ((buyer    . sentient)
                    (seller   . sentient)
                    (goods    . physical-object)
                    (money    . currency)
                    (quantity . measure)))
     (inherits-from transfer))

    (consuming
     (core         (consumer input))
     (peripheral   (quantity time place purpose))
     (restrictions ((consumer . sentient)
                    (input    . food)               ; ← strict: must be food
                    (quantity . measure)
                    (time     . entity)
                    (place    . entity)
                    (purpose  . purpose)))
     (inherits-from event))

    (using
     (core         (user instrument))
     (peripheral   (purpose time place))
     (restrictions ((user       . sentient)
                    (instrument . tool)
                    (purpose    . purpose)
                    (time       . entity)
                    (place      . entity)))
     (inherits-from event))

    (working
     (core         (worker task))
     (peripheral   (duration tool product))
     (restrictions ((worker  . sentient)
                    (task    . purpose)
                    (tool    . tool)
                    (product . physical-object)
                    (duration . measure)))
     (inherits-from intentionally-create))))


;;; ── Flat derivations of *frames* ──────────────────────────────────────────
;;; Each is a list of tuples that in-list-o can walk directly.

(define (assq-cadr key alist default)
  (let ((p (assoc key alist)))
    (if p (cadr p) default)))

(define *frame-names*
  (map car *frames*))

(define *core-fes*
  ;; (FRAME FE)
  (append-map
    (lambda (def)
      (let ((name (car def))
            (cores (assq-cadr 'core (cdr def) '())))
        (map (lambda (fe) (list name fe)) cores)))
    *frames*))

(define *peripheral-fes*
  ;; (FRAME FE)
  (append-map
    (lambda (def)
      (let ((name (car def))
            (peripherals (assq-cadr 'peripheral (cdr def) '())))
        (map (lambda (fe) (list name fe)) peripherals)))
    *frames*))

(define *fe-restrictions*
  ;; (FRAME FE CLASS)
  (append-map
    (lambda (def)
      (let ((name (car def))
            (rests (assq-cadr 'restrictions (cdr def) '())))
        (map (lambda (r) (list name (car r) (cdr r))) rests)))
    *frames*))

(define *frame-parents*
  ;; (CHILD PARENT)  — only frames that have a non-#f parent
  (filter-map
    (lambda (def)
      (let ((name (car def))
            (par (assq-cadr 'inherits-from (cdr def) #f)))
        (and par (list name par))))
    *frames*))


;;; ── Structural relations ──────────────────────────────────────────────────

(define (frame-o frame)
  "FRAME is a defined frame name."
  (in-list-o frame *frame-names*))

(define (core-fe-o frame fe)
  "FE is one of FRAME's CORE frame elements."
  (in-list-o `(,frame ,fe) *core-fes*))

(define (peripheral-fe-o frame fe)
  "FE is one of FRAME's PERIPHERAL frame elements."
  (in-list-o `(,frame ,fe) *peripheral-fes*))

(define (fe-of-o frame fe)
  "FE is any FE of FRAME (core or peripheral)."
  (conde
    ((core-fe-o       frame fe))
    ((peripheral-fe-o frame fe))))

(define (fe-restriction-o frame fe class)
  "FE in FRAME has class restriction CLASS."
  (in-list-o `(,frame ,fe ,class) *fe-restrictions*))

(define (parent-frame-o sub super)
  "SUB inherits directly from SUPER."
  (in-list-o `(,sub ,super) *frame-parents*))

(define (frame-isa-o sub super)
  "SUB inherits (transitively) from SUPER. Reflexive."
  (conde
    ((frame-o sub) (== sub super))
    ((fresh (mid)
       (parent-frame-o sub mid)
       (frame-isa-o mid super)))))

(define (inherits-fe-o frame fe)
  "FE is available on FRAME, either declared directly or via inheritance."
  (fresh (ancestor)
    (frame-isa-o frame ancestor)
    (fe-of-o ancestor fe)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Lexical units — human-friendly nested definitions
;;;
;;; (WORD FRAME ((SYN . FE) ...))
;;;
;;; Two lexical units can evoke the same frame from opposite perspectives —
;;; "buy" maps subject→buyer; "sell" maps subject→seller.
;;; ══════════════════════════════════════════════════════════════════════════

(define *lexical-units*
  '(;; producing
    ("bake"     producing
                ((subject . agent)  (object . product)
                 (in      . instrument) (for . recipient)))
    ("produce"  producing
                ((subject . agent)  (object . product)
                 (with    . instrument) (for . recipient)))
    ("grow"     producing
                ((subject . agent)  (object . product)))
    ("forge"    producing
                ((subject . agent)  (object . product)
                 (with    . instrument)))
    ("make"     producing
                ((subject . agent)  (object . product)
                 (with    . instrument) (for . recipient)))

    ;; transfer
    ("give"     transfer
                ((subject . donor) (object . theme) (to . recipient)))
    ("send"     transfer
                ((subject . donor) (object . theme) (to . recipient)))
    ("hand"     transfer
                ((subject . donor) (object . theme) (to . recipient)))

    ;; commerce-buy: same frame, two perspectives
    ("buy"      commerce-buy
                ((subject . buyer) (object . goods)
                 (from    . seller) (for . money)))
    ("purchase" commerce-buy
                ((subject . buyer) (object . goods)
                 (from    . seller) (for . money)))
    ("sell"     commerce-buy
                ((subject . seller) (object . goods)
                 (to      . buyer) (for . money)))

    ;; consuming
    ("eat"      consuming
                ((subject . consumer) (object . input)))
    ("drink"    consuming
                ((subject . consumer) (object . input)))
    ("consume"  consuming
                ((subject . consumer) (object . input) (for . purpose)))

    ;; using
    ("use"      using
                ((subject . user) (object . instrument) (for . purpose)))
    ("wield"    using
                ((subject . user) (object . instrument)))

    ;; working
    ("work"     working
                ((subject . worker) (on . task) (with . tool)))
    ("labor"    working
                ((subject . worker) (on . task)))))


;;; ── Flat derivations of *lexical-units* ───────────────────────────────────

(define *lu-evokes*
  ;; (WORD FRAME)
  (map (lambda (lu) (list (car lu) (cadr lu))) *lexical-units*))

(define *lu-mappings*
  ;; (WORD SYN FE)
  (append-map
    (lambda (lu)
      (let ((word (car lu))
            (mapping (caddr lu)))
        (map (lambda (sf) (list word (car sf) (cdr sf))) mapping)))
    *lexical-units*))


;;; ── Lexical-unit relations ────────────────────────────────────────────────

(define (lexical-unit-o word frame mapping)
  "WORD evokes FRAME with the (nested) syntax→FE MAPPING.
   This still works because *lexical-units* is itself ground."
  (in-list-o `(,word ,frame ,mapping) *lexical-units*))

(define (evokes-o word frame)
  "WORD evokes FRAME (under any perspective)."
  (in-list-o `(,word ,frame) *lu-evokes*))

(define (syn-of-fe-o word fe syn)
  "Under WORD's perspective, FE is realized at syntactic position SYN."
  (in-list-o `(,word ,syn ,fe) *lu-mappings*))

(define (fe-of-syn-o word syn fe)
  "Under WORD's perspective, the syntactic position SYN realizes FE."
  (in-list-o `(,word ,syn ,fe) *lu-mappings*))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Frame instances
;;;
;;; A frame instance is a partial filling. We don't materialize it as a
;;; record — it lives implicitly in (word, constituents), and we query it
;;; one slot at a time. CONSTITUENTS is a ground alist of (syn . filler).
;;; ══════════════════════════════════════════════════════════════════════════

(define (filled-o word constituents fe filler)
  "Given WORD and CONSTITUENTS, bind FILLER to whatever fills FE.
   Bidirectional: ground FILLER and ask which FE holds it."
  (fresh (syn)
    (syn-of-fe-o word fe syn)
    (in-list-o `(,syn . ,filler) constituents)))

(define (absent-from-o key alist)
  "KEY is not the head of any pair in ALIST. Walks ALIST relationally,
   asserting each pair's head =/= KEY at every step."
  (conde
    ((== alist '()))
    ((fresh (k v rest)
       (== alist `((,k . ,v) . ,rest))
       (=/= k key)
       (absent-from-o key rest)))))

(define (missing-core-o word constituents fe)
  "FE is a core FE of WORD's frame, AND no constituent in CONSTITUENTS
   binds the syntactic position that maps to FE."
  (fresh (frame syn)
    (evokes-o word frame)
    (core-fe-o frame fe)
    (syn-of-fe-o word fe syn)
    (absent-from-o syn constituents)))

(define (constituent-typed-o word syn filler)
  "The single constituent (SYN . FILLER) is well-typed under WORD."
  (fresh (frame fe class)
    (evokes-o word frame)
    (fe-of-syn-o word syn fe)
    (fe-restriction-o frame fe class)
    (classified-as-o filler class)))

(define (well-typed-fill-o word constituents)
  "Every constituent in CONSTITUENTS is well-typed under WORD's frame.
   Walks CONSTITUENTS as a list, type-checking each pair in turn."
  (conde
    ((== constituents '()))
    ((fresh (syn filler rest)
       (== constituents `((,syn . ,filler) . ,rest))
       (constituent-typed-o word syn filler)
       (well-typed-fill-o word rest)))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Cross-frame relations
;;;
;;; Two frames "share" an FE name if both have an FE with that exact name.
;;; This is a weak notion (it doesn't bridge `goods` to `theme` even though
;;; they're conceptually the same), but it falls out of the data for free.
;;; ══════════════════════════════════════════════════════════════════════════

(define (shared-fe-o frame-a frame-b fe)
  "FRAME-A and FRAME-B both have an FE named FE (and are not the same)."
  (fresh ()
    (=/= frame-a frame-b)
    (fe-of-o frame-a fe)
    (fe-of-o frame-b fe)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; ValueFlows event translation
;;;
;;; Each frame has a corresponding VF economic event, with FE-to-VF-param
;;; mapping. This is the bridge from "structured natural-language meaning"
;;; to "thing the planner can schedule." One row per (frame, event-type).
;;; ══════════════════════════════════════════════════════════════════════════

(define *vf-translations*
  ;; (FRAME VF-EVENT-TYPE ((FE . VF-PARAM) ...))
  '((producing    produce
                  ((agent     . provider)
                   (product   . resource)
                   (quantity  . quantity)
                   (recipient . receiver)
                   (recipe    . recipe)))
    (transfer     transfer
                  ((donor     . provider)
                   (recipient . receiver)
                   (theme     . resource)
                   (quantity  . quantity)))
    (commerce-buy transfer
                  ((seller    . provider)
                   (buyer     . receiver)
                   (goods     . resource)
                   (quantity  . quantity)
                   (money     . price)))
    (consuming    consume
                  ((consumer  . provider)
                   (input     . resource)
                   (quantity  . quantity)))
    (working      work
                  ((worker    . provider)
                   (task      . purpose)
                   (duration  . quantity)
                   (tool      . instrument)))
    (using        use
                  ((user       . provider)
                   (instrument . resource)
                   (purpose    . purpose)))))


;;; ── Flat derivations of *vf-translations* ─────────────────────────────────

(define *vf-event-types*
  ;; (FRAME EVENT-TYPE)
  (map (lambda (vt) (list (car vt) (cadr vt))) *vf-translations*))

(define *vf-param-map*
  ;; (FRAME FE VF-PARAM)
  (append-map
    (lambda (vt)
      (let ((frame (car vt))
            (mapping (caddr vt)))
        (map (lambda (mp) (list frame (car mp) (cdr mp))) mapping)))
    *vf-translations*))


;;; ── VF translation relations ──────────────────────────────────────────────

(define (vf-event-type-o frame event-type)
  "FRAME translates to VF event EVENT-TYPE."
  (in-list-o `(,frame ,event-type) *vf-event-types*))

(define (vf-translation-o frame event-type mapping)
  "FRAME translates to VF event EVENT-TYPE with FE→VF-param MAPPING (nested)."
  (in-list-o `(,frame ,event-type ,mapping) *vf-translations*))

(define (vf-param-of-o frame fe vf-param)
  "Under FRAME's VF translation, FE corresponds to VF-PARAM."
  (in-list-o `(,frame ,fe ,vf-param) *vf-param-map*))
