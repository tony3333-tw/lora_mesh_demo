;;;
;;; Print our own node's entry in the node database as JSON, like
;;; print-myNodeInfo. The LFE twin of mte_myinfo.erl.
;;;
;;;   mte myinfo --lfe
;;;

(defmodule mtl_myinfo
  (export (run 1)))

(defun run (opts)
  (let ((c (mtc:connect opts)))
    (case (mtc:node c (mtc:my_num c))
      ((tuple 'ok node)
       (io:format "~ts~n" (list (mtc:json node))))
      ('error
       (io:format "our node is not in the node database yet~n")))
    (mtc:close c)))
