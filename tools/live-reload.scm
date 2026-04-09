#!/usr/bin/env -S guile --no-auto-compile
!#
;;; tools/live-reload.scm — push a saved Scheme file into a running REPL.
;;;
;;; Used by tools/live-watch.sh (or directly from an editor save hook) to
;;; implement Hoot 0.8 live hacking without recompiling the wasm bundle.
;;; Computes the module name from the file path, opens a TCP connection
;;; to a running REPL relay (`(hoot web-server)` listens on 37146 by
;;; default), switches the REPL into the file's module, sends the file
;;; body, then calls (refresh!) so the page re-renders.
;;;
;;; Usage:
;;;   tools/live-reload.scm module/weave/ui/room.scm
;;;
;;; Options (env vars override the defaults):
;;;   PLAYNET_REPL_HOST   default 127.0.0.1
;;;   PLAYNET_REPL_PORT   default 37146
;;;   PLAYNET_REPL_TIMEOUT_MS  default 1500  (max time to wait for output)
;;;   PLAYNET_NO_REFRESH  if non-empty, do NOT call (refresh!) at the end
;;;
;;; The script is intentionally generic. The route table at the bottom
;;; maps repo-relative path prefixes to (load-path-root . module-prefix)
;;; — add a row when you wire up a new live-hackable subtree.
;;;
;;; Exit codes:
;;;   0  - bytes flushed to the REPL (the REPL may still error inside the
;;;        wasm; that's logged to stderr but not propagated)
;;;   1  - usage error / file not found / no route matches
;;;   2  - couldn't connect to the REPL (relay isn't running)
;;;
;;; This script never fails the editor save: failures are logged to
;;; stderr and we move on. Live-hacking should be additive comfort, not
;;; a footgun.

(use-modules (ice-9 match)
             (ice-9 textual-ports)
             (ice-9 rdelim)
             (ice-9 format)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-9)
             (srfi srfi-13))

;; Ignore SIGPIPE so a half-closed socket (e.g. the relay hung up because
;; no browser tab is attached yet) doesn't kill the script — we want to
;; print a friendly diagnostic instead.
(sigaction SIGPIPE SIG_IGN)

;;; ── Config / route table ────────────────────────────────────────────────────

(define (env-or var default)
  (or (and=> (getenv var) (lambda (s) (if (string-null? s) default s)))
      default))

(define %repl-host    (env-or "PLAYNET_REPL_HOST" "127.0.0.1"))
(define %repl-port    (string->number (env-or "PLAYNET_REPL_PORT" "37146")))
(define %timeout-ms   (string->number (env-or "PLAYNET_REPL_TIMEOUT_MS" "1500")))
(define %no-refresh?  (let ((v (getenv "PLAYNET_NO_REFRESH")))
                        (and v (not (string-null? v)))))

;; Route table: each row maps a repo-relative path prefix to the
;; "module root" — the prefix portion of the path that should be
;; stripped off before splitting the rest into a module name. The
;; entries are tried in order, first match wins.
;;
;; "module/" → strip "module/", split rest, so
;;    module/weave/ui/room.scm → (weave ui room)
;;    module/playnet/ui/calendar.scm → (playnet ui calendar)
;;
;; Add new rows for new live-hackable subtrees.

;; Each row is (path-prefix . spec).
;;   spec = string  → strip-prefix mode (path-prefix → tail → modname list).
;;                    The string is the prefix to strip from the path.
;;   spec = list    → literal module name; used for top-level scripts that
;;                    don't have a (define-module …) form and live in
;;                    (guile-user) directly.
;;
;; Order matters: first matching prefix wins. Put the most specific path
;; prefixes first so a generic catch-all doesn't shadow them.
(define %routes
  '(("browser/repl.scm" . (guile-user))
    ("module/" . "module/")))

;;; ── Path → module name ──────────────────────────────────────────────────────

