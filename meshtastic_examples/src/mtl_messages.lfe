;;;
;;; Print every text message lora_mesh receives, like print-messages.py.
;;; With --seconds S it stops after S seconds, like get-all-messages.py.
;;; The LFE twin of mte_messages.erl.
;;;
;;;   mte messages --lfe
;;;   mte messages --lfe --seconds 10
;;;

(defmodule mtl_messages
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (deadline (case (maps:find 'seconds opts)
                     ((tuple 'ok s) (mtc:deadline (* s 1000)))
                     ('error 'infinity))))
    (mtc:subscribe c 'rx)
    (loop c deadline)
    (mtc:disconnect c)))

(defun loop (c deadline)
  (case (mtc:next c (mtc:left deadline))
    ((tuple 'rx (map #"text" text))
     (io:format "~ts~n" (list text))
     (loop c deadline))
    ((tuple 'node _)
     (loop c deadline))
    ('timeout
     'ok)))
