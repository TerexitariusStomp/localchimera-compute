;;; module/playnet/ui/zone-format.scm — DDMRP zone classification for rendering
;;;
;;; The live planner computes buffer zones as typed <buffer-zone> records
;;; (module/playnet/planner/ddmrp/buffer-zones.scm) and its own
;;; buffer-status (module/playnet/planner/ddmrp/buffers.scm) operates on
;;; those records. The SXML rendering layer, however, works with plain
;;; alist snapshots (tor/toy/tog as bare keys) coming off the wire — so it
;;; needs its own tiny, presentation-only copy of the same threshold logic
;;; rather than coercing snapshots into planner records just to draw a bar.
;;;
;;; This is UI-alist zone-classification math only — not the DDMRP
;;; algorithm itself (ADU/DLT/NFP/replenishment), which lives solely in
;;; the live planner modules above. Extracted from the deprecated DDMRP
;;; module, where this rendering-only logic was co-located with retired
;;; planning code.
;;;
;;; Hoot/WASM compatible.

(define-module (playnet ui zone-format)
  #:use-module (playnet utils alist)
  #:export (classify-zone
            classify-zone/no-stockout
            buffer-status))

(define (classify-zone value tor toy tog)
  "Classify a numeric VALUE into a zone symbol given thresholds."
  (cond
   ((<= value 0)   'stockout)
   ((<= value tor) 'red)
   ((<= value toy) 'yellow)
   ((<= value tog) 'green)
   (else           'excess)))

(define (classify-zone/no-stockout value tor toy tog)
  "Like classify-zone but without stockout (for NFP which can be negative)."
  (cond
   ((<= value tor) 'red)
   ((<= value toy) 'yellow)
   ((<= value tog) 'green)
   (else           'excess)))

(define (buffer-status onhand bz)
  "Current on-hand buffer status — physical position relative to zone
   boundaries. BZ is a plain alist with 'tor/'toy/'tog (and optional
   'tipping-point) keys, as found in UI snapshots.
   Returns an alist with onhand, pct, zone, red-pct, and optional
   tipping-point-breached."
  (let* ((tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         (pct (if (> tog 0) (* (/ onhand tog) 100) 0))
         (red-pct (if (> tor 0) (* (/ onhand tor) 100) 0))
         (zone (classify-zone/no-stockout onhand tor toy tog))
         (tipping (alist-ref bz 'tipping-point #f))
         (base `((onhand . ,onhand)
                 (pct . ,pct)
                 (zone . ,zone)
                 (red-pct . ,red-pct))))
    (if tipping
        (alist-set base 'tipping-point-breached (< onhand tipping))
        base)))
