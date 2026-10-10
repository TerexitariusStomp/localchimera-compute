;;; federation-wire-fixture.scm — the two-commune economy the wire tests solve.
;;;
;;; The same economy test-federation-pull.scm and test-federation-live.scm
;;; solve: commune A (Granary) is flour-rich and SUPPLIES flour; commune B
;;; (Table) has no flour, DRAWS it and bakes bread locally to meet a demand
;;; of 40. Flour is the INTERMEDIATE that crosses and #:never-raw, so B's only
;;; flour is what crosses the boundary — the coupling binds and the dual is
;;; the pull on flour.
;;;
;;; Each commune's record is built by `commune->scope-record` from its OWN
;;; records, so a process hosting one commune builds one record and never sees
;;; the other's — the sovereignty the wire tests exercise.
;;;
;;; A module beside the tests' prelude: every wire test imports it by name,
;;; and what it needs — the engine's DSL, the host's keeping — it names.

(define-module (playnet test planner federation-wire-fixture)
  #:use-module ((playnet solve engine) #:select (commune->scope-record lg cell make-boundary-oracle solve-consensus))
  #:use-module ((playnet solve compile) #:select (rp out in wrk))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet federation host) #:select (read-kept keep! wire-handshake))
  #:use-module ((playnet federation peer) #:select (call-from-thread))
  #:use-module ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
  #:use-module (goblins)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:export (fx-res fx-place fx-worker fx-bake-p fx-bake-f
            fx-commune-a fx-commune-b fx-seed fx-identity fx-commune-a-scarce fx-reference
            fx-federation! fx-serve-federation! fx-final-certificate fx-until fx-words-of
            fx-remote fx-remote-root fx-remote-libs fx-remote-guile fx-same-handshake!
            fx-host-path fx-host-keep! fx-host-read fx-host-rm!
            fx-spawn-host fx-host-sturdyref fx-stop-host! fx-tunnel!))

;; the repository root: this module's file sits four directories below it
(define %root
  (let ((here (%search-load-path "playnet/test/planner/federation-wire-fixture.scm")))
    (dirname (dirname (dirname (dirname (dirname here)))))))

