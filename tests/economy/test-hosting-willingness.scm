;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-hosting-willingness.scm — consent bounds how far a span may reach.
;;;
;;; Step 4 of patchwork-scopes-containment.md: a span declaration is the
;;; steward's act, and a span landing in ANOTHER scope's place also needs the
;;; host's — a hosting-willingness credential, the labour availability pattern
;;; over means. The envelope is a ceiling, never a claim; refusal is the
;;; default, never an event.

(use-modules (localchimera test harness))
(use-modules )
(use-modules (localchimera credentials declarations) (localchimera keri acdc) (localchimera economy socialization) (localchimera keri acdc) (localchimera keri acdc-store))
(use-modules (goblins))
(use-modules (srfi srfi-1))

(define STEWARD "EWorkshopScope")
(define HOST    "ETownScope")
(define FUTURE  "2099-12-31T00:00:00Z")
(define PAST    "2000-01-01T00:00:00Z")

;; the injected mappings — only the caller knows the scope graph
(define (place-scope-of p)
  (assoc-ref '(("town-square" . "ETownScope")
               ("workshop-a"  . "EWorkshopScope"))
             p))
(define (spec-of rid) (and (equal? rid "lathe-1") "lathe"))

(display "\n── 1. The credential: a scope's own consent, with a ceiling ──\n")

(let ((w (make-hosting-willingness-credential #:scope-aid HOST
                                              #:resource-spec "lathe"
                                              #:ceiling 20.0
                                              #:valid-until FUTURE)))
  (check-pred "issuer = holder = the hosting scope"
              (and (equal? HOST (cred-issuer w)) (equal? HOST (cred-holder w))))
  (check-pred "willingness schema"
              (equal? *schema-localchimera-hosting-willingness* (cred-schema w)))
  (check-pred "the ceiling is a number, not a claim" (= 20.0 (cred-claim w 'ceiling))))

(define vat (spawn-vat))

(with-vat vat
  (display "\n── 2. Without the host's consent, a foreign span is dropped ──\n")
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "town-square"))
    (check-pred "live-span-of sees the declaration (no gate)"
                (equal? "town-square" (assoc-ref (live-span-of store) "lathe-1")))
    (check-pred "consented-span-of drops it — refusal is the default"
                (not (assoc-ref (consented-span-of store
                                                   #:place-scope-of place-scope-of
                                                   #:spec-of spec-of)
                                "lathe-1"))))

  (display "\n── 3. With it, the span passes; lapsed, it drops again ──\n")
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "town-square"))
    ($ store 'issue (make-hosting-willingness-credential #:scope-aid HOST
                                                         #:resource-spec "lathe"
                                                         #:ceiling 20.0
                                                         #:valid-until FUTURE))
    (check-pred "host consented ⇒ the span reaches its place"
                (equal? "town-square"
                        (assoc-ref (consented-span-of store
                                                      #:place-scope-of place-scope-of
                                                      #:spec-of spec-of)
                                   "lathe-1"))))
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "town-square"))
    ($ store 'issue (make-hosting-willingness-credential #:scope-aid HOST
                                                         #:resource-spec "lathe"
                                                         #:ceiling 20.0
                                                         #:valid-until PAST))
    (check-pred "consent lapsed ⇒ the span drops, with no further event"
                (not (assoc-ref (consented-span-of store
                                                   #:place-scope-of place-scope-of
                                                   #:spec-of spec-of)
                                "lathe-1"))))

  (display "\n── 4. What needs no consent ──\n")
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "workshop-a"))
    (check-pred "the steward's own walls"
                (equal? "workshop-a"
                        (assoc-ref (consented-span-of store
                                                      #:place-scope-of place-scope-of
                                                      #:spec-of spec-of)
                                   "lathe-1"))))
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "riverbank"))
    (check-pred "a place no scope claims: open ground"
                (equal? "riverbank"
                        (assoc-ref (consented-span-of store
                                                      #:place-scope-of place-scope-of
                                                      #:spec-of spec-of)
                                   "lathe-1"))))
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                      #:resource-id "lathe-1"
                                                      #:span-place "town-square"))
    (check-pred "no mappings supplied ⇒ the gate cannot be asked (live-span-of)"
                (equal? "town-square"
                        (assoc-ref (consented-span-of store) "lathe-1")))))

(display "\n── 5. Standing: only the rights-holder may span ──\n")

(with-vat vat
  ;; rights: lathe-1 is OWNED by the steward; commons-1 is COMMON property.
  (let ((rights (lambda (rid) (cond ((equal? rid "lathe-1")   STEWARD)
                                    ((equal? rid "commons-1") 'common)
                                    (else #f)))))
    (let ((store (spawn-acdc-store)))
      ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                        #:resource-id "lathe-1"
                                                        #:span-place "workshop-a"))
      ($ store 'issue (make-span-declaration-credential #:scope-aid "EMallory"
                                                        #:resource-id "lathe-1"
                                                        #:span-place "workshop-a"))
      (check-pred "the owner's declaration passes the standing gate"
                  (equal? "workshop-a"
                          (assoc-ref (consented-span-of store #:rights-of rights) "lathe-1"))))
    (let ((store (spawn-acdc-store)))
      ($ store 'issue (make-span-declaration-credential #:scope-aid "EMallory"
                                                        #:resource-id "lathe-1"
                                                        #:span-place "town-square"))
      (check-pred "a stranger's declaration over an owned means is dropped"
                  (not (assoc-ref (consented-span-of store #:rights-of rights) "lathe-1"))))
    (let ((store (spawn-acdc-store)))
      ($ store 'issue (make-span-declaration-credential #:scope-aid STEWARD
                                                        #:resource-id "commons-1"
                                                        #:span-place "workshop-a"))
      (check-pred "no scope has standing over a COMMON means — not even its custodian"
                  (not (assoc-ref (consented-span-of store #:rights-of rights #:uc-aid "EUC")
                                  "commons-1"))))
    (let ((store (spawn-acdc-store)))
      ($ store 'issue (make-span-declaration-credential #:scope-aid "EUC"
                                                        #:resource-id "commons-1"
                                                        #:span-place "workshop-a"))
      (check-pred "universal governance alone spans common property (a ratified reservation)"
                  (equal? "workshop-a"
                          (assoc-ref (consented-span-of store #:rights-of rights #:uc-aid "EUC")
                                     "commons-1"))))
    (let ((store (spawn-acdc-store)))
      ($ store 'issue (make-span-declaration-credential #:scope-aid "EMallory"
                                                        #:resource-id "unknown-9"
                                                        #:span-place "anywhere"))
      (check-pred "unknown rights stay ungated — today's behaviour, stated"
                  (equal? "anywhere"
                          (assoc-ref (consented-span-of store #:rights-of rights) "unknown-9"))))))

(test-summary!)
