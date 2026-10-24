;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-mesh.scm — off-WiFi demand over Reticulum
;;;
;;; A mesh requester reaches the lobby's sturdyref over the ret netlayer
;;; and calls doors like any session — but it sleeps on LoRa: it asks,
;;; goes dark, and drains a mailbox when it's back in earshot. What this
;;; suite pins:
;;;
;;;   • machine-mesh-info answers the honest caps — the input budget,
;;;     the image-ref rule, the dest shape — and whether the mailbox
;;;     stands
;;;   • machine-mesh-intake mints a mutual-credit job with params.mesh
;;;     stamped into the shelved envelope — no payer row, no fake money;
;;;     a bad dest, a missing envelope, an oversized input, and an
;;;     inline image all refuse at the door
;;;   • a receipt landing on a mesh-stamped job posts a delivery to the
;;;     result-dest mailbox — hex of the notice — while an ordinary
;;;     job's receipt delivers nothing
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-mesh.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine registry)
             (localchimera machine envelope)
             (localchimera machine receipt)
             (localchimera machine payers)
             (localchimera boot governance)
             (localchimera gateway mesh-mailbox)
             (localchimera doors lobby)
             (localchimera utils hex)
             (goblins) (goblins vat)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (json)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-mesh-e2e"))
(define HOME "did:keri:EHomeCommune")
(define BOB  "did:keri:DBobMeshRequester")
(define NODE "did:keri:DNodeLender")
(define DEST "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
(define DEST2 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (define mailbox (spawn ^mesh-mailbox (hashmap)))
  (current-mesh-mailbox mailbox)

  (define (mesh-env input)
    `((kind . "exec") (bridgeJobId . "bj-mesh")
      (image . "js:demand") (entrypoint . "demand")
      (inputHash . "in:mesh") (caps . ()) (network . #f)
      (params . ((input . ,input)))))

  (define (inline-env len)
    `((kind . "exec") (bridgeJobId . "bj-x")
      (image . ,(string-append "js:" (make-string len #\x)))
      (entrypoint . "m") (inputHash . "in:m")
      (caps . ()) (network . #f) (params . ())))

  (define (receipt-wire claim in-h out-h)
    (let ((r (make-receipt #:bridge-job-id claim #:lender-did NODE
                           #:input-hash in-h #:output-hash out-h
                           #:executed-at 1761000002000)))
      `((bridgeJobId . ,claim) (lenderDid . ,NODE)
        (inputHash . ,in-h) (outputHash . ,out-h)
        (executedAt . 1761000002000)
        (digest . ,(receipt-digest r)))))

  (scenario "the mesh door answers what crosses and what doesn't")
  (check "mesh-info names the caps and the live mailbox"
         (let ((r (door-call gov BOB 'machine-mesh-info HOME)))
           (list (assoc-ref (assoc-ref r "caps") "maxInputBytes")
                 (assoc-ref r "mailbox")))
         '(4096 #t))

  (scenario "the intake — the honest caps refuse what can't cross")
  (check "a non-hex dest refuses"
         (car ($ gov 'machine-mesh-intake BOB HOME "not-a-dest"
                 "swarm-infer" "member" "deterministic" "in:m"
                 'envelope (mesh-env '((q . "x")))))
         'error)
  (check "a short dest refuses"
         (car ($ gov 'machine-mesh-intake BOB HOME "abcd"
                 "swarm-infer" "member" "deterministic" "in:m"
                 'envelope (mesh-env '((q . "x")))))
         'error)
  (check "a missing envelope refuses"
         (car ($ gov 'machine-mesh-intake BOB HOME DEST
                 "swarm-infer" "member" "deterministic" "in:m"))
         'error)
  (check "an input over the cap refuses"
         (car ($ gov 'machine-mesh-intake BOB HOME DEST
                 "swarm-infer" "member" "deterministic" "in:m"
                 'envelope (mesh-env `((q . ,(make-string 5000 #\x))))))
         'error)
  (check "an inline image refuses"
         (car ($ gov 'machine-mesh-intake BOB HOME DEST
                 "swarm-infer" "member" "deterministic" "in:m"
                 'envelope (inline-env 300)))
         'error)

  (scenario "the intake — mesh-stamped, mutual credit")
  (define mesh-job
    (assoc-ref (door-call gov BOB 'machine-mesh-intake HOME DEST
                          "swarm-infer" "member" "deterministic" "in:mesh"
                          'envelope (mesh-env '((q . "water level?"))))
               "jobId"))
  (check "the job minted"
         (string? mesh-job) #t)
  (check "no payer row — mesh work is mutual credit, not a receivable"
         (length (door-call gov BOB 'machine-payer-events HOME
                            'jobId mesh-job))
         0)
  (define mesh-claim
    (door-call gov NODE 'machine-claim HOME mesh-job
               (door-call gov NODE 'machine-offer HOME "member" "swarm-infer"
                          4 "deterministic")))
  ($ gov 'machine-accept BOB HOME mesh-claim)
  (check "the mesh stamp reached the shelved envelope"
         (let* ((env (door-call gov NODE 'machine-fetch-envelope HOME mesh-claim))
                (params (assoc-ref env "params"))
                (md (assq-ref params 'mesh)))
           (and md (assq-ref md 'result-dest)))
         DEST)

  (scenario "the wake — a receipt posts the delivery")
  (check "the receipt lands"
         (car ($ gov 'machine-receipt NODE HOME
                 (receipt-wire mesh-claim "in:mesh" "out:mesh")))
         'ok)
  (check "the dest's mailbox carries the notice"
         (length ($ mailbox 'drain! DEST)) 1)

  (define mesh-job2
    (assoc-ref (door-call gov BOB 'machine-mesh-intake HOME DEST2
                          "swarm-infer" "member" "deterministic" "in:mesh2"
                          'envelope (mesh-env '((q . "bridge out?"))))
               "jobId"))
  (define mesh-claim2
    (door-call gov NODE 'machine-claim HOME mesh-job2
               (door-call gov NODE 'machine-offer HOME "member" "swarm-infer"
                          4 "deterministic")))
  ($ gov 'machine-accept BOB HOME mesh-claim2)
  ($ gov 'machine-receipt NODE HOME (receipt-wire mesh-claim2 "in:mesh2" "out:mesh2"))
  (check "the second delivery decodes to its own job's notice"
         (let* ((payloads ($ mailbox 'drain! DEST2))
                (decoded (and (pair? payloads)
                              (json-string->scm
                               (utf8->string (hex->bv (car payloads)))))))
           (and decoded
                (list (assoc-ref decoded "jobId")
                      (assoc-ref decoded "state")
                      (assoc-ref decoded "outputHash"))))
         (list mesh-job2 "receipted" "out:mesh2"))

  (scenario "an ordinary job's receipt delivers nothing")
  (define plain-job
    (door-call gov BOB 'machine-submit HOME "swarm-infer" "member"
               "deterministic" "in:plain"
               'envelope (mesh-env '((q . "no mesh here")))))
  (define plain-claim
    (door-call gov NODE 'machine-claim HOME plain-job
               (door-call gov NODE 'machine-offer HOME "member" "swarm-infer"
                          4 "deterministic")))
  ($ gov 'machine-accept BOB HOME plain-claim)
  ($ gov 'machine-receipt NODE HOME
     (receipt-wire plain-claim "in:plain" "out:plain"))
  (check "no delivery where no result-dest rode"
         (length ($ mailbox 'destinations)) 0))
