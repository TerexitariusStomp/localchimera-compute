;;; module/playnet/identity/devices.scm — the devices a root authorized
;;;
;;; One file per person, `<dir>/devices-<aid16>.scm`: a list of entries, each
;;; the device-authorization credential the root signed plus this gateway's
;;; revocation mark. Pure file reads and writes — no actor, no vat — so the
;;; signer-keys resolver (playnet keri citizen-sig) can consult it from any
;;; vat, mid-turn, the way the oobi dir serves current keys.
;;;
;;; Entry:
;;;   ((said        . "E…")     ; the credential's SAID
;;;    (device-aid  . "B…")     ; non-transferable prefix = the device's key
;;;    (label       . "phone")
;;;    (tier        . "hardware" | "software")
;;;    (enrolled-at . 1745539200)
;;;    (expires-at  . #f | 1777075200)
;;;    (revoked-at  . #f | 1745600000)
;;;    (cred        . <credential alist, symbol keys, with signature>))
;;;
;;; The wire form (JSON, what the browser stores and presents):
;;;   {"said","schema","issuer","holder","claims":{…},"sig"}
;;; The server re-derives the SAID from the parsed fields and refuses a wire
;;; whose `said` does not match — a signature is only ever checked over a
;;; SAID that commits to the content in hand.

(define-module (playnet identity devices)
  #:use-module ((playnet governance credentials)
                #:select (*schema-playnet-device-authorization*
                          cred-said cred-schema cred-issuer cred-holder
                          cred-claims cred-signature))
  #:use-module ((playnet keri said) #:select (compute-said))
  #:use-module ((playnet keri citizen-sig)
                #:select (verify-said-signature-under-key))
  #:use-module ((playnet utils boot-cell) #:select (make-boot-cell))
  #:use-module ((srfi srfi-1) #:select (find filter-map every))
  #:use-module (json)
  #:export (device-registry-dir
            device-wire->cred
            device-credential-verdict
            device-enroll!
            device-revoke!
            devices-retire!
            devices-of
            device-keys-at
            device-entry-live-at?
            device-entry
            device-entry-live?
            live-device-keys
            device-owner-of
            device-entry-doors
            device-entry->wire-alist))

;; Where the files live. The gateway binds this to its data dir at boot;
;; unbound it follows the lobby's per-user-file convention.
(define device-registry-dir
  (make-boot-cell
   (or (getenv "PLAYNET_DATA_DIR")
       (string-append (or (getenv "HOME") "/tmp") "/.local/state/playnet"))))

(define (devices-file person-aid)
  (string-append (device-registry-dir) "/devices-"
                 (substring person-aid 0 (min 16 (string-length person-aid)))
                 ".scm"))

