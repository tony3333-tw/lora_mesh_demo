;;;
;;; Ask a node for something and print its answer, like the
;;; request-*.py examples. The LFE twin of mte_request.erl.
;;;
;;;   mte request --lfe -d "Hill top"                     telemetry (device metrics)
;;;   mte request --lfe -d "Hill top" --what environment
;;;   mte request --lfe -d "Hill top" --what position
;;;   mte request --lfe -d "Hill top" --what nodeinfo
;;;   also --what local_stats | power
;;;

(defmodule mtl_request
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (dest (mtc:dest c opts))
         (ask (map 'to dest
                   'want_response 'true
                   'channel (maps:get 'channel opts 0)))
         (port-id (ask c (maps:get 'what opts "telemetry") ask))
         (port (element 1 port-id)))
    (io:format "Asked ~ts, waiting for the answer...~n" (list (mtc:name c dest)))
    (case (mtc:reply c (element 2 port-id) port 60000)
      ((tuple 'ok p)
       (answer port p))
      ((tuple 'error reason)
       (io:format "No answer: ~s~n" (list reason)))
      ('timeout
       (io:format "No answer within 60 s~n"))
      ('closed
       (io:format "the radio closed the connection~n")))
    (mtc:close c)))

;; -> (tuple port packet-id)
(defun ask
  ((c "telemetry" ask)
   (tuple 'TELEMETRY_APP (mtc:send_telemetry c 'device_metrics ask)))
  ((c "environment" ask)
   (tuple 'TELEMETRY_APP (mtc:send_telemetry c 'environment_metrics ask)))
  ((c "local_stats" ask)
   (tuple 'TELEMETRY_APP (mtc:send_telemetry c 'local_stats ask)))
  ((c "power" ask)
   (tuple 'TELEMETRY_APP (mtc:send_telemetry c 'power_metrics ask)))
  ((c "position" ask)
   (tuple 'POSITION_APP (mtc:send_position c ask)))
  ((c "nodeinfo" ask)
   ;; our own User, with want_response: the node answers with its own
   (let (((tuple 'ok me) (mtc:node c (mtc:my_num c))))
     (tuple 'NODEINFO_APP
            (mtc:send_data c 'NODEINFO_APP (tuple 'user (maps:get 'user me)) ask)))))

(defun answer
  (('TELEMETRY_APP p)
   (io:format "Telemetry received:~n")
   (let ((telemetry (mtc:get p '(decoded telemetry) (map))))
     (case (maps:find 'device_metrics telemetry)
       ((tuple 'ok m)
        (pct "Battery level: ~.2f%~n" m 'battery_level)
        (pct "Voltage: ~.2f V~n" m 'voltage)
        (pct "Total channel utilization: ~.2f%~n" m 'channel_utilization)
        (pct "Transmit air utilization: ~.2f%~n" m 'air_util_tx)
        (case (maps:find 'uptime_seconds m)
          ((tuple 'ok up) (io:format "Uptime: ~p s~n" (list up)))
          ('error 'ok)))
       ('error
        (lists:foreach
         (lambda (kind-values)
           (io:format "~s:~n" (list (element 1 kind-values)))
           (lists:foreach
            (lambda (kv)
              (io:format "  ~s: ~ts~n" (list (element 1 kv) (mtc:show (element 2 kv)))))
            (lists:sort (maps:to_list (element 2 kind-values)))))
         (maps:to_list (maps:remove 'time telemetry)))))))
  (('POSITION_APP p)
   (let* ((pos (mtc:get p '(decoded position) (map)))
          (where (case pos
                   ((map 'latitude lat 'longitude lon)
                    (list "(" (mtc:show lat) ", " (mtc:show lon) ")"))
                   (_
                    "(unknown)")))
          (alt (case (maps:find 'altitude pos)
                 ((tuple 'ok a) (io_lib:format " ~pm" (list a)))
                 ('error "")))
          (precision (case (maps:get 'precision_bits pos 0)
                       (32 " full precision")
                       (0 " position disabled")
                       (bits (io_lib:format " precision:~p" (list bits))))))
     (io:format "Position received: ~s~s~s~n" (list where alt precision))))
  (('NODEINFO_APP p)
   (io:format "~ts~n" (list (mtc:json p)))))

(defun pct (format m key)
  (case (maps:find key m)
    ((tuple 'ok v) (io:format format (list (float v))))
    ('error 'ok)))
