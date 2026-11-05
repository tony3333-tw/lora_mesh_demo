;;;
;;; Publish a node info, a position and a text message to a Meshtastic
;;; MQTT broker as a made-up node, like MQTT/send-mqtt-packets.py.
;;; The LFE twin of mte_mqtt_send.erl.
;;;
;;;   mte mqtt-send --lfe                         to msh/US/Bots/2/e/LongFast/!abcdXXXX
;;;   mte mqtt-send --lfe -m "hello" --root msh/TW/2/e/
;;;   mte mqtt-send --lfe --broker localhost
;;;

(defmodule mtl_mqtt_send
  (export (run 1)
          (bot 2)
          (send-all 2)))

(defun broadcast () #xFFFFFFFF)

(defun run (opts)
  (let ((conn (mtq:connect opts))
        (bot (bot opts "msh/US/Bots/2/e/")))
    (io:format "Connected to server: ~s~n"
               (list (maps:get 'broker opts "mqtt.meshtastic.org")))
    (io:format "Publish Topic is: ~s~n~n" (list (maps:get 'topic bot)))
    (send-all conn bot)
    (mtq:disconnect conn)
    (io:format "Client Disconnected~n")))

;; Who we are and where we publish
(defun bot (opts default-root)
  (let ((node (mtq:random_node))
        (channel (maps:get 'channel_name opts "LongFast")))
    (map 'node node
         'key (mtq:key (maps:get 'key opts "AQ=="))
         'channel_name channel
         'topic (++ (mtq:root opts default-root)
                    channel
                    "/"
                    (binary_to_list (mtc:node_id node)))
         'pause (* (maps:get 'pause opts 4) 1000)
         'message (maps:get 'message opts "Hello from LFE")
         'position (map 'latitude_i (trunc (* (maps:get 'lat opts 0) 10000000))
                        'longitude_i (trunc (* (maps:get 'lon opts 0) 10000000))
                        'altitude (round (maps:get 'alt opts 0))))))

(defun send-all (conn bot)
  (let ((pause (maps:get 'pause bot)))
    (send-node-info conn bot)
    (timer:sleep pause)
    (send-position conn bot)
    (timer:sleep pause)
    (send-message conn bot)
    (timer:sleep pause)))

(defun send-node-info (conn bot)
  (io:format "Sending NodeInfo Packet to ~p~n" (list (broadcast)))
  (let ((user (map 'id (mtc:node_id (maps:get 'node bot))
                   'long_name #"Bottastic"
                   'short_name #"BOT"
                   'hw_model 'PRIVATE_HW)))
    (publish conn bot 'NODEINFO_APP (mtc:encode user 'user))))

(defun send-position (conn bot)
  (io:format "Sending Position Packet to ~p~n" (list (broadcast)))
  (let ((pos (maps:put 'time (erlang:system_time 'second) (maps:get 'position bot))))
    (publish conn bot 'POSITION_APP (mtc:encode pos 'position))))

(defun send-message (conn bot)
  (io:format "Sending Text Message Packet to ~p~n" (list (broadcast)))
  (publish conn bot 'TEXT_MESSAGE_APP
           (unicode:characters_to_binary (maps:get 'message bot))))

;; generate_mesh_packet(): Data -> encrypted MeshPacket -> ServiceEnvelope
;; bitfield 1: the sender is OK with the packet going to MQTT
(defun publish (conn bot port payload)
  (let* ((node (maps:get 'node bot))
         (channel (maps:get 'channel_name bot))
         (data (map 'portnum port 'payload payload 'bitfield 1))
         (packet (mtq:packet data (maps:get 'key bot) node (map 'channel_name channel)))
         (envelope (mtq:envelope packet channel (mtc:node_id node))))
    (mtq:publish conn (maps:get 'topic bot) envelope)))
