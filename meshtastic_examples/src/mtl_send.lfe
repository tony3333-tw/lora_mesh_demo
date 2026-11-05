;;;
;;; Broadcast one packet of a kind, like the send-*.py examples.
;;; The LFE twin of mte_send.erl.
;;;
;;;   mte send --lfe --what position      send-position.py (--lat 45 --lon -120 --alt 100)
;;;   mte send --lfe --what nodeinfo      send-nodeinfo.py
;;;   mte send --lfe --what device        send-device-metrics.py
;;;   mte send --lfe --what environment   send-environment-metrics.py
;;;   mte send --lfe --what telemetry     send-telemetry.py
;;;   mte send --lfe --what waypoint      send-waypoint.py
;;;
;;; -c N sends on channel N, -d NODE to one node instead of everyone.
;;;

(defmodule mtl_send
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (to (if (maps:is_key 'dest opts)
               (mtc:dest c opts)
               #xFFFFFFFF))
         (send (map 'to to 'channel (maps:get 'channel opts 0)))
         (what (maps:get 'what opts "position"))
         (id (send what c opts send)))
    (io:format "Sent ~s to ~ts (packet id ~p)~n" (list what (mtc:name c to) id))
    (mtc:close c)))

(defun send
  (("position" c opts send)
   (mtc:send_position c (maps:merge send (map 'lat (maps:get 'lat opts 45)
                                              'lon (maps:get 'lon opts -120)
                                              'alt (maps:get 'alt opts 100)))))
  (("nodeinfo" c _opts send)
   (let (((tuple 'ok me) (mtc:node c (mtc:my_num c))))
     (mtc:send_data c 'NODEINFO_APP (tuple 'user (maps:get 'user me)) send)))
  (("device" c _opts send)
   (let ((telemetry (map 'time (erlang:system_time 'second)
                         'device_metrics (map 'battery_level 69
                                              'voltage 4.1
                                              'channel_utilization 42.0
                                              'air_util_tx 1.0))))
     (mtc:send_data c 'TELEMETRY_APP (tuple 'telemetry telemetry) send)))
  (("environment" c _opts send)
   (let ((telemetry (map 'time (erlang:system_time 'second)
                         'environment_metrics (map 'temperature 25.2
                                                   'relative_humidity 69.0))))
     (mtc:send_data c 'TELEMETRY_APP (tuple 'telemetry telemetry) send)))
  (("telemetry" c _opts send)
   (mtc:send_telemetry c 'device_metrics send))
  (("waypoint" c _opts send)
   ;; lfec reads files as Latin-1: the emoji is written as its code point
   (let ((waypoint (map 'id (rand:uniform #xFFFFFFFE)
                        'latitude_i 454877655
                        'longitude_i -1215699769
                        'expire (+ (erlang:system_time 'second) 120)
                        'locked_to (mtc:my_num c)
                        'name #"Point 1"
                        'description (binary ("Waypoint 1 with emoji " utf8)
                                             (#x1F525 utf8))
                        'icon #x1F525)))
     (mtc:send_data c 'WAYPOINT_APP (tuple 'waypoint waypoint) send))))
