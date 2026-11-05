;;;
;;; List the nodes in the radio's node database, like print-nodedb.py.
;;; The LFE twin of mte_nodedb.erl.
;;;
;;;   mte nodedb --lfe
;;;   mte nodedb --lfe --json
;;;

(defmodule mtl_nodedb
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (nodes (mtc:nodes c)))
    (if (maps:get 'json opts 'false)
      (io:format "~ts~n" (list (mtc:json nodes)))
      (lists:foreach (fun print-node 1) nodes))
    (mtc:close c)))

(defun print-node (node)
  (let ((user (maps:get 'user node (map)))
        (pos (maps:get 'position node (map)))
        (metrics (maps:get 'device_metrics node (map))))
    (io:format "Node Num: ~p~n" (list (maps:get 'num node)))
    (io:format "Node ID: ~ts~n" (list (maps:get 'id user #"?")))
    (io:format "Long Name: ~ts~n" (list (maps:get 'long_name user #"")))
    (io:format "Short Name: ~ts~n" (list (maps:get 'short_name user #"")))
    (io:format "Hardware Model: ~s~n" (list (maps:get 'hw_model user 'UNSET)))
    (field "Role" user 'role)
    (case (maps:find 'macaddr user)
      ((tuple 'ok mac) (io:format "MAC Address: ~s~n" (list (mac mac))))
      ('error 'ok))
    (case (maps:find 'public_key user)
      ((tuple 'ok key) (io:format "Public Key: ~s~n" (list (base64:encode key))))
      ('error 'ok))
    (field "SNR" node 'snr)
    (field "Last Heard" node 'last_heard)
    (field "Hops Away" node 'hops_away)
    (field "Latitude" pos 'latitude)
    (field "Longitude" pos 'longitude)
    (field "Altitude" pos 'altitude)
    (field "Time" pos 'time)
    (field "Battery Level" metrics 'battery_level)
    (field "Voltage" metrics 'voltage)
    (field "Channel Utilization" metrics 'channel_utilization)
    (field "Air Util Tx" metrics 'air_util_tx)
    (field "Uptime Seconds" metrics 'uptime_seconds)
    (io:format "~n~n")))

;; print a line only when the field is there, as print-nodedb.py does
(defun field (label m key)
  (case (maps:find key m)
    ((tuple 'ok v) (io:format "~s: ~ts~n" (list label (mtc:show v))))
    ('error 'ok)))

(defun mac (mac)
  (lists:join ":"
              (lists:map (lambda (b) (io_lib:format "~2.16.0b" (list b)))
                         (binary_to_list mac))))
