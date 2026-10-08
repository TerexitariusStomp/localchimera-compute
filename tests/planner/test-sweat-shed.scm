;;; test-sweat-shed.scm — the sodium a working body loses comes from the SHED's
;;; own climate record and from whether that body is acclimated to it.
;;;
;;; Two [DRAFT]s closed, and this test is what closes them:
;;;
;;;   · The working TEMPERATURE was a five-row table of round numbers keyed by a
;;;     coarse region name — "temperate 20 °C" — while every bioregion already
;;;     carried sixty years of ERA5 and its derived file already stated the mean
;;;     of its warmest quarter (bioclim BIO10, data/emit-derived.scm). The shed
;;;     knows; the catalogue now asks it.
;;;   · ACCLIMATION was a comment. A body that has worked this heat for a
;;;     fortnight reabsorbs sodium before it reaches the skin — the same litres
;;;     of sweat carry 15–25 mmol/L less — so a settled worker and a new arrival
;;;     in the same field had identical floors, which is measurably wrong.
;;;
;;; Nothing here is new machinery. Every layer of the catalogue already received
;;; the full ctx; these are two more things the ctx says.
;;;
;;; Run:  guile --no-auto-compile -L module tests/planner/test-sweat-shed.scm

(use-modules (srfi srfi-1) (ice-9 format) (ice-9 textual-ports)
             ((srfi srfi-13) #:select (string-contains string-index string-trim-both)))
(let ((self (find file-exists? (filter string? (cons (false-if-exception (current-filename))
                                                     (command-line))))))
  (when self (add-to-load-path (string-append (dirname self) "/../../module"))))
(use-modules (playnet planner knowledge catalogues subsistence))
;; the sheds themselves. Each imports its own generated derived file, which is
;; where *<shed>-derived-warm-quarter-degc* comes from. doon-valley is a MODULE
;; and belongs in the import above, not in this list: a filename inside a data
;; list reaches `load` without any scanner seeing it, and loading a module that
;; way captures the rest of the caller into its namespace.
(use-modules (playnet planner knowledge worlds doon-valley))
(use-modules (playnet planner knowledge worlds doon-shed)
             (playnet planner knowledge worlds cascadia)
             (playnet planner knowledge worlds berlin)
             (playnet planner knowledge worlds bay-area))

(define pass 0) (define fail 0)
(define (ok? name p)
  (if p (begin (set! pass (+ pass 1)) (format #t "  ok: ~a~%" name))
        (begin (set! fail (+ fail 1)) (format #t "  ✗  ~a~%" name))))
(define (≈ a b) (< (abs (- a b)) 1e-6))

;;; ─── the shed states its own temperature ─────────────────────────────────
(display "\n── what each shed says it works at (warmest quarter, its own ERA5) ──\n")
(define SHEDS '("doon" "cascadia" "berlin" "bay-area"))
(for-each (lambda (s)
            (format #t "  ~10a ~5,1f °C   ⇒ ~6,1f mg Na over an 8 h shift~%"
                    s (working-degc `((shed . ,s)))
                    (sweat-sodium-mg (working-degc `((shed . ,s))) 8)))
          SHEDS)

;; The lazy resolution is the point: no shed calls register-shed-working-degc!.
;; Loading a shed binds its generated global, and the catalogue finds it at the
;; moment a floor is computed — so the two have no load-order relation at all.
(ok? "a loaded shed's temperature is found with no registration call"
     (every (lambda (s) (number? (shed-derived-degc s))) SHEDS))
(ok? "Berlin works at its own 19.9 °C, from its own record"
     (≈ 19.9 (working-degc '((shed . "berlin")))))
(ok? "the Doon Valley is far hotter than any region label said (26.8 °C)"
     (> (working-degc '((shed . "doon"))) 26.0))

;;; ─── the shed BEATS the coarse table, and the table survives as fallback ──
(display "\n── shed vs the [DRAFT] region table ──\n")
(define doon-ctx  '((shed . "doon")     (region . "temperate") (labour-hours . 8)))
(define plain-ctx '((region . "temperate") (labour-hours . 8)))
(define bay-ctx   '((shed . "bay-area") (region . "temperate") (labour-hours . 8)))
(format #t "  a Doon worker tagged \"temperate\" : ~5,1f °C (the shed wins over the label)~%"
        (working-degc doon-ctx))
(format #t "  the same worker in no shed at all : ~5,1f °C (the table, honestly coarse)~%"
        (working-degc plain-ctx))

(ok? "the shed's real figure overrides the coarse region label"
     (> (working-degc doon-ctx) (working-degc plain-ctx)))
(ok? "with no shed the coarse table still answers — no error, no zero"
     (≈ 20.0 (working-degc plain-ctx)))
(ok? "an unknown shed falls through to the table rather than inventing a number"
     (≈ 20.0 (working-degc '((shed . "atlantis") (region . "temperate")))))
(ok? "a stated figure wins over both"
     (≈ 31.5 (working-degc '((working-degc . 31.5) (shed . "berlin")))))
;; and the Bay Area is COOLER than the label guessed — the correction runs both ways.
(ok? "the shed corrects downward too (bay-area 16.8 < temperate 20)"
     (< (working-degc bay-ctx) (working-degc plain-ctx)))

;;; ─── acclimation ─────────────────────────────────────────────────────────
;;; Unacclimated is the DEFAULT and the HIGHER floor. That direction is the
;;; safe one: assuming everyone is seasoned would under-feed exactly the person
;;; most at risk — the new arrival, in their first hot fortnight.
(display "\n── the same shift, a settled worker and a new arrival ──\n")
(define hot (working-degc '((shed . "doon"))))
(define new-arrival (sweat-sodium-mg hot 8))
(define settled     (sweat-sodium-mg hot 8 #t))
(format #t "  new arrival : ~6,1f mg Na    settled : ~6,1f mg Na    (~,0f % less)~%"
        new-arrival settled (* 100 (- 1 (/ settled new-arrival))))

(ok? "acclimation lowers the sodium a shift costs"
     (< settled new-arrival))
(ok? "…by exactly the concentration it takes off (45 → 25 mmol/L), not a guess"
     (≈ (/ settled new-arrival) (/ 25.0 45.0)))
(ok? "unacclimated is the DEFAULT — the higher floor protects the new arrival"
     (≈ new-arrival (sweat-sodium-mg hot 8 #f)))

;;; ─── it reaches the FLOOR, not just the helper ───────────────────────────
;;; The term lives in L3, where heat meets hours; L1 is a body at rest and must
;;; not move. So the whole fold is what the test reads, not sweat-sodium-mg.
(display "\n── the floors themselves (mg sodium/day) ──\n")
(define (na ctx) (assoc-ref (subsistence-floors ctx) "sodium"))
(define (na-ul ctx)
  (sub-ul (find (lambda (n) (equal? "sodium" (sub-spec n))) (subsistence-profile ctx))))
(define worker    '((sex . "M") (age . 34) (labour-hours . 8) (shed . "doon")))
(define worker-ac '((sex . "M") (age . 34) (labour-hours . 8) (shed . "doon") (acclimated . #t)))
(define at-rest   '((sex . "M") (age . 34) (labour-hours . 0) (shed . "doon")))
(define cool-work '((sex . "M") (age . 34) (labour-hours . 8) (shed . "bay-area")))
(for-each (lambda (p) (format #t "  ~28a ~7,0f~%" (car p) (na (cdr p))))
          (list (cons "Doon, new arrival"   worker)
                (cons "Doon, acclimated"    worker-ac)
                (cons "Doon, no labour"     at-rest)
                (cons "Bay Area, same 8 h"  cool-work)))

(ok? "a hot shift raises the sodium floor above rest"
     (> (na worker) (na at-rest)))
(ok? "acclimation lowers that floor, and the fold carries it through"
     (< (na worker-ac) (na worker)))
(ok? "the acclimated worker is still owed more than a body at rest"
     (> (na worker-ac) (na at-rest)))
(ok? "no labour ⇒ no sweat term, however hot the shed"
     (≈ (na at-rest) (na '((sex . "M") (age . 34) (labour-hours . 0) (shed . "bay-area")))))
(ok? "the same 8 h in a cooler shed costs less sodium"
     (< (na cool-work) (na worker)))
;; the sweat term is ADDITIVE — grams the body lost — so it must not scale the
;; ceiling away: the UL rises with it, or a hot shift becomes infeasible.
(ok? "the ceiling rises with the floor (an additive loss, not a ratio)"
     (> (na-ul worker) (na-ul at-rest)))

;;; ─── the browser must not drift ──────────────────────────────────────────
;;; nutrition.js carries the same curve so the dial can show a floor without a
;;; round trip, and it carries the shed temperatures as a literal table. A
;;; literal copied by hand is the thing that drifts, so the test reads the JS
;;; and compares it to the generated Scheme rather than trusting a comment.
(define js-path
  (find file-exists? (list "browser/app/nutrition.js"
                           (string-append (dirname (or (false-if-exception (current-filename)) "."))
                                          "/../../browser/app/nutrition.js"))))
(define js (and js-path (call-with-input-file js-path
                          (lambda (p) (get-string-all p)))))

;; pull `key: 12.3` pairs out of the SHED_WORKING_DEGC literal
(define (js-shed-table text)
  (let* ((i (string-contains text "SHED_WORKING_DEGC"))
         (a (and i (string-index text #\{ i)))
         (b (and a (string-index text #\} a)))
         (body (and b (substring text (+ a 1) b))))
    (filter-map
     (lambda (piece)
       (let* ((kv (string-split piece #\:))
              (k (and (= 2 (length kv))
                      (string-trim-both (car kv) (lambda (c) (or (char-whitespace? c) (eqv? c #\"))))))
              (v (and k (string->number (string-trim-both (cadr kv))))))
         (and k v (cons k v))))
     (string-split (or body "") #\,))))

(display "\n── browser ⇄ engine, the shed table ──\n")
(define js-table (if js (js-shed-table js) '()))
(for-each (lambda (kv)
            (format #t "  ~10a js ~5,1f   scheme ~5,1f~%"
                    (car kv) (cdr kv) (or (shed-derived-degc (car kv)) -999)))
          js-table)

(ok? "nutrition.js states a temperature for every shed the engine knows"
     (and (pair? js-table)
          (every (lambda (s) (assoc s js-table)) SHEDS)))
(ok? "…and every one of them matches the generated derived file"
     (every (lambda (kv) (≈ (cdr kv) (or (shed-derived-degc (car kv)) -999))) js-table))

(format #t "~%=== Results: ~a passed, ~a failed ===~%" pass fail)
(exit (if (zero? fail) 0 1))
