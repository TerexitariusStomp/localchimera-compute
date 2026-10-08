;;; tests/gateway/test-http-door.scm — the doors over HTTP, signed by a device key
;;;
;;; What this pins:
;;;   • a request an enrolled device signs reaches its door with the body's
;;;     arguments in head order, and the reply comes back as JSON;
;;;   • every refusal in the verifier: a tampered body, a stale created, a
;;;     replay, an unenrolled device, missing headers;
;;;   • anonymous doors need no signature; root and operator doors, and doors
;;;     with capability arguments, have no HTTP form; unknown paths are 404;
;;;     a missing required argument is 400.
;;; The gateway's objects are stand-ins that record what they were asked, so
;;; the test is about the door, not the lobby.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-http-door.scm

(use-modules (playnet test harness)
             (playnet gateway http-door)
             ((playnet planner vf schemas) #:select (make-measure))
             (playnet gateway device-registry)
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair bran->rotation-keypair public-key->aid-prefix
                        build-icp next-key-digest seed->ed25519-keypair sign-bytes))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes ed25519-keypair-public))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
                ; installs the SAID blake3 backend
             ((playnet governance credentials) #:select (make-device-authorization-credential))
             (web request) (web response) (web uri)
             (rnrs bytevectors)
             (json)
             (srfi srfi-1))

;; ── a person, a device, an enrollment ─────────────────────────────────────
(define tmp (let ((d (string-append "/tmp/playnet-http-door-" (number->string (getpid)))))
              (mkdir d) d))
(device-registry-dir tmp)

(define bran "http-door-passcode-21chars")
(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (next-key-digest (ed25519-keypair-public kp1)))))
(define person (assoc-ref icp-alist "i"))

(define (device-keypair) (seed->ed25519-keypair (keri-crypto-random-bytes 32)))
(define (device-aid kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))
(define phone (device-keypair))
(define stranger (device-keypair))
(define %now 1760000000)

