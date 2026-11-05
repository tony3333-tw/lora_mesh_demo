;;;
;;; Publish what the radio receives to an MQTT broker as JSON, like
;;; MQTT/serial-mqtt.py. The LFE twin of mte_radio_mqtt.erl.
;;;
;;;   mte radio-mqtt --lfe                           broker localhost
;;;   mte radio-mqtt --lfe --broker 192.168.1.10
;;;
;;; Topic: <root>!deadbeef, root msh/sMQTT/2/json/LongFast/.
;;;

(defmodule mtl_radio_mqtt
  (export (run 1)))

(defun virtual-node () "!deadbeef")

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (conn (mtq:connect (maps:put 'broker (maps:get 'broker opts "localhost") opts)))
         (topic (++ (mtq:root opts "msh/sMQTT/2/json/LongFast/") (virtual-node))))
    (io:format "Publishing to ~s~n" (list topic))
    (loop c conn topic)))

(defun loop (c conn topic)
  (case (mtc:next c 'infinity)
    ((tuple 'packet (= (map 'decoded data) p))
     (let ((json (json:format (message p data))))
       (io:format "~ts~n~n" (list json))
       (mtq:publish conn topic (iolist_to_binary json)))
     (loop c conn topic))
    ((tuple 'packet _encrypted)
     (loop c conn topic))
    ('closed
     (io:format "the radio closed the connection~n"))))

;; The JSON message of serial-mqtt.py
(defun message (p data)
  (let (((tuple type payload) (payload (maps:get 'portnum data 'UNKNOWN_APP) data)))
    (without-undefined
     (map 'channel (maps:get 'channel p 0)
          'from (maps:get 'from p 0)
          'id (maps:get 'id p 0)
          'rssi (maps:get 'rx_rssi p 'undefined)
          'sender (list_to_binary (virtual-node))
          'snr (maps:get 'rx_snr p 'undefined)
          'timestamp (maps:get 'rx_time p 'undefined)
          'to (maps:get 'to p 'undefined)
          'type type
          'payload (without-undefined payload)))))

(defun payload
  (('NODEINFO_APP (map 'user u))
   (tuple 'nodeinfo
          (map 'hardware (maps:get 'hw_model u 'UNSET)
               'id (maps:get 'id u 'undefined)
               'longname (maps:get 'long_name u 'undefined)
               'shortname (maps:get 'short_name u 'undefined))))
  (('POSITION_APP (map 'position pos))
   (tuple 'position
          (map 'PDOP (maps:get 'PDOP pos 'undefined)
               'altitude (maps:get 'altitude pos 'undefined)
               'groundSpeed (maps:get 'ground_speed pos 'undefined)
               'latitude_i (maps:get 'latitude_i pos 'undefined)
               'longitude_i (maps:get 'longitude_i pos 'undefined)
               'precision_bits (maps:get 'precision_bits pos 'undefined)
               'satsInView (maps:get 'sats_in_view pos 'undefined)
               'time (maps:get 'time pos 'undefined))))
  (('TEXT_MESSAGE_APP (map 'text text))
   (tuple 'textMessage (map 'text text)))
  (('TELEMETRY_APP (map 'telemetry t))
   (let ((d (maps:get 'device_metrics t (map)))
         (w (maps:get 'power_metrics t (map)))
         (e (maps:get 'environment_metrics t (map))))
     (tuple 'telemetry
            (maps:from_list
             (++ (pick d '(#(air_util_tx air_util_tx)
                           #(battery_level battery_level)
                           #(channel_utilization channel_utilization)
                           #(uptime_seconds uptime_seconds)
                           #(voltage voltage)))
                 (pick w '(#(current_ch1 ch1_current)
                           #(current_ch2 ch2_current)
                           #(current_ch3 ch3_current)
                           #(voltage_ch1 ch1_voltage)
                           #(voltage_ch2 ch2_voltage)
                           #(voltage_ch3 ch3_voltage)))
                 (pick e '(#(barometric_pressure barometric_pressure)
                           #(current current)
                           #(gas_resistance gas_resistance)
                           #(iaq iaq)
                           #(lux lux)
                           #(temperature temperature)
                           #(voltage voltage)
                           #(white_lux white_lux)
                           #(wind_direction wind_direction)
                           #(wind_speed wind_speed))))))))
  ((_other _data)
   (tuple 'todo (map))))

;; (tuple json-key field) pairs -> (tuple json-key value) for the fields there
(defun pick (m pairs)
  (lists:filtermap
   (lambda (pair)
     (case (maps:find (element 2 pair) m)
       ((tuple 'ok v) (tuple 'true (tuple (element 1 pair) v)))
       ('error 'false)))
   pairs))

(defun without-undefined (m)
  (maps:filter (lambda (_k v) (andalso (=/= v 'undefined) (=/= v #""))) m))
