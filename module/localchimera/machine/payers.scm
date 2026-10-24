;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/machine/payers.scm — the demand side: who pays, what
;;; they buy, and the ledger that ties their refs to our jobs.
;;;
;;; The provider registry (providers.scm) is outbound: ring-3 capacity we
;;; call when the inner rings are empty. This is the inverse — the payers
;;; whose demand can route IN, each named by how its supply requirement
;;; fits a commons whose nodes are browser tabs:
;;;
;;;   api            a paid-intake wire shape our own demand desk serves
;;;                  (OpenAI-compat chat, scrape-fetch, multi-vantage
;;;                  checks, load bursts, S3, ipfs pin, OCR, judge,
;;;                  lo-fi render, small-circuit prove, MCP tools) — the
;;;                  work lands as ordinary envelopes on tab capacity.
;;;   browser        a payer protocol a tab speaks natively (nostr DVM).
;;;   commune-daemon pays, but only through its native node — out of the
;;;                  browser boundary: catalogued, not wireable.
;;;   hardware       pays, but only through its sensors/radios.
;;;   closed-client  pays, but only through its own client — nothing to
;;;                  integrate; named so the choice reads as chosen.
;;;   flagged        a real market shape, parked for a stated reason.
;;;
;;; THE PARTS:
;;;   • *payer-specs* / payer-for / payer-serves? — the catalogue.
;;;   • <payer-row> + ^payer-ledger — the inbound book: one row per
;;;     payer-funded job, naming the payer's own ref and what the demand
;;;     desk debited. The settlement statement's payments point here.
;;;   • <demand-customer> + ^demand-desk — the prepaid customer book: a
;;;     demand-API key hashes to a balance the operator tops up (the
;;;     billing rail lives at the treasury edge) and intake debits per
;;;     job. Customers never become citizens; the OPERATOR is the
;;;     borrower on the minted job, the ledger row carries the payer ref.
;;;
;;; This module holds no registry import so registry.scm may register
;;; the stores in its persistence env without a cycle.

(define-module (localchimera machine payers)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((localchimera utils store-utils) #:select (serialize-hashmap
                                                     hashmap-filter))
  #:export (*payer-specs* payer-for payer-serves? payer-class
            %payer-classes %wireable-classes
            <payer-row> make-payer-row payer-row?
            payer-row-id payer-row-job-id payer-row-payer
            payer-row-ref payer-row-amount payer-row-asset
            payer-row-state payer-row-at
            payer-row->list list->payer-row
            ^payer-ledger spawn-payer-ledger
            <demand-customer> make-demand-customer demand-customer?
            demand-customer-key-hash demand-customer-name
            demand-customer-owner-did demand-customer-balance
            demand-customer-asset demand-customer-active?
            demand-customer->list list->demand-customer
            ^demand-desk spawn-demand-desk))


;;; ── the catalogue — who pays, and how their supply fits a tab ────────────
;;; Each entry: (kinds . the envelope kinds it buys) (class . the supply
;;; class above) (api . the wire shape its customers speak) (why . the
;;; honest note). wireable = api | browser — the rest are named so a
;;; reader sees the boundary as chosen, not missed.

