;;;
;;; Print every packet lora_mesh's bridges hear, five ways, like the
;;; print-packets*.py examples. The LFE twin of mte_packets.erl
;;; (lora_mesh 0.4: mesh/packet/<from>).
;;;
;;;   mte packets --lfe                 parsed by port
;;;   mte packets --lfe --raw           the packet map as it is
;;;   mte packets --lfe --json          as JSON
;;;   mte packets --lfe --log FILE      as JSON, also kept in FILE
;;;   mte packets --lfe --counts        text bar charts every 10 s
;;;

(defmodule mtl_packets
  (export (run 1)))

(defun count-every-ms () 10000)

(defun run (opts)
  (let* ((c (mtc:connect opts))
         ;; our own radios' packets (local stats) are not logged
         (mine (lists:map
                (lambda (b) (maps:get #"my_id" b))
                (mtc:bridges c (map 'all 'true))))
         (mode (mode opts))
         (log (maps:get 'log opts 'undefined)))
    (mtc:subscribe c 'packets)
    (loop c mode log mine (tuple (map) (map)) (mtc:deadline (count-every-ms)))))

(defun mode
  (((map 'counts 'true)) 'counts)
  (((map 'raw 'true)) 'raw)
  (((map 'json 'true)) 'json)
  (((map 'log _)) 'json)
  ((_) 'parsed))

(defun loop (c mode log mine counts next)
  (let ((timeout (if (=:= mode 'counts)
                   (mtc:left next)
                   'infinity)))
    (case (mtc:next c timeout)
      ((tuple 'packet p)
       (if (andalso (=/= log 'undefined)
                    (not (lists:member (maps:get #"from_id" p) mine)))
         (append log p)
         'ok)
       (show mode p)
       (loop c mode log mine (count p counts) next))
      ('timeout
       (chart counts)
       (loop c mode log mine counts (mtc:deadline (count-every-ms))))
      (_other
       (loop c mode log mine counts next)))))

(defun show
  (('parsed p) (print-packet p))
  (('raw p) (io:format "~p~n~n" (list p)))
  (('json p) (io:format "~ts~n~n" (list (mtc:json p))))
  (('counts _p) 'ok))

;;--------------------------------------------------------------------
;; --log: a JSON array in a file, one more packet each time
;;--------------------------------------------------------------------

(defun append (file p)
  (let ((old (case (file:read_file file)
               ((tuple 'ok bin)
                (try
                  (let ((list (json:decode bin)))
                    (if (is_list list) list ()))
                  (catch
                    ((tuple _ _ _) ()))))
               ((tuple 'error _)
                ()))))
    (file:write_file file (json:format (++ old (list p))))))

;;--------------------------------------------------------------------
;; --counts
;;--------------------------------------------------------------------

(defun count (p counts)
  (let ((port (mtc:get p (list #"decoded" #"portnum") #"Unknown"))
        (from (maps:get #"from_id" p #"?"))
        (inc (lambda (n) (+ n 1))))
    (tuple (maps:update_with port inc 1 (element 1 counts))
           (maps:update_with from inc 1 (element 2 counts)))))

(defun chart (counts)
  (io:format "~nPortnums Frequency~n")
  (bars (element 1 counts))
  (io:format "From Numbers Frequency~n")
  (bars (element 2 counts)))

(defun bars (counts)
  (lists:foreach
   (lambda (kv)
     (let (((tuple key n) kv))
       (io:format "  ~-20ts ~s ~p~n"
                  (list key (lists:duplicate n #\#) n))))
   (lists:reverse (lists:keysort 2 (maps:to_list counts)))))

;;--------------------------------------------------------------------
;; print-packets.py
;;--------------------------------------------------------------------

(defun print-packet (p)
  (io:format "Received packet:~n")
  (io:format "  From: ~p / ~ts~n"
             (list (maps:get #"from" p 0) (maps:get #"from_id" p)))
  (io:format "  To: ~p / ~ts~n"
             (list (maps:get #"to" p 0) (maps:get #"to_id" p)))
  (field "  Channel" p #"channel")
  (field "  SNR" p #"rx_snr")
  (field "  RSSI" p #"rx_rssi")
  (field "  Hop Limit" p #"hop_limit")
  (field "  Hop Start" p #"hop_start")
  (field "  Priority" p #"priority")
  (field "  via MQTT" p #"via_mqtt")
  (io:format "  Heard by: ~ts~n"
             (list (lists:join ", " (maps:get #"bridges" p ()))))
  (case (maps:find #"decoded" p)
    ((tuple 'ok data)
     (let ((port (maps:get #"portnum" data #"UNKNOWN_APP")))
       (io:format "  Port Number: ~ts~n" (list port))
       (print-data port data)))
    ('error
     (io:format "  No 'decoded' key found in the packet. Our node doesn't have the encryption key!~n")))
  (io:format "~n"))

(defun print-data
  ((#"NODEINFO_APP" (map #"user" user))
   (io:format "  Node Information:~n")
   (io:format "    ID: ~ts~n" (list (maps:get #"id" user #"N/A")))
   (io:format "    Long Name: ~ts~n" (list (maps:get #"long_name" user #"N/A")))
   (io:format "    Short Name: ~ts~n" (list (maps:get #"short_name" user #"N/A")))
   (io:format "    MAC Address: ~ts~n" (list (maps:get #"macaddr" user #"N/A")))
   (io:format "    Hardware Model: ~ts~n" (list (maps:get #"hw_model" user #"UNSET")))
   (field "    Role" user #"role"))
  ((#"POSITION_APP" (map #"position" pos))
   (io:format "  Position:~n")
   (io:format "    Latitude: ~ts~n" (list (mtc:show (maps:get #"latitude" pos #"N/A"))))
   (io:format "    Longitude: ~ts~n" (list (mtc:show (maps:get #"longitude" pos #"N/A"))))
   (io:format "    Altitude: ~ts~n" (list (mtc:show (maps:get #"altitude" pos #"N/A"))))
   (field "    PDOP" pos #"PDOP")
   (field "    Ground Track" pos #"ground_track")
   (field "    Satellites in View" pos #"sats_in_view"))
  ((#"TEXT_MESSAGE_APP" (map #"text" text))
   (io:format "  Text Message:~n")
   (io:format "    Text: ~ts~n" (list text)))
  ((#"TELEMETRY_APP" (map #"telemetry" t))
   (io:format "  Telemetry:~n")
   (io:format "    Time: ~ts~n" (list (mtc:show (maps:get #"time" t #"N/A"))))
   (metrics "    Device Metrics:" t #"device_metrics"
            (list (tuple "Battery Level" #"battery_level")
                  (tuple "Voltage" #"voltage")
                  (tuple "Channel Utilization" #"channel_utilization")
                  (tuple "Air Utilization Tx" #"air_util_tx")
                  (tuple "Uptime Seconds" #"uptime_seconds")))
   (metrics "    Power Metrics:" t #"power_metrics"
            (list (tuple "CH1 Voltage" #"ch1_voltage")
                  (tuple "CH1 Current" #"ch1_current")
                  (tuple "CH2 Voltage" #"ch2_voltage")
                  (tuple "CH2 Current" #"ch2_current")))
   (metrics "    Environment Metrics:" t #"environment_metrics"
            (list (tuple "Temperature" #"temperature")
                  (tuple "Relative Humidity" #"relative_humidity")
                  (tuple "Barometric Pressure" #"barometric_pressure")))
   (metrics "    Local Stats:" t #"local_stats"
            (list (tuple "Packets Tx" #"num_packets_tx")
                  (tuple "Packets Rx" #"num_packets_rx")
                  (tuple "Online Nodes" #"num_online_nodes")
                  (tuple "Channel Utilization" #"channel_utilization"))))
  ((#"NEIGHBORINFO_APP" (map #"neighborinfo" info))
   (io:format "  Neighbor Information:~n")
   (io:format "    Node ID: ~p~n" (list (maps:get #"node_id" info 0)))
   (io:format "    Last Sent By ID: ~p~n" (list (maps:get #"last_sent_by_id" info 0)))
   (io:format "    Node Broadcast Interval (secs): ~p~n"
              (list (maps:get #"node_broadcast_interval_secs" info 0)))
   (io:format "    Neighbors:~n")
   (lists:foreach
    (lambda (n)
      (io:format "      Neighbor ID: ~p~n        SNR: ~ts~n"
                 (list (maps:get #"node_id" n 0)
                       (mtc:show (maps:get #"snr" n 0.0)))))
    (maps:get #"neighbors" info ())))
  ((#"RANGE_TEST_APP" (map #"text" text))
   (io:format "  Range Test Information:~n")
   (io:format "    Payload: ~ts~n" (list text)))
  ((#"STORE_FORWARD_APP" (map #"store_forward" sf))
   (io:format "  Store Forward Information:~n")
   (field "    Statistics" sf #"stats")
   (field "    History" sf #"history")
   (field "    Heartbeat" sf #"heartbeat"))
  ((#"PAXCOUNTER_APP" (map #"paxcounter" pax))
   (io:format "  Paxcounter Information:~n")
   (io:format "    Wifi: ~p~n" (list (maps:get #"wifi" pax 0)))
   (io:format "    BLE: ~p~n" (list (maps:get #"ble" pax 0)))
   (io:format "    Uptime: ~p~n" (list (maps:get #"uptime" pax 0))))
  ((port _data)
   (io:format "  Decoded packet does not contain data we are looking for: ~ts~n"
              (list port))))

(defun metrics (title telemetry key fields)
  (case (maps:find key telemetry)
    ((tuple 'ok m)
     (io:format "~s~n" (list title))
     (lists:foreach
      (lambda (lf)
        (let (((tuple label f) lf))
          (io:format "      ~s: ~ts~n"
                     (list label (mtc:show (maps:get f m #"N/A"))))))
      fields))
    ('error
     'ok)))

(defun field (label m key)
  (case (maps:find key m)
    ((tuple 'ok v)
     (io:format "~s: ~ts~n" (list label (mtc:show v))))
    ('error
     'ok)))
