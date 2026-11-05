;;;
;;; Infos: what lora_mesh is connected to, like serial_infos.py.
;;; The LFE twin of ex_infos.erl.
;;;
;;;   lme infos --lfe
;;;

(defmodule lx_infos
  (export (run 1)))

(defun run (opts)
  (let* ((client (lmc:connect opts))
         (nodes (lmc:nodes client 1000))
         (bridges (lists:usort
                   (lists:append
                    (lists:map
                     (lambda (node)
                       (maps:keys (maps:get #"heard_by" node #m())))
                     nodes)))))
    (io:format "broker:   ~s:~p, topics ~ts/...~n"
               (list (maps:get 'host opts "localhost")
                     (maps:get 'port opts 1883)
                     (maps:get 'prefix client)))
    (io:format "nodes:    ~p (~p MeshCore, ~p Meshtastic)~n"
               (list (length nodes)
                     (count nodes #"meshcore")
                     (count nodes #"meshtastic")))
    (io:format "bridges that have heard something: ~ts~n"
               (list (if (=:= bridges '())
                       #"none yet"
                       (lists:join ", " bridges))))
    (lmc:disconnect client)))

(defun count (nodes protocol)
  (length
   (lists:filter
    (lambda (node)
      (=:= (maps:get #"protocol" node) protocol))
    nodes)))
