;;; test-delegation-scope-arg.scm — the delegation-family doors' scope-id
;;;
;;; The six delegation doors (delegation-preimage/set-delegation-signed,
;;; set-delegation, delegation-mandated-preimage/set-delegation-mandated-signed,
;;; revoke-delegation) used to take a bare `. rest` tail whose ONLY real
;;; content is a franchise tag — `()` for federation-wide, `('scope SID)`
;;; for one commune. doors/lobby.scm now declares one named, optional `scope-id`
;;; and builds that internal tag at the door boundary; governance-svc's own
;;; arms (and delegation-map's) are UNCHANGED — this pins the translation.
;;;
;;; What this pins:
;;;   • set-delegation with no scope-id lands in federation-default;
;;;   • set-delegation WITH scope-id lands in scope-overrides under that
;;;     scope, federation-default untouched;
;;;   • revoke-delegation's scope-id reaches the same place a set did, and
;;;     removes the RIGHT one (scope-bound, not the federation-wide one);
;;;   • delegation-preimage's SAID actually differs with and without
;;;     scope-id (the franchise really is baked into what gets signed, not
;;;     dropped silently at the boundary).
;;;
;;; Run: guile -L module -L tests tests/governance/test-delegation-scope-arg.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet boot governance) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap))

(define vat (spawn-vat))
(define ME  "ECitizen000000000000000000000000000000000000")
(define D1  "EDelegate10000000000000000000000000000000000")
(define SID "commune-a")

(define store (with-vat vat (spawn-acdc-store)))
(define svc (with-vat vat (spawn-governance-service '() #f #:acdc-store store)))
(define session (with-vat vat (spawn ^lobby-session ME #f #f svc #f)))

(define (settle p)
  (let ((box #f) (done #f))
    (with-vat vat
      (on p (lambda (v) (set! box v) (set! done #t))
          #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
    (let loop ((i 0)) (unless (or done (> i 200)) (usleep 10000) (loop (+ i 1))))
    box))

;; ensure-citizen's first call spawns the delegation-map, so the reply is a
;; promise until it settles — settle it once and reuse the resolved ref.
(define dm-ref (settle (with-vat vat ($ svc 'delegation-map ME))))
(define (dm) dm-ref)

(define (federation-entry) (hashmap-ref (with-vat vat ($ (dm) 'federation-default)) D1 #f))
(define (scope-entry sid) (let ((ov (hashmap-ref (with-vat vat ($ (dm) 'scope-overrides)) sid #f)))
                            (and ov (hashmap-ref ov D1 #f))))

(display "\n── set-delegation: scope-id absent lands federation-wide ──\n")
(check "set-delegation with no scope-id" (settle (with-vat vat ($ session 'set-delegation D1 0.4))) 'ok)
(check-pred "…lands in federation-default" (federation-entry))
(check "…and nowhere in scope-overrides" (scope-entry SID) #f)

(display "\n── set-delegation: scope-id lands only in that scope ──\n")
(check "set-delegation with scope-id" (settle (with-vat vat ($ session 'set-delegation D1 0.6 SID))) 'ok)
(check-pred "…lands in scope-overrides under SID" (scope-entry SID))
(check-pred "…the federation-wide entry from before is untouched" (federation-entry))

(display "\n── revoke-delegation: scope-id removes the right one ──\n")
(check "revoke-delegation with scope-id" (settle (with-vat vat ($ session 'revoke-delegation D1 SID))) 'ok)
(check "…the scoped entry is gone" (scope-entry SID) #f)
(check-pred "…the federation-wide one survives" (federation-entry))
(check "revoke-delegation with no scope-id" (settle (with-vat vat ($ session 'revoke-delegation D1))) 'ok)
(check "…the federation-wide entry is gone too" (federation-entry) #f)

(display "\n── delegation-preimage: the franchise is IN the fields, not dropped ──\n")
;; the preimage's own fields (not a returned SAID — the client computes that
;; itself from these, same as every other preimage/signed door here) carry
;; `claims.franchise`; that is what actually gets signed, so it is the real
;; proof the scope-id reached the credential rather than being lost at the
;; door boundary.
(define r1 (settle (with-vat vat ($ session 'delegation-preimage D1 0.5))))
(define r2 (settle (with-vat vat ($ session 'delegation-preimage D1 0.5 SID))))
(define (franchise-of r) (assq-ref (assq-ref (cadr r) 'claims) 'franchise))
(check "no scope-id: federation" (franchise-of r1) 'federation)
(check "scope-id: (scope . SID)" (franchise-of r2) (list 'scope SID))

(test-summary!)
