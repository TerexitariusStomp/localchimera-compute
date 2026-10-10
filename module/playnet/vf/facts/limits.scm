;;; vf/facts/limits.scm — the sizes the gateway refuses past.
;;;
;;; Each is a bound a client has to stay within BEFORE it sends: a document or
;;; a picture over its bound is refused whole. So the page reads these same
;;; figures — ui/app/limits-catalogue.ts is the generated copy
;;; (tools/limits-emit.scm, `make check-limits-fresh`) — and sizes what it
;;; sends against them (the log's backup, a feedback body, the pictures of a
;;; read, the picture a count names).
;;;
;;; The module holds numbers and imports nothing, so the emit, the lobby, the
;;; evidence store and the static server all load it.

(define-module (playnet vf facts limits)
  #:export (%max-user-data-bytes %picture-max-chars %evidence-max-chars
            %feedback-max-bytes
            %report-max-bytes))

;; Per-AID sync payload cap. sync-contacts / sync-credentials / sync-taxonomy
;; and the log's backup all accept authenticated-but-arbitrary client data and
;; funnel through the lobby's %write-user-data!, so one bound covers them.
;; Since the credential path is an opaque encrypted blob by design, a size
;; limit is the only check left standing between an authenticated client and
;; the gateway's disk. Measured on the Scheme-written form of the payload.
(define %max-user-data-bytes (* 512 1024)) ; 512 KiB

;; A picture crosses in parts. A message larger than any the connection has
;; carried is answered by nothing at all (deploy/UPSTREAM-ISSUES.md §14), so
;; the browser sends a picture as parts and the session joins them. The whole
;; of one read's pictures is bounded, in base64 characters: a picture reduced
;; for reading is a few hundred kilobytes, and four of one thing is a
;; generous sitting.
(define %picture-max-chars (* 1200 1024))

;; The picture a count names: one reduced picture, in base64 characters.
(define %evidence-max-chars (* 400 1024))

;; A feedback body: text + context + one downscaled screenshot.
(define %feedback-max-bytes 262144)

;; A report: text only — what, where, and an optional way back. No screenshot,
;; no diagnostic, so a small bound; the pool it lands in is its own.
(define %report-max-bytes 16384)
