;;;
;;; json.scm - JSON (RFC4627) Parser
;;;
;;;   Copyright (c) 2006 Rui Ueyama (rui314@gmail.com)
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

;;; http://www.ietf.org/rfc/rfc4627.txt

;; NOTE: This module depends on parser.peg, whose API is not officially
;; fixed.  Hence do not take this code as an example of parser.peg;
;; this will likely to be rewritten once parser.peg's API is changed.

(define-module rfc.json
  (use gauche.parameter)
  (use gauche.sequence)
  (use parser.peg)
  (use srfi-13)
  (use srfi-14)
  (use srfi-43)
  (export <json-parse-error> <json-construct-error>
          parse-json parse-json-string
          construct-json construct-json-string

          json-array-handler json-object-handler json-special-handler

          json-parser                   ;experimental
          ))
(select-module rfc.json)

;; NB: We have <json-parse-error> independent from <parse-error> for
;; now, since parser.peg's interface may be changed later.
(define-condition-type <json-parse-error> <error> #f
  (position)                            ;stream position
  (objects))                            ;offending object(s) or messages

(define-condition-type <json-construct-error> <error> #f
  (object))                             ;offending object

(define json-array-handler   (make-parameter list->vector))
(define json-object-handler  (make-parameter identity))
(define json-special-handler (make-parameter identity))

(define (build-array elts) ((json-array-handler) elts))
(define (build-object pairs) ((json-object-handler) pairs))
(define (build-special symbol) ((json-special-handler) symbol))

;;;============================================================
;;; Parser
;;;
(define %ws ($skip-many ($one-of #[ \t\r\n])))

(define %begin-array     ($seq ($char #\[) %ws))
(define %begin-object    ($seq ($char #\{) %ws))
(define %end-array       ($seq ($char #\]) %ws))
(define %end-object      ($seq ($char #\}) %ws))
(define %name-separator  ($seq ($char #\:) %ws))
(define %value-separator ($seq ($char #\,) %ws))

(define %special
  ($fmap ($ build-special $ string->symbol $ rope-finalize $)
         ($or ($string "false") ($string "true") ($string "null"))))

(define %value
  ($lazy
   ($fmap (^[v _] v) ($or %special %object %array %number %string) %ws)))

(define %array
  ($fmap (^[_0 lis _1] (build-array (rope-finalize lis)))
         %begin-array ($sep-by %value %value-separator) %end-array))

(define %number
  (let* ([%sign ($or ($do [($char #\-)] ($return -1))
                     ($do [($char #\+)] ($return 1))
                     ($return 1))]
         [%digits ($fmap ($ string->number $ list->string $) ($many digit 1))]
         [%int %digits]
         [%frac ($do [($char #\.)]
                     [d ($many digit 1)]
                     ($return (string->number (apply string #\0 #\. d))))]
         [%exp ($fmap (^[_ s d] (* s d)) ($one-of #[eE]) %sign %digits)])
    ($fmap (^[sign int frac exp]
             (let1 mantissa (+ int frac)
               (* sign (if exp (exact->inexact mantissa) mantissa)
                  (if exp (expt 10 exp) 1))))
           %sign %int ($or %frac ($return 0)) ($or %exp ($return #f)))))

(define %string
  (let* ([%dquote ($char #\")]
         [%escape ($char #\\)]
         [%hex4 ($fmap (^s (string->number (list->string s) 16))
                       ($many hexdigit 4 4))]
         [%special-char
          ($do %escape
               ($or ($char #\")
                    ($char #\\)
                    ($char #\/)
                    ($do [($char #\b)] ($return #\x08))
                    ($do [($char #\f)] ($return #\page))
                    ($do [($char #\n)] ($return #\newline))
                    ($do [($char #\r)] ($return #\return))
                    ($do [($char #\t)] ($return #\tab))
                    ($do [($char #\u)] (c %hex4) ($return (ucs->char c)))))]
         [%unescaped ($none-of #[\"])]
         [%body-char ($or %special-char %unescaped)]
         [%string-body ($->rope ($many %body-char))])
    ($between %dquote %string-body %dquote)))

(define %object
  (let1 %member ($do [k %string] %ws
                     %name-separator
                     [v %value]
                     ($return (cons k v)))
    ($between %begin-object
              ($fmap ($ build-object $ rope-finalize $)
                     ($sep-by %member %value-separator))
              %end-object)))

(define json-parser ($seq %ws ($or eof %object %array)))

;; entry point
(define (parse-json :optional (port (current-input-port)))
  (guard (e [(<parse-error> e)
             ;; not to expose parser.peg's <parse-error>.
             (error <json-parse-error>
                    :position (~ e'position) :objects (~ e'objects)
                    :message (~ e'message))])
    (peg-parse-port json-parser port)))

(define (parse-json-string str)
  (call-with-input-string str (cut parse-json <>)))

;;;============================================================
;;; Writer
;;;

(define (print-value obj)
  (cond [(or (eq? obj 'false) (eq? obj #f)) (display "false")]
        [(or (eq? obj 'true) (eq? obj #t))  (display "true")]
        [(eq? obj 'null)  (display "null")]
        [(list? obj)      (print-object obj)]
        [(string? obj)    (print-string obj)]
        [(number? obj)    (print-number obj)]
        [(is-a? obj <dictionary>) (print-object obj)]
        [(is-a? obj <sequence>)   (print-array obj)]
        [else (error <json-construct-error> :object obj
                     "can't convert Scheme object to json:" obj)]))

(define (print-object obj)
  (display "{")
  (fold (^[attr comma]
          (unless (pair? attr)
            (error <json-construct-error> :object obj
                   "construct-json needs an assoc list or dictionary, \
                    but got:" obj))
          (display comma)
          (print-string (x->string (car attr)))
          (display ":")
          (print-value (cdr attr))
          ",")
        "" obj)
  (display "}"))

(define (print-array obj)
  (display "[")
  (for-each-with-index (^[i val]
                         (unless (zero? i) (display ","))
                         (print-value val))
                       obj)
  (display "]"))

(define (print-number num)
  (cond [(or (not (real? num)) (not (finite? num)))
         (error <json-construct-error> :object num
                "json cannot represent a number" num)]
        [(and (rational? num) (not (integer? num)))
         (write (exact->inexact num))]
        [else (write num)]))

(define (print-string str)
  (define specials
    '((#\" . #\") (#\\ . #\\) (#\x08 . #\b) (#\page . #\f)
      (#\newline . #\n) (#\return . #\r) (#\tab . #\t)))
  (define (print-char c)
    (cond [(assv c specials) => (^p (write-char #\\) (write-char (cdr p)))]
          [(and (char-set-contains? char-set:ascii c)
                (not (eq? (char-general-category c) 'Cc)))
           (write-char c)]
          [else (format #t "\\u~4,'0x" (char->ucs c))]))
  (display "\"")
  (string-for-each print-char str)
  (display "\""))

(define (construct-json x :optional (oport (current-output-port)))
  (with-output-to-port oport
    (^()
      (cond [(or (list? x) (is-a? x <dictionary>)) (print-object x)]
            [(and (is-a? x <sequence>) (not (string? x))) (print-array x)]
            [else (error <json-construct-error> :object x
                         "construct-json expects a list or a vector, \
                          but got" x)]))))

(define (construct-json-string x)
  (call-with-output-string (cut construct-json x <>)))