(define (read-entries person-aid)
  (let ((f (devices-file person-aid)))
    (if (file-exists? f)
        (catch #t
          (lambda () (let ((v (call-with-input-file f read)))
                       (if (list? v) v '())))
          (lambda _ '()))
        '())))

(define (write-entries! person-aid entries)
  (let* ((f (devices-file person-aid)) (dir (dirname f)))
    (unless (file-exists? dir)
      (catch 'system-error (lambda () (mkdir dir)) (lambda _ #f)))
    (call-with-output-file f
      (lambda (p) (write entries p) (newline p)))))

(define (aref a k) (let ((p (assq k a))) (and p (cdr p))))

;; ── wire ↔ credential ───────────────────────────────────────────────────
(define (json-null->f v) (if (eq? v 'null) #f v))

(define (device-wire->cred json-string)
  "The credential alist the browser presented, or #f when the wire is not
   even the right shape. Claim keys become symbols, JSON null becomes #f."
  (catch #t
    (lambda ()
      (let* ((w (json-string->scm json-string))
             (wref (lambda (k) (let ((p (assoc k w))) (and p (cdr p)))))
             (claims (let ((a (wref "claims")))
                       (and (list? a)
                            (map (lambda (kv)
                                   (cons (string->symbol (car kv))
                                         (json-null->f (cdr kv))))
                                 a)))))
        (and (string? (wref "said")) (string? (wref "schema"))
             (string? (wref "issuer")) (string? (wref "holder"))
             claims (string? (wref "sig"))
             (list (cons 'said (wref "said"))
                   (cons 'schema (wref "schema"))
                   (cons 'issuer (wref "issuer"))
                   (cons 'holder (wref "holder"))
                   (cons 'claims claims)
                   (cons 'edges '())
                   (cons 'signature (wref "sig"))
                   (cons 'revoked? #f)))))
    (lambda _ #f)))

(define (device-credential-verdict cred person-aid root-key)
  "#t when CRED is a device authorization PERSON-AID's root signed, else the
   reason. ROOT-KEY is the person's current KEL key (qb64) — the one key
   that may authorize a device; the signer-keys resolver is deliberately
   not consulted here."
  (let* ((claims (or (cred-claims cred) '()))
         (holder (cred-holder cred)))
    (cond
     ((not (equal? (cred-schema cred) *schema-playnet-device-authorization*))
      "not a device authorization")
     ((not (equal? (cred-issuer cred) person-aid))
      "authorization is not this person's")
     ((not (and (string? holder) (= 44 (string-length holder))
                (char=? (string-ref holder 0) #\B)))
      "device AID must be a 44-char non-transferable (B) prefix")
     ((not (equal? (aref claims 'person-aid) person-aid))
      "claims name another person")
     ((not (equal? (aref claims 'device-aid) holder))
      "claims name another device")
     ((not (member (aref claims 'tier) '("hardware" "software")))
      "unknown device tier")
     ((not (and (integer? (aref claims 'enrolled-at))
                (let ((e (aref claims 'expires-at)))
                  (or (not e) (integer? e)))))
      "enrolled-at / expires-at must be integers")
     ((let ((d (aref claims 'doors)))
        (and d (not (and (list? d) (every string? d)))))
      "doors must be a list of door names")
     ((not (equal? (cred-said cred)
                   (compute-said (cred-issuer cred) holder (cred-schema cred)
                                 claims '())))
      "digest does not commit to the contents")
     ((not (verify-said-signature-under-key (cred-said cred)
                                            (cred-signature cred) root-key))
      "signature is not the root's")
     (else #t))))

;; ── the registry ────────────────────────────────────────────────────────
(define (cred->entry cred now)
  (let ((claims (cred-claims cred)))
    (list (cons 'said (cred-said cred))
          (cons 'device-aid (cred-holder cred))
          (cons 'label (or (aref claims 'label) ""))
          (cons 'tier (aref claims 'tier))
          (cons 'enrolled-at (or (aref claims 'enrolled-at) now))
          (cons 'expires-at (aref claims 'expires-at))
          (cons 'revoked-at #f)
          (cons 'cred cred))))

(define (device-enroll! person-aid cred now)
  "Record CRED (already verified) for PERSON-AID. Idempotent by SAID."
  (let ((entries (read-entries person-aid)))
    (unless (find (lambda (e) (equal? (aref e 'said) (cred-said cred))) entries)
      (write-entries! person-aid (append entries (list (cred->entry cred now)))))
    'ok))

(define (device-revoke! person-aid said now)
  "Mark SAID revoked for PERSON-AID. #t when an entry was marked."
  (let* ((entries (read-entries person-aid))
         (hit (find (lambda (e) (equal? (aref e 'said) said)) entries)))
    (and hit
         (begin
           (write-entries!
            person-aid
            (map (lambda (e)
                   (if (eq? e hit)
                       (map (lambda (kv) (if (eq? (car kv) 'revoked-at)
                                             (cons 'revoked-at (or (cdr kv) now))
                                             kv))
                            e)
                       e))
                 entries))
           #t))))

(define (devices-retire! person-aid now)
  "Retire every live authorization of PERSON-AID at NOW — a forget
   (identity/forget.scm) — and reply how many were live. The entries stay:
   each is a device-authorization credential, a signed statement of key
   material the person's root made, and the log a past signature of that
   device is read against (`device-keys-at`). From NOW no device of theirs
   signs, and `device-owner-of` finds no live device of theirs. Idempotent:
   none live replies 0."
  (let* ((entries (read-entries person-aid))
         (live    (filter (lambda (e) (device-entry-live-at? e now)) entries)))
    (when (pair? live)
      (write-entries!
       person-aid
       (map (lambda (e)
              (if (memq e live)
                  (map (lambda (kv) (if (eq? (car kv) 'revoked-at) (cons 'revoked-at now) kv)) e)
                  e))
            entries)))
    (length live)))

(define (devices-of person-aid) (read-entries person-aid))

(define (device-entry person-aid said)
  (find (lambda (e) (equal? (aref e 'said) said)) (read-entries person-aid)))

;; The registry is a device key's LOG — what the KEL is to a root key.
;; Whether a device signed AS the person at an instant is read off its
;; entry's window: enrolled, and neither expired nor revoked by then. A
;; retirement closes the window; it never re-reads the past, so a vouch a
;; phone made while authorized stays the person's after the phone is
;; revoked, expires, or its person is forgotten (`key-in-force-at` for
;; devices: keri/citizen-sig.scm's resolver asks with the time of the
;; statement).
(define (device-entry-live-at? entry at)
  (and entry
       (let ((from (aref entry 'enrolled-at))
             (exp  (aref entry 'expires-at))
             (rev  (aref entry 'revoked-at)))
         (and (or (not (number? from)) (<= from at))
              (or (not exp) (< at exp))
              (or (not rev) (< at rev))))))

(define (device-entry-live? entry now) (device-entry-live-at? entry now))

(define (device-keys-at person-aid at)
  "The device AIDs (B-prefix keys) that signed as PERSON-AID at instant AT."
  (filter-map (lambda (e) (and (device-entry-live-at? e at) (aref e 'device-aid)))
              (read-entries person-aid)))

(define (live-device-keys person-aid now)
  "The device AIDs (B-prefix keys) that sign as PERSON-AID right now."
  (device-keys-at person-aid now))

(define (device-entry-doors entry)
  "The door names this device may call, as symbols, or #f for every
   device-level door (no doors claim on its authorization)."
  (let* ((cred (aref entry 'cred))
         (claims (or (and cred (aref cred 'claims)) '()))
         (d (aref claims 'doors)))
    (and (list? d) (map string->symbol d))))

(define (device-owner-of device-aid now)
  "The (person-aid . entry) whose LIVE entry names DEVICE-AID, or #f. A scan
   of the per-person files: the HTTP door names only the device (the caller
   never states the person), and the registry is small. Each entry carries
   the person in its credential's claims."
  (let* ((dir (device-registry-dir))
         (files (catch #t
                  (lambda ()
                    (let ((d (opendir dir)))
                      (let loop ((f (readdir d)) (acc '()))
                        (if (eof-object? f)
                            (begin (closedir d) acc)
                            (loop (readdir d)
                                  (if (and (string-prefix? "devices-" f) (string-suffix? ".scm" f))
                                      (cons (string-append dir "/" f) acc)
                                      acc))))))
                  (lambda _ '()))))
    (let scan ((fs files))
      (and (pair? fs)
           (let* ((entries (catch #t
                             (lambda () (let ((v (call-with-input-file (car fs) read)))
                                          (if (list? v) v '())))
                             (lambda _ '())))
                  (hit (find (lambda (e) (and (equal? (aref e 'device-aid) device-aid)
                                              (device-entry-live? e now)))
                             entries)))
             (if hit
                 (let ((person (aref (or (aref (aref hit 'cred) 'claims) '()) 'person-aid)))
                   (and person (cons person hit)))
                 (scan (cdr fs))))))))

(define (device-entry->wire-alist e)
  "What a session lists to its owner: no credential body, just the facts."
  `(("said" . ,(aref e 'said))
    ("deviceAid" . ,(aref e 'device-aid))
    ("label" . ,(aref e 'label))
    ("tier" . ,(aref e 'tier))
    ("enrolledAt" . ,(aref e 'enrolled-at))
    ("expiresAt" . ,(or (aref e 'expires-at) 'null))
    ("doors" . ,(let ((d (device-entry-doors e)))
                  (if d (list->vector (map symbol->string d)) 'null)))
    ("revokedAt" . ,(or (aref e 'revoked-at) 'null))))