(define (path->module path)
  "Convert a repo-relative PATH into a module-name list. Routes are
   either a string-prefix-strip rule (module/weave/ui/room.scm → (weave
   ui room)) or a literal modname for top-level scripts (browser/repl.scm
   → (guile-user)). Returns #f if no route matches."
  (define (try routes)
    (cond
     ((null? routes) #f)
     ((string-prefix? (caar routes) path)
      (let ((spec (cdar routes)))
        (cond
         ((list? spec) spec)            ; literal modname
         ((string? spec)                ; strip-prefix → modname
          (let ((tail (substring path (string-length spec))))
            (and (string-suffix? ".scm" tail)
                 (let ((stem (substring tail 0 (- (string-length tail) 4))))
                   (map string->symbol (string-split stem #\/))))))
         (else #f))))
     (else (try (cdr routes)))))
  (try %routes))

;;; ── Body extraction ─────────────────────────────────────────────────────────

(define (read-file-text path)
  (call-with-input-file path get-string-all))

(define (strip-define-module text)
  "Return TEXT with the first top-level (define-module …) form replaced by
whitespace of the same length, so the in-REPL parser ignores it but line
numbers in any error message are preserved. Newlines inside the form
are kept verbatim — only non-newline characters become spaces."
  (let ((idx (string-contains text "(define-module")))
    (if (not idx)
        text
        ;; Walk parens from idx to find the matching close.
        (let loop ((i (+ idx 1)) (depth 1))
          (cond
           ((>= i (string-length text)) text) ; malformed; give up
           ((zero? depth)
            (let ((blanked (string-map (lambda (c)
                                         (if (char=? c #\newline) c #\space))
                                       (substring text idx i))))
              (string-append (substring text 0 idx)
                             blanked
                             (substring text i))))
           ((char=? (string-ref text i) #\() (loop (+ i 1) (+ depth 1)))
           ((char=? (string-ref text i) #\)) (loop (+ i 1) (- depth 1)))
           (else (loop (+ i 1) depth)))))))

;;; ── Wire protocol — TCP REPL relay ──────────────────────────────────────────
;;;
;;; The Hoot REPL prompt is "(module-name)> ". We wait for it to know the
;;; REPL is ready (or has finished evaluating a form). Output between
;;; prompts is the eval result (and any printf debug from the user code);
;;; we copy it to stderr so the editor / inotify caller can see it.

(define (millis)
  ;; Inexact ms is fine for deadline arithmetic; we never need exact here.
  (let ((tv (gettimeofday)))
    (+ (* 1000 (car tv)) (/ (cdr tv) 1000))))

(define prompt-suffix "> ")

(define-record-type <drain-result>
  (make-drain-result kind text)
  drain-result?
  (kind  drain-result-kind)   ; 'prompt | 'eof | 'timeout
  (text  drain-result-text))  ; accumulated text from this drain

(define (drain-until-prompt sock max-wait-ms tag)
  "Read from SOCK until we see a line ending with \"> \" (the Hoot REPL
prompt), the socket closes, or MAX-WAIT-MS elapses. Echoes interesting
output to stderr (prefixed with TAG) and returns a <drain-result>."
  (let ((deadline (+ (millis) max-wait-ms))
        (acc '()))
    (define (echo kind)
      (let ((trimmed (string-trim-both (list->string (reverse acc)))))
        (unless (or (string-null? trimmed)
                    (and (= (string-length trimmed) 1)
                         (char=? (string-ref trimmed 0) #\>)))
          (format (current-error-port) "[~a] ~a~%" tag trimmed))
        (make-drain-result kind (list->string (reverse acc)))))
    (let loop ()
      (cond
       ((> (millis) deadline) (echo 'timeout))
       ((char-ready? sock)
        (let ((c (false-if-exception (read-char sock))))
          (cond
           ((or (not c) (eof-object? c)) (echo 'eof))
           (else
            (set! acc (cons c acc))
            (let ((s (list->string (reverse acc))))
              (if (and (>= (string-length s) (string-length prompt-suffix))
                       (string-suffix? prompt-suffix s))
                  (echo 'prompt)
                  (loop)))))))
       (else
        (usleep 10000) ; 10 ms
        (loop))))))

(define (no-control-websocket? text)
  ;; The relay greets us with this when no browser tab is attached.
  (and text (string-contains text "No control WebSocket")))

(define (send-line sock line)
  ;; Wrap the writes so a closed socket (relay hung up between drains)
  ;; doesn't crash the script — drain-until-prompt is the source of
  ;; truth for "is the connection alive".
  (false-if-exception
   (begin (display line sock) (newline sock) (force-output sock))))

;;; ── Main ────────────────────────────────────────────────────────────────────

(define (die fmt . args)
  (apply format (current-error-port) (string-append "live-reload: " fmt "~%") args)
  (exit 1))

(define (warn fmt . args)
  (apply format (current-error-port) (string-append "live-reload: " fmt "~%") args))

(define (push-file path)
  (unless (file-exists? path)
    (die "no such file: ~a" path))
  (let ((modname (path->module path)))
    (unless modname
      (die "no route for ~a (add a prefix to %routes in tools/live-reload.scm)"
           path))
    (let* ((text (read-file-text path))
           (body (strip-define-module text)))
      (let ((sock (false-if-exception (socket PF_INET SOCK_STREAM 0))))
        (unless sock
          (warn "couldn't open socket"); not fatal — just exit-2
          (exit 2))
        (let ((addr (false-if-exception
                     (connect sock AF_INET (inet-pton AF_INET %repl-host) %repl-port))))
          (unless addr
            (warn "no REPL relay at ~a:~a (is `make weave-dev` / `make serve-dev` running?)"
                  %repl-host %repl-port)
            (close-port sock)
            (exit 2)))
        ;; Drain whatever the welcome banner emitted. If the relay
        ;; closed on us with "No control WebSocket", that just means
        ;; no browser tab is attached yet — exit cleanly so the
        ;; editor doesn't show this as an error.
        (let ((welcome (drain-until-prompt sock 500 "welcome")))
          (when (no-control-websocket? (drain-result-text welcome))
            (warn "no browser tab attached to ~a:~a yet — open the page and retry"
                  %repl-host %repl-port)
            (close-port sock)
            (exit 0))
          (when (eq? (drain-result-kind welcome) 'eof)
            (warn "relay closed connection before sending a prompt")
            (close-port sock)
            (exit 0)))
        (format (current-error-port)
                "live-reload: ~a → ~a~%"
                path modname)
        ;; ,m switches the REPL into the file's module so the
        ;; subsequent (define …)s replace bindings there (with -g2
        ;; mutable-defs).
        (send-line sock (format #f ",m ~s" modname))
        (drain-until-prompt sock %timeout-ms "module")
        (send-line sock body)
        (drain-until-prompt sock %timeout-ms "body")
        ;; Pop back to (guile-user) so (refresh!) resolves to the
        ;; entry-point's binding, not whatever module we just edited.
        (unless %no-refresh?
          (send-line sock ",m (guile-user)")
          (drain-until-prompt sock %timeout-ms "back")
          ;; Catch in case (refresh!) isn't bound (e.g. you connected
          ;; before the entry point finished booting).
          (send-line sock
                     "(catch #t (lambda () (refresh!)) (lambda _ #f))")
          (drain-until-prompt sock %timeout-ms "refresh"))
        (false-if-exception (close-port sock))
        (exit 0)))))

(define (main args)
  (match args
    ((_ path)         (push-file path))
    ((_ "--help")     (display "usage: live-reload.scm <repo-relative-path>\n")
                      (exit 0))
    (_                (die "usage: live-reload.scm <repo-relative-path>"))))

(main (command-line))
