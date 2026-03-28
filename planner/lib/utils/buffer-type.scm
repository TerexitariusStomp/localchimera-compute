;;; buffer-type.scm — Buffer type classification from resource tags

(use-modules (srfi srfi-1))

(define *buffer-types* '(ecological strategic reserve social metabolic consumption))
(define *tier-priority*
  '((ecological . 1) (strategic . 2) (reserve . 3)
    (social . 4) (metabolic . 5) (consumption . 6)))
(define *zone-ord*
  '((red . 0) (yellow . 1) (green . 2) (excess . 3)))
(define *response-times*
  '((ecological . seasons) (strategic . months) (reserve . emergency)
    (social . ongoing) (metabolic . days) (consumption . days)))

(define (buffer-type-from-tags tags)
  "Extract buffer type from resourceClassifiedAs tags. Default: metabolic."
  (or (find (lambda (bt)
              (member (string-append "tag:buffer:" (symbol->string bt)) (or tags '())))
            *buffer-types*)
      'metabolic))

(define (get-response-time buffer-type)
  "Map buffer type to response time symbol."
  (or (assq-ref *response-times* buffer-type) 'days))

(define (composite-buffer-priority tier zone)
  "Composite priority: lower = more urgent. tier-priority * 10 + zone-ord."
  (+ (* (or (assq-ref *tier-priority* tier) 5) 10)
     (or (assq-ref *zone-ord* zone) 3)))

(define (get-buffer-type spec-id resource-specs)
  "Get buffer type for a spec from its tags."
  (let ((spec (find (lambda (s) (equal? (resource-specification-id s) spec-id))
                    resource-specs)))
    (if spec
        (buffer-type-from-tags (resource-specification-resource-classified-as spec))
        'metabolic)))
