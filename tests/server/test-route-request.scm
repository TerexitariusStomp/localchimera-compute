;;; tests/server/test-route-request.scm
;;;
;;; The /route proxy builds Valhalla's request body by hand, so what a query
;;; may say is read down to a few shapes: two ends, optional waypoints, a
;;; costing token, up to three alternates, a clock (now / leave-at / arrive-by),
;;; a language tag and a unit. Anything else is dropped — the request then asks
;;; for less, never for something else.
;;;
;;; Run: guile -L module -L tests -L . tests/server/test-route-request.scm

(use-modules (playnet test harness)
             ((server serve-static) #:select (route-request-json))
             (srfi srfi-13))

(define (has? body needle) (and body (string-contains body needle) #t))
(define from-to "from=37.77,-122.41&to=37.78,-122.40")
(define (q . extra) (string-join (cons from-to extra) "&"))

;; ── the ends ─────────────────────────────────────────────────────────────
(check "no destination: no request" (route-request-json "from=37.77,-122.41") #f)
(check "no query: no request" (route-request-json #f) #f)
(check "a bad coordinate: no request" (route-request-json "from=x,y&to=1,2") #f)
(let ((b (route-request-json (q))))
  (check "two ends: both locations, in order"
    (and (has? b "\"locations\":[{\"lat\":37.77,\"lon\":-122.41},{\"lat\":37.78,\"lon\":-122.4}]") #t) #t)
  (check "the default costing is the engine's walking one" (has? b "\"costing\":\"foot\"") #t)
  (check "kilometres by default" (has? b "\"units\":\"kilometers\"") #t)
  (check "no alternates unless asked" (has? b "alternates") #f)
  (check "no clock unless asked" (has? b "date_time") #f)
  (check "no language unless asked" (has? b "language") #f))

;; ── costing ──────────────────────────────────────────────────────────────
(check "a costing name passes through"
  (has? (route-request-json (q "profile=multimodal")) "\"costing\":\"multimodal\"") #t)
(check "a costing is a token, nothing more"
  (has? (route-request-json (q "profile=auto\",\"x\":\"1")) "\"costing\":\"autox\"") #t)

;; ── alternates ───────────────────────────────────────────────────────────
(check "alternates=2 asks for two"
  (has? (route-request-json (q "alternates=2")) "\"alternates\":2") #t)
(check "alternates past three are dropped"
  (has? (route-request-json (q "alternates=9")) "alternates") #f)
(check "alternates=0 asks for none"
  (has? (route-request-json (q "alternates=0")) "alternates") #f)
(check "alternates that are not a number are dropped"
  (has? (route-request-json (q "alternates=a\"b")) "alternates") #f)
(check "waypoints and alternates do not mix (Valhalla offers none then)"
  (has? (route-request-json (q "alternates=2" "via=37.775,-122.405")) "alternates") #f)
(check "a clock and alternates do not mix either"
  (has? (route-request-json (q "alternates=2" "depart=now")) "alternates") #f)

;; ── the clock ────────────────────────────────────────────────────────────
(check "depart=now: the engine's current time"
  (has? (route-request-json (q "depart=now")) "\"date_time\":{\"type\":0}") #t)
(check "depart=T: leave at T"
  (has? (route-request-json (q "depart=2026-10-14T08:30"))
        "\"date_time\":{\"type\":1,\"value\":\"2026-10-14T08:30\"}") #t)
(check "arrive=T: be there by T"
  (has? (route-request-json (q "arrive=2026-10-14T08:30"))
        "\"date_time\":{\"type\":2,\"value\":\"2026-10-14T08:30\"}") #t)
(check "a malformed time is dropped"
  (has? (route-request-json (q "depart=2026-10-14T08:30\",\"x\":1")) "date_time") #f)
(check "a time with seconds is dropped (the engine takes minutes)"
  (has? (route-request-json (q "depart=2026-10-14T08:30:00")) "date_time") #f)
(check "a time with letters in the digits is dropped"
  (has? (route-request-json (q "depart=2026-1a-14T08:30")) "date_time") #f)

;; ── language and units ───────────────────────────────────────────────────
(check "a language tag passes"
  (has? (route-request-json (q "lang=de-DE")) "\"language\":\"de-DE\"") #t)
(check "a language with quotes is dropped"
  (has? (route-request-json (q "lang=en\"x")) "language") #f)
(check "a language too long is dropped"
  (has? (route-request-json (q "lang=abcdefghijk")) "language") #f)
(check "units=mi asks for miles"
  (has? (route-request-json (q "units=mi")) "\"units\":\"miles\"") #t)
(check "any other unit is kilometres"
  (has? (route-request-json (q "units=parsecs")) "\"units\":\"kilometers\"") #t)

;; ── the whole body is one JSON object ────────────────────────────────────
(let ((b (route-request-json (q "profile=bicycle" "alternates=1" "lang=en-US" "units=mi"))))
  (check "a full request is one object"
    (and (string-prefix? "{" b) (string-suffix? "}" b)) #t)
  (check "…with every part in place"
    (and (has? b "\"costing\":\"bicycle\"") (has? b "\"alternates\":1")
         (has? b "\"units\":\"miles\",\"language\":\"en-US\"}}"))
    #t))

(test-summary!)
