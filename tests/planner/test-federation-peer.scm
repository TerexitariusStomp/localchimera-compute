;;; test-federation-peer.scm — the coordinator-free federated solve across
;;; vat boundaries, every message signed.
;;;
;;; Each commune is a ^commune-peer in its own vat under its own KERI AID,
;;; holding a reference to the far end of each of its links and nothing else.
;;; Nobody conducts: the communes are started, a clock ticks, and the
;;; federation settles when it falls silent. The certificate is read off the
;;; communes' own signed attestations.
;;;
;;;   1. THE PAIR  — Granary and Table, scarce flour (λ ≈ −30.8): the pull and
;;;      the demand met are the coordinator's (solve-consensus over direct
;;;      oracles), reached with no round.
;;;   2. THE CHAIN — four communes in four vats, three links.
;;;   3. FORGERY   — a stranger's message, and a genuine one with a number
;;;      edited, are refused and counted; the federation settles as before.
;;;   4. A CROSSING  — one good, a granary and two bakers, three vats: each end
;;;      of the good is a named, pinned participant; one pull, and the demand
;;;      met is the monolith's.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-peer.scm

(use-modules (playnet test harness)
             (playnet planner federation peer)
             (playnet planner federation async)
             ((playnet planner federation wire) #:select (signed-reply))
             ((playnet planner solve engine) #:select (make-boundary-oracle solve-consensus))
             (playnet planner solve solver)
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid))
             (goblins) (goblins actor-lib methods)
             (srfi srfi-1) (ice-9 format))

(use-modules (playnet test planner federation-wire-fixture))
(load (string-append (dirname (dirname (dirname (current-filename))))
                     "/module/playnet/test/planner/federated-fixtures.scm"))
(load (string-append (dirname (current-filename)) "/federation-crossing-fixture.scm"))

