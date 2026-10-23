;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/server/test-operator-endpoint.scm
;;;
;;; Who runs this gateway comes from PLAYNET_OPERATOR_* in the environment and
;;; is answered at /operator.json and /.well-known/security.txt — nothing in a
;;; tracked file. A field left out is left out; with no security contact the
;;; unfinished template answers instead.
;;;
;;; Run: guile -L . -L module -L tests tests/server/test-operator-endpoint.scm

(use-modules (playnet test harness)
             ((server serve-static) #:select (handle-operator handle-security-txt))
             ((playnet utils operator) #:select (%operator-fields operator-email contact-uri))
             (ice-9 textual-ports) (ice-9 match)
             (web response)
             (srfi srfi-13)
             (json))

(define (call thunk) (call-with-values thunk list))
(define (status-of p) (response-code (car p)))
(define (json-of p) (json-string->scm (cadr p)))

(define %vars (map cdr %operator-fields))
(for-each unsetenv %vars)

;; deploy/os.scm names the same fields: the two lists must not drift
(check "os.scm's operator keys are the module's fields"
       (let* ((text (call-with-input-file "deploy/os.scm" get-string-all))
              (m (string-contains text "(define %operator-keys"))
              (form (read (open-input-string (substring text m)))))
         (match form
           (('define '%operator-keys ('quote keys))
            (equal? (sort (map symbol->string keys) string<?)
                    (sort (map car %operator-fields) string<?)))
           (_ #f)))
       #t)

;; nothing set: an empty object, and the fallback template answers security.txt
(let ((r (call handle-operator)))
  (check "operator.json (nothing set): 200" (status-of r) 200)
  (check "operator.json (nothing set): an empty object" (cadr r) "{}"))
(check "security.txt (no contact): the template answers"
       (call-with-values (lambda () (handle-security-txt (lambda () (values 'fallback "template"))))
         (lambda (a b) (list a b)))
       '(fallback "template"))

;; set: only what is set is answered, trimmed
(setenv "PLAYNET_OPERATOR_NAME" "  Kreuzberg Commune e.V.  ")
(setenv "PLAYNET_OPERATOR_CONTACT" "contact@example.org")
(setenv "PLAYNET_OPERATOR_ABUSE" "")
(let ((j (json-of (call handle-operator))))
  (check "operator.json: name, trimmed" (assoc-ref j "name") "Kreuzberg Commune e.V.")
  (check "operator.json: contact" (assoc-ref j "contact") "contact@example.org")
  (check "operator.json: an empty variable is left out" (assoc-ref j "abuse") #f)
  (check "operator.json: unset fields are left out" (assoc-ref j "address") #f))

;; security.txt: falls back to contact, an address becomes mailto:, Expires is a year out
(let* ((r (call (lambda () (handle-security-txt (lambda () (error "no fallback expected"))))))
       (txt (cadr r)))
  (check "security.txt: 200" (status-of r) 200)
  (check "security.txt: Contact is a mailto: of the contact"
         (and (string-contains txt "Contact: mailto:contact@example.org\n") #t) #t)
  (check "security.txt: Expires present" (and (string-contains txt "\nExpires: 20") #t) #t))

;; a URL stands as written; a dedicated security contact wins
(setenv "PLAYNET_OPERATOR_SECURITY" "https://example.org/security")
(let ((txt (cadr (call (lambda () (handle-security-txt (lambda () (error "no"))))))))
  (check "security.txt: a URL stands as written, and wins over contact"
         (and (string-contains txt "Contact: https://example.org/security\n") #t) #t)
  (check "security.txt: the general contact is not repeated"
         (string-contains txt "mailto:contact@example.org") #f))


;; push and mail follow the operator, and never another deployment's address
(unsetenv "PLAYNET_OPERATOR_CONTACT") (unsetenv "SMTP_FROM")
(check "no contact, no operator email" (operator-email) #f)
(setenv "PLAYNET_OPERATOR_CONTACT" "hi@example.org")
(check "an email contact is the operator email" (operator-email) "hi@example.org")
(setenv "PLAYNET_OPERATOR_CONTACT" "https://example.org/contact")
(check "a URL contact is not an email" (operator-email) #f)
(check "a URL contact stands as the push subject" (contact-uri "https://example.org/contact") "https://example.org/contact")

(test-summary!)
