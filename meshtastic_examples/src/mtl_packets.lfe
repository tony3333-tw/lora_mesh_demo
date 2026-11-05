;;;
;;; Print every packet the radio receives, five ways, like the
;;; print-packets*.py examples. The LFE twin of mte_packets.erl.
;;;
;;;   mte packets --lfe                  parsed by port (print-packets.py)
;;;   mte packets --lfe --raw            as it is (print-packets-basic.py)
;;;   mte packets --lfe --json           as JSON (print-packets-json.py)
;;;   mte packets --lfe --log FILE       JSON, kept in FILE (print-packets-json-log.py)
;;;   mte packets --lfe --counts         per port and sender, every 10 s
;;;                                      (print-packets-json-log-and-plot.py)
;;;

(defmodule mtl_packets
  (export (run 1)))

(defun count-every-ms () 10000)

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (mode (cond
                ((maps:get 'counts opts 'false) 'counts)
                ((maps:get 'raw opts 'false) 'raw)
                ((maps:get 'json opts 'false) 'json)
                ((maps:is_key 'log opts) 'json)
                ('true 'parsed)))
         (log (maps:get 'log opts 'undefined)))
    (loop c mode log (mtc:my_num c) (tuple (map) (map))
          (mtc:deadline (count-every-ms)))))

(defun loop (c mode log my-num counts next)
  (let ((timeout (if (=:= mode 'counts)
                   (mtc:left next)
                   'infinity)))
    (case (mtc:next c timeout)
      ((tuple 'packet p)
       (if (andalso (=/= log 'undefined)
                    (=/= (maps:get 'from p 0) my-num))   ; as the Python log: not our own
         (append log p))
       (show mode p)
       (loop c mode log my-num (count p counts) next))
      ('timeout
       (chart counts)
       (loop c mode log my-num counts (mtc:deadline (count-every-ms))))
      ('closed
       (io:format "the radio closed the connection~n")))))

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
                  (let ((decoded (json:decode bin)))
                    (if (is_list decoded) decoded '()))
                  (catch
                    ((tuple _ _ _) '()))))
               ((tuple 'error _)
                '()))))
    (file:write_file file (json:format (++ old (list (mtc:json_term p)))))))

;;--------------------------------------------------------------------
;; --counts
;;--------------------------------------------------------------------

(defun count (p counts)
  (let ((port (mtc:get p '(decoded portnum) 'Unknown))
        (from (mtc:node_id (maps:get 'from p 0)))
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
     (let ((n (element 2 kv)))
       (io:format "  ~-20ts ~s ~p~n"
                  (list (element 1 kv) (lists:duplicate n #\#) n))))
   (lists:reverse (lists:keysort 2 (maps:to_list counts)))))

;;--------------------------------------------------------------------
;; print-packets.py
;;--------------------------------------------------------------------

(defun print-packet (p)
  (io:format "Received packet:~n")
  (io:format "  From: ~p / ~s~n" (list (maps:get 'from p 0) (maps:get 'from_id p)))
  (io:format "  To: ~p / ~s~n" (list (maps:get 'to p 0) (maps:get 'to_id p)))
  (field "  Channel" p 'channel)
  (field "  SNR" p 'rx_snr)
  (field "  RSSI" p 'rx_rssi)
  (field "  Hop Limit" p 'hop_limit)
  (field "  Hop Start" p 'hop_start)
  (field "  Priority" p 'priority)
  (field "  via MQTT" p 'via_mqtt)
  (case (maps:find 'decoded p)
    ((tuple 'ok data)
     (let ((port (maps:get 'portnum data 'UNKNOWN_APP)))
       (io:format "  Port Number: ~s~n" (list port))
       (print-data port data)))
    ('error
     (io:format "  No 'decoded' key found in the packet. Our node doesn't have the encryption key!~n")))
  (io:format "~n"))

(defun print-data
  (('NODEINFO_APP (map 'user user))
   (io:format "  Node Information:~n")
   (io:format "    ID: ~ts~n" (list (maps:get 'id user "N/A")))
   (io:format "    Long Name: ~ts~n" (list (maps:get 'long_name user "N/A")))
   (io:format "    Short Name: ~ts~n" (list (maps:get 'short_name user "N/A")))
   (io:format "    MAC Address: ~s~n" (list (base64:encode (maps:get 'macaddr user #""))))
   (io:format "    Hardware Model: ~s~n" (list (maps:get 'hw_model user 'UNSET)))
   (field "    Role" user 'role))
  (('POSITION_APP (map 'position pos))
   (io:format "  Position:~n")
   (io:format "    Latitude: ~ts~n" (list (mtc:show (maps:get 'latitude pos 'N/A))))
   (io:format "    Longitude: ~ts~n" (list (mtc:show (maps:get 'longitude pos 'N/A))))
   (io:format "    Altitude: ~ts~n" (list (mtc:show (maps:get 'altitude pos 'N/A))))
   (field "    PDOP" pos 'PDOP)
   (field "    Ground Track" pos 'ground_track)
   (field "    Satellites in View" pos 'sats_in_view))
  (('TEXT_MESSAGE_APP (map 'text text))
   (io:format "  Text Message:~n")
   (io:format "    Text: ~ts~n" (list text)))
  (('TELEMETRY_APP (map 'telemetry t))
   (io:format "  Telemetry:~n")
   (io:format "    Time: ~ts~n" (list (mtc:show (maps:get 'time t 'N/A))))
   (metrics "    Device Metrics:" t 'device_metrics
            '(#("Battery Level" battery_level)
              #("Voltage" voltage)
              #("Channel Utilization" channel_utilization)
              #("Air Utilization Tx" air_util_tx)
              #("Uptime Seconds" uptime_seconds)))
   (metrics "    Power Metrics:" t 'power_metrics
            '(#("CH1 Voltage" ch1_voltage)
              #("CH1 Current" ch1_current)
              #("CH2 Voltage" ch2_voltage)
              #("CH2 Current" ch2_current)))
   (metrics "    Environment Metrics:" t 'environment_metrics
            '(#("Temperature" temperature)
              #("Relative Humidity" relative_humidity)
              #("Barometric Pressure" barometric_pressure)))
   (metrics "    Local Stats:" t 'local_stats
            '(#("Packets Tx" num_packets_tx)
              #("Packets Rx" num_packets_rx)
              #("Online Nodes" num_online_nodes)
              #("Channel Utilization" channel_utilization))))
  (('NEIGHBORINFO_APP (map 'neighborinfo info))
   (let ((node-id (maps:get 'node_id info 0)))
     (io:format "  Neighbor Information:~n")
     (io:format "    Node ID: ~p / ~s~n" (list node-id (mtc:node_id node-id)))
     (io:format "    Last Sent By ID: ~p~n" (list (maps:get 'last_sent_by_id info 0)))
     (io:format "    Node Broadcast Interval (secs): ~p~n"
                (list (maps:get 'node_broadcast_interval_secs info 0)))
     (io:format "    Neighbors:~n")
     (lists:foreach
      (lambda (n)
        (let ((id (maps:get 'node_id n 0)))
          (io:format "      Neighbor ID: ~p / ~s~n        SNR: ~ts~n"
                     (list id (mtc:node_id id) (mtc:show (maps:get 'snr n 0.0))))))
      (maps:get 'neighbors info '()))))
  (('RANGE_TEST_APP (map 'text text))
   (io:format "  Range Test Information:~n")
   (io:format "    Payload: ~ts~n" (list text)))
  (('STORE_FORWARD_APP (map 'store_forward sf))
   (io:format "  Store Forward Information:~n")
   (field "    Statistics" sf 'stats)
   (field "    History" sf 'history)
   (field "    Heartbeat" sf 'heartbeat))
  (('ADMIN_APP (= (map 'admin admin) data))
   (io:format "  Administrative Information:~n")
   (io:format "    Payload: ~p~n" (list (maps:get 'payload data)))
   (case (maps:find 'get_channel_response admin)
     ((tuple 'ok ch)
      (io:format "    Get Channel Response:~n")
      (io:format "      Index: ~p~n" (list (maps:get 'index ch 0)))
      (io:format "      Settings:~n")
      (lists:foreach
       (lambda (kv)
         (io:format "        ~s: ~ts~n" (list (element 1 kv) (mtc:show (element 2 kv)))))
       (maps:to_list (maps:get 'settings ch (map)))))
     ('error
      'ok)))
  (('PAXCOUNTER_APP (map 'paxcounter pax))
   (io:format "  Paxcounter Information:~n")
   (io:format "    Wifi: ~p~n" (list (maps:get 'wifi pax 0)))
   (io:format "    BLE: ~p~n" (list (maps:get 'ble pax 0)))
   (io:format "    Uptime: ~p~n" (list (maps:get 'uptime pax 0))))
  ((port _data)
   (io:format "  Decoded packet does not contain data we are looking for: ~s~n"
              (list port))))

(defun metrics (title telemetry key fields)
  (case (maps:find key telemetry)
    ((tuple 'ok m)
     (io:format "~s~n" (list title))
     (lists:foreach
      (lambda (field)
        (io:format "      ~s: ~ts~n"
                   (list (element 1 field)
                         (mtc:show (maps:get (element 2 field) m 'N/A)))))
      fields))
    ('error
     'ok)))

(defun field (label m key)
  (case (maps:find key m)
    ((tuple 'ok v) (io:format "~s: ~ts~n" (list label (mtc:show v))))
    ('error 'ok)))
