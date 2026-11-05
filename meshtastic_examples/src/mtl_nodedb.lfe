;;;
;;; List the nodes lora_mesh knows, like print-nodedb.py. The LFE twin
;;; of mte_nodedb.erl.
;;;
;;;   mte nodedb --lfe
;;;   mte nodedb --lfe --json
;;;   mte nodedb --lfe --all       MeshCore nodes too
;;;

(defmodule mtl_nodedb
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (nodes (mtc:nodes c opts)))
    (if (maps:get 'json opts 'false)
      (io:format "~ts~n" (list (json:format nodes)))
      (lists:foreach (fun print-node 1) nodes))
    (mtc:disconnect c)))

(defun print-node (node)
  (field "Node Num" node #"num")
  (field "Node ID" node #"id")
  (field "Long Name" node #"long_name")
  (field "Short Name" node #"short_name")
  (field "Hardware Model" node #"hw_model")
  (field "Role" node #"role")
  (let ((pos (case (maps:get #"position" node 'null)
               ('null (map))
               (p p))))
    (field "Latitude" pos #"latitude")
    (field "Longitude" pos #"longitude")
    (field "Altitude" pos #"altitude")
    (field "Time" pos #"time"))
  (field "Battery Level" node #"battery_level")
  (field "Voltage" node #"voltage")
  (field "Last Heard" node #"last_heard")
  (lists:foreach
   (lambda (heard)
     (let (((tuple bridge info) heard))
       (io:format "Heard By: ~ts (SNR ~ts)~n"
                  (list bridge
                        (show (maps:get #"rx_snr" (maps:get #"rxq" info)))))))
   (lists:sort (maps:to_list (maps:get #"heard_by" node (map)))))
  (io:format "~n~n"))

;; print a line only when the field has a value, as print-nodedb.py does
(defun field (label m key)
  (case (maps:get key m 'null)
    ('null 'ok)
    (v (io:format "~s: ~ts~n" (list label (show v))))))

(defun show
  ((v) (when (is_binary v)) v)
  ((v) (when (is_float v)) (float_to_binary v '(short)))
  ((v) (io_lib:format "~p" (list v))))
