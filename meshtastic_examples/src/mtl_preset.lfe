;;;
;;; Print the radio's modem preset (LONG_FAST, ...), like
;;; get-config-modem-preset.py. The LFE twin of mte_preset.erl.
;;;
;;;   mte preset --lfe
;;;

(defmodule mtl_preset
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (lora (mtc:config c 'lora)))
    (io:format "~s~n" (list (maps:get 'modem_preset lora)))
    (mtc:close c)))
