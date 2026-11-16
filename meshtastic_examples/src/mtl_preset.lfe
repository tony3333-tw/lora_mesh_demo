;;;
;;; Print each bridge's radio modem preset, like
;;; get-config-modem-preset.py. The LFE twin of mte_preset.erl
;;; (lora_mesh 0.4: mesh/bridge/<id>/info).
;;;
;;;   mte preset --lfe
;;;

(defmodule mtl_preset
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (bridges (mtc:bridges c opts)))
    (if (=:= bridges ())
      (io:format "no Meshtastic bridge has reported its radio yet (lora_mesh 0.4 needed)~n")
      (lists:foreach
       (lambda (b)
         (io:format "~ts: ~ts~n"
                    (list (maps:get #"bridge" b)
                          (preset b))))
       bridges))
    (mtc:disconnect c)))

;; LONG_FAST is the first preset, a default, so lora_mesh leaves it out
(defun preset (b)
  (mtc:get b
           (list #"config" #"lora" #"modem_preset")
           #"LONG_FAST"))
