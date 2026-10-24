;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; utils/repl-client.scm — send one form to a live (system repl server) socket.
;;;
;;; `.claude/skills/repl/SKILL.md` documents the pattern this reuses, and
;;; `server/gateway.scm`'s own `gateway-repl.sock` (mode 0600, `(system repl
;;; server)`) already runs the far end of it: pipe a form's printed text
;;; through `nc -U`, strip the connection banner and every
;;; `scheme@(...)>` prompt, keep what is left. One Scheme door here, so
;;; `tools/dev/dev-plan.scm`/`dev-signal-cycle.scm`/`dev-loop-close.scm` share
;;; it instead of three copies of shell plumbing.
;;;
;;; The form's text goes through a temp file, `cat`, then `nc` — never
;;; interpolated into a shell string — so an arbitrary form (quotes,
;;; newlines, anything `write` produces) never needs escaping.

(define-module (localchimera utils repl-client)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module ((srfi srfi-13) #:select (string-trim string-trim-both string-prefix? string-null?))
  #:export (repl-eval repl-eval/read))

(define (banner-line? l)
  (or (string-prefix? "GNU Guile" l) (string-prefix? "Copyright" l)
      (string-prefix? "Guile comes with" l) (string-prefix? "This program is" l)
      (string-prefix? "under certain" l) (string-prefix? "Enter `" l)))

;; "scheme@(module-name)> " or "scheme@(module-name) [3]> ", the two shapes
;; the REPL's own prompt takes — stripped from the FRONT of a line, never
;; matched mid-line, so a value that happens to print the same text is safe
(define (strip-prompt l)
  (let loop ((l (string-trim l)))
    (if (string-prefix? "scheme@(" l)
        (let ((gt (string-index l #\>)))
          (if gt (loop (string-trim (substring l (+ gt 1)))) l))
        l)))

(define (clean-reply text)
  "TEXT, `nc`'s raw capture: the banner dropped, every line's own prompt
   prefix stripped, blank lines collapsed — the shape a human reading
   eval.sh's own output sees."
  (string-join
   (filter (lambda (l) (not (string-null? l)))
           (map strip-prompt
                (filter (lambda (l) (not (banner-line? l)))
                        (string-split text #\newline))))
   "\n"))

(define* (repl-eval sock-path form #:key (wait 0.5))
  "Connect to the Unix-domain (system repl server) socket at SOCK-PATH,
   send FORM (written, not displayed — a string in FORM still needs its
   own quotes to read back as one), and return its printed reply as one
   cleaned string (see clean-reply). #f when nothing could be read — the
   socket refused, the path is wrong, the far side is not up. WAIT is the
   pause `nc -q1` needs after EOF before it hands back what it read."
  (let ((tmp (string-append (or (getenv "TMPDIR") "/tmp") "/repl-eval-"
                            (number->string (getpid)) "-"
                            (number->string (random 1000000)) ".scm")))
    (call-with-output-file tmp
      (lambda (p) (write form p) (newline p)))
    (let ((out (false-if-exception
                (let* ((port (open-input-pipe
                              (string-append "{ cat " tmp "; sleep " (number->string wait)
                                            "; } | nc -q1 -U " sock-path)))
                       (text (get-string-all port)))
                  (close-pipe port)
                  text))))
      (false-if-exception (delete-file tmp))
      (and out (not (string-null? (string-trim-both out))) (clean-reply out)))))

(define* (repl-eval/read sock-path form #:key (wait 0.5))
  "repl-eval, with the REPL's own `$N = ` value echo stripped (best-
   effort — present only when FORM's value is what printed it, absent for
   a form whose own side effect did the printing) and the remainder read
   back as a Scheme datum. #f wherever repl-eval itself would answer #f,
   or when what is left does not read as one datum."
  (let ((reply (repl-eval sock-path form #:wait wait)))
    (and reply
         (let ((eq (string-index reply #\=)))
           (false-if-exception
            (call-with-input-string
             (if (and eq (string-prefix? "$" reply)) (substring reply (+ eq 1)) reply)
             read))))))
