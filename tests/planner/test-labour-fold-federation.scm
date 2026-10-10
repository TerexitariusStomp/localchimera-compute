;;; test-labour-fold-federation.scm — the federated solve reads the standing
;;; labour roster.
;;;
;;; Two demo communes (federation-demo.scm: flour+work→bread), registered with
;;; the real ^planner-service — so add-scope! wires each scope's ^labour-pool
;;; and the UC root holds the keyed roster. federated-plan then takes each
;;; commune's labour off that pool (#:labour-entries), so what the roster says
;;; is what the solve has:
;;;   • bakers with no declared window stand at *default-agent-hours* under
;;;     spec-labor — the conformant fallback the solver itself uses;
;;;   • shrinking one baker's window through set-availability shrinks the
;;;     hours the NEXT federated solve can spend — no restart, no re-ship.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-labour-fold-federation.scm

(use-modules (playnet test harness)
             (playnet knowledge recipes federation-demo) (playnet scope root) (playnet vf schemas) (playnet observation states) (playnet vf beyond schedules) (srfi srfi-1)
             (playnet doors service)
             (playnet knowledge recipes federation-demo)
             (playnet test scope)
             (playnet scope live)
             (srfi srfi-13)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))

;; The pool carries hours a WEEK — a recurring window's one date-free measure,
;; and the shape the app ships (one schedule per weekday): 09:00–17:00 every day
;; is 56 h, 09:00–13:00 is 28 h.
(define vat (spawn-vat))
(define %svc #f) (define %table #f)

(with-vat vat

  (define scopeA (spawn-scope-root "Granary"))
  (define scopeB (spawn-scope-root "Table"))
  (define svc    (spawn ^planner-service (hashmap)))

  (seed-fed-commune! scopeA "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
  (seed-fed-commune! scopeB "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
  ;; this suite's subject is the pool REFOLDING on an availability WRITE —
  ;; start both bakers windowless (the seed's demo working hours cleared),
  ;; so the shrunk window below is the one window in play
  (for-each
   (lambda (pair)
     (let ((as ($ (car pair) 'agent-store)) (id (cdr pair)))
       ($ as 'update-agent id
          (lambda (old)
            (make-agent #:id (agent-id old) #:type (agent-type old) #:name (agent-name old)
                        #:note (agent-note old) #:image (agent-image old)
                        #:primary-location (agent-primary-location old) #:classified-as (agent-classified-as old))))))
   (list (cons scopeA "w-venue-granary") (cons scopeB "w-venue-table")))
  ($ svc 'add-scope! "Granary" scopeA)
  ($ svc 'add-scope! "Table"   scopeB)

  (display "\n── the roster holds both bakers under their declared skill ──\n")
  ;; the seeded Baker HOLDS the baking skill (federation-demo seeds the same
  ;; resource shape declare-skill writes), so the pool keys each baker's 8h
  ;; under "baking" — the skill the bake work flow conforms to
  (check "two windowless bakers ⇒ 112h a week of baking labour at the UC"
         ($ svc 'labour-total-hours #:skill "baking") 112.0)

  (define (met-of env)
    (if (eq? (car env) 'ok) (assq-ref (cdr env) 'met) -1))

  (display "\n── the federated solve spends the roster's hours ──\n")
  (define met-full
    (met-of ($ svc 'federated-plan "flour"
               (list (list "Granary" (cons "bread#venue-granary@0" 5.0))
                     (list "Table"   (cons "bread#venue-table@0" 40.0))))))
  (check "with default hours the demand clears" (> met-full 40.0) #t)

  (display "\n── a shrunk window reaches the NEXT solve through the pool ──\n")
  ;; Table's baker offers only 09:00–10:30 now: 1.5h < the 4h its 40kg bake
  ;; needs at 0.1h/kg. The pool refolds on the write; the re-solve reads it.
  ($ svc 'set-availability "Table" "w-venue-table"
     (make-availability-window
      #f #f #f (list (make-time-range "09:00" "10:30"))))
  (check "the roster moved: 56h a week + 10.5h a week" ($ svc 'labour-total-hours) 66.5)
  (define met-tight
    (met-of ($ svc 'federated-plan "flour"
               (list (list "Granary" (cons "bread#venue-granary@0" 5.0))
                     (list "Table"   (cons "bread#venue-table@0" 40.0))))))
  ;; 1.5h at 0.1 h/kg bakes 15 of the 40 kg wanted; the granary's 5 stay whole,
  ;; so the federation reads (100 + 37.5)/2 = ~68 at most — the bound the
  ;; roster states, not a number a convergence path happens to land on
  (check "the tightened hours bind the federated solve: met falls well below full"
         (< met-tight 70.0) #t)
  (check "and the bound is the roster's: the table cannot exceed 15 of 40 kg"
         (< met-tight met-full) #t)
  (set! %svc svc) (set! %table scopeB))

;; the solves landed through the solve descent and each scope's slack node
;; heard cache-solve! — an eventual refold, so the reads take the next turn
(with-vat vat
  (display "\n── the slack fold: the desire overlay as one read ──\n")
  (let ((slacks ($ %svc 'slack-read 'slacks)))
    (check "both venues stand in the UC total"
           (and (assoc "venue-granary" slacks) (assoc "venue-table" slacks) #t) #t)
    (check "every slack is a ratio in [0,1]"
           (every (lambda (p) (and (>= (cdr p) 0) (<= (cdr p) 1))) slacks) #t)
    (check "the granary, flour-rich, reads whole (to solver tolerance)"
           (> (assoc-ref slacks "venue-granary") 0.999) #t))
  (check "a scope's own node carries only its own venue"
         (map car ($ ($ %svc 'slack "Table") 'slacks)) '("venue-table"))
  (check "the geomean over the commons is a read"
         (number? ($ %svc 'slack-read 'geomean)) #t)

  (display "\n── the solve lands in the scope's OWN store ──\n")
  ;; the descent's leaf wrote its row into its scope's plan-store — a
  ;; persisted meta row, so a restart draws the last plan — and only there
  (let ((row ($ ($ %table 'plan-store) 'get-meta "solve:last")))
    (check "Table's plan-store holds Table's last federated solve" (and row #t) #t)
    (check "whose demand names Table's venue"
           (and row (any (lambda (d) (equal? "venue-table" (list-ref d 1)))
                         (car (assq-ref row 'solve))))
           #t)
    (check "and never Granary's"
           (and row (any (lambda (d) (equal? "venue-granary" (list-ref d 1)))
                         (car (assq-ref row 'solve))))
           #f)))

;; A row's silence is not a statement: a federated row carries materials and
;; crossings, no `claims` and no `work`, so landing one retires neither the
;; claims the last own plan minted nor the open shifts it laid.
(with-vat vat
  (display "\n── a federated row does not retire what it does not state ──\n")
  (let* ((obs ($ %table 'observer)) (ps ($ %table 'plan-store))
         (cid (plan-claim! obs "bread" "claimant-1" 2.0 #:scope "Table"))
         (shift (lambda () (length (filter (lambda (i) (string-prefix? "ni|" (intent-id i)))
                                           ($ ps 'all-intents)))))
         (open-claims (lambda () (length (filter (lambda (fs) (equal? cid (fulfillment-state-commitment-id fs)))
                                                 ($ obs 'open-fulfillments))))))
    ($ ps 'add-intent (work-intent "ni|bake|baking|venue-table@0" #:name "bake" #:proc "bake"
                                   #:skill "baking" #:hours 1.0 #:place "venue-table"))
    (check "the claim stands before" (open-claims) 1)
    (check "the shift stands before" (shift) 1)
    ($ %svc 'federated-plan "flour"
       (list (list "Granary" (cons "bread#venue-granary@0" 5.0))
             (list "Table"   (cons "bread#venue-table@0" 5.0))))
    (check "a federated row leaves the claim standing" (open-claims) 1)
    (check "and the open shift" (shift) 1)
    ;; control: an own plan states `claims` (here none) and so retires
    ($ %svc 'plan "Table" (list (list "bread" "venue-table" 0 5.0)))
    (check "an own plan that states no claims retires the claim" (open-claims) 0)))

(test-summary!)
