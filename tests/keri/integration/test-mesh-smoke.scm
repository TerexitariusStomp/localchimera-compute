;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/integration/test-mesh-smoke.scm — LIVE mesh hop:
;;; two rns-bridges over a local TCP interface, one persona's mail
;;; destination registered + announced behind bridge B, a mail packet
;;; injected at bridge A, and the DELIVERY surfacing on B's SUBSCRIBE
;;; stream — the whole LXMF transport story over a real Reticulum link.
;;;
;;;   node/rns-wasm (persona)        bridge A          bridge B
;;;   ───────────────────────        ────────          ────────
;;;   identity, announce, mail          │     TCP link     │
;;;          announce ──────────────────┼──────────────────▶ (origin B)
;;;          REGISTER dest ────────────────────────────────▶
;;;          SUBSCRIBE ────────────────────────────────────▶
;;;          mail pkt ────▶ SEND_RAW ───┼── routed ────────▶ DELIVERY line
;;;
;;; Needs: server/rns-bridge/target/debug/rns-bridge (cargo build) and
;;; node + rns-wasm/pkg. Skips politely when either is absent.
;;;
;;; Run: make test-mesh-smoke

(use-modules (playnet test harness)
             ((playnet test keri-integration) #:select (check-call))
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 format)
             (json)
             ((srfi srfi-1)  #:select (last))
             ((srfi srfi-13) #:select (string-trim-right string-null?
                                       string-prefix? string-contains)))

