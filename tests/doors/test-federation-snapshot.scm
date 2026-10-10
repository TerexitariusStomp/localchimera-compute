;;; test-federation-snapshot.scm — the FEDERATION-WIDE overlay, end to end.
;;;
;;; Two sovereign communes seeded into the same federation (`fed`), registered
;;; with the real ^planner-service, composed by the cross-vat pull ADMM via the
;;; service's `federated-plan` method — then we ask ONE commune for its
;;; scope-snapshot and assert the overlay data spans the WHOLE federation:
;;;   • viewing Granary returns BOTH venue-granary AND venue-table (the sibling
;;;     union — a commune sharing the `fed` root is folded in), so the earth-map
;;;     draws the whole `fed ⊃ {commune ⊃ venue}` tree from either vantage;
;;;   • venue-table carries its per-location slack from the federated solve, so it
;;;     reads whole (greens) once A's flour crosses the boundary to meet B.
;;;
;;; This is the gateway's exact path (server/gateway.scm demo block): seed →
;;; add-scope! → federated-plan → scope-snapshot.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-federation-snapshot.scm

(use-modules ((playnet wire rows) #:select (wire->plain))   ; a door's rows, read back as alists
             (playnet knowledge recipes federation-demo) (playnet federation store-registry) (playnet scope root) (srfi srfi-1)
             (playnet scope live)
             (playnet doors service)
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define scope-root-env-full
  ;; each env names its own actor; a new slot on ^scope-root needs no edit here
  (make-persistence-env '() #:extends (list scope-root-env store-registry-env)))

;; ── spin up two sovereign communes + the real service holding both ──
(define store (make-memory-store))
(define-values (vat scopeA)
  (spawn-persistent-vat scope-root-env-full
    (lambda () (spawn-scope-root "Granary")) store))
(define scopeB (with-vat vat (spawn-scope-root "Table")))
;; the service is spawned OUTSIDE the persistent thunk (it isn't part of the
;; persisted portrait set) — the same shape plan-snapshot-e2e.scm uses.
(define svc (with-vat vat (spawn ^planner-service (hashmap))))

(with-vat vat
  (seed-fed-commune! scopeA "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)  ; flour-rich
  (seed-fed-commune! scopeB "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)    ; flour-poor
  ($ svc 'add-scope! "Granary" scopeA)
  ($ svc 'add-scope! "Table"   scopeB))

;; ── compose them through the service: the crossing settles, A to B ──
(define fed-env
  (with-vat vat
    ($ svc 'federated-plan "flour"
       (list (list "Granary" (cons "bread#venue-granary@0" 5.0))  ; holds the flour, so the solve has it supply; token local demand anchors its subproblem
             (list "Table"   (cons "bread#venue-table@0" 40.0)))))) ; holds none: draws, and bakes to demand
(format #t "~%   federated-plan → ~s~%" fed-env)
(unless (eq? (car fed-env) 'ok)
  (format #t "   [XX] federated-plan failed~%") (exit 1))
(define fed-met (assq-ref (cdr fed-env) 'met))

;; ── the overlay read: Granary's snapshot must span the whole federation ──
(define snap (with-vat vat (wire->plain ($ svc 'scope-snapshot "Granary" #f))))
(define locs (assq-ref snap 'locations))
(define (loc id) (find (lambda (l) (equal? (assq-ref l 'id) id)) locs))

(define ids (map (lambda (l) (assq-ref l 'id)) locs))
(format #t "   Granary snapshot locations = ~s~%" ids)

(define has-own     (and (loc "venue-granary") #t))
(define has-sibling (and (loc "venue-table") #t))          ; the FEDERATION-WIDE union
(define shared-root (= 1 (length (filter (lambda (id) (equal? id "fed")) ids))))  ; deduped
(define vt-slack    (and (loc "venue-table") (let ((s (assq-ref (loc "venue-table") 'slack))) (and (number? s) s))))

(format #t "~%── FEDERATION-WIDE OVERLAY (viewed from Granary) ──~%")
(format #t "   own venue present:        ~a~%" has-own)
(format #t "   sibling venue present:    ~a   (the union)~%" has-sibling)
(format #t "   shared `fed` root deduped: ~a~%" shared-root)
(format #t "   venue-table slack:        ~a   (met∕want; #f or ~~1 = whole/green)~%" vt-slack)
(format #t "   federated met:            ~a%%~%" fed-met)

;; symmetry: viewing Table must ALSO see venue-granary
(define snapB (with-vat vat (wire->plain ($ svc 'scope-snapshot "Table" #f))))
(define idsB (map (lambda (l) (assq-ref l 'id)) (assq-ref snapB 'locations)))
(define b-sees-a (and (member "venue-granary" idsB) #t))
(format #t "   symmetric (Table sees Granary's venue): ~a~%" b-sees-a)

(let ((ok (and has-own has-sibling shared-root b-sees-a
               (or (not vt-slack) (> vt-slack 0.9)))))
  (format #t "~%   [~a] one commune's snapshot spans the federation, slack rides along~%~%"
          (if ok "OK" "XX"))
  (exit (if ok 0 1)))
