;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/host.scm — a commune's peer on a real network: the door between
;;; the signed shell (federation/peer.scm) and the OCapN it travels over.
;;;
;;; The shell owns no network: it holds references and sends one-way. This
;;; module is where the references come from and come back from:
;;;
;;;   A BERTH is what a commune keeps so that it is reachable at the SAME
;;;   sturdyref after every restart — the designator key of its netlayer, the
;;;   port it listens on and the swiss number its peer is registered under.
;;;   `moor!` puts a peer behind a websocket netlayer at its berth and answers
;;;   the sturdyref; a restart moors again at the same berth and the far
;;;   communes' sturdyrefs still name it.
;;;
;;;   A far commune enters from a CREDENTIAL. The federation issues each
;;;   commune a `localchimera-federation-sturdyref/v1` ACDC naming its AID (the
;;;   holder) and its sturdyref; `join!` checks the credential — its SAID
;;;   commits to its content, the federation's signature over the SAID checks
;;;   under the issuer AID the caller trusts — enlivens the sturdyref and
;;;   connects the far end with its AID pinned. Nothing is handed a reference
;;;   by hand.
;;;
;;;   Every far reference is REACHED the same way (`reach!`): enlivened,
;;;   handed to whoever wanted it, and pinged; kept reached after. A question
;;;   put to a far end until it answers is `ask!`, the one retry there is.
;;;
;;;   The round trip is measured on the way in (`ping`), and the peer's
;;;   deadline — the wait before a stalled version is published again — is set
;;;   to several of it, so a link over Tor waits longer than one on a LAN and
;;;   neither re-sends into a reply that is on its way.
;;;
;;;   A session that severs is Goblins' signal (`on-sever`, on the remote
;;;   reference): the far end is enlivened again from the same sturdyref and
;;;   connected back, and while the far commune is still away the enliven is
;;;   tried again after a `timeout` — a promise, in the vat, with no thread.
;;;   The clock is the shell's `start-ticker!`, an actor in the vat likewise.
;;;   Everything here runs in a turn of the peer's vat, and speaks to the
;;;   mycapn and the netlayer — which may live in another — by `<-`.
;;;
;;;   What a commune KEEPS — its berth, its peer's snapshot after every change
;;;   (`file-keeper`), its sturdyref for whoever reads it — is one datum in one
;;;   file, written whole (`keep!`) and read back (`read-kept`); a restart hands
;;;   the snapshot to `make-peer` as its RESTORE and resumes at its versions.

(define-module (localchimera federation host)
  #:use-module (goblins)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib timers)
  #:use-module (goblins ocapn captp)
  #:use-module (goblins ocapn ids)
  #:use-module (goblins ocapn netlayer websocket)
  #:use-module (goblins utils crypto)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera federation peer) #:select (now-seconds))
  #:use-module ((localchimera federation sturdyref-credential) #:select (sturdyref-credential-end))
  #:export (keep! read-kept file-keeper mkdir-p
            make-berth berth-swiss! berth-sturdyref berth-register! moor!
            wire-handshake
            roster-ends
            ask! reach! join!))

;; ── what a commune keeps ─────────────────────────────────────────────────────
(define (keep! path datum)
  "DATUM kept at PATH, written whole: a reader sees the old file or the new."
  (let ((tmp (string-append path ".tmp")))
    (call-with-output-file tmp (lambda (p) (write datum p) (newline p)))
    (rename-file tmp path)
    datum))

