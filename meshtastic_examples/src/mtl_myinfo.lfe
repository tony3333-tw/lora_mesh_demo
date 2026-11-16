;;;
;;; Print each bridge's own radio as JSON, like print-myNodeInfo. The
;;; LFE twin of mte_myinfo.erl (lora_mesh 0.4: mesh/bridge/<id>/info).
;;;
;;;   mte myinfo --lfe
;;;   mte myinfo --lfe --bridge home
;;;

(defmodule mtl_myinfo
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (bridges (mtc:bridges c opts)))
    (if (=:= bridges ())
      (io:format "no Meshtastic bridge has reported its radio yet (lora_mesh 0.4 needed)~n")
      (let ((nodes (mtc:nodes c opts)))
        (lists:foreach
         (lambda (b) (print-bridge b nodes))
         bridges)))
    (mtc:disconnect c)))

(defun print-bridge (b nodes)
  (let* ((my-id (maps:get #"my_id" b))
         (node (case (mtc:find nodes my-id)
                 ((tuple 'ok n) n)
                 ('error (map #"id" my-id)))))
    (io:format "~ts:~n~ts~n"
               (list (maps:get #"bridge" b)
                     (mtc:json (maps:put #"my_info"
                                         (maps:get #"my_info" b (map))
                                         node))))))
