;;; engine/fragility.scm — the engine's side of a fragility: the grid, as the one dispatch.
;;;
;;; The record and its constructors are (playnet vf formulas fragility); this
;;; fragment routes each fragility to the table whose collector reads its scale.

;; ── the grid, as the one dispatch ───────────────────────────────────────────
;; Every cell of (extent × window) routes to the table whose collector already
;; reads that scale. This procedure IS the grid: adding a scale means adding a
;; line here, not a table elsewhere, and a combination nobody had spelled before
;; (a container's per-period yield; a commons' lifetime total) is reachable
;; without new machinery. The tables stay as they were, so every existing call
;; site and every existing test reads exactly what it did.
(define (route-fragility! f)
  (let ((p (fragility-profile f))
        (k (fragility-key f))
        (w (fragility-window f)))
    ;; SIDE is honoured, never guessed: a floor is a LEVEL to hold, and only a
    ;; located good has a level. A floor-sided spec / container / commons would
    ;; be a band tiled per cell (the way *frag-spec* tiles a ceiling) — until
    ;; that is built it is an error here, not a ceiling by accident.
    (when (and (eq? (fragility-side f) 'floor) (not (eq? (fragility-kind f) 'good)))
      (error "a floor-sided fragility holds a LEVEL, and only a located good has one — extent:"
             (fragility-extent f)))
    (case (fragility-kind f)
      ((good)      (if (eq? (fragility-side f) 'floor)
                       (apply-repro-bands!                ; a level to HOLD: the good's band, floor with margin
                        (list (list k (list (car p) (cadr p) (caddr p)) #f (cadddr p))))
                       (hash-set! *frag-cap* k p)))      ; a limit on a DRAW: one cell, per period
      ((spec)      (if (eq? w 'horizon)
                       (hash-set! *frag-budget* k p)    ; that spec, summed over time
                       (hash-set! *frag-spec* k p)))    ; that spec, each period
      ((contained) (hash-set! *frag-container* k p))    ; its contents, at its own cell
      ((within)    (hash-set! *frag-within* k (list p (fragility-specs f) w
                                                    (fragility-level f))))
      (else (error "unknown fragility extent" (fragility-extent f))))))