(define* (read-kept path #:key (wait 0))
  "The datum kept at PATH, or #f — waited for up to WAIT seconds, a second at
   a time, when another process is about to keep it."
  (cond ((file-exists? path) (call-with-input-file path read))
        ((<= wait 0) #f)
        (else (sleep 1) (read-kept path #:wait (- wait 1)))))

(define (file-keeper path)
  "A KEEP for `^commune-peer`: each snapshot kept at PATH; `read-kept` of it is
   `make-peer`'s RESTORE."
  (lambda (snapshot) (keep! path snapshot)))

;; ── the berth ────────────────────────────────────────────────────────────────
(define* (make-berth port #:key (host "127.0.0.1"))
  "A fresh berth: a designator key, a swiss number, and HOST:PORT to listen at."
  `((key . ,(private-key->data (generate-key-pair)))
    (swiss . ,(strong-random-bytes 32))
    (host . ,host)
    (port . ,port)))

(define (mkdir-p dir)
  (unless (file-exists? dir) (mkdir-p (dirname dir)) (mkdir dir)))

(define (berth-swiss! state-dir)
  "The swiss number kept at STATE-DIR's berth, minted and kept there when
   there is none (the directory made when there is none): what a peer at
   that state directory is registered under, the same after every restart."
  (mkdir-p state-dir)
  (let ((path (string-append state-dir "/berth")))
    (assq-ref (or (read-kept path) (keep! path `((swiss . ,(strong-random-bytes 32))))) 'swiss)))

(define (berth-sturdyref netlayer swiss)
  "The sturdyref of whatever is registered under SWISS behind NETLAYER — its
   location and the swiss number — as a vow of its string. It names the
   berth before anything is registered there: a far side that enlivens it
   early is refused and tries again."
  (let*-on ((loc (<- netlayer 'our-location)))
    (ocapn-id->string (make-ocapn-sturdyref loc swiss))))

(define (berth-register! mycapn netlayer actor swiss)
  "ACTOR registered at MYCAPN under SWISS — the same sturdyref after every
   restart — reachable through NETLAYER, one of MYCAPN's; from any vat's
   turn. → a vow of the sturdyref's string."
  (let*-on ((registry (<- mycapn 'get-registry))
            (swiss* (<- registry 'register actor swiss)))
    (berth-sturdyref netlayer swiss*)))

(define* (moor! berth #:key (encrypted? #f))
  "A websocket netlayer of its own at BERTH, and a mycapn over it; in a turn.
   → an alist: `netlayer`, `mycapn`. Whoever moors registers what it will
   (`berth-register!`) under the berth's swiss number, and `berth-sturdyref`
   names it before then."
  (let* ((nl (spawn ^websocket-netlayer
                    #:host (assq-ref berth 'host) #:port (assq-ref berth 'port)
                    #:encrypted? encrypted?
                    #:designator-key (data->private-key (assq-ref berth 'key))))
         (mycapn (spawn-mycapn nl)))
    `((netlayer . ,nl) (mycapn . ,mycapn))))

;; ── the handshake ────────────────────────────────────────────────────────────
(define (wire-handshake)
  "The handshake this process's Goblins opens a websocket session with, read
   off the library itself: `peer-auth` (an <init:peer-auth> record signed,
   0.18 on) or `challenge` (64 raw bytes signed, before). Two ends speak to
   each other when they answer the same."
  (if (false-if-exception
       (module-ref (resolve-interface '(goblins ocapn netlayer websocket-utils)) 'init:peer-auth))
      'peer-auth
      'challenge))

;; ── the roster: which goods cross for whom, and who masters each ────────────
(define (roster-ends roster me)
  "ROSTER ((good aid …) …) — every good that crosses in the federation and
   the communes it crosses for — read from ME's side. The master of a good is
   its first participant by AID, the same on every side.
   A good that crosses for ME alone has nobody to cross to, and is left out.
   → an alist for `make-peer` and `join!`: `mastering` the goods ME masters,
   `members` ((good aid …) …) the others on those, and `ends`
   ((good who aid) …) — for a mastered good each other participant by its
   AID, for any other the master, as `master`."
  (let* ((mine (filter (lambda (g) (and (member me (cdr g)) (pair? (cddr g)))) roster))
         (master-of (lambda (g) (car (sort (cdr g) string<?))))
         (mastered (filter (lambda (g) (equal? (master-of g) me)) mine))
         (others (lambda (g) (remove (lambda (a) (equal? a me)) (sort (cdr g) string<?)))))
    `((mastering . ,(map car mastered))
      (members . ,(map (lambda (g) (cons (car g) (others g))) mastered))
      (ends . ,(append-map
                (lambda (g)
                  (if (equal? (master-of g) me)
                      (map (lambda (a) (list (car g) a a)) (others g))
                      (list (list (car g) 'master (master-of g)))))
                mine)))))

;; ── the far end ──────────────────────────────────────────────────────────────
(define* (ask! mycapn uri question #:key (retry 0.5) (patience 30.0) (log (lambda (m) #f))
               (refused? (lambda (answer) #f)))
  "In a turn: QUESTION put to the far end at the sturdyref URI until it
   answers. An attempt enlivens the far end through MYCAPN and hands it to
   QUESTION, which answers a vow; one that breaks, that neither answers nor
   breaks within PATIENCE seconds, or whose answer is REFUSED? is followed by
   the next RETRY seconds later, for as long as it takes — the far side may
   still be booting. LOG hears each attempt as (uri ok) or (uri away
   reason). → a vow of the answer."
  (define (attempt)
    (race (let*-on ((far (<- mycapn 'enliven (string->ocapn-id uri)))) (question far))
          (let*-on ((_ (timeout patience))) (error "federation-host: the far end did not answer" uri))))
  (define (later why) (log (list uri 'away why)) (let*-on ((_ (timeout retry))) (again!)))
  (define (again!)
    (on (attempt)
        (lambda (answer) (if (refused? answer) (later answer) (begin (log (list uri 'ok)) answer)))
        #:catch later
        #:promise? #t))
  (again!))

(define* (reach! mycapn uri reached #:key (retry 0.5) (patience 30.0) (log (lambda (m) #f)))
  "In a turn: the far end at the sturdyref URI, reached and kept reached
   (`ask!`, RETRY and PATIENCE as there). Reached, it is handed to REACHED
   and answers a ping. It is watched from then on: severed later (a session
   CapTP gives up on as it opens, two sides connecting at once, or one that
   dies), it is reached again the same way, and REACHED hears the new
   reference. → a vow of (far . rtt), the first reach and its round trip."
  (define (again!)
    (ask! mycapn uri
          (lambda (far)
            (let*-on ((_ (reached far))
                      (t (<- far 'ping (now-seconds))))
              (when (remote-refr? far)
                (on-sever far (lambda (type reason) (again!))))
              (cons far (- (now-seconds) t))))
          #:retry retry #:patience patience #:log log))
  (again!))

(define* (join! mycapn ref link cred #:key issuer (who #f) (deadline-floor 1.0) (deadline-factor 8.0)
                (retry 0.5) (patience 30.0) (log #f))
  "In a turn: LINK of the peer REF connected to the commune CRED names — as WHO
   the master knows it, `master` from a participant's side, or #f for the one
   counterpart — reached through MYCAPN (`reach!`: kept reached, RETRY and
   PATIENCE as there) and pinned to the credential's AID
   (`sturdyref-credential-end`, under ISSUER); connected again on every
   reach. The round trip is measured on the way in and REF's deadline raised
   to DEADLINE-FACTOR of it when DEADLINE-FLOOR is shorter. LOG, when given,
   hears each attempt as (link who ok) or (link who away reason). → a vow of
   an alist: `ref` the far end, `aid`, `rtt` the round trip in seconds,
   `deadline` the peer's."
  (call-with-values (lambda () (sturdyref-credential-end cred #:issuer issuer))
    (lambda (aid uri)
      (let*-on ((far+rtt (reach! mycapn uri (lambda (far) (<- ref 'connect link who far aid))
                                 #:retry retry #:patience patience
                                 #:log (lambda (m) (when log (log (cons* link who (cdr m))))))))
        (let ((far (car far+rtt)) (rtt (cdr far+rtt)))
          (let*-on ((d (<- ref 'deadline! (max deadline-floor (* deadline-factor rtt)))))
            `((ref . ,far) (aid . ,aid) (rtt . ,rtt) (deadline . ,d))))))))
