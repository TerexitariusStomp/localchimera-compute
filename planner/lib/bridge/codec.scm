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

(define (json-ref obj key)
  "Get KEY from a JSON object (alist).  Returns #f if missing or null."
  (let ((pair (assoc key obj)))
    (if pair
        (let ((v (cdr pair)))
          (if (equal? v 'null) #f v))
        #f)))

(define (maybe f v)
  "Apply F to V if V is not #f."
  (if v (f v) #f))

(define (string->action s)
  "Convert a JSON action string to a VF action symbol.
   Signals an error if the action is not a valid VF action."
  (let ((sym (string->symbol s)))
    (if (vf-action? sym) sym
        (error "Unknown VF action" s))))

(define (action->string a)
  "Convert a VF action symbol to a JSON string."
  (symbol->string a))

(define (json-array->list v)
  "Convert a JSON array (vector) to a list.  Pass through lists; #f stays #f."
  (cond
    ((vector? v) (vector->list v))
    ((list? v) v)
    (else v)))

(define (json-array? v)
  "True if V is a plain list (not an alist) — should become a JSON array."
  (and (list? v) (not (null? v)) (not (pair? (car v)))))

(define (maybe-pair key val)
  "Build a (key . val) pair, or #f if val is #f.
   Plain lists become vectors for JSON array serialization.
   Alists stay as-is (they serialize as JSON objects)."
  (cond
    ((not val) #f)
    ((json-array? val) (cons key (list->vector val)))
    (else (cons key val))))


;; =========================================================================
;; Measure ↔ JSON
;; =========================================================================

(define (json->measure obj)
  "Convert {\"value\": N, \"unit\": \"kg\"} to a <measure>.
   Returns #f if obj is #f or missing required fields."
  (and obj
       (let ((val (json-ref obj "value"))
             (unit (json-ref obj "unit")))
         (and val unit (make-measure val unit)))))

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
   Validates required fields: action (must be a valid VF action).
   Missing optional fields default to #f."
  (let ((action-str (json-ref obj "action")))
    (unless action-str
      (error "EconomicEvent requires 'action' field"))
    (make-economic-event
      (json-ref obj "id")
      (string->action action-str)
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
      (maybe json-array->list (json-ref obj "inScopeOf"))
      (json-ref obj "previousEvent")
      (json-ref obj "excludeFromAdu")
      (json-ref obj "marketValue"))))

(define (economic-event->json e)
  "Convert an <economic-event> to a JSON-compatible alist.
   Omits fields that are #f to keep payloads compact."
  (filter identity
    (list
      (maybe-pair "id"                      (economic-event-id e))
      (maybe-pair "action"                  (action->string (economic-event-action e)))
      (maybe-pair "inputOf"                 (economic-event-input-of e))
      (maybe-pair "outputOf"                (economic-event-output-of e))
      (maybe-pair "resourceInventoriedAs"   (economic-event-resource-inventoried-as e))
      (maybe-pair "toResourceInventoriedAs" (economic-event-to-resource-inventoried-as e))
      (maybe-pair "resourceConformsTo"      (economic-event-resource-conforms-to e))
      (maybe-pair "resourceClassifiedAs"    (economic-event-resource-classified-as e))
      (maybe-pair "provider"                (economic-event-provider e))
      (maybe-pair "receiver"                (economic-event-receiver e))
      (maybe-pair "resourceQuantity"        (measure->json (economic-event-resource-quantity e)))
      (maybe-pair "effortQuantity"          (measure->json (economic-event-effort-quantity e)))
      (maybe-pair "hasBeginning"            (economic-event-has-beginning e))
      (maybe-pair "hasEnd"                  (economic-event-has-end e))
      (maybe-pair "hasPointInTime"          (economic-event-has-point-in-time e))
      (maybe-pair "created"                 (economic-event-created e))
      (maybe-pair "atLocation"              (economic-event-at-location e))
      (maybe-pair "toLocation"              (economic-event-to-location e))
      (maybe-pair "state"                   (economic-event-state e))
      (maybe-pair "fulfills"                (economic-event-fulfills e))
      (maybe-pair "satisfies"               (economic-event-satisfies e))
      (maybe-pair "corrects"                (economic-event-corrects e))
      (maybe-pair "realizationOf"           (economic-event-realization-of e))
      (maybe-pair "settles"                 (economic-event-settles e))
      (maybe-pair "note"                    (economic-event-note e))
      (maybe-pair "inScopeOf"               (economic-event-in-scope-of e))
      (maybe-pair "previousEvent"           (economic-event-previous-event e))
      (maybe-pair "excludeFromAdu"          (economic-event-exclude-from-adu e))
      (maybe-pair "marketValue"             (economic-event-market-value e)))))


;; =========================================================================
;; Signal ↔ JSON
;; =========================================================================

(define (signal->json signal)
  "Convert a typed signal alist (symbol keys) to JSON-compatible alist (string keys)."
  (map (lambda (pair)
         (cons (symbol->string (car pair))
               (cdr pair)))
       signal))

(define (json->signal obj)
  "Convert a JSON alist (string keys) to a typed signal alist (symbol keys)."
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
   Format: vf/{scope}/{category}[/{kind}[/{detail}]]
   Returns an alist with 'scope, 'category, and optionally 'kind, 'detail.
   Returns #f if the topic doesn't start with vf/."
  (let ((parts (string-split topic-string #\/)))
    (and (pair? parts)
         (string=? (car parts) "vf")
         (match (cdr parts)
           ((scope category)
            `((scope . ,scope) (category . ,category)))
           ((scope category kind)
            `((scope . ,scope) (category . ,category) (kind . ,kind)))
           ((scope category kind detail)
            `((scope . ,scope) (category . ,category)
              (kind . ,kind) (detail . ,detail)))
           (_ #f)))))

(define (build-topic scope-id category . rest)
  "Build a VF topic string.
   (build-topic \"riverside\" \"events\" \"produce\")
   → \"vf/riverside/events/produce\""
  (string-join (cons* "vf" scope-id category rest) "/"))
