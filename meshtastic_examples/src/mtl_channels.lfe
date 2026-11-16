;;;
;;; Print the channels saved on each bridge's radio, like
;;; get-channels.py. The LFE twin of mte_channels.erl (lora_mesh 0.4:
;;; mesh/bridge/<id>/info; private keys show as "(hidden)").
;;;
;;;   mte channels --lfe
;;;

(defmodule mtl_channels
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (bridges (mtc:bridges c opts)))
    (if (=:= bridges ())
      (io:format "No channels found (no Meshtastic bridge has reported its radio).~n")
      (lists:foreach (fun print-bridge 1) bridges))
    (mtc:disconnect c)))

(defun print-bridge (b)
  (let ((bridge (maps:get #"bridge" b))
        ;; DISABLED is the default role, so lora_mesh leaves it out
        (channels (lists:filter
                   (lambda (ch) (maps:is_key #"role" ch))
                   (maps:get #"channels" b ()))))
    (if (=:= channels ())
      (io:format "~ts: No channels found.~n" (list bridge))
      (progn
        (io:format "~ts: Channels:~n" (list bridge))
        (lists:foreach (fun print-channel 1) channels)))))

(defun print-channel (ch)
  (let ((settings (maps:get #"settings" ch (map))))
    (io:format "Index: ~p, Role: ~ts, PSK (Base64): ~ts, Name: ~ts~n"
               (list (maps:get #"index" ch)
                     (maps:get #"role" ch)
                     (psk (maps:get #"psk" settings #""))
                     (maps:get #"name" settings #"")))))

;; "base64:AQ==" -> "AQ=="; "(hidden)" stays
(defun psk
  (((binary "base64:" (b64 binary)))
   b64)
  ((other)
   other))
