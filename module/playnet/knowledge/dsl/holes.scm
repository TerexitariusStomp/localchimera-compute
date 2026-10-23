;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; dsl/holes.scm — a HOLE in the recipe web: a process known by its boundary alone.
;;;
;;; A scope maps its economy recipe by recipe, and the map has holes in it
;;; long before it is whole: "waste management" takes the kitchen's organic
;;; waste and gives compost, and that much is known before any recipe for it
;;; is written. A hole states exactly that much. It is an ordinary recipe of
;;; ONE process, tagged "hole" and with the folksonomy term it stands for, whose
;;; flows are its PORTS — what crosses its boundary in and out, with the
;;; quantities that cross. Nothing new is added to the store: a hole rides the
;;; same records, the same indexes, the same wire, and the solve treats it as
;;; the one activity it is, so a plan balances through it — the sector row of
;;; an input-output table, an activity whose interior is not yet mapped.
;;;
;;; A hole YIELDS. Once a recipe of the scope's own makes what the hole's
;;; output port names, the hole has been mapped and leaves the solve: the
;;; admit predicate below is what says so, composed into the barbell's own at
;;; the one gather door. Conformance is the folksonomy's: a flow's spec fills a
;;; port when it is the port's spec, or classified under it (a term is a
;;; taxonomy path, and "organic-waste/vegetable-trimmings" sits under
;;; "organic-waste"). A caller with a folded folksonomy in hand passes its own
;;; broader? relation and the same rule reads through it.

(define-module (playnet knowledge dsl holes)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module (playnet knowledge dsl world)
  #:export (hole-world
            hole-tag hole-process? hole-recipe? hole-term hole-ports
            port-conforms? hole-fillers hole-admit compose-admit
            holes-of))

(define hole-tag "hole")

;;; ─── the shape ────────────────────────────────────────────────────────────

(define* (hole-world id name term #:key (in '()) (out '()) (hours #f))
  "A world holding one hole: recipe ID named NAME, standing for the folksonomy
   TERM, with IN and OUT its ports — each `(spec q unit)`. HOURS, when given,
   is the labour the boundary is known to take per run. Seed it with
   seed-world-recipes! like any other world."
  (let* ((pid   (string-append id "/hole"))
         (flow  (lambda (kind i port)
                  (let ((spec (car port)) (q (cadr port)) (unit (caddr port)))
                    (if (eq? kind 'in)
                        (consume* (string-append pid "/in/" (number->string i)) spec q pid unit)
                        (out* (string-append pid "/out/" (number->string i)) spec q pid unit
                              #:primary (= i 0))))))
         (ins   (map (lambda (p i) (flow 'in i p)) in (iota (length in))))
         (outs  (map (lambda (p i) (flow 'out i p)) out (iota (length out))))
         (work  (if hours (list (wk* (string-append pid "/work") "labour" hours pid)) '()))
         (proc  (rp* pid name #:tags (list hole-tag term)))
         (prim  (and (pair? out) (car (car out)))))
    (world #:procs (list proc)
           #:flows (append ins outs work)
           #:recipes (list (make-recipe #:id id #:name name #:primary-output prim
                                        #:recipe-processes (list pid) #:recipe-exchanges '())))))

;;; ─── reading a hole ───────────────────────────────────────────────────────

(define (hole-process? rp)
  "Whether the recipe process is a hole: its classification carries the tag."
  (let ((tags (recipe-process-process-classified-as rp)))
    (and (list? tags) (member hole-tag tags) #t)))

(define (hole-term rp)
  "The folksonomy term a hole stands for: its first tag past the marker, or #f."
  (let ((tags (recipe-process-process-classified-as rp)))
    (and (list? tags)
         (find (lambda (t) (and (string? t) (not (string=? t hole-tag)))) tags))))

(define (hole-recipe? rs r)
  "Whether recipe R of store RS is a hole: any of its processes is one."
  (any (lambda (pid)
         (let ((rp ($ rs 'get-recipe-process pid)))
           (and rp (hole-process? rp))))
       (or (recipe-recipe-processes r) '())))

(define (hole-ports rs r)
  "A hole's ports as `(inputs . outputs)` — its process's flows."
  (let ((pid (find (lambda (pid)
                     (let ((rp ($ rs 'get-recipe-process pid))) (and rp (hole-process? rp))))
                   (or (recipe-recipe-processes r) '()))))
    (if pid ($ rs 'flows-for-process pid) (cons '() '()))))

(define (holes-of rs)
  "Every hole recipe in the store."
  (filter (lambda (r) (hole-recipe? rs r)) ($ rs 'all-recipes)))

;;; ─── conformance ──────────────────────────────────────────────────────────

(define (under? term path)
  "PATH names TERM or sits under it in the taxonomy: equal, or prefixed by it."
  (and (string? term) (string? path)
       (or (string=? term path)
           (string-prefix? (string-append term "/") path))))

(define* (port-conforms? rs port-spec spec #:key (broader? #f))
  "Whether a flow of SPEC fills a port of PORT-SPEC: the same spec, a spec
   whose classification sits under the port's term, or — given BROADER?, a
   (term term) → bool relation from a folded folksonomy — a spec whose id or
   classes the port's term is broader than."
  (or (equal? port-spec spec)
      (under? port-spec spec)
      (let* ((s (and spec ($ rs 'get-resource-spec spec)))
             (classes (if s (or (resource-specification-resource-classified-as s) '()) '())))
        (or (any (lambda (c) (under? port-spec c)) (if (list? classes) classes '()))
            (and broader?
                 (or (broader? port-spec spec)
                     (any (lambda (c) (broader? port-spec c)) (if (list? classes) classes '()))))))))

(define* (hole-fillers rs hole #:key (broader? #f))
  "The recipes of RS that map HOLE: every non-hole recipe whose primary output
   fills one of the hole's output ports."
  (let ((outs (cdr (hole-ports rs hole))))
    (filter (lambda (r)
              (and (not (hole-recipe? rs r))
                   (let ((made (recipe-primary-output r)))
                     (and made
                          (any (lambda (port)
                                 (port-conforms? rs (recipe-flow-resource-conforms-to port) made
                                                 #:broader? broader?))
                               outs)))))
            ($ rs 'all-recipes))))

(define* (hole-admit rs #:key (broader? #f))
  "The admit predicate under which a hole yields: a recipe is admitted unless
   it is a hole that a recipe of the scope's own already fills."
  (lambda (r)
    (or (not (hole-recipe? rs r))
        (null? (hole-fillers rs r #:broader? broader?)))))

(define (compose-admit . preds)
  "One admit predicate from several — a recipe passes when every given one
   admits it; a #f in the list is no condition at all."
  (let ((ps (filter procedure? preds)))
    (and (pair? ps)
         (lambda (r) (every (lambda (p) (p r)) ps)))))
