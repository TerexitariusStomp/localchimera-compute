;;; operator.scm — who runs THIS gateway, read from the environment.
;;;
;;; The controller the notices name, and where a report, a data request or a
;;; vulnerability goes, is deployment configuration — never repository content.
;;; It is set once in the environment (on the box, from the provider config's
;;; `operator` alist via deploy/os.scm; locally, `export PLAYNET_OPERATOR_NAME=…`)
;;; and read at call time, so a change is a restart away and never a commit.
;;; Every field is optional: one left out is left out of the answer, and the
;;; notices then render it as a visibly unfilled placeholder.
;;;
;;; ONE table (`%operator-fields`) names every field and its variable. The
;;; static server answers /operator.json and /.well-known/security.txt from it
;;; (server/serve-static.scm); the gateway signs push with the contact and
;;; sends mail from it (push/crypto.scm, interface/adapters/email.scm);
;;; deploy/os.scm builds the variables from the provider config.
;;;
;;;   PLAYNET_OPERATOR_NAME            who is the controller
;;;   PLAYNET_OPERATOR_CONTACT         the general contact (terms §14, privacy §1)
;;;   PLAYNET_OPERATOR_ABUSE           reports and child safety (the page falls back to CONTACT)
;;;   PLAYNET_OPERATOR_PRIVACY         data-subject requests    (the page falls back to CONTACT)
;;;   PLAYNET_OPERATOR_SECURITY        security.txt Contact     (falls back to CONTACT)
;;;   PLAYNET_OPERATOR_JURISDICTION    governing law, the age threshold
;;;   PLAYNET_OPERATOR_ADDRESS         postal address / imprint
;;;   PLAYNET_OPERATOR_SUPERVISORY     the data-protection authority to complain to
;;;   PLAYNET_OPERATOR_REPRESENTATIVE  Art 27 representative or data-protection officer
;;;   PLAYNET_OPERATOR_SOURCE          where this deployment offers its source (AGPL §13);
;;;                                    the upstream repository when unset
;;;   PLAYNET_OPERATOR_DOCS            the live API docs, likewise

(define-module (playnet utils operator)
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module ((srfi srfi-13) #:select (string-trim-both string-null? string-index))
  #:export (%operator-fields operator-config operator-ref contact-uri
            operator-email))

(define %operator-fields
  '(("name"           . "PLAYNET_OPERATOR_NAME")
    ("contact"        . "PLAYNET_OPERATOR_CONTACT")
    ("abuse"          . "PLAYNET_OPERATOR_ABUSE")
    ("privacy"        . "PLAYNET_OPERATOR_PRIVACY")
    ("security"       . "PLAYNET_OPERATOR_SECURITY")
    ("jurisdiction"   . "PLAYNET_OPERATOR_JURISDICTION")
    ("address"        . "PLAYNET_OPERATOR_ADDRESS")
    ("supervisory"    . "PLAYNET_OPERATOR_SUPERVISORY")
    ("representative" . "PLAYNET_OPERATOR_REPRESENTATIVE")
    ("source"         . "PLAYNET_OPERATOR_SOURCE")
    ("docs"           . "PLAYNET_OPERATOR_DOCS")))

(define (operator-config)
  "The operator's fields that are set, as an alist of (key . text)."
  (filter-map (lambda (f)
                (let* ((v (getenv (cdr f)))
                       (t (and v (string-trim-both v))))
                  (and t (not (string-null? t)) (cons (car f) t))))
              %operator-fields))

(define (operator-ref key)
  "One field's text, or #f."
  (assoc-ref (operator-config) key))

;; RFC 9116 and RFC 8292 want a URI: an address becomes mailto:, a URL stands.
(define (contact-uri v)
  (cond ((string-index v #\:) v)
        ((string-index v #\@) (string-append "mailto:" v))
        (else v)))

(define (operator-email)
  "The general contact when it is an e-mail address, else #f — the sender a
   deployment with a mail relay and no `from` falls back to."
  (let ((c (operator-ref "contact")))
    (and c (string-index c #\@) (not (string-index c #\:)) c)))