(define (reference recs)
  (let ((oracles (map make-boundary-oracle recs)))
    (call-with-values
        (lambda ()
          (solve-consensus (map (lambda (o) (o 'links)) oracles)
                           (lambda (centres rho*) (map (lambda (o c) (o 'solve! c rho*)) oracles centres))
                           #:iters 400))
      (lambda (reports met rounds pulls) (list met rounds pulls)))))

(define (identity-of i) (make-keri-identity (fx-seed (+ 1 i))))

;; The communes of RECS, each in its own vat, connected along their links.
;; → (vat refs aids ids): VAT a further vat for the host's own use.
(define (federate recs)
  (let* ((n (length recs))
         (ids (map identity-of (iota n)))
         (aids (map keri-identity-aid ids))
         (vats (map (lambda (i) (spawn-vat #:name (format #f "commune-~a" i))) (iota n)))
         (host (spawn-vat #:name "host"))
         (peers (federation-of (map make-boundary-oracle recs)))
         (refs (map (lambda (vat p id i)
                      (with-vat vat (spawn ^commune-peer p id #:name (format #f "commune-~a" i))))
                    vats peers ids (iota n))))
    ;; each link joins its master and the other scope that shares it
    (for-each
     (lambda (p i)
       (for-each
        (lambda (l)
          (let ((j (list-index (lambda (q) (and (not (eq? q p)) (member l (q 'links)))) peers)))
            (when j
              (with-vat host (<- (list-ref refs i) 'connect l #f (list-ref refs j) (list-ref aids j)))
              (with-vat host (<- (list-ref refs j) 'connect l #f (list-ref refs i) (list-ref aids i))))))
        (p 'mastering)))
     peers (iota n))
    (list host refs aids ids)))

;; start the communes, tick them, and read the certificate until the
;; federation says it has settled: → the certificate, or #f at TIMEOUT seconds
(define (settle! fed timeout)
  (let ((host (car fed)) (refs (cadr fed)) (aids (caddr fed)))
    (with-vat host (for-each (lambda (r) (<-np r 'start)) refs))
    (let* ((ticker (with-vat host (start-ticker! refs 0.5)))
           (stop! (lambda () (with-vat host (<-np ticker 'stop)))))
      (let wait ((waited 0.0))
        (let ((cert (gather-attestations host refs aids)))
          (cond ((and (assq-ref cert 'settled?) (assq-ref cert 'final?)) (stop!) cert)
                ((> waited timeout) (stop!) #f)
                (else (sleep 1) (wait (+ waited 1.0)))))))))

(define (pull-of cert link) (cdr (assoc link (assq-ref cert 'pulls))))
(define (ref-pull ref link) (hash-ref (caddr ref) link 0.0))

(define (agrees label cert ref links pull-tol)
  (check (string-append label ": the federation settled") (and cert #t))
  (when cert
    (format #t "   ~a: met ~,2f (ref ~,2f)  consensus ~,5f~%" label (assq-ref cert 'met) (car ref)
            (assq-ref cert 'consensus))
    (for-each (lambda (l) (format #t "      ~a: λ ~,4f (ref ~,4f)~%" l (pull-of cert l) (ref-pull ref l))) links)
    (check (string-append label ": the flows agree across every link") (< (assq-ref cert 'consensus) 1e-3))
    (check (string-append label ": every commune made its exact local solve at the settled pulls")
           (and (assq-ref cert 'final?) (assq-ref cert 'feasible?)))
    (check (string-append label ": no commune takes what its master does not ship (to 1e-4 kg)")
           (<= (assq-ref cert 'overdraw) 1e-4))
    (check (string-append label ": the demand met is the reference's") (< (abs (- (assq-ref cert 'met) (car ref))) 0.5))
    ;; PULL-TOL a number: the good is scarce, its pull unique, and the run's
    ;; is the reference's to that much. (abundant . BOUND): the good is abundant,
    ;; its optimum a flat face the run lands anywhere on, and the pull there is
    ;; the barrier's gradient at that point — read as a bound, small against a
    ;; scarce good's (the pair's flour settles at −30.8).
    (for-each (lambda (l)
                (if (pair? pull-tol)
                    (check (string-append label ": the pull on " l " is an abundant good's")
                           (< (abs (pull-of cert l)) (cdr pull-tol)))
                    (check (string-append label ": the pull on " l " is the reference's")
                           (< (abs (- (pull-of cert l) (ref-pull ref l))) pull-tol))))
              links)))

;; ── 1. the pair ──────────────────────────────────────────────────────────────
(display "\n── 1. two communes, two vats, signed, no coordinator ──\n")
(define ref-scarce (reference (list (fx-commune-a-scarce) (fx-commune-b))))
(define pair (federate (list (fx-commune-a-scarce) (fx-commune-b))))
(define cert-pair (settle! pair 120))
(agrees "scarce pair" cert-pair ref-scarce '("flour") 0.5)
(check "every attestation was signed by the commune it names"
       (and cert-pair (= 2 (length (assq-ref cert-pair 'attestations)))))
(check "nothing was refused" (every (lambda (r) (zero? (call-from-thread (car pair) r 'refused)))
                                    (cadr pair)))

;; ── 2. the chain ─────────────────────────────────────────────────────────────
(display "\n── 2. four communes in four vats ──\n")
(define chain-links '("L0" "L1" "L2"))
(define ref-chain (reference (fx-chain 4)))
(define chain (federate (fx-chain 4)))
(define cert-chain (settle! chain 300))
(agrees "chain" cert-chain ref-chain chain-links '(abundant . 5.0))

;; ── 3. forgery ───────────────────────────────────────────────────────────────
(display "\n── 3. a stranger, and an edited message, are refused ──\n")
(define stranger (make-keri-identity (fx-seed 99)))
(define (refused-by ref) (call-from-thread (car chain) ref 'refused))
(define last-ref (list-ref (cadr chain) 3))           ; participant of L2, master of none
(define before (refused-by last-ref))
;; a stranger claiming to be the master of L2 and setting an absurd centre
(let ((forged (signed-reply stranger `((aid . ,(keri-identity-aid stranger)) (kind . centre)
                                       (link . "L2") (v . 999999) (c . 1e9) (z . 1e9) (pull . 0.0)))))
  (with-vat (car chain) (apply <-np last-ref 'deliver forged)))
;; the real master's own centre, its number edited after it was signed
(let* ((genuine (signed-reply (list-ref (cadddr chain) 2)
                              `((aid . ,(keri-identity-aid (list-ref (cadddr chain) 2))) (kind . centre)
                                (link . "L2") (v . 999999) (c . 1.0) (z . 1.0) (pull . 0.0))))
       (edited (list (string-append (substring (car genuine) 0 (- (string-length (car genuine)) 1)) " (c . 2.0))")
                     (cadr genuine))))
  (with-vat (car chain) (apply <-np last-ref 'deliver edited)))
(sleep 1)
(check "both were refused and counted" (= 2 (- (refused-by last-ref) before)))
(check "and the federation is where it was"
       (let ((cert (gather-attestations (car chain) (cadr chain) (caddr chain))))
         (and (assq-ref cert 'settled?) (< (abs (- (assq-ref cert 'met) (car ref-chain))) 0.5))))

;; ── 4. a crossing ──────────────────────────────────────────────────────────────
(display "\n── 4. one good, three communes, one pull ──\n")
(define crossing-specs (economy 'one-supplies 0.6))
(define crossing-mono (monolith-met crossing-specs))
(define (federate-crossing specs)
  (let* ((n (length specs))
         (ids (map identity-of (iota n)))
         (aids (map keri-identity-aid ids))
         (vats (map (lambda (i) (spawn-vat #:name (format #f "crossing-~a" i))) (iota n)))
         (host (spawn-vat #:name "crossing-host"))
         (master (car specs))
         (peers (map (lambda (sp)
                       (make-peer (make-boundary-oracle (scope-record sp)) #:name (car sp)
                                  #:mastering (if (eq? sp master) '("G") '())
                                  #:members (if (eq? sp master)
                                                (list (cons "G" (map car (cdr specs))))
                                                '())))
                     specs))
         (refs (map (lambda (vat p id sp)
                      (with-vat vat (spawn ^commune-peer p id #:name (car sp))))
                    vats peers ids specs)))
    (for-each
     (lambda (j)
       (with-vat host (<- (car refs) 'connect "G" (car (list-ref specs j)) (list-ref refs j) (list-ref aids j)))
       (with-vat host (<- (list-ref refs j) 'connect "G" 'master (car refs) (car aids))))
     (iota (- n 1) 1))
    (list host refs aids ids)))
(define crossing (federate-crossing crossing-specs))
(define cert-crossing (settle! crossing 180))
(check "the federation over one good settled" (and cert-crossing #t))
(when cert-crossing
  (format #t "   crossing: met ~,2f (monolith ~,2f)  λ ~,4f  balance ~,5f  overdraw ~,6f~%"
          (assq-ref cert-crossing 'met) crossing-mono (cdr (assoc "G" (assq-ref cert-crossing 'pulls)))
          (assq-ref cert-crossing 'consensus) (assq-ref cert-crossing 'overdraw))
  (check "what the granary ships is what the two bakers take" (< (assq-ref cert-crossing 'consensus) 1e-3))
  (check "every commune finished and its floors close" (and (assq-ref cert-crossing 'final?) (assq-ref cert-crossing 'feasible?)))
  (check "nobody takes what is not shipped" (<= (assq-ref cert-crossing 'overdraw) 1e-4))
  (check "the demand met is the monolith's" (< (abs (- (assq-ref cert-crossing 'met) crossing-mono)) 0.5))
  (check "one pull for the good" (not (zero? (cdr (assoc "G" (assq-ref cert-crossing 'pulls)))))))
(check "and nothing was refused"
       (every (lambda (r) (zero? (call-from-thread (car crossing) r 'refused))) (cadr crossing)))

(test-summary!)