(define cred (make-device-authorization-credential person (device-aid phone) "phone" "software"
                                                   %now #:signing-keypair kp0))
(device-enroll! person cred %now)

;; ── stand-in objects and a synchronous call ───────────────────────────────
(define asked '())
(define (target object person-aid)
  (list 'ref object person-aid))
(define (call ref name args)
  (set! asked (cons (list ref name args) asked))
  (case name
    ((whoami) (caddr ref))
    ((my-skills) '("spec:carpentry" "spec:cooking"))
    ((who) '())
    ((declare-need) '(ok . "iid-1"))
    ((family-split family-bills) 'answered)
    (else 'answered)))

(define (req path body-string headers)
  (build-request (string->uri (string-append "http://localhost" path))
                 #:method 'POST
                 #:headers (cons '(content-type . (application/json)) headers)
                 #:port (open-input-string "")
                 #:validate-headers? #f))

(define (door path body-string headers)
  "→ (code . parsed-json)"
  (call-with-values
      (lambda () (handle-door-request (req path body-string headers)
                                      (string->utf8 body-string)
                                      #:target target #:call call #:now %now))
    (lambda (response text)
      (cons (response-code response) (json-string->scm text)))))

(define (signed kp path body-string)
  (sign-door-request kp (device-aid kp) 'POST path (string->utf8 body-string) #:now %now))

(define (aref a k) (let ((p (assoc k a))) (and p (cdr p))))

(display "\n── 1. a signed request reaches its door ──\n")

(define r1 (door "/api/session/whoami" "{}" (signed phone "/api/session/whoami" "{}")))
(check "200" (= 200 (car r1)))
(check "the reply is the session's answer for the enrolled person"
       (equal? person (aref (cdr r1) "reply")))
(check "the target was the person's session"
       (equal? (list 'ref 'session person) (car (car asked))))

(define body2 "{\"scope-id\":\"uc\",\"spec\":\"spec:bread\",\"qty\":3,\"unit\":\"kg\",\"location\":\"here\",\"arcs-json\":\"[]\",\"note\":\"n\",\"emoji\":\"🍞\",\"from\":\"2026-09-13\",\"until\":\"2026-09-20\"}")
(define r2 (door "/api/session/declare-need" body2 (signed phone "/api/session/declare-need" body2)))
(check "arguments arrive in head order"
       (equal? '("uc" "spec:bread" 3 "kg" "here" "[]" "n" "🍞" "2026-09-13" "2026-09-20"
                 #f #f #f #f 0)
               (caddr (car asked))))
(check "an (ok . value) reply is JSON" (equal? (vector "ok" "iid-1") (aref (cdr r2) "reply")))

(display "\n── 2. the verifier's refusals ──\n")

(define hs (signed phone "/api/session/whoami" "{}"))
(check "tampered body" (= 401 (car (door "/api/session/whoami" "{\"x\":1}" hs))))
(check "stale created"
       (= 401 (car (door "/api/session/whoami" "{}"
                         (sign-door-request phone (device-aid phone) 'POST "/api/session/whoami"
                                            (string->utf8 "{}") #:now (- %now 1000))))))
(check "a stranger's key is not enrolled"
       (= 401 (car (door "/api/session/whoami" "{}" (signed stranger "/api/session/whoami" "{}")))))
(check "no headers at all" (= 401 (car (door "/api/session/whoami" "{}" '()))))
(define hs3 (sign-door-request phone (device-aid phone) 'POST "/api/session/whoami"
                               (string->utf8 "{}") #:now (+ %now 1)))
(check "first use passes" (= 200 (car (door "/api/session/whoami" "{}" hs3))))
(check "the same signed request again is a replay" (= 401 (car (door "/api/session/whoami" "{}" hs3))))
(check "a signature over another path does not carry"
       (= 401 (car (door "/api/session/my-skills" "{}" (signed phone "/api/session/whoami" "{}")))))

(display "\n── 2b. an allowlisted device reaches only its doors ──\n")

;; a narrow interface: enrolled with doors '("whoami")
(define narrow (device-keypair))
(define narrow-cred (make-device-authorization-credential person (device-aid narrow) "bot" "software"
                                                          %now #:doors '("whoami") #:signing-keypair kp0))
(device-enroll! person narrow-cred %now)
(check "the allowlisted door answers"
       (= 200 (car (door "/api/session/whoami" "{}"
                         (sign-door-request narrow (device-aid narrow) 'POST "/api/session/whoami"
                                            (string->utf8 "{}") #:now (+ %now 2))))))
(check "a door outside the allowlist is 403"
       (= 403 (car (door "/api/session/my-skills" "{}"
                         (sign-door-request narrow (device-aid narrow) 'POST "/api/session/my-skills"
                                            (string->utf8 "{}") #:now (+ %now 3))))))
(define skills-body "{\"scope-id\":\"uc\"}")
(check "the unrestricted device still reaches it"
       (= 200 (car (door "/api/session/my-skills" skills-body
                         (sign-door-request phone (device-aid phone) 'POST "/api/session/my-skills"
                                            (string->utf8 skills-body) #:now (+ %now 4))))))
(check "the allowlist is checked before the arguments are"
       (= 403 (car (door "/api/session/my-skills" "{}"
                         (sign-door-request narrow (device-aid narrow) 'POST "/api/session/my-skills"
                                            (string->utf8 "{}") #:now (+ %now 5))))))

(display "\n── 3. which doors have an HTTP form ──\n")

(check "an anonymous door needs no signature" (= 200 (car (door "/api/lobby/who" "{}" '()))))
(check "a root door has no HTTP form"
       (= 403 (car (door "/api/session/rotate-aid" "{}" (signed phone "/api/session/rotate-aid" "{}")))))
(check "an operator door has no HTTP form" (= 403 (car (door "/api/planner/settle-payout" "{}" '()))))
(check "a door with a capability argument has no HTTP form"
       (= 403 (car (door "/api/session/watch-credentials" "{}" (signed phone "/api/session/watch-credentials" "{}")))))
(check "an unknown door is 404" (= 404 (car (door "/api/session/no-such-door" "{}" '()))))
(check "a missing required argument is 400"
       (= 400 (car (door "/api/session/declare-need" "{\"spec\":\"x\"}" (signed phone "/api/session/declare-need" "{\"spec\":\"x\"}")))))
(check "a body that is not JSON is 400"
       (= 400 (car (door "/api/lobby/who" "nope" '()))))

(display "\n── 4. a skipped optional is filled, never omitted ──\n")
;; family-split's declared #:optional (members-json "[]") (per-citizen-hours
;; 40.0) matches lobby.scm's own Scheme #:optional list verbatim (both read
;; positionally). Omitting a skipped optional from the JSON body used to
;; OMIT it from the argument list too — fine when every trailing optional is
;; skipped (Guile's own #:optional then supplies its default), wrong the
;; moment a LATER one is supplied while an EARLIER one is skipped: the args
;; shift left and the door reads them under the wrong names.
(define fs-body-neither "{\"needs-json\":\"[]\",\"purse\":10,\"labour-h\":2,\"weighted?\":false}")
(door "/api/session/family-split" fs-body-neither (signed phone "/api/session/family-split" fs-body-neither))
(check "neither optional given: both fall to the door's own declared defaults"
       (caddr (car asked)) '("[]" 10 2 #f "[]" 40.0))
(define fs-body-first "{\"needs-json\":\"[]\",\"purse\":10,\"labour-h\":2,\"weighted?\":false,\"members-json\":\"[\\\"a\\\"]\"}")
(door "/api/session/family-split" fs-body-first (signed phone "/api/session/family-split" fs-body-first))
(check "members-json given, per-citizen-hours skipped: the trailing default still lands in its own slot"
       (caddr (car asked)) '("[]" 10 2 #f "[\"a\"]" 40.0))
(define fs-body-second "{\"needs-json\":\"[]\",\"purse\":10,\"labour-h\":2,\"weighted?\":false,\"per-citizen-hours\":25}")
(door "/api/session/family-split" fs-body-second (signed phone "/api/session/family-split" fs-body-second))
(check "per-citizen-hours given, members-json SKIPPED: the exact case that used to shift — members-json still reads its own default, per-citizen-hours its own value, neither in the other's slot"
       (caddr (car asked)) '("[]" 10 2 #f "[]" 25))

;; a door's rows leave the planner written by their table; a record the wire
;; has no table for is a defect the door names rather than a string it prints
(display "\n── 5. a record with no table is refused ──\n")
(check-pred "a record is refused by the writer"
            (catch #t (lambda () (value->json (make-measure 1 "kg")) #f) (lambda _ #t)))
(check "a finished row passes" (value->json '(("id" . "r") ("q" . 2))) '(("id" . "r") ("q" . 2)))

(test-summary!)
