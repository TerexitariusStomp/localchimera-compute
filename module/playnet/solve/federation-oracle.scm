;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/solve/federation-oracle.scm — a commune's BOUNDARY ORACLE, and the consensus loop
;;; over oracles that answer from anywhere.
;;;
;;; solve-decomposed (engine §10) holds every scope's LP in one process and runs
;;; the ADMM rounds over an in-memory vector. Cross-vat federation (Rung 3 of
;;; docs/planning/federation/FEDERATED-SOLVE.md) keeps the SAME arithmetic and moves the
;;; scope's half of it behind a message: a commune holds its own kernel record
;;; in its own vat and answers one question per round —
;;;
;;;     given a CENTRE per good I share and the weight ρ,
;;;     what flow does my subproblem put on each?
;;;
;;; The centre is z − u: the signed flow agreed for the commune less the good's
;;; scaled dual, which is where the pull stands. What crosses the boundary INTO
;;; a commune is therefore one number per good, in the good's own unit; what
;;; crosses OUT is its signed flow on that good — above nothing it supplies,
;;; below it draws — and a fill percentage. Never a form, a column, a plan.
;;; Which columns carry the flow, and from where they are measured, stays with
;;; the commune (the engine's crossings): the oracle converts on its own side.
;;;
;;; Two objects:
;;;   make-boundary-oracle  rec → a closure over ONE scope's kernel record with
;;;                         the round/finish protocol as messages. The engine
;;;                         side of a commune's sovereignty: the Goblins actor
;;;                         that wraps it (federation/wire.scm) adds identity
;;;                         and a signature and nothing else.
;;;   solve-consensus       the coordinator: the ADMM z/u loop of
;;;                         solve-decomposed — over-relaxation, adaptive ρ,
;;;                         Anderson acceleration, the met-slope stop — with the
;;;                         per-round scope solves handed to a ROUND! procedure
;;;                         the caller supplies. In-process, round! calls the
;;;                         oracles; over the wire it fans out messages and
;;;                         waits. The loop does not know which.
;;;
;;; A module above the engine's §10: it reads the kernel records, the
;;; crossings and the exact local solve (`refine-plan`) from (playnet solve
;;; engine) and the exchange from solve/admm-link.

(define-module (playnet solve federation-oracle)
  #:use-module (srfi srfi-1)
  #:use-module (rnrs bytevectors)
  #:use-module ((playnet solve voice-field) #:select (voice-labform voice-report))
  #:use-module (playnet solve admm-link)
  #:use-module (playnet solve solver)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve decomposed)
  #:export (make-boundary-oracle solve-consensus consensus-of flow-of signed-flows))

;; ── the oracle ───────────────────────────────────────────────────────────────
(define* (make-boundary-oracle rec #:key (rho 4.0))
  "REC is a solve-decomposed scope-record (forms labform x0 crossings …).
   Returns a procedure taking a message symbol. Every flow it takes or answers
   is SIGNED: above nothing the scope supplies the good, below it draws.
     (o 'links)              the goods it shares (link-key …), in the order of its crossings
     (o 'sides)              ((link-key . give|take|net) …): what its column on each
                             can do — for whoever holds the record, never sent
     (o 'solve! centres rho) centres ((link-key . c) …) → ((flows . ((key . y) …)) (met . %));
                             RHO the prox weight: one number for every link, or
                             ((link-key . ρ) …) for a weight per link
     (o 'refine! z pulls rho)  the exact local solve at the settled pulls, prox
                             kept at z; certified against the scope's own forms
                             → ((flows …) (met …) (feasible? …) (gap-bound …) (refined? …))
     (o 'clamp! caps)        the scope held to CAPS ((key . y) …), the flow it may
                             keep on each good: where it draws more, its column
                             is set to the cap → same shape, (clamped? …)
     (o 'flows) (o 'met) (o 'plan)  — the plan never leaves the oracle's holder
                             unless asked for by name; the wire actor does not
                             expose it. The plan is read as the recipes mean
                             it: a column measured from what the scope can give
                             is answered as the draw it stands for."
  (let* ((get (lambda (k) (let ((a (assq k rec))) (and a (cdr a)))))
         (kr (admm-kernel-rec rec rho))
         (solve1! (admm-kernel-batch (list kr)))
         (bnd (vector-ref kr 4)) (n (vector-ref kr 1))
         (links (map crossing-key bnd))
         (xbv (lambda () (vector-ref kr 14)))
         (f64ref (lambda (bv i) (bytevector-ieee-double-native-ref bv (* 8 i))))
         (f64set! (lambda (bv i v) (bytevector-ieee-double-native-set! bv (* 8 i) v)))
         (flows (lambda () (map (lambda (b) (cons (crossing-key b) (crossing-flow b (f64ref (xbv) (crossing-col b))))) bnd)))
         (columns (lambda () (f64bv->vec (xbv) n)))                  ; the columns as the kernel holds them
         (plan (lambda () (record-plan rec (columns))))
         (set-plan! (lambda (xv) (do ((i 0 (+ i 1))) ((= i n)) (f64set! (xbv) i (vector-ref xv i)))))
         ;; a per-link alist, hashed once, → the value per crossing, in their order
         (per-bnd (lambda (h dflt)
                    (map (lambda (b) (exact->inexact (hash-ref h (crossing-key b) dflt))) bnd)))
         (own-forms (world-forms (or (get 'forms) '())))
         (certify (lambda (x lab)
                    (let ((k (kkt-report (flatten own-forms) lab x)))
                      (values (and k (assq-ref k 'feasible?) #t)
                              (if k (assq-ref k 'gap-bound) +inf.0)))))
         (refined? #f) (clamped? #f)
         (last-lab (or (get 'labform) '())))
    (define (report feasible? gap)
      `((flows . ,(flows)) (met . ,(admm-scope-met kr))
        (feasible? . ,feasible?) (gap-bound . ,gap)
        (refined? . ,refined?) (clamped? . ,clamped?)))
    (lambda (msg . args)
      (case msg
        ((links) links)
        ((sides) (map (lambda (b) (cons (crossing-key b) (crossing-side b))) bnd))
        ((flows) (flows))
        ((met) (admm-scope-met kr))
        ((plan) (plan))
        ((solve!)
         (let* ((centres (car args)) (rho* (cadr args))
                (rho-h (and (pair? rho*) (crossing-alist->hash rho*))))
           (admm-write-prox! kr (per-bnd (crossing-alist->hash centres) 0.0) (if rho-h 1.0 rho*))
           (when rho-h                        ; the prox weight ρ/2 sits in slot j of w, per boundary column
             (let lp ((b bnd) (j 0))
               (unless (null? b)
                 (f64set! (vector-ref kr 11) j (/ (exact->inexact (hash-ref rho-h (crossing-key (car b)))) 2.0))
                 (lp (cdr b) (+ j 1)))))
           (solve1!)
           `((flows . ,(flows)) (met . ,(admm-scope-met kr)))))
        ;; The exact local solve at the converged pulls, exactly as
        ;; solve-decomposed's `refine`: the pull folds into labform as
        ;; (col . λ/κ), the prox stays centred on the agreed z (at
        ;; convergence the augmented minimiser IS the constrained one; against
        ;; the bare program a scope that supplies an abundant good is
        ;; indifferent and sends what nobody receives). Kept only if it is feasible and
        ;; tightens this scope's OWN bound — the cross-scope agreement test the
        ;; monolith also applies is the coordinator's, on the flows returned.
        ;; The exact local solve at the converged pulls (refine-plan), kept only
        ;; if it is feasible and tightens this scope's OWN bound — the
        ;; cross-scope agreement test the monolith also applies is the
        ;; coordinator's, on the flows returned.
        ((refine!)
         (let* ((z (car args)) (pulls (cadr args)) (rho* (caddr args))
                (x0 (columns))
                (r (refine-plan rec x0 z pulls rho*))
                (x1 (and r (car r)))
                (lab* (if r (cdr r) (or (get 'labform) '()))))
           (call-with-values (lambda () (certify x0 lab*))
             (lambda (ok0 gap0)
               (set! last-lab lab*)
               (if (not x1)
                   (report ok0 gap0)
                   (call-with-values (lambda () (certify x1 lab*))
                     (lambda (ok1 gap1)
                       (if (and ok1 (< gap1 gap0))
                           (begin (set-plan! x1) (set! refined? #t) (report ok1 gap1))
                           (report ok0 gap0)))))))))
        ;; RECONCILE BY CLAMPING (solve-decomposed's `clamp`): where the scope
        ;; draws more than it is held to, its column set to exactly that, nothing
        ;; else moved, and the result put back through the same feasibility
        ;; test — the reply says whether this scope's floors still close under
        ;; the edit.
        ((clamp!)
         (let* ((caps (car args)) (caps-h (crossing-alist->hash caps)) (x (columns)) (moved #f))
           (for-each (lambda (b)
                       (let ((cap (hash-ref caps-h (crossing-key b) #f)))
                         (when (and cap (< (crossing-flow b (vector-ref x (crossing-col b))) cap))
                           (vector-set! x (crossing-col b) (exact->inexact (crossing-column b cap)))
                           (set! moved #t))))
                     bnd)
           (if (not moved)
               (call-with-values (lambda () (certify x last-lab)) report)
               (call-with-values (lambda () (certify x last-lab))
                 (lambda (ok gap)
                   (if ok (begin (set-plan! x) (set! clamped? #t)))
                   (report ok gap))))))
        (else (error "boundary-oracle: unknown message" msg))))))

;; ── the coordinator ──────────────────────────────────────────────────────────
(define* (solve-consensus link-tables round!
                          #:key (finish! #f)
                                (rho 4.0) (iters 120) (tol 1e-4) (alpha 1.6)
                                (accel #t) (mmax 8) (met-eps 0.05) (met-stall 3)
                                (z0 '()) (max-stale 5))
  "The ADMM over scopes that answer through ROUND!.
   LINK-TABLES: per scope, the goods it shares (link-key …) — what each scope
     told the coordinator (an oracle's 'links). A good may have any number of
     scopes on it: one pull for it, their signed flows summing to nothing
     (solve/admm-link.scm's exchange).
   ROUND!: (round! centres rho) with CENTRES per scope ((link-key . c) …) →
     per scope ((flows . ((link-key . y) …)) (met . %)), each flow signed, or
     #f in the place of a scope that missed the round's deadline. The caller
     decides what a round costs (a call, a message) and when it is over.
   A scope that misses a round contributes its last reply, the ADMM under
     bounded staleness; one that has not yet spoken contributes the centre
     the loop holds for it, which moves nothing. A link with a stale scope at
     either end holds still that round, z and the dual, as the master of
     Zhang & Kwok's asynchronous ADMM holds a worker's last (x, λ). A round
     with a stale scope restarts the acceleration and cannot end the solve: convergence is read
     off replies every scope gave that round. A scope silent for more than
     MAX-STALE rounds in a row raises — past that bound the staleness has no
     convergence guarantee, and dropping a scope is the caller's to decide.
   FINISH!: #f, or (finish! phase args rho) with PHASE `refine` (ARGS per scope
     (z pulls)) or `clamp` (ARGS per scope caps) → per scope the oracle's
     report alist. Runs the exact local solve and the reconciliation the
     in-process solve runs, one message each.
   Z0: ((link-key y …) …), the signed flows to start a good from, one per
     scope that shares it, in scope order.
   Returns (values reports met rounds pulls): REPORTS per scope — the last
   reply from that scope (flows, met, and after finish! feasibility and gap);
   PULLS a hash link-key → λ = ρ·u, the pull the good settled at. The
   federated certificate (with `stale-rounds`) goes to *last-certificate* as `federated-wire`."
  (let* ((S (length link-tables))
         (parts (make-hash-table)))                  ; good → the scopes that share it, scope order
    (define tables link-tables)
    (let lp ((ts tables) (s 0))
      (unless (null? ts)
        (for-each (lambda (k) (hash-set! parts k (append (hash-ref parts k '()) (list s))))
                  (car ts))
        (lp (cdr ts) (+ s 1))))
    ;; the exchange (solve/admm-link.scm): every live good's signed agreed flows and its pull
    (define ex (make-exchange (map (lambda (g) (cons (car g) (length (cdr g)))) (hash-map->list cons parts)) z0 #:rho rho))
    (define (pos-of s k) (list-index (lambda (p) (= p s)) (hash-ref parts k)))
    (define (flow-of reply key) (let ((a (assoc key (or (assq-ref reply 'flows) '())))) (and a (exact->inexact (cdr a)))))
    (define (pulls) (let ((h (make-hash-table)))
                       (hash-for-each (lambda (k v) (hash-set! h k (exchange-pull ex k))) parts) h))
    (define (signed-flows replies k)               ; each participant's signed flow on good K
      (map (lambda (p) (flow-of (list-ref replies p) k)) (hash-ref parts k)))
    (define (consensus-of replies)                 ; max |Σ y| over the goods
      (fold (lambda (k mx) (max mx (abs (fold + 0.0 (signed-flows replies k))))) 0.0 (exchange-keys ex)))
    (define (overdraw-of replies)                  ; max (what is drawn − what is supplied, 0): the unexecutable part
      (fold (lambda (k mx) (max mx (- (fold + 0.0 (signed-flows replies k))))) 0.0 (exchange-keys ex)))
    (define (mean-met replies) (/ (fold (lambda (r a) (+ a (or (assq-ref r 'met) 0.0))) 0.0 replies) (max 1 S)))
    ;; WHAT THE FINISH HOLDS EACH SCOPE TO: the flows the scopes answered in
    ;; the last round, brought to sum to nothing. Every scope has seen the
    ;; centre those answer, and they balance to the loop's tolerance, so a
    ;; scope that keeps its iterate and one that takes its exact solve stand on
    ;; one agreement. (The exchange's own flows are a round ahead: the step, and
    ;; the leap, on those answers — a centre no scope has answered yet.)
    (define last-replies #f)
    (define (answered k)
      (let* ((ys (map (lambda (y) (or y 0.0)) (signed-flows last-replies k)))
             (mean (/ (fold + 0.0 ys) (max 1 (length ys)))))
        (map (lambda (y) (- y mean)) ys)))
    (call-with-values
        (lambda () (exchange-rounds ex tables (lambda (centres) (round! centres (exchange-rho ex)))
                                    #:alpha alpha #:accel accel #:mmax mmax #:iters iters #:tol tol
                                    #:met-eps met-eps #:met-stall met-stall #:max-stale max-stale))
      (lambda (replies met rounds stale-rounds residuals)
                (set! last-replies replies)
                ;; ── finish: the exact local solve at the settled pulls, then
                ;;    the reconciliation — each a message to every scope ──
                (let* ((pr (pulls))
                       (final
                        (if (not finish!) replies
                            (let* ((refined (finish! 'refine
                                                     (map (lambda (s)
                                                            (let ((mine (list-ref link-tables s)))
                                                              ;; the flow each scope is held to on a good, and the good's pull
                                                              (list (map (lambda (k) (cons k (list-ref (answered k) (pos-of s k)))) mine)
                                                                    (map (lambda (k) (cons k (hash-ref pr k 0.0))) mine))))
                                                          (iota S))
                                                     (exchange-rho ex)))
                                   ;; what is supplied, shared out (allocate-caps) → the flow each scope is held to
                                   (caps (map (lambda (s)
                                                (filter-map
                                                 (lambda (k)
                                                   (and (exchange-live? ex k)
                                                        (let* ((ps (hash-ref parts k))
                                                               (held (allocate-caps
                                                                      (map (lambda (p) (or (flow-of (list-ref refined p) k) 0.0)) ps))))
                                                          (cons k (list-ref held (list-index (lambda (p) (= p s)) ps))))))
                                                 (list-ref link-tables s)))
                                              (iota S)))
                                   (clamped (if (> (overdraw-of refined) 1e-9)
                                                (finish! 'clamp caps (exchange-rho ex))
                                                refined)))
                              ;; the clamp is kept only if every scope stays feasible under it
                              (if (every (lambda (r) (assq-ref r 'feasible?)) clamped) clamped refined))))
                       (met* (mean-met final))
                       (od (overdraw-of final))
                       (feas (map (lambda (r) (let ((f (assq 'feasible? r))) (if f (cdr f) 'unknown))) final))
                       (gaps (map (lambda (r) (let ((g (assq 'gap-bound r))) (if g (cdr g) +inf.0))) final)))
                  (set-last-certificate!
                        `((kind . federated-wire) (scopes . ,S)
                          (feasible? . ,(every (lambda (f) (eq? f #t)) feas))
                          (local-bound . ,(fold + 0.0 gaps))
                          (local-bounds . ,gaps)
                          (local-feasible . ,feas)
                          (consensus . ,(consensus-of final))
                          (overdraw . ,od)
                          (coupling-feasible? . ,(<= od 1e-9))
                          (reconciled? . ,(any (lambda (r) (assq-ref r 'clamped?)) final))
                          (refined? . ,(map (lambda (r) (and (assq-ref r 'refined?) #t)) final))
                          (rounds . ,rounds)
                          (stale-rounds . ,stale-rounds)
                          (met . ,met*)))
                  (values final met* rounds pr))))))
