;;;
;;; Every setting the protobufs define, with its default value, like
;;; list-protos.py. The LFE twin of mte_protos.erl.
;;;
;;;   mte protos --lfe
;;;

(defmodule mtl_protos
  (export (run 1)))

(defun user-settings ()
  '(long_name short_name is_licensed is_unmessagable))

(defun run (_opts)
  (let ((user (lists:filter
               (lambda (f) (lists:member (element 1 f) (user-settings)))
               (menu 'user)))
        (channel (menu 'channel_settings)))
    (io:format "{~n")
    (pretty "\"User Config\"" (tuple 'obj user) 2 'true)
    (pretty "\"Channel Config\"" (tuple 'list (lists:duplicate 8 (tuple 'obj channel))) 2 'true)
    (pretty "\"Radio Config\"" (tuple 'obj (menu 'config)) 2 'true)
    (pretty "\"Module Config\"" (tuple 'obj (menu 'module_config)) 2 'false)
    (io:format "}~n")))

;; A message's fields in order, as a list of (tuple name default);
;; nested messages (oneof alternatives too) as (tuple 'obj ...)
(defun menu (msg-name)
  (lists:append (lists:map (fun field 1) (mt_pb:find_msg_def msg-name))))

(defun field
  (((map 'fields alternatives))
   (lists:append
    (lists:map (lambda (f) (field (maps:put 'occurrence 'optional f)))
               alternatives)))
  (((map 'name name 'occurrence 'repeated))
   (list (tuple name (tuple 'list '()))))
  (((map 'name name 'type (tuple 'msg sub)))
   (list (tuple name (tuple 'obj (menu sub)))))
  (((map 'name name 'type (tuple 'map _ _)))
   (list (tuple name (tuple 'obj '()))))
  (((map 'name name 'type (tuple 'enum enum)))
   (list (tuple name (mt_pb:enum_symbol_by_value enum 0))))
  (((map 'name name 'type type))
   (list (tuple name (default type)))))

(defun default
  (('bool) 'false)
  (('string) #"")
  (('bytes) #"")
  (('float) 0.0)
  (('double) 0.0)
  ((_integer) 0))

(defun pretty
  ((title (tuple 'obj fields) indent comma)
   (let ((pad (lists:duplicate indent 32)))
     (io:format "~s~s{~n" (list pad (prefix title)))
     (items (lists:map (lambda (kv)
                         (tuple (io_lib:format "\"~s\"" (list (element 1 kv)))
                                (element 2 kv)))
                       fields)
            (+ indent 2))
     (io:format "~s}~s~n" (list pad (comma comma)))))
  ((title (tuple 'list items) indent comma)
   (let ((pad (lists:duplicate indent 32)))
     (io:format "~s~s[~n" (list pad (prefix title)))
     (items (lists:map (lambda (v) (tuple "" v)) items) (+ indent 2))
     (io:format "~s]~s~n" (list pad (comma comma)))))
  ((title value indent comma)
   (let ((pad (lists:duplicate indent 32)))
     (io:format "~s~s~s~s~n" (list pad (prefix title) (value value) (comma comma))))))

(defun items (items indent)
  (let ((last (length items)))
    (lists:foreach
     (lambda (i-kv)
       (let ((kv (element 2 i-kv)))
         (pretty (element 1 kv) (element 2 kv) indent (=/= (element 1 i-kv) last))))
     (lists:enumerate items))))

;; "\"name\": " before a value, nothing for a list item
(defun prefix
  (("") "")
  ((title) (list title ": ")))

(defun value
  (('true) "true")
  (('false) "false")
  ((#"") "\"\"")
  ((v) (when (is_atom v)) (io_lib:format "\"~s\"" (list v)))
  ((v) (io_lib:format "~p" (list v))))

(defun comma
  (('true) ",")
  (('false) ""))
