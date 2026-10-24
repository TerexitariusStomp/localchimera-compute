;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/adapters/comms-publish.scm — the gated publish layer.
;;;
;;; Transport-agnostic publishing for the comms flow, with two safety rails so
;;; nothing reaches the network by accident:
;;;   • ^dry-run-publisher — the DEFAULT. Logs the post, sends nothing.
;;;   • publish-with-gate  — the HUMAN GATE. Fail-closed: publishes ONLY if an
;;;                          explicit approve? predicate says yes; otherwise holds.
;;;
;;; An "adapter" is any actor answering (post text) — ^dry-run-publisher here, or
;;; spawn-mastodon (platforms.scm) for a real sovereign channel. The composed,
;;; entailment-fenced, mandate-gated text arrives from the planner side; this is
;;; only the send.

(define-module (localchimera interface adapters comms-publish)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 format)
  #:export (^dry-run-publisher
            publish-post
            publish-with-gate))

;; ^dry-run-publisher — the SAFE DEFAULT. Logs the post, sends NOTHING.
(define (^dry-run-publisher _bcom label)
  (methods
    ((post text)
     (format #t "~%[DRY-RUN ~a] would publish:~%  ~a~%" label text)
     `((ok . #t) (dry-run . #t) (label . ,label) (text . ,text)))))

;; publish-post — send TEXT via ADAPTER (any actor answering (post text)).
(define (publish-post adapter text) ($ adapter 'post text))

;; publish-with-gate — the HUMAN GATE. Publish only if (approve? text) is true;
;; otherwise HOLD and send nothing. approve? defaults to REFUSING (fail-closed):
;; a real post requires a deliberate approval, never a default.
(define* (publish-with-gate adapter text #:key (approve? (lambda (_) #f)))
  (if (approve? text)
      (publish-post adapter text)
      `((ok . #f) (held . #t) (reason . "no approval") (text . ,text))))
