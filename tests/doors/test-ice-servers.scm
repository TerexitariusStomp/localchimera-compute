;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/doors/test-ice-servers.scm — the gateway says which servers a call
;;; finds its peers through, and the browser carries none of its own.
;;;
;;; What this pins:
;;;   • the env string splits into one server per url, blanks dropped, spaces
;;;     trimmed, and an empty string is no servers;
;;;   • the anonymous lobby's `ice-servers` door replies the list it was given,
;;;     with a relay's "username" and "credential" travelling beside its urls;
;;;   • a lobby given no list replies the default;
;;;   • no source file the browser loads names a STUN host: the list lives here.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-ice-servers.scm

(add-to-load-path "module")

(use-modules (localchimera test harness)
             (localchimera doors lobby)
             (goblins) (goblins vat) (goblins actor-lib on)
             (ice-9 rdelim) (ice-9 popen)
             (srfi srfi-1))

(define vat (spawn-vat))

(define (ask lobby . msg)
  (let ((answer 'unsettled))
    (with-vat vat
      (on (apply $ lobby msg)
          (lambda (v) (set! answer v))
          #:catch (lambda (e) (set! answer (list 'broken e)))))
    (let wait ((n 0))
      (when (and (eq? answer 'unsettled) (< n 100))
        (usleep 20000)
        (wait (+ n 1))))
    answer))

(define (spawn-lobby . ice)
  (with-vat vat
    (apply spawn ^lobby #f #f #f #f #f #f #f #f
           #f #f #f #f #f #f #f #f ice)))

(display "\n── 1. the env string is a list of servers ──\n")
(check "one url is one server"
       (ice-servers-from-urls "stun:a.example:3478")
       '((("urls" . "stun:a.example:3478"))))
(check "commas split, spaces trim, blanks drop"
       (ice-servers-from-urls " stun:a.example:3478 , ,turn:b.example:3478 ")
       '((("urls" . "stun:a.example:3478")) (("urls" . "turn:b.example:3478"))))
(check "the empty string is no servers" (ice-servers-from-urls "") '())
(check "no string is no servers" (ice-servers-from-urls #f) '())

(display "\n── 2. the door replies what the gateway holds ──\n")
(define relay '((("urls" . "turn:r.example:3478")
                 ("username" . "1893456000:EAid")
                 ("credential" . "c2VjcmV0"))))
(check "a configured list comes back whole, a relay's credential beside its urls"
       (ask (spawn-lobby relay) 'ice-servers) relay)
(check "a configured empty list is no servers, not the default"
       (ask (spawn-lobby '()) 'ice-servers) '())
(check "a lobby given no list replies the default"
       (ask (spawn-lobby) 'ice-servers)
       (ice-servers-from-urls %default-ice-urls))

(display "\n── 3. the browser holds no STUN host ──\n")
(define (grep-count)
  (let* ((port (open-pipe* OPEN_READ "grep" "-rlE" "(stun|turn)s?:[a-z0-9[]"
                           "browser/day-boot.js" "hoot/day-boot.scm" "ui/app/voice"))
         (files (let loop ((acc '()))
                  (let ((l (read-line port)))
                    (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
    (close-pipe port)
    files))
(check "day-boot and the voice modules name no ice url" (grep-count) '())

(test-summary!)
