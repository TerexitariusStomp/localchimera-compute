;;; test-law-lint.scm — the lint catches the class of bug this layer keeps making.
;;;
;;; Three passes over the legal layer produced three bugs of ONE shape: a fact
;;; that goes missing, so no guard matches, so the law quietly does not apply.
;;; Under-regulation that reads exactly like permission — and invisible to any
;;; test that arranges its own places by hand.
;;;
;;; `lint-law-packs` reads a folder without registering anything and asks whether
;;; every jurisdiction a guard keys on is a place some pack actually places. This
;;; suite checks BOTH directions: the shipped packs are clean, and a pack broken
;;; on purpose is caught — because a lint nobody tests is a lint that passes.
;;;
;;; Run: guile -L module tests/planner/test-law-lint.scm

(use-modules (playnet test harness)
             (playnet planner knowledge law lint)
             (playnet planner facts places)
             (srfi srfi-1) (ice-9 format) (ice-9 ftw))

(define contexts "docs/legal/contexts")

(define (kinds findings sev)
  (sort (map (lambda (f) (symbol->string (finding-kind f)))
             (filter (lambda (f) (eq? sev (finding-severity f))) findings))
        string<?))

(display "\n── the shipped packs ──\n")
(define shipped (lint-law-packs contexts #:known (all-place-ids)))
(define shipped-errors (filter (lambda (f) (eq? 'error (finding-severity f))) shipped))
(when (pair? shipped-errors) (format #t "~a\n" (format-findings shipped-errors)))
(format #t "  errors ~a · info ~a\n" (length shipped-errors)
        (length (filter (lambda (f) (eq? 'info (finding-severity f))) shipped)))
(check-pred "every jurisdiction the shipped packs guard on is a place they place"
            (null? shipped-errors))
(check-pred "…and the crossings they name beyond the catalogue are reported, not flagged"
            (every (lambda (f) (eq? 'info (finding-severity f)))
                   (filter (lambda (f) (eq? 'crossing-beyond-catalogue (finding-kind f)))
                           shipped)))

;;; ─── a pack broken on purpose, one defect of each kind ───────────────────
(define dir (string-append (or (getenv "TMPDIR") "/tmp") "/law-lint-" (number->string (getpid))))
(mkdir dir)
(define broken (string-append dir "/broken.sexp"))
(call-with-output-file broken
  (lambda (port)
    (set-port-encoding! port "UTF-8")
    (write
     '((places
        ;; parent nobody places — the climb stops here
        ("ville" "Ville" "province-inconnue" locality () #f #f)
        ;; stands within a regime nobody places — that endpoint is never built
        ("bourg" "Bourg" "ville" locality ((within . ("bassin-fantome"))) #f #f)
        ;; a containment cycle — a climb that would not terminate on its own
        ("a" "A" "b" locality () #f #f)
        ("b" "B" "a" locality () #f #f))
       (rules
        ;; guards a jurisdiction no pack places: can NEVER fire, silently
        ((all-of (in-jurisdiction "atlantide") (on-crossing public-sale))
         ((forbid "rien" #f #f ((reason . "rien") (direction . #f))))
         "test/ungrounded" "(test)" "2020-01-01" reported "scope:test")
        ;; in force from a date after the one it ends on: never in force
        ((all-of (in-jurisdiction "ville") (on-crossing public-sale))
         ((forbid "jamais" #f #f ((reason . "jamais") (direction . #f))))
         "test/empty-window" "(test)" "2030-01-01" reported "scope:test" "2020-01-01")
        ;; derogates from a demand no pack demands — cancels nothing, silently
        ((all-of (in-jurisdiction "ville") (on-crossing public-sale))
         () "test/cancels-nothing" "(test)" "2020-01-01" verified "scope:test" #f
         ("Licence fantôme"))))
     port)
    (newline port)))

(define found (lint-law-packs dir))
(display "\n── a pack broken on purpose ──\n")
(format #t "~a\n" (format-findings found))
(define errs (kinds found 'error))
(check "each defect is caught, once"
       errs '("containment-cycle" "containment-cycle" "dangling-within"
              "empty-window" "orphan-place" "ungrounded-jurisdiction"))
(check "a derogation that cancels nothing is a warning, not an error"
       (kinds found 'warning) '("cancels-nothing"))
(check-pred "the ungrounded rule is named by its label"
            (any (lambda (f) (and (eq? 'ungrounded-jurisdiction (finding-kind f))
                                  (equal? "test/ungrounded" (finding-subject f))))
                 found))
(check-pred "the dangling `within` names the place that declared it"
            (any (lambda (f) (and (eq? 'dangling-within (finding-kind f))
                                  (equal? "bourg" (finding-subject f))))
                 found))

(display "\n── what KNOWN forgives ──\n")
;;; A pack may lean on places another tree already holds. Told those ids are
;;; known, the same folder is clean of the ungrounded finding — which is why the
;;; tool passes the live tree's ids in.
(define forgiven (lint-law-packs dir #:known '("atlantide" "province-inconnue" "bassin-fantome")))
(check-pred "ids the caller vouches for stop being ungrounded"
            (not (any (lambda (f) (memq (finding-kind f)
                                        '(ungrounded-jurisdiction orphan-place dangling-within)))
                      forgiven)))
(check-pred "…but a cycle and an impossible window are defects either way"
            (equal? (kinds forgiven 'error)
                    '("containment-cycle" "containment-cycle" "empty-window")))

(delete-file broken)
(rmdir dir)
(test-summary!)
