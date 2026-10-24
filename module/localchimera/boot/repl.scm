;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/repl.scm — the operator's REPL inside the gateway: the live refs bound in (guile-user), a socket of mode 0600.
;;;
;;; An operator evaluates in (guile-user) over the REPL socket, where the
;;; prelude (boot/prelude) and the refs bound here stand — fleet-reconciler,
;;; gateway-vat, spend-policy, planner-vat, dev-commune — so tools reach them
;;; via repl-eval (tools/dev/dev-loop-close.scm). NO monero-wallet binding —
;;; that's the whole point of process isolation. Only spend-policy (the
;;; OCapN cap) is here. Every $ call on dev-commune from the REPL needs
;;; (with-vat planner-vat ...), same as every other economic commune.

(define-module (localchimera boot repl)
  #:use-module ((localchimera boot site) #:select (log!))
  #:use-module ((ice-9 threads) #:select (call-with-new-thread))
  #:use-module ((system repl server) #:select (make-unix-domain-server-socket run-server))
  #:export (start-repl!))

(define (start-repl! bindings)
  "BINDINGS, an alist of name → value, defined in (guile-user); then the REPL
server on its socket under $XDG_RUNTIME_DIR/localchimera (else /var/run/localchimera)."
  (let ((gu (resolve-module '(guile-user))))
    (for-each (lambda (b) (module-define! gu (car b) (cdr b))) bindings))
  (let* ((repl-sock-dir (or (and=> (getenv "XDG_RUNTIME_DIR")
                                   (lambda (d) (string-append d "/localchimera")))
                            "/var/run/localchimera"))
         (gateway-repl-sock (string-append repl-sock-dir "/gateway-repl.sock")))
    ;; Ensure the parent dir exists. On the host this is created
    ;; by tmpfiles; in containers we have to make it ourselves.
    (let loop ((path repl-sock-dir))
      (unless (file-exists? path)
        (loop (dirname path))
        (catch #t (lambda () (mkdir path)) (lambda _ #f))))
    (when (file-exists? gateway-repl-sock)
      (delete-file gateway-repl-sock))
    ;; Bind synchronously, lock down, then hand off to a serving
    ;; thread. The previous order raced: chmod could run before
    ;; the new thread had finished creating the socket file.
    (let ((sock (make-unix-domain-server-socket #:path gateway-repl-sock)))
      (chmod gateway-repl-sock #o600)
      (call-with-new-thread (lambda () (run-server sock))))
    (log! "  [gateway] REPL listening on ~a (mode 0600)~%" gateway-repl-sock)))
