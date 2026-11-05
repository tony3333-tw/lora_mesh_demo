;;;
;;; Print the channels saved on the radio, like get-channels.py.
;;; The LFE twin of mte_channels.erl.
;;;
;;;   mte channels --lfe
;;;

(defmodule mtl_channels
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (channels (lists:filter
                    (lambda (ch) (=/= (maps:get 'role ch) 'DISABLED))
                    (mtc:channels c))))
    (case channels
      ('()
       (io:format "No channels found.~n"))
      (_
       (io:format "Channels:~n")
       (lists:foreach (fun print-channel 1) channels)))
    (mtc:close c)))

(defun print-channel (ch)
  (let ((settings (maps:get 'settings ch)))
    (io:format "Index: ~p, Role: ~s, PSK (Base64): ~s, Name: ~ts~n"
               (list (maps:get 'index ch)
                     (maps:get 'role ch)
                     (base64:encode (maps:get 'psk settings #""))
                     (maps:get 'name settings #"")))))
