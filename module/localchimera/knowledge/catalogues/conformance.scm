;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; conformance-catalogue.scm — the CONFORMANCE fragility catalogue.
;;;
;;; localchimera.typ §2.0.8 (and social-means §"Inspection", §1110): "the margin above each
;;; breakdown floor — how much inspection and reserve buys — is priced by the barrier,"
;;; and WHICH fragilities the federation tracks, how steeply their curves rise, are
;;; "political-economic choices, made by stewardship scopes and ratified at the UC
;;; level." A conformance edge's *verification freshness* is exactly such a limit: it
;;; degrades gracefully (drift) and, unwatched, fails — so its fragility profile
;;; belongs in the governed catalogue, NOT hard-coded as a bare `mk-frag` weight in a
;;; solve.
;;;
;;; This is the conformance twin of eco-catalogue.scm's planetary catalogue. Both read
;;; through the SAME `frag` kind (φ(s) = −w·log s, tension-kinds.scm) and the SAME
;;; `catalogue->policy` / `catalogue->wire` compilers (catalogue.scm) — a conformance
;;; profile is one more fragility agent, differing only in its content (a freshness
;;; margin, not a carbon budget). Custodied by the same `^tension-registry` actor: the
;;; confidence barrier's steepness `w` becomes a ratified DATUM, entering the plan as
;;; one row.
;;;
;;; a conformance fragility agent (display-carrying, length 10):
;;;   (spec 'rate lo hi alpha w "source" label group unit)
;;;     spec  — the bare conformance-freshness spec the barrier sits on
;;;     s     — the freshness MARGIN reaching the barrier (1 = just verified, →0 = due)
;;;     lo hi — the margin range: lo = critical (recert urgent), hi = healthy
;;;     alpha — precaution: where in [lo,hi] the operative tip sits (0.5 = central)
;;;     w     — steepness: how loudly the plan is pulled toward re-verifying (= WCONF)
;;;
;;; DRAFT figures — to be ratified at the UC level, like every other catalogue number.
;;;
;;; Run:  guile -L module module/localchimera/knowledge/catalogues/conformance.scm

(define-module (localchimera knowledge catalogues conformance)
  #:use-module ((localchimera utils host) #:select (getenv))
  #:use-module (srfi srfi-1)
  #:export (*conformance-catalogue* conformance-frag-weight))

(define *conformance-catalogue*
  (list
   ;; The generic specification-conformance profile: any edge whose freshness the plan
   ;; leans on is held above a breakdown margin by this barrier. One profile serves
   ;; skills, instruments, and batches alike (the a* of §1091 is per-edge via reliance,
   ;; not per-profile), so a single governed row prices them all — stewardship scopes
   ;; may register sharper profiles for edges that drift faster or fail harder.
   '("conformance-confidence" rate 0.15 1.0 0.5 0.5
     "DRAFT — steepness w is the confidence barrier weight of the in-plan inspection model (docs/legal/inspection-in-plan.md); ratify at UC"
     "conformance freshness" "verification" "freshness-margin")))

;; convenience: the governed steepness w for a conformance profile (what the in-plan
;; confidence barrier −w·log(V−Q) should read, instead of a hard-coded constant).
(define* (conformance-frag-weight #:optional (spec "conformance-confidence")
                                             (catalogue *conformance-catalogue*))
  (let ((e (find (lambda (e) (and (pair? e) (equal? (car e) spec))) catalogue)))
    (and e (list-ref e 5))))

;; standalone demo (skipped when loaded as a library fragment — no use-modules, so it
;; is safe when spliced into the umbrella via include-from-path)
;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (and (not (getenv "CONFORMANCE_LIB"))
             (equal? (current-filename)
                     (and (pair? (command-line)) (car (command-line)))))
    (display "\nconformance catalogue: ")
    (display (length *conformance-catalogue*)) (display " profile(s)\n")
    (display "  conformance-confidence steepness w = ")
    (display (conformance-frag-weight)) (newline)))
 (else))