(define (fx-res spec loc q)
  (make-economic-resource #:id (string-append spec "@" loc) #:conforms-to spec #:classified-as '()
    #:accounting-quantity (make-measure q "kg") #:onhand-quantity (make-measure q "kg") #:current-location loc))
(define (fx-place id lat lon) (make-spatial-thing #:id id #:lat lat #:long lon))
(define (fx-worker id loc) (make-agent #:id id #:type 'person #:name id #:primary-location loc
                                       #:classified-as '("general")))
(define fx-bake-p (list (rp "bake" "Bake bread")))
(define fx-bake-f (list (out "o" "bread" 1.0 "bake") (in "i" "flour" 1.0 "bake") (wrk "w" 0.1 "bake")))

(define (fx-commune-a)
  "Granary: 300 kg flour, a worker, a tiny local bread demand; supplies flour."
  (commune->scope-record (list (fx-res "flour" "a-home" 300.0)) (list (fx-worker "wa" "a-home"))
                         (list (fx-place "a-home" 42.70 23.32)) fx-bake-p fx-bake-f
                         #:id "Granary"
                         #:demand (list (cons (lg "bread" (cell "a-home" 0)) 5.0))
                         #:never-raw '("flour")
                         #:crossing '("flour")))

(define (fx-commune-b)
  "Table: no flour, a worker, bread demand 40; draws flour and bakes."
  (commune->scope-record '() (list (fx-worker "wb" "b-home"))
                         (list (fx-place "b-home" 42.75 23.40)) fx-bake-p fx-bake-f
                         #:id "Table"
                         #:demand (list (cons (lg "bread" (cell "b-home" 0)) 40.0))
                         #:never-raw '("flour")
                         #:crossing '("flour")))

;; deterministic identities, so a host process and its coordinator agree on
;; who is who without exchanging keys out of band
(define (fx-seed byte) (let ((bv (make-bytevector 32 byte))) bv))
(define (fx-identity byte) (make-keri-identity (fx-seed byte)))   ; the identity a seed byte derives

;; ── the federation's side ────────────────────────────────────────────────────
;; A signed federation scope that admits communes A and B as remote members
;; at their sturdyrefs, and its spec off its store. CENSUS ((identity . goods) …)
;; are the censuses told to it here by communes this process holds the identity
;; of; any other tells the federation's desk when it boots. Governance is
;; reached at the call, so a test that never federates never loads it.
(define* (fx-federation! aid-a sref-a aid-b sref-b #:key (seed 3) (census '()))
  "In a turn. → (values federation-scope spec)."
  (let* ((gov (resolve-interface '(playnet boot prelude)))
         (door (resolve-interface '(playnet federation federate)))
         (spawn-scope (module-ref gov 'spawn-scope))
         (spawn-acdc-store (module-ref gov 'spawn-acdc-store))
         (id-f (fx-identity seed))
         (fed (spawn-scope "Valley" #:kind 'federation
                           #:scope-aid (keri-identity-aid id-f) #:keypair (keri-identity-keypair id-f)
                           #:acdc-store (spawn-acdc-store)))
         (cap ($ fed 'mint-gov-cap "bootstrap")))
    ($ fed 'admit-commune-remote cap "granary" aid-a sref-a)
    ($ fed 'admit-commune-remote cap "table" aid-b sref-b)
    (for-each (lambda (c)
                ($ fed 'accept-census
                   ((module-ref door 'census-credential) (car c) (keri-identity-aid id-f) (cdr c) "t0")))
              census)
    (values fed ($ fed 'federation-spec))))

(define* (fx-serve-federation! fed mycapn netlayer state-dir #:key (seed 3))
  "In a turn: the federation FED answering for itself on the wire — its desk
   and its fold behind MYCAPN, kept at STATE-DIR (the gateway's
   `serve-federation!`), signing through FED's own key. → a vow of its alist:
   `desk`, `fold`, `sturdyref`, `tell`."
  (let ((door (resolve-interface '(playnet federation federate))))
    ((module-ref door 'serve-federation!)
     fed ((module-ref door 'scope-signer) (keri-identity-aid (fx-identity seed)) fed)
     mycapn netlayer state-dir)))

(define (fx-until ok? seconds)
  "Whether OK? came to hold within SECONDS, asked every two from this plain thread."
  (let wait ((left seconds))
    (cond ((ok?) #t)
          ((<= left 0) #f)
          (else (sleep 2) (wait (- left 2))))))

(define (fx-words-of vat fold aid)
  "How many words of AID the FOLD has heard: read while a commune is down,
   a larger count later is a word it has said since."
  (or (assoc-ref (call-from-thread vat fold 'words) aid) 0))

(define* (fx-final-certificate vat fold #:key (wait 120) (say (lambda (s) #f)))
  "FOLD's certificate once it has heard two communes settled and final,
   polled from this plain thread every two seconds for up to WAIT seconds;
   SAY hears (seconds heard settled? final?) each minute. → the certificate,
   or #f."
  (let poll ((waited 0))
    (let ((c (call-from-thread vat fold 'certificate)))
      (cond ((and (= 2 (length (assq-ref c 'attestations))) (assq-ref c 'settled?) (assq-ref c 'final?)) c)
            ((> waited wait) #f)
            (else (when (and (positive? waited) (zero? (modulo waited 60)))
                    (say (list waited (length (assq-ref c 'attestations)) (assq-ref c 'settled?) (assq-ref c 'final?))))
                  (sleep 2) (poll (+ waited 2)))))))

(define (fx-commune-a-scarce)
  "Granary with only 20 kg flour and its own bread demand of 5: the boundary
   binds, and the pull the link settles at is the dual of that binding fold —
   large, and the same number in-process and over the wire."
  (commune->scope-record (list (fx-res "flour" "a-home" 20.0)) (list (fx-worker "wa" "a-home"))
                         (list (fx-place "a-home" 42.70 23.32)) fx-bake-p fx-bake-f
                         #:id "Granary"
                         #:demand (list (cons (lg "bread" (cell "a-home" 0)) 5.0))
                         #:never-raw '("flour")
                         #:crossing '("flour")))

;; the in-process reference for a wire run: solve-consensus over direct
;; oracles, no finish — the ADMM rounds the wire must reproduce exactly when
;; both start from the same kernel state (the path floor a finish settles)
(define (fx-reference rec-a rec-b)
  (let ((oracles (list (make-boundary-oracle rec-a) (make-boundary-oracle rec-b))))
    (call-with-values
        (lambda ()
          (solve-consensus (map (lambda (o) (o 'links)) oracles)
                           (lambda (centres rho*) (map (lambda (o c) (o 'solve! c rho*)) oracles centres))))
      (lambda (reports met rounds pulls) (list met rounds (hash-ref pulls "flour" 0.0))))))

;; ── the child on another machine ─────────────────────────────────────────────
;; With PLAYNET_FED_REMOTE an ssh target, the child commune runs THERE: in
;; PLAYNET_FED_REMOTE_ROOT (a checkout of module/ and tests/planner/, default
;; /tmp/fed), run by PLAYNET_FED_REMOTE_GUILE (the command that is `guile`
;; there in the same pinned environment as here — a `guix shell … -- guile`
;; from the box's checkout; default guile) with PLAYNET_FED_REMOTE_LIBS on its
;; LD_LIBRARY_PATH (the crypto libraries the KERI backend loads, when the
;; environment lacks them). What the two sides keep for each other
;; — the spec, the sturdyref, the berth — is read and written through ssh,
;; and one ssh session carries both directions of the wire: the child's port
;; forwarded here, this side's port forwarded there, so each sturdyref's
;; 127.0.0.1 is the other machine.
(define fx-remote (getenv "PLAYNET_FED_REMOTE"))
(define fx-remote-root (or (getenv "PLAYNET_FED_REMOTE_ROOT") "/tmp/fed"))
(define fx-remote-libs (or (getenv "PLAYNET_FED_REMOTE_LIBS") ""))
(define fx-remote-guile (or (getenv "PLAYNET_FED_REMOTE_GUILE") "guile"))

(define (fx-ssh . args)                          ; → the command's stdout, whole
  (let* ((port (apply open-pipe* OPEN_READ "ssh" "-o" "BatchMode=yes" fx-remote args))
         (out (get-string-all port)))
    (close-pipe port)
    out))

;; Two Goblins open a session when they shake hands the same way, and the
;; library changed its handshake between releases: this side's is read off
;; the library it runs (`wire-handshake`), the far side's the same way over
;; ssh, and a run whose two ends differ stops here, saying what each speaks
;; and how this side is run on the far side's Goblins.
(define fx-same-handshake!
  (let ((checked? #f))
    (lambda ()
      "With the child on another machine: both ends open a session the same
       way, or an error that says which handshake each speaks."
      (when (and fx-remote (not checked?))
        (let ((here (wire-handshake))
              (there (string-trim-both
                      (fx-ssh (string-append
                               "cd " fx-remote-root " && LD_LIBRARY_PATH=" fx-remote-libs " " fx-remote-guile
                               " --no-auto-compile -q -L module -c"
                               " '(display ((@ (playnet federation host) wire-handshake)))' 2>/dev/null")))))
          (unless (equal? (symbol->string here) there)
            (error (format #f "the two ends shake hands differently: here ~a, on ~a ~s. Run this side on the channel pin's Goblins: make test-federation-peer-remote"
                           here fx-remote there)))
          (set! checked? #t))))))

(define (fx-host-path tail)
  "Where the child keeps TAIL: under the remote root, or under TMPDIR here."
  (if fx-remote
      (string-append fx-remote-root "/" tail)
      (string-append (or (getenv "TMPDIR") "/tmp") "/" tail)))

(define (fx-host-keep! path datum)
  "DATUM kept at PATH on the child's machine."
  (if fx-remote
      (let ((port (open-pipe* OPEN_WRITE "ssh" "-o" "BatchMode=yes" fx-remote
                              (string-append "mkdir -p $(dirname " path ") && cat > " path ".tmp && mv " path ".tmp " path))))
        (write datum port) (newline port)
        (close-pipe port)
        datum)
      (keep! path datum)))

(define* (fx-host-read path #:key (wait 0))
  "The datum kept at PATH on the child's machine, or #f; waited for up to WAIT seconds."
  (if fx-remote
      (let lp ((left wait))
        (let ((text (fx-ssh (string-append "cat " path " 2>/dev/null"))))
          (cond ((> (string-length text) 0) (call-with-input-string text read))
                ((<= left 0) #f)
                (else (sleep 5) (lp (- left 5))))))
      (read-kept path #:wait wait)))

(define (fx-host-rm! . paths)
  (if fx-remote
      (fx-ssh (string-append "rm -rf " (string-join paths " ")))
      (for-each (lambda (p) (when (file-exists? p) (if (file-is-directory? p) (system* "rm" "-rf" p) (delete-file p)))) paths)))

(define (fx-spawn-host which sref-path seed . more)
  "The host script started for commune WHICH with SEED, keeping its sturdyref
   at SREF-PATH; MORE its further arguments (peer, state-dir, spec-file). Here,
   or on the remote machine — once both ends shake hands the same way
   (`fx-same-handshake!`). → the pid (there, its pid there)."
  (fx-same-handshake!)
  (let ((root %root))
    (if fx-remote
        (let* ((cmd (string-append
                     "cd " fx-remote-root " && LD_LIBRARY_PATH=" fx-remote-libs
                     ;; setsid -f: a guile left in the session holds ssh open until it exits
                     " setsid -f " fx-remote-guile " --no-auto-compile -q -L module tests/planner/federation-wire-host.scm "
                     (string-join (cons* which sref-path (number->string seed) more) " ")
                     " > " fx-remote-root "/host-" which ".log 2>&1 < /dev/null; sleep 1; pgrep -n -f federation-wire-host.scm"))
               (pid (string->number (string-trim-both (fx-ssh cmd)))))
          (format #t "   host ~a spawned on ~a (pid ~a); waiting for its sturdyref…~%" which fx-remote pid)
          pid)
        (let ((pid ((@ (guile) spawn) "guile"
                    (append (list "guile" "--no-auto-compile" "-q" "-L" (string-append root "/module")
                                  (string-append root "/tests/planner/federation-wire-host.scm")
                                  which sref-path (number->string seed))
                            more))))
          (format #t "   host ~a spawned (pid ~a); waiting for its sturdyref…~%" which pid)
          pid))))

(define* (fx-host-sturdyref sref-path pid #:key (wait 120))
  "→ (values sturdyref aid) as the host kept them, waited for up to WAIT
   seconds; the host is stopped when it never does."
  (let ((kept (fx-host-read sref-path #:wait wait)))
    (unless kept (fx-stop-host! pid) (error "host never kept its sturdyref"))
    (apply values kept)))

(define (fx-stop-host! pid)
  (if fx-remote
      (fx-ssh (string-append "kill " (number->string pid) "; sleep 1; kill -9 " (number->string pid) " 2>/dev/null; true"))
      (begin (kill pid 15) (false-if-exception (waitpid pid)))))

(define (fx-tunnel! here-port there-port)
  "One ssh session carrying the wire both ways: the child's THERE-PORT reaches
   here as 127.0.0.1:THERE-PORT, and this side's HERE-PORT reaches the child
   as 127.0.0.1:HERE-PORT. → a thunk that closes it. Nothing, when the child
   is local."
  (if fx-remote
      (let ((pid ((@ (guile) spawn) "ssh"
                  (list "ssh" "-o" "BatchMode=yes" "-o" "ExitOnForwardFailure=yes" "-N"
                        "-L" (format #f "~a:127.0.0.1:~a" there-port there-port)
                        "-R" (format #f "~a:127.0.0.1:~a" here-port here-port)
                        fx-remote))))
        (sleep 8)                                   ; the circuit, the forwards
        (lambda () (kill pid 15) (false-if-exception (waitpid pid))))
      (lambda () #t)))
