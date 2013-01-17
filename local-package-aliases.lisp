;;;; -*- Mode: LISP; Syntax: COMMON-LISP; indent-tabs-mode: nil; coding: utf-8;  -*-
;;;; Copyright (C) 2013 Anton Vodonosov (avodonosov@yandex.ru)
;;;; See LICENSE for details.

(defpackage local-package-aliases
  (:use #:cl)
  (:shadow #:set)
  (:export #:set
           #:set-aliasing-reader
           #:call-with-aliasing-readtable
           #:hook-into-swank
           #:unhook-from-swank))

(in-package #:local-package-aliases)

(define-condition aliased-ref-error (simple-error reader-error) ())

(defun err (format-control &rest format-arguments)
  (error 'aliased-ref-error
         :format-control format-control
         :format-arguments format-arguments))

;;; datastructure to store package aliases ---------------------------

(defparameter *package-to-aliases-map* (make-hash-table :test #'eq)
  "Mapping from package object to a hash-table of local aliases active in this package.
The hash-table of local aliases maps string alias to a package designator.")

(defun alias-table-for (package)
  (gethash package *package-to-aliases-map*))

(defun has-local-aliases-p (package)
  (let ((alias-table (alias-table-for package)))
    (and alias-table (> (hash-table-count alias-table) 0))))

(defun set-alias-table-for (for-package &rest package-alias-pairs)
  "PACKAGE-ALIAS-PAIRS is a list in the form (package-designator alias-string package-designator alias-string ...)"
  (let ((aliases-table (make-hash-table :test #'equal)))
    (loop for (package alias) on package-alias-pairs by #'cddr
         do (setf (gethash (string alias) aliases-table) package))
    (setf (gethash for-package *package-to-aliases-map*) aliases-table)))

(defmacro set (&rest package-alias-pairs)
  (let ((args (loop for (package alias) on package-alias-pairs by #'cddr
                 nconcing (list (if (symbolp package) (list 'quote package) package)
                                (string alias)))))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (set-alias-table-for *package* ,@args))))

(defun find-aliased-package (alias)
  (or (gethash alias
               (or (gethash *package* *package-to-aliases-map*)
                   (err "There is no alias ~A in the package ~A" alias *package*)))
      (err "There is no alias ~A in the package ~A" alias *package*)))

(defun aliases-of (package in-package)
  (let ((alias-table (alias-table-for in-package))
        aliases)
    (when alias-table
      (maphash (lambda (alias aliased-package-designator)
                 (when (eq package (find-package aliased-package-designator))
                   (push alias aliases)))
               alias-table))
    aliases))

;;; the reader macro ------------------------------------------

(defun find-aliased-symbol (token)
  "TOEKN is a string in the form alias:symbol or alias::symbol."
  (let* ((colon-pos (or (position #\: token :test #'char=)
                        (err "Wrong aliased reference: ~A" token)))
         (double-colon-p (if (<= (length token) (1+ colon-pos))
                             (err "Wrong aliased reference: ~A" token)
                             (char= #\: (aref token (1+ colon-pos)))))
         (package-alias (subseq token 0 colon-pos))
         (package (find-aliased-package package-alias))
         (symbol-name (subseq token (+ colon-pos (if double-colon-p 2 1)))))
    (multiple-value-bind (symbol status) (find-symbol symbol-name package)     
      (when (null status)
        (err "Symbol ~A is not found in the package ~A" symbol-name package))
      (when (and (not double-colon-p)
                 (not (eq :external status)))
        (err "Symbol ~A is not external in the package ~A" symbol-name package))
      symbol)))

(defun whitespace-p (char)
  (or (case char ((#\Space #\Tab #\Return #\Linefeed #\Page)
                  t))
      (char= #\Newline char)))

(defun terminating-macro-char-p (char)
  (case char ((#\" #\' #\( #\) #\, #\; #\`)
                  t)))

(defun terminator-p (char)
  (or (whitespace-p char)
      (terminating-macro-char-p char)))

(defun apply-case-mode (readtable-case-mode str)
  (funcall (ecase readtable-case-mode
             (:upcase #'string-upcase)
             (:downcase #'string-downcase)
             (:preserve #'identity)
             (:invert (error ":invert readtable-case mode handling is not implemented yet")))
           str))

(defun read-token (stream)
  (let ((str (make-array 3 :element-type 'character :adjustable t :fill-pointer 0))
        char)
    (loop       
       (setf char (read-char stream nil nil))
       (when (null char) (RETURN))
       (when (terminator-p char)
         (unread-char char stream)
         (RETURN))
       (vector-push-extend char str))
    (apply-case-mode (readtable-case *readtable*) str)))

(defun read-package-aliased-symbol (stream char original-readtable)
  (if (has-local-aliases-p *package*)
      (find-aliased-symbol (read-token stream))
      (let ((*readtable* (copy-readtable *readtable*)))
        (set-syntax-from-char char char *readtable* original-readtable)
        (with-input-from-string (s (string char))
          (read (make-concatenated-stream s stream) t nil t)))))

(defun set-aliasing-reader (to-readtable &optional (macro-char #\$) default-readtable)
  "Modifies TO-READTABLE so that MACRO-CHAR at the beginning a token in
form $ALIAS:SYMBOL or $ALIAS::SYMBOL is used to refere other packages,
according to the aliases set in the current packges by LOCAL-PACKAGE-ALIASES:SET.

The DEFAULT-READTABLE is used when the current package has no aliases.
In this case the hangler for MACRO-CHAR is retrieved from DEFAULT-READTABLE
and temporary applied to the current readtable using CL:SET-SYNTAX-FROM-CHAR.

The default value for DEFAULT-READTABLE is copy of TO-READTABLE before
it's syntax is modified."

  (when (not default-readtable)
    (setf default-readtable (copy-readtable to-readtable)))
  (set-macro-character macro-char
                       (lambda (stream char)
                         (read-package-aliased-symbol stream char default-readtable))
                         t
                         to-readtable))

(defun aliasing-readtable (&optional (prototype-readtable *readtable*) (macro-char #\$))
  (let ((readtable (copy-readtable prototype-readtable)))
    (set-aliasing-reader readtable macro-char)
    readtable))

(defun call-with-aliasing-readtable (thunk)
  "Convenience function to use in ASDF's :around-compile argument."
  (let ((*readtable* (aliasing-readtable)))
    (funcall thunk)))

;;; slime support -------------------------------------------

(defun call-with-nicknames (alias-table fn)
  "Helper function useful to hook into SLIME
in order to provide completion, go-to-definition,
function parameters help and other SLIME support."
  (let ((old-names '()))
    (unwind-protect
         (progn
           (when alias-table
             ;; add every alias as a nickname to the corresponding package
             (maphash (lambda (alias package-designator)
                        (let ((package (find-package package-designator)))
                          (when package
                            (push (cons (package-name package)
                                        (package-nicknames package))
                                  old-names)
                            (handler-case
                                (rename-package package
                                                (package-name package)
                                                (cons (format nil "$~A" alias)
                                                      (package-nicknames package)))
                              (serious-condition (e)
                                (warn "local-package-aliases: can't add alias $~A as a nickname to the package ~A package: ~A"
                                      alias package e))))))
                      alias-table))
           (funcall fn))
      ;; Restore the original nicknames.
      ;; Do this in reverse order to handle correctly
      ;; the case when alias-table refers the same
      ;; package several times.
      (dolist (old-name-nicknames (reverse old-names))
        (rename-package (car old-name-nicknames)
                        (car old-name-nicknames)
                        (cdr old-name-nicknames))))))

(defun swank-buffer-package ()
  (ignore-errors (symbol-value (read-from-string "swank::*buffer-package*"))))

(defun with-aliases-as-nicknames-hook (next-fn)
  (call-with-nicknames (alias-table-for (swank-buffer-package))
                       next-fn))

(defun hook-into-swank ()
  (load (asdf:system-relative-pathname :local-package-aliases "swank-patch.lisp"))
  (format t "~&; swank patched by local-package-aliases to provide swank::*around-eval-for-emacs-hook*~%")
  (pushnew 'with-aliases-as-nicknames-hook
           (symbol-value (read-from-string "swank::*around-eval-for-emacs-hook*")))
  (format t "~&; installed swank::*around-eval-for-emacs-hook* handler to temporary add aliases local to swank::*buffer-package* as nicknames to their corresponding packages~%"))

(defun unhook-from-swank ()
  "Returns T if the hook handler was uninstalled, and NIL otherwize."
  (let* ((hook-var (find-symbol (string '#:*around-eval-for-emacs-hook*) :swank))
         (hook-chain (and hook-var (symbol-value hook-var))))
    (when (member 'with-aliases-as-nicknames-hook hook-chain)
      (setf (symbol-value hook-var) (remove 'with-aliases-as-nicknames-hook hook-chain))
      t)))