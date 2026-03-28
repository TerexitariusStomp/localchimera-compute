;;; codec.scm — Pure JSON ↔ VF record translation for the MQTT bridge
;;;
;;; Converts between JSON alists (from guile-json's json-string->scm)
;;; and VF record types from schemas.scm.  No actors, no side effects.
;;;
;;; JSON wire format uses camelCase keys matching the VF GraphQL spec.
;;; Scheme uses the record accessors from schemas.scm.
;;;
;;; Assumes schemas.scm is loaded.

(use-modules (json)
             (srfi srfi-1)
             (ice-9 match))


;; =========================================================================
;; Helpers
;; =========================================================================

(define (json-ref obj key . default)
  "Get KEY from a JSON object (alist).  Returns #f if missing, or DEFAULT."
  (let ((pair (assoc key obj)))
    (if pair
        (let ((v (cdr pair)))
          (if (equal? v 'null) #f v))
        (if (null? default) #f (car default)))))

(define (maybe f v)
  "Apply F to V if V is not #f."
  (if v (f v) #f))

(define (string->action s)
  "Convert a JSON action string like \"produce\" to a VF action symbol."
  (let ((sym (string->symbol s)))
    (if (vf-action? sym) sym
        (error "Unknown VF action" s))))

(define (action->string a)
  "Convert a VF action symbol to a JSON string."
  (symbol->string a))


;; =========================================================================
;; Measure ↔ JSON
;; =========================================================================

(define (json->measure obj)
  "Convert {\"value\": N, \"unit\": \"kg\"} to a <measure>."
  (and obj
       (make-measure (json-ref obj "value")
                     (json-ref obj "unit"))))

(define (measure->json m)
  "Convert a <measure> to a JSON-compatible alist."
  (and m
       `(("value" . ,(measure-has-numerical-value m))
         ("unit"  . ,(measure-has-unit m)))))


;; =========================================================================
;; EconomicEvent ↔ JSON
;; =========================================================================

(define (json->economic-event obj)
  "Convert a JSON alist to an <economic-event>.
   Missing fields default to #f.  Action is required."
  (make-economic-event
    (json-ref obj "id")
    (string->action (json-ref obj "action"))
    (json-ref obj "inputOf")
    (json-ref obj "outputOf")
    (json-ref obj "resourceInventoriedAs")
    (json-ref obj "toResourceInventoriedAs")
    (json-ref obj "resourceConformsTo")
    (json-ref obj "resourceClassifiedAs")
    (json-ref obj "provider")
    (json-ref obj "receiver")
    (maybe json->measure (json-ref obj "resourceQuantity"))
    (maybe json->measure (json-ref obj "effortQuantity"))
    (json-ref obj "hasBeginning")
    (json-ref obj "hasEnd")
    (json-ref obj "hasPointInTime")
    (json-ref obj "created")
    (json-ref obj "atLocation")
    (json-ref obj "toLocation")
    (json-ref obj "state")
    (json-ref obj "fulfills")
    (json-ref obj "satisfies")
    (json-ref obj "corrects")
    (json-ref obj "realizationOf")
    (json-ref obj "settles")
    (json-ref obj "note")
    (json-ref obj "inScopeOf")
    (json-ref obj "previousEvent")
    (json-ref obj "excludeFromAdu")
    (json-ref obj "marketValue")))

(define (economic-event->json e)
  "Convert an <economic-event> to a JSON-compatible alist.
   Omits fields that are #f to keep payloads compact."
  (filter cdr
    `(("id"                      . ,(economic-event-id e))
      ("action"                  . ,(action->string (economic-event-action e)))
      ("inputOf"                 . ,(economic-event-input-of e))
      ("outputOf"                . ,(economic-event-output-of e))
      ("resourceInventoriedAs"   . ,(economic-event-resource-inventoried-as e))
      ("toResourceInventoriedAs" . ,(economic-event-to-resource-inventoried-as e))
      ("resourceConformsTo"      . ,(economic-event-resource-conforms-to e))
      ("resourceClassifiedAs"    . ,(economic-event-resource-classified-as e))
      ("provider"                . ,(economic-event-provider e))
      ("receiver"                . ,(economic-event-receiver e))
      ("resourceQuantity"        . ,(measure->json (economic-event-resource-quantity e)))
      ("effortQuantity"          . ,(measure->json (economic-event-effort-quantity e)))
      ("hasBeginning"            . ,(economic-event-has-beginning e))
      ("hasEnd"                  . ,(economic-event-has-end e))
      ("hasPointInTime"          . ,(economic-event-has-point-in-time e))
      ("created"                 . ,(economic-event-created e))
      ("atLocation"              . ,(economic-event-at-location e))
      ("toLocation"              . ,(economic-event-to-location e))
      ("state"                   . ,(economic-event-state e))
      ("fulfills"                . ,(economic-event-fulfills e))
      ("satisfies"               . ,(economic-event-satisfies e))
      ("corrects"                . ,(economic-event-corrects e))
      ("realizationOf"           . ,(economic-event-realization-of e))
      ("settles"                 . ,(economic-event-settles e))
      ("note"                    . ,(economic-event-note e))
      ("inScopeOf"               . ,(economic-event-in-scope-of e))
      ("previousEvent"           . ,(economic-event-previous-event e))
      ("excludeFromAdu"          . ,(economic-event-exclude-from-adu e))
      ("marketValue"             . ,(economic-event-market-value e)))))


;; =========================================================================
;; Signal ↔ JSON
;; =========================================================================

(define (signal->json signal)
  "Convert a typed signal alist to a JSON-compatible alist."
  (map (lambda (pair)
         (cons (symbol->string (car pair))
               (cdr pair)))
       signal))

(define (json->signal obj)
  "Convert a JSON alist to a typed signal alist."
  (map (lambda (pair)
         (cons (string->symbol (car pair))
               (cdr pair)))
       obj))

(define (signal->json-string signal)
  "Convert a signal alist to a JSON string."
  (scm->json-string (signal->json signal)))

(define (json-string->signal str)
  "Parse a JSON string into a signal alist."
  (json->signal (json-string->scm str)))


;; =========================================================================
;; Topic parsing / building
;; =========================================================================

(define (parse-topic topic-string)
  "Parse a VF topic string into an alist.
   \"vf/scope-id/events/produce/spec-wheat\"
   → ((prefix . \"vf\") (scope . \"scope-id\") (category . \"events\")
      (kind . \"produce\") (detail . \"spec-wheat\"))"
  (let ((parts (string-split topic-string #\/)))
    (match parts
      ((prefix scope category)
       `((prefix . ,prefix) (scope . ,scope)
         (category . ,category)))
      ((prefix scope category kind)
       `((prefix . ,prefix) (scope . ,scope)
         (category . ,category) (kind . ,kind)))
      ((prefix scope category kind detail)
       `((prefix . ,prefix) (scope . ,scope)
         (category . ,category) (kind . ,kind) (detail . ,detail)))
      (_ `((raw . ,topic-string))))))

(define (build-topic scope-id category . rest)
  "Build a VF topic string.
   (build-topic \"riverside\" \"events\" \"produce\")
   → \"vf/riverside/events/produce\""
  (string-join (cons* "vf" scope-id category rest) "/"))