(setvbuf (current-output-port) 'none)

;; Strays from an earlier aborted run would share the TCP port AND the
;; rns shared-instance socket — kill them before anything else.
(system "pkill -9 -f '[r]ns-bridge --control-socket /tmp/mesh-smoke' 2>/dev/null")

(define %root (or (getenv "PLAYNET_ROOT") (getcwd)))
(define %bridge-bin (string-append %root "/server/rns-bridge/target/debug/rns-bridge"))
(define %tmp (string-append (or (getenv "TMPDIR") "/tmp")
                            "/mesh-smoke-" (number->string (getpid))))
(define %tcp-port 14242)

(define (run-capture cmd)
  (let* ((port (open-input-pipe (string-append cmd " 2>&1")))
         (out  (get-string-all port))
         (code (status:exit-val (close-pipe port))))
    (cons code out)))

(define (have? cmd)
  (let ((r (run-capture cmd)))
    (and (zero? (car r)) (not (string-null? (string-trim-right (cdr r)))))))

(when (not (and (file-exists? %bridge-bin)
                (have? "command -v node")
                (file-exists? (string-append %root "/rns-wasm/pkg/rns_wasm.js"))))
  (format #t "SKIP: needs rns-bridge debug binary + node + rns-wasm pkg~%")
  (exit 0))

(format #t "=== Live mesh smoke: two bridges, one TCP hop ===~%")

;;; ── persona vectors via the real rns-wasm ────────────────────────────────────

(define %node-script "
const fs = require('fs');
(async () => {
  const pkg = process.cwd() + '/rns-wasm/pkg';
  const wasm = await import('file://' + pkg + '/rns_wasm.js');
  await wasm.default(fs.readFileSync(pkg + '/rns_wasm_bg.wasm'));
  const seed = new Uint8Array(64); seed.fill(7);
  const id = wasm.Identity.fromPrivateKey(seed);
  const hex = b => Buffer.from(b).toString('hex');
  const now = BigInt(Math.floor(Date.now() / 1000));
  const mailPkt = id.packLxmfPacket(id.publicKey(), 'smoke', 'over the wire',
                                    Date.now() / 1000);
  console.log(JSON.stringify({
    lxmfDest: id.lxmfDestHashHex(),
    announce: hex(id.packAnnounceFor('lxmf', 'delivery', now, undefined)),
    mailPkt:  hex(mailPkt),
  }));
})().catch(e => { console.error(e); process.exit(1); });
")

(define %vec
  (let* ((tmp (string-append %tmp "-vec.cjs"))
         (_   (call-with-output-file tmp
                (lambda (p) (display %node-script p))))
         (r   (run-capture (string-append "node " tmp))))
    (delete-file tmp)
    (unless (zero? (car r)) (error "vector script failed" (cdr r)))
    (json-string->scm
     (last (filter (lambda (s) (not (string-null? s)))
                   (string-split (cdr r) #\newline))))))

(define %dest (assoc-ref %vec "lxmfDest"))
(format #t "  persona mail dest: ~a~%" %dest)

;;; ── two bridges over one TCP interface ──────────────────────────────────────

(define (write-config! dir iface)
  (system* "mkdir" "-p" dir)
  (call-with-output-file (string-append dir "/config")
    (lambda (p) (display iface p))))

(define %dir-a (string-append %tmp "/a"))
(define %dir-b (string-append %tmp "/b"))
(define %ctl-a (string-append %tmp "/a.sock"))
(define %ctl-b (string-append %tmp "/b.sock"))

;; share_instance = No on BOTH: two rns nodes on one host otherwise
;; join the same local shared instance and the topology silently stops
;; being the TCP hop this test is about.
(write-config! %dir-a
  (format #f "[reticulum]~%share_instance = No~%~%[interfaces]~%  [[srv]]~%    type = TCPServerInterface~%    enabled = Yes~%    listen_ip = 127.0.0.1~%    listen_port = ~a~%" %tcp-port))
(write-config! %dir-b
  (format #f "[reticulum]~%share_instance = No~%~%[interfaces]~%  [[cli]]~%    type = TCPClientInterface~%    enabled = Yes~%    target_host = 127.0.0.1~%    target_port = ~a~%" %tcp-port))

(define (spawn-bridge! ctl dir log)
  (system (format #f "~a --control-socket ~a --socket-dir ~a/socks --config ~a > ~a 2>&1 &"
                  %bridge-bin ctl dir dir log)))

(define (wait-for-socket path)
  (let loop ((n 0))
    (cond ((file-exists? path) #t)
          ((> n 50) (error "bridge control socket never appeared" path))
          (else (usleep 200000) (loop (+ n 1))))))

;; Server before client — B's TCP client connects at startup.
(spawn-bridge! %ctl-a %dir-a (string-append %tmp "/a.log"))
(wait-for-socket %ctl-a)
(spawn-bridge! %ctl-b %dir-b (string-append %tmp "/b.log"))
(wait-for-socket %ctl-b)
(sleep 2) ; let the TCP link come up

(define (ctl-connect path)
  (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
    (connect sock AF_UNIX path)
    sock))

(define (ctl-cmd! sock line)
  (display line sock) (newline sock) (force-output sock)
  (string-trim-right (read-line sock)))

;;; Recipient side (bridge B): register the persona's dest + subscribe.

(define b-main (ctl-connect %ctl-b))
(check-call "REGISTER at the persona's gateway (B)"
  (lambda () (equal? "OK" (ctl-cmd! b-main (string-append "REGISTER " %dest)))))

(define b-events (ctl-connect %ctl-b))
(check-call "SUBSCRIBE event stream on B"
  (lambda () (equal? "OK" (ctl-cmd! b-events "SUBSCRIBE"))))

;;; Announce the persona FROM its gateway; the path propagates B → A.

(check-call "relay the persona's announce at B"
  (lambda () (equal? "OK" (ctl-cmd! b-main
                            (string-append "ANNOUNCE_RAW "
                                           (assoc-ref %vec "announce"))))))
(sleep 2) ; propagation

;;; Sender side (bridge A): inject the mail packet; it must route the
;;; TCP hop and surface as a DELIVERY line on B's subscribe stream.

(define a-main (ctl-connect %ctl-a))
(check-call "SEND_RAW the mail packet at A"
  (lambda () (equal? "OK" (ctl-cmd! a-main
                            (string-append "SEND_RAW "
                                           (assoc-ref %vec "mailPkt"))))))

(check-call "DELIVERY surfaces on B for the persona's dest"
  (lambda ()
    ;; read-line blocks; the harness-level timeout guards the suite.
    (let ((line (string-trim-right (read-line b-events))))
      (format #t "  → ~a…~%" (substring line 0 (min 60 (string-length line))))
      ;; payload = EXACTLY the packet's ciphertext (HEADER_1 = 19 bytes
      ;; stripped by the bridge) — what the browser decrypts.
      (equal? line
              (string-append "DELIVERY " %dest " "
                             (substring (assoc-ref %vec "mailPkt") 38))))))

;;; teardown
(for-each (lambda (s) (false-if-exception (close-port s)))
          (list a-main b-main b-events))
(system (format #f "pkill -f 'rns-bridge --control-socket ~a' " %tmp))
(system* "rm" "-rf" %tmp)

(test-summary!)
