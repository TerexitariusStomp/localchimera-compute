;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-mint-gov-cap.scm — federation-kind mint-gov-cap, self-
;;; governed via its own member communes.
;;;
;;; may-govern? (governance/scope.scm) checks a federation's own `members`
;;; hashmap (commune-id -> commune-ref, populated by admit-commune) rather
;;; than nothing at all: a citizen recognised by AT LEAST ONE currently-
;;; admitted member commune may govern the federation. A member commune-ref
;;; can be a genuinely FAR ref (a different vat, in-process or over the
;;; network) — `$` only ever works on a near-refr? and THROWS immediately
;;; on a far one (Goblins: no hang, no silently-wrong promise), so
;;; false-if-exception around each member's own scope-aid is the whole
;;; safety net: a far member simply doesn't count toward eligibility,
;;; never crashes the check and never wrongly admits anyone.
;;;
;;; The far-ref proof unit-tests may-govern? directly with a synthetic
;;; non-actor "member" rather than a genuinely live cross-vat ^scope:
;;; admit-commune's own verify-scope! gate already refuses an unresolved
;;; cross-vat promise (a separate, pre-existing limitation of admit-commune
;;; itself — a caller must await such a promise before admitting, which
;;; needs Goblins' async machinery, not exercised here), so a real
;;; different-vat commune can't reach `members` through admit-commune in a
;;; plain synchronous test. Calling `$` on ANY non-actor value throws the
;;; identical way a genuinely far ref would, which is exactly the failure
;;; mode false-if-exception guards against.

(use-modules (localchimera test harness))
(use-modules (localchimera scope root))
(use-modules (localchimera boot scope) (localchimera keri acdc-store) (localchimera keri citizen-sig) (localchimera keri first-person credentials))
(use-modules ((localchimera keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid))
             (goblins) (goblins vat) (goblins utils hashmap))

(define fed-vat (spawn-vat #:name "federation"))

(with-vat fed-vat
  (let* ((store (spawn-acdc-store))
         (commune-id (make-keri-identity)) (commune-aid (keri-identity-aid commune-id))
         (commune-root (spawn-scope-root "LocalCommune"))
         (commune (spawn-scope "LocalCommune" #:kind 'commune #:scope-root-ref commune-root
                               #:scope-aid commune-aid #:acdc-store store))
         (fed-root (spawn-scope-root "Federation"))
         (fed (spawn-scope "Federation" #:kind 'federation #:scope-root-ref fed-root
                           #:scope-aid "EFederation" #:acdc-store store))
         (fed-gov ($ fed 'mint-gov-cap "op"))
         (citizen (make-keri-identity)) (citizen-aid (keri-identity-aid citizen))
         (stranger (make-keri-identity)) (stranger-aid (keri-identity-aid stranger)))

    (define (may-mint? aid)
      (catch #t (lambda () ($ fed 'mint-gov-cap aid) #t) (lambda _ #f)))

    (check-pred "no member communes yet: bootstrap open, anyone may govern"
                (may-mint? stranger-aid))

    ($ fed 'admit-commune fed-gov "local" commune)
    ;; LocalCommune has recognised nobody yet — that commune's OWN
    ;; bootstrap-open window (ecosystem-personhood-bootstrapped?, scoped to
    ;; commune-aid) still applies transitively.
    (check-pred "member commune not yet bootstrapped: still open"
                (may-mint? stranger-aid))

    ($ store 'issue (make-personhood-credential #:ecosystem-aid commune-aid
                                                #:holder-aid citizen-aid
                                                #:enrolled-at "2026-01-01T00:00:00Z"))
    (check-pred "citizen recognised by the member commune may govern the federation"
                (may-mint? citizen-aid))
    (check-pred "a stranger recognised by no member commune is refused"
                (not (may-mint? stranger-aid)))

    ;; A far/unreachable member, unit-tested directly against may-govern?
    ;; (see file header for why not through the full admit-commune path):
    ;; a bare, non-actor value in MEMBERS makes `$` throw exactly the way a
    ;; genuinely far ref would.
    (let ((members-with-unreachable
           (hashmap-set (hashmap-set (hashmap) "local" commune)
                        "unreachable" 'not-an-actor)))
      (check-pred "an unreachable member doesn't crash the check"
                  (may-govern? 'federation "EFederation" store citizen-aid
                              members-with-unreachable))
      (check-pred "…and a stranger recognised nowhere is still refused"
                  (not (may-govern? 'federation "EFederation" store stranger-aid
                                   members-with-unreachable))))))

;; A federation whose members are all remote has no near commune to read; its
;; own people decide, as a commune's do: open while it has recognised nobody,
;; then those it has recognised.
(with-vat fed-vat
  (let* ((store (spawn-acdc-store))
         (fed (spawn-scope "Remote" #:kind 'federation #:scope-aid "ERemote" #:acdc-store store))
         (founder (keri-identity-aid (make-keri-identity)))
         (stranger (keri-identity-aid (make-keri-identity))))
    (define (may-mint? aid)
      (catch #t (lambda () ($ fed 'mint-gov-cap aid) #t) (lambda _ #f)))
    (check-pred "no one recognised yet: the bootstrap window is open" (may-mint? stranger))
    ($ store 'issue (make-personhood-credential #:ecosystem-aid "ERemote"
                                                #:holder-aid founder
                                                #:enrolled-at "2026-01-01T00:00:00Z"))
    (check-pred "once it has a founder, the founder governs" (may-mint? founder))
    (check-pred "and a stranger no longer does" (not (may-mint? stranger)))))

(display "\n")
(test-summary!)
