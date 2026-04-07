;;; module/weave/ui/ffi.scm — FFI bindings shared between Weave UI modules.
;;;
;;; Hoot 0.8.0's library-group linker rejects cross-module top-level
;;; references — when (weave ui join) is a `define-module` and refers to
;;; `prevent-default!` declared in `module/weave/browser.scm`, the linker
;;; throws "unbound top-level prevent-default!". The fix is to move the
;;; small set of DOM bindings the UI modules need into a real module that
;;; both the entry point and the UI modules import.
;;;
;;; Keep this module focused: only put bindings here that are referenced
;;; from a UI module under module/weave/ui/. DOM bindings used solely by
;;; module/weave/browser.scm itself stay there to avoid bloating the wasm
;;; import section.

(define-module (weave ui ffi)
  #:use-module (hoot ffi)
  #:export (get-element-by-id
            prevent-default!
            element-value
            set-element-value!))

;; DOM lookup
(define-foreign get-element-by-id
  "document" "getElementById"
  (ref string) -> (ref null extern))

;; Event helpers
(define-foreign prevent-default!
  "event" "preventDefault"
  (ref null extern) -> none)

;; <input>/<select> value access
(define-foreign element-value
  "element" "value"
  (ref null extern) -> (ref string))

(define-foreign set-element-value!
  "element" "setValue"
  (ref null extern) (ref string) -> none)
