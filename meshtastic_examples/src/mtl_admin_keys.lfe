;;;
;;; Set the admin keys of the radio, like save-admin-keys.py.
;;; The LFE twin of mte_admin_keys.erl.
;;;
;;;   mte admin-keys --lfe --keys KEY1,KEY2     base64 public keys
;;;   mte admin-keys --lfe --clear              remove all admin keys
;;;
;;; There is no default list: a key gives its owner control of the radio.
;;;

(defmodule mtl_admin_keys
  (export (run 1)))

(defun run (opts)
  (let ((keys (lists:map (fun base64 decode 1) (maps:get 'keys opts '()))))
    (if (andalso (=:= keys '())
                 (not (maps:get 'clear opts 'false)))
      (error (tuple 'missing_option "--keys KEY1,KEY2 (or --clear)"))
      (let* ((c (mtc:connect opts))
             (security (mtc:config c 'security)))
        (case (maps:get 'admin_key security '())
          ('()
           'ok)
          (_existing
           (io:format "Clearing existing admin keys...~n")
           (write c (maps:put 'admin_key '() security))
           (timer:sleep 1000)))
        (case keys
          ('()
           'ok)
          (_
           (lists:foreach
            (lambda (k) (io:format "Adding admin key: ~s~n" (list (base64:encode k))))
            keys)
           (write c (maps:put 'admin_key keys security))
           (io:format "Admin keys updated successfully!~n")))
        (mtc:close c)))))

;; node.writeConfig("security")
(defun write (c security)
  (let ((id (mtc:admin c (map 'set_config (map 'security security)))))
    (case (mtc:ack c id 10000)
      ('ok 'ok))))
