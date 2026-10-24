;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/backends/router.scm — Multi-scope router
;;;
;;; The *composite* of the backend taxonomy. A ^scope-router presents
;;; the same backend protocol that ^scope-handler does, but internally
;;; fans out to one of N named scope-handlers based on per-command
;;; addressing.
;;;
;;; Addressing convention: a leading `@<name>` in the args targets that
;;; scope; absent, the router's default scope receives the command.
;;;
;;;   /inventory                  → default scope
;;;   /inventory @garden          → garden scope, args become ""
;;;   /inventory @kitchen lettuce → kitchen scope, args become "lettuce"
;;;
;;; The channel binds to one router ref and never knows it's not a
;;; single scope. Two backends, one protocol — composition lives at
;;; the economic layer, not in the channel.
;;;
;;; `wire-output` fans out to every handler so alerts from any scope
;;; reach the channel's sink. `available-commands` defers to the default
;;; handler — addressed-only commands aren't a thing.

(define-module (localchimera interface backends router)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:export (^scope-router
            make-scope-router
            parse-addressed-args))


;; =========================================================================
;; parse-addressed-args — pure helper
;; =========================================================================

(define (parse-addressed-args args)
  "Return (target-symbol . remaining-args).

   If ARGS starts with '@name [rest]', target-symbol is 'name and
   remaining-args is rest (trimmed). Otherwise target-symbol is #f
   and remaining-args is the trimmed args verbatim."
  (let ((trimmed (string-trim-both (or args ""))))
    (cond
     ((string-null? trimmed) (cons #f ""))
     ((not (char=? (string-ref trimmed 0) #\@))
      (cons #f trimmed))
     (else
      (let* ((sp (string-index trimmed #\space))
             (name (if sp
                       (substring trimmed 1 sp)
                       (substring trimmed 1)))
             (rest (if sp
                       (string-trim-both (substring trimmed (+ sp 1)))
                       "")))
        (cons (string->symbol name) rest))))))


;; =========================================================================
;; ^scope-router — fan-out backend
;; =========================================================================

(define (^scope-router bcom default-name handlers)
  ;; default-name : symbol — which scope unaddressed commands hit
  ;; handlers     : hashmap symbol → handler-ref (any backend-protocol actor)

  (define (lookup name)
    (hashmap-ref handlers name #f))

  (methods

    ;; --- Backend protocol ---

    ((handle request-ctx cmd-name args)
     (let* ((parsed   (parse-addressed-args args))
            (addr     (car parsed))
            (rest     (cdr parsed))
            (target   (or addr default-name))
            (handler  (lookup target)))
       (cond
        ((not handler)
         (list 'error (format #f "Unknown scope: ~a" target)))
        (else
         ;; Forward sync — handler returns ('response …)/('error …).
         ;; The channel called us via <-, so this nested $ stays inside
         ;; this one vat turn, then the outer call's vow fires.
         ($ handler 'handle request-ctx cmd-name rest)))))

    ((available-commands)
     (let ((h (lookup default-name)))
       (if h ($ h 'available-commands) '())))

    ((wire-output sink-ref)
     ;; Fan out: every handler's alerts route to the channel's sink.
     (hashmap-fold
      (lambda (k h acc)
        (<-np h 'wire-output sink-ref)
        acc)
      'ok handlers))

    ;; --- Introspection ---

    ((default-scope) default-name)

    ((scope-names)
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() handlers))

    ((handler-for name)
     (lookup name))))


;; =========================================================================
;; Convenience constructor
;; =========================================================================

(define* (make-scope-router default-name handler-alist)
  "Spawn a ^scope-router. DEFAULT-NAME is the symbol naming the default
   scope. HANDLER-ALIST is a list of (name . handler-ref) pairs; every
   handler must implement the backend protocol. The DEFAULT-NAME entry
   must exist in HANDLER-ALIST.

   Call within a vat context."
  (let ((handlers (fold (lambda (pair acc)
                          (hashmap-set acc (car pair) (cdr pair)))
                        (hashmap)
                        handler-alist)))
    (unless (hashmap-ref handlers default-name #f)
      (error "make-scope-router: default-name not present in handler-alist"
             default-name (map car handler-alist)))
    (spawn ^scope-router default-name handlers)))