(define %payer-classes
  '(api browser commune-daemon hardware closed-client flagged))
(define %wireable-classes '(api browser))

(define *payer-specs*
  `(;; the traditional paid-intake shapes the demand desk serves
    (api-openai   . ((kinds . (exec bundle))  (class . api)
                     (api . "POST /api/demand/v1/chat/completions + /v1/audio/transcriptions")
                     (why  . "the OpenRouter/Together market's wire shape")))
    (api-fetch    . ((kinds . (relay))        (class . api)
                     (api . "POST /api/demand/fetch")
                     (why  . "Bright Data/ScraperAPI's per-request residential fetch")))
    (api-monitor  . ((kinds . (relay))        (class . api)
                     (api . "POST /api/demand/check")
                     (why  . "BetterStack/Pingdom multi-vantage checks — tabs are the vantage points")))
    (api-loadtest . ((kinds . (relay))        (class . api)
                     (api . "POST /api/demand/loadtest")
                     (why  . "k6/BlazeMeter distributed load — fleet swarms")))
    (api-s3       . ((kinds . (store))        (class . api)
                     (api . "PUT/GET /api/demand/s3/*")
                     (why  . "backup/archive buyers; restic works unmodified")))
    (api-pin      . ((kinds . (store))        (class . api)
                     (api . "POST /api/demand/pin")
                     (why  . "Pinata/web3.storage pinning — helia serves")))
    (api-ocr      . ((kinds . (exec))         (class . api)
                     (api . "POST /api/demand/ocr")
                     (why  . "OCR.space/ConvertAPI image→text, tesseract.js-wasm")))
    (api-judge    . ((kinds . (exec))         (class . api)
                     (api . "POST /api/demand/judge")
                     (why  . "Judge0/Piston code-exec shape — a plain exec envelope")))
    (api-render   . ((kinds . (exec))         (class . api)
                     (api . "POST /api/demand/render")
                     (why  . "Urlbox/Browserless lo-fi tier — in-page rasterization, no CDP")))
    (api-prove    . ((kinds . (exec))         (class . api)
                     (api . "POST /api/demand/prove")
                     (why  . "small-circuit snarkjs-wasm — the proof self-verifies")))
    (api-mcp      . ((kinds . (exec store relay sense bundle)) (class . api)
                     (api . "POST /api/mcp tools/call")
                     (why  . "agent buyers — the MCP door is already live")))
    ;; the payer protocol a tab serves natively
    (nostr-dvm    . ((kinds . (exec store relay sense)) (class . browser)
                     (api . "NIP-90 kind:5xxx request → kind:6xxx result + zap/bolt11")
                     (why  . "the one open payer protocol that needs no native node")))
    ;; pays, but only through its native node — out of the browser
    ;; boundary; catalogued so the exclusion reads as chosen
    (golem        . ((kinds . (exec bundle))  (class . commune-daemon)
                     (api . "yagna market/exe-unit")
                     (why  . "provider requires the native yagna daemon")))
    (bacalhau     . ((kinds . (exec bundle))  (class . commune-daemon)
                     (api . "bacalhau compute node")
                     (why  . "compute provider is a native node")))
    (akash        . ((kinds . (exec bundle))  (class . commune-daemon)
                     (api . "akash provider/k8s")
                     (why  . "leases run on kubernetes")))
    (storj-node   . ((kinds . (store))        (class . commune-daemon)
                     (api . "storagenode")
                     (why  . "supply is the native storagenode daemon")))
    (mysterium    . ((kinds . (relay))        (class . commune-daemon)
                     (api . "myst node")
                     (why  . "exit-node supply is a native daemon")))
    (pokt         . ((kinds . (relay))        (class . commune-daemon)
                     (api . "morse/shannon node")
                     (why  . "relaying needs the chain's node")))
    (livepeer     . ((kinds . (exec))         (class . commune-daemon)
                     (api . "orchestrator/transcoder")
                     (why  . "transcode supply is a GPU pipeline")))
    (succinct     . ((kinds . (exec))         (class . commune-daemon)
                     (api . "ProverNet prover")
                     (why  . "zkVM proving needs the native GPU prover — small circuits route via api-prove")))
    (boundless    . ((kinds . (exec))         (class . commune-daemon)
                     (api . "Boundless prover")
                     (why  . "RISC-V zkVM proving needs the native prover")))
    (zkcloud      . ((kinds . (exec))         (class . commune-daemon)
                     (api . "Gevulot prover")
                     (why  . "proving needs the native prover stack")))
    ;; hardware-bound
    (helium       . ((kinds . (relay))        (class . hardware)
                     (api . "gateway-rs hotspot")
                     (why  . "LoRa backhaul pays the radio, not a tab")))
    (hivemapper   . ((kinds . (sense))        (class . hardware)
                     (api . "dashcam")
                     (why  . "mapping pays their signed dashcam")))
    (dimo         . ((kinds . (sense))        (class . hardware)
                     (api . "vehicle adapter")
                     (why  . "vehicle data pays their hardware")))
    (weatherxm    . ((kinds . (sense))        (class . hardware)
                     (api . "weather station")
                     (why  . "meteo pays their signed stations")))
    (geodnet      . ((kinds . (sense))        (class . hardware)
                     (api . "GNSS station")
                     (why  . "RTK pays their receivers")))
    ;; closed clients — real payers, nothing to integrate
    (grass        . ((kinds . (relay))        (class . closed-client)
                     (api . "their extension")
                     (why  . "bandwidth pays inside their client only")))
    (acurast      . ((kinds . (exec))         (class . closed-client)
                     (api . "their phone app")
                     (why  . "Processor Lite is an app, not a browser")))
    (koii         . ((kinds . (exec))         (class . closed-client)
                     (api . "koii-node app")
                     (why  . "tasks run inside their desktop node")))
    (honeygain    . ((kinds . (relay))        (class . closed-client)
                     (api . "their app")
                     (why  . "bandwidth pays inside their client only")))
    ;; flagged — real shapes, parked for a stated reason
    (p2p-cdn      . ((kinds . (relay store))  (class . flagged)
                     (api . "hls.js + datachannel distribution")
                     (why  . "the Peer5 model — needs a content-provider partnership first")))
    (browser-agent . ((kinds . (exec))        (class . flagged)
                     (api . "agent-driven session")
                     (why  . "the Browserbase market — a session lifecycle, not a one-shot claim")))))

(define (payer-for name)
  "The payer spec NAME (string or symbol) names, or #f."
  (let ((n (if (symbol? name) name (and (string? name) (string->symbol name)))))
    (and n (assoc n *payer-specs*))))

(define (payer-serves? name kind)
  "Does payer NAME take envelopes of KIND?"
  (let ((spec (payer-for name)))
    (and spec (memq kind (assq-ref (cdr spec) 'kinds)) #t)))

(define (payer-class name)
  "The supply class of payer NAME ('api, 'browser, 'commune-daemon,
   'hardware, 'closed-client, 'flagged), or #f for an unknown payer."
  (let ((spec (payer-for name)))
    (and spec (assq-ref (cdr spec) 'class))))


;;; ── the ledger — inbound demand rows ─────────────────────────────────────
;;; One row per payer-funded job: which payer, its own ref (invoice id,
;;; nostr event id, demand key), what the desk debited, and the state of
;;; the money. 'paid lands only when the treasury edge confirms — the
;;; door never writes it on a client's word.

(define-record-type <payer-row>
  (%make-payer-row id job-id payer ref amount asset state at)
  payer-row?
  (id       payer-row-id)        ; string
  (job-id   payer-row-job-id)    ; the internal job the demand minted
  (payer    payer-row-payer)     ; symbol — the catalogue name
  (ref      payer-row-ref)       ; the payer's own reference | #f
  (amount   payer-row-amount)    ; what the desk debited | #f
  (asset    payer-row-asset)     ; CAIP-19 the payer settles in | #f
  (state    payer-row-state)     ; 'offered | 'running | 'paid | 'unpaid | 'unavailable
  (at       payer-row-at))       ; epoch ms

(define* (make-payer-row #:key id job-id payer ref amount asset state at)
  (unless (and (string? id) (not (string-null? id)))
    (error "payer-row: id must be a non-empty string" id))
  (unless (string? job-id)
    (error "payer-row: job-id must be a string" job-id))
  (unless (symbol? payer)
    (error "payer-row: payer must be a symbol" payer))
  (unless (memq state '(offered running paid unpaid unavailable))
    (error "payer-row: bad state" state))
  (%make-payer-row id job-id payer ref amount asset state at))

(define (payer-row->list r)
  (list (payer-row-id r) (payer-row-job-id r)
        (symbol->string (payer-row-payer r)) (payer-row-ref r)
        (payer-row-amount r) (payer-row-asset r)
        (symbol->string (payer-row-state r)) (payer-row-at r)))

(define (list->payer-row l)
  (make-payer-row #:id (list-ref l 0) #:job-id (list-ref l 1)
                  #:payer (string->symbol (list-ref l 2))
                  #:ref (list-ref l 3) #:amount (list-ref l 4)
                  #:asset (list-ref l 5)
                  #:state (string->symbol (list-ref l 6))
                  #:at (list-ref l 7)))

(define (^payer-ledger bcom rows)
  (methods
    ((put! r)
     (bcom (^payer-ledger bcom (hashmap-set rows (payer-row-id r) r))
           (payer-row-id r)))
    ((of id)      (hashmap-ref rows id #f))
    ((by-job jid) (hashmap-filter
                   (lambda (r) (equal? (payer-row-job-id r) jid)) rows))
    ((all)        (hashmap-filter (lambda (v) #t) rows))
    ((portrait)   (list 'payer-ledger
                        (serialize-hashmap rows payer-row->list)))))

(define (spawn-payer-ledger)
  (spawn ^payer-ledger (hashmap)))


;;; ── the demand desk — prepaid customers ──────────────────────────────────
;;; A customer is an API-key hash the operator tops up; intake debits by
;;; the quoted amount. The key itself never enters the book — only its
;;; hash — and the owner-did binds the customer to the citizen running
;;; the demand surface for them.

(define-record-type <demand-customer>
  (%make-demand-customer key-hash name owner-did balance asset active?)
  demand-customer?
  (key-hash  demand-customer-key-hash) ; string — sha256 of the API key
  (name      demand-customer-name)     ; string — the operator's label
  (owner-did demand-customer-owner-did); string — the operator citizen
  (balance   demand-customer-balance)  ; number — prepaid remainder
  (asset     demand-customer-asset)    ; string — the unit the balance counts
  (active?   demand-customer-active?)) ; boolean

(define* (make-demand-customer #:key key-hash name owner-did balance asset active?)
  (unless (and (string? key-hash) (not (string-null? key-hash)))
    (error "demand-customer: key-hash must be a non-empty string" key-hash))
  (unless (string? name)
    (error "demand-customer: name must be a string" name))
  (unless (string? owner-did)
    (error "demand-customer: owner-did must be a string" owner-did))
  (unless (and (number? balance) (>= balance 0))
    (error "demand-customer: balance must be a non-negative number" balance))
  (unless (string? asset)
    (error "demand-customer: asset must be a string" asset))
  (%make-demand-customer key-hash name owner-did balance asset active?))

(define (demand-customer->list c)
  (list (demand-customer-key-hash c) (demand-customer-name c)
        (demand-customer-owner-did c) (demand-customer-balance c)
        (demand-customer-asset c) (demand-customer-active? c)))

(define (list->demand-customer l)
  (make-demand-customer #:key-hash (list-ref l 0) #:name (list-ref l 1)
                        #:owner-did (list-ref l 2) #:balance (list-ref l 3)
                        #:asset (list-ref l 4) #:active? (list-ref l 5)))

(define (^demand-desk bcom customers)
  (methods
    ((put! c)
     (bcom (^demand-desk bcom (hashmap-set customers (demand-customer-key-hash c) c))
           (demand-customer-key-hash c)))
    ((of key-hash) (hashmap-ref customers key-hash #f))
    ;; credit! tops up: amount ≥ 0, answers the new balance | #f unknown key
    ((credit! key-hash amount)
     (let ((c (hashmap-ref customers key-hash #f)))
       (if c
           (bcom (^demand-desk
                  bcom
                  (hashmap-set
                   customers key-hash
                   (make-demand-customer
                    #:key-hash key-hash #:name (demand-customer-name c)
                    #:owner-did (demand-customer-owner-did c)
                    #:balance (+ (demand-customer-balance c) amount)
                    #:asset (demand-customer-asset c)
                    #:active? (demand-customer-active? c))))
                 (+ (demand-customer-balance c) amount))
           #f)))
    ;; debit! spends: amount ≥ 0 — 'insufficient when the balance is
    ;; short, #f on an unknown key, the new balance otherwise
    ((debit! key-hash amount)
     (let ((c (hashmap-ref customers key-hash #f)))
       (cond ((not c) #f)
             ((< (demand-customer-balance c) amount) 'insufficient)
             (else
             (bcom (^demand-desk
                    bcom
                    (hashmap-set
                     customers key-hash
                     (make-demand-customer
                      #:key-hash key-hash #:name (demand-customer-name c)
                      #:owner-did (demand-customer-owner-did c)
                      #:balance (- (demand-customer-balance c) amount)
                      #:asset (demand-customer-asset c)
                      #:active? (demand-customer-active? c))))
                   (- (demand-customer-balance c) amount))))))
    ((all) (hashmap-filter (lambda (v) #t) customers))
    ((portrait) (list 'demand-desk
                      (serialize-hashmap customers demand-customer->list)))))

(define (spawn-demand-desk)
  (spawn ^demand-desk (hashmap)))
